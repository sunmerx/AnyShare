//! Platform-independent transport: UDP packetization, XOR FEC, reassembly.
//! Protocol v1 — see docs/E2-S0/Step5-设计-传输层.md.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

pub const MAGIC: u32 = 0x3153_3245;
pub const VERSION: u16 = 1;
pub const HEADER_LEN: usize = 30;
pub const DEFAULT_PAYLOAD: usize = 1200;
pub const FEC_BLOCK: usize = 8;
pub const FRAME_TIMEOUT: Duration = Duration::from_millis(300);
/// A different session id is accepted (stream restart / reconnect) after this
/// much silence from the current session.
pub const SESSION_IDLE_RESET: Duration = Duration::from_secs(2);
/// Reject frames claiming more data packets than this (untrusted input bound).
pub const MAX_PACKETS_PER_FRAME: usize = 4096;
/// Parity packets prefix their XOR data with the AU's total byte length.
pub const PARITY_LEN_PREFIX: usize = 4;

pub const FLAG_KEYFRAME: u8 = 0x01;
pub const FLAG_DISCONTINUITY: u8 = 0x02;
pub const FLAG_HEADER: u8 = 0x04;
pub const FLAG_FEC: u8 = 0x08;
/// Receiver -> sender selective retransmission request (same Packet framing,
/// payload = bitmask over the frame's data-packet indices).
pub const FLAG_NACK: u8 = 0x10;
/// Total NACK attempts per frame before giving up and waiting for the 300 ms
/// frame timeout / keyframe request.
pub const NACK_ATTEMPTS: u8 = 2;
/// Minimum spacing between NACK attempts for the same frame.
pub const NACK_RETRY_INTERVAL: Duration = Duration::from_millis(8);
/// A frame only becomes a NACK candidate after this much time without packet
/// progress: packets of one frame arrive over several milliseconds, so empty
/// slots while packets are still in flight are NOT losses.
pub const NACK_GRACE: Duration = Duration::from_millis(40);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Packet {
    pub session: u32,
    pub frame_id: u32,
    pub seq: u16,
    pub count: u16,
    pub flags: u8,
    pub timestamp_100ns: u64,
    pub payload: Vec<u8>,
}

impl Packet {
    pub fn is_fec(&self) -> bool {
        self.flags & FLAG_FEC != 0
    }

    /// The fixed 30-byte header, without the payload.
    pub fn header_bytes(&self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        out[4..6].copy_from_slice(&VERSION.to_le_bytes());
        out[6] = self.flags;
        out[7] = 0;
        out[8..12].copy_from_slice(&self.session.to_le_bytes());
        out[12..16].copy_from_slice(&self.frame_id.to_le_bytes());
        out[16..18].copy_from_slice(&self.seq.to_le_bytes());
        out[18..20].copy_from_slice(&self.count.to_le_bytes());
        out[20..28].copy_from_slice(&self.timestamp_100ns.to_le_bytes());
        out[28..30].copy_from_slice(&(self.payload.len() as u16).to_le_bytes());
        out
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.extend_from_slice(&self.header_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(buffer: &[u8]) -> Option<Packet> {
        if buffer.len() < HEADER_LEN {
            return None;
        }
        if u32::from_le_bytes(buffer[0..4].try_into().ok()?) != MAGIC {
            return None;
        }
        if u16::from_le_bytes(buffer[4..6].try_into().ok()?) != VERSION {
            return None;
        }
        let flags = buffer[6];
        let session = u32::from_le_bytes(buffer[8..12].try_into().ok()?);
        let frame_id = u32::from_le_bytes(buffer[12..16].try_into().ok()?);
        let seq = u16::from_le_bytes(buffer[16..18].try_into().ok()?);
        let count = u16::from_le_bytes(buffer[18..20].try_into().ok()?);
        let timestamp_100ns = u64::from_le_bytes(buffer[20..28].try_into().ok()?);
        let payload_len = u16::from_le_bytes(buffer[28..30].try_into().ok()?) as usize;
        if buffer.len() < HEADER_LEN + payload_len {
            return None;
        }
        Some(Packet {
            session,
            frame_id,
            seq,
            count,
            flags,
            timestamp_100ns,
            payload: buffer[HEADER_LEN..HEADER_LEN + payload_len].to_vec(),
        })
    }
}

// ---------------------------------------------------------------------------
// Data-plane encryption (AES-256-GCM)
//
// Screen content must never travel as plaintext H.264 over a LAN. The session
// key (32 bytes) is exchanged over the authenticated control plane (the
// existing HTTPS endpoint with mutual certificates), never over this socket.
//
// Only the PAYLOAD is encrypted; the 30-byte header stays readable so packets
// can be routed/sequenced before decryption, and the header bytes (without the
// payload-length field) are authenticated as AAD, so an attacker cannot flip
// session/frame/sequence numbers without the tag check failing.
//
// Nonce = session(4 LE) || frame_id(4 LE) || kind/seq(4 LE)
//   kind/seq = seq                     for data packets
//            = 0x8000_0000 | seq       for FEC parity packets
// Retransmissions repeat a nonce with byte-identical plaintext, which is safe
// for GCM (same nonce + same plaintext = same ciphertext).
// ---------------------------------------------------------------------------

use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};

pub const SESSION_KEY_LEN: usize = 32;
pub const AEAD_TAG_LEN: usize = 16;
/// AAD covers magic..timestamp, excluding the payload-length field.
const AAD_LEN: usize = 28;

pub fn cipher_from_key(key: &[u8]) -> Option<Aes256Gcm> {
    if key.len() != SESSION_KEY_LEN {
        return None;
    }
    Some(Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key)))
}

fn packet_nonce(packet: &Packet) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[0..4].copy_from_slice(&packet.session.to_le_bytes());
    nonce[4..8].copy_from_slice(&packet.frame_id.to_le_bytes());
    let kind_seq = if packet.is_fec() {
        0x8000_0000u32 | u32::from(packet.seq)
    } else {
        u32::from(packet.seq)
    };
    nonce[8..12].copy_from_slice(&kind_seq.to_le_bytes());
    nonce
}

fn aad_of(packet: &Packet) -> [u8; AAD_LEN] {
    let header = packet.header_bytes();
    let mut aad = [0u8; AAD_LEN];
    aad.copy_from_slice(&header[..AAD_LEN]);
    aad
}

/// Encrypts `packet.payload` in place. Returns false when the key is absent.
pub fn seal_packet(cipher: &Aes256Gcm, packet: &mut Packet) -> bool {
    let aad = aad_of(packet);
    let nonce_bytes = packet_nonce(packet);
    let nonce = Nonce::from_slice(&nonce_bytes);
    match cipher.encrypt_in_place(nonce, &aad, &mut packet.payload) {
        Ok(()) => true,
        Err(_) => false,
    }
}

/// Decrypts `packet.payload` in place. `false` means authentication failed:
/// the caller must drop the packet.
pub fn open_packet(cipher: &Aes256Gcm, packet: &mut Packet) -> bool {
    let aad = aad_of(packet);
    let nonce_bytes = packet_nonce(packet);
    let nonce = Nonce::from_slice(&nonce_bytes);
    cipher.decrypt_in_place(nonce, &aad, &mut packet.payload).is_ok()
}

// ---------------------------------------------------------------------------
// Latency probe (clock-offset calibration)
//
// The sender stamps every access unit with its own wall clock (epoch, 100 ns).
// Subtracting that from the receiver's wall clock only yields the true
// one-way latency when both machines share a clock; independent machines are
// routinely hundreds of milliseconds apart. The receiver therefore probes the
// sender over the same UDP socket:
//
//   receiver -> sender : PING  {nonce, t1}
//   sender  -> receiver: PONG  {nonce, t1, t2, t3}
//
// t1/t4 are the receiver's clock, t2/t3 the sender's. Assuming symmetric path
// delay, offset = ((t2 - t1) + (t3 - t4)) / 2 is the sender clock minus the
// receiver clock, and rtt = (t4 - t1) - (t3 - t2).
// ---------------------------------------------------------------------------

pub const LAT_PING_MAGIC: &[u8; 8] = b"ANYSLAT1";
pub const LAT_PONG_MAGIC: &[u8; 8] = b"ANYSLAT2";
/// PING: magic(8) + nonce(8) + t1(8); PONG: magic(8) + nonce(8) + t1(8) + t2(8) + t3(8).
pub const LAT_PING_LEN: usize = 24;
pub const LAT_PONG_LEN: usize = 40;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LatPing {
    pub nonce: u64,
    pub t1_us: u64,
}

impl LatPing {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(LAT_PING_LEN);
        out.extend_from_slice(LAT_PING_MAGIC);
        out.extend_from_slice(&self.nonce.to_le_bytes());
        out.extend_from_slice(&self.t1_us.to_le_bytes());
        out
    }

    pub fn decode(buffer: &[u8]) -> Option<LatPing> {
        if buffer.len() != LAT_PING_LEN || &buffer[..8] != LAT_PING_MAGIC {
            return None;
        }
        Some(LatPing {
            nonce: u64::from_le_bytes(buffer[8..16].try_into().ok()?),
            t1_us: u64::from_le_bytes(buffer[16..24].try_into().ok()?),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LatPong {
    pub nonce: u64,
    pub t1_us: u64,
    pub t2_us: u64,
    pub t3_us: u64,
}

impl LatPong {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(LAT_PONG_LEN);
        out.extend_from_slice(LAT_PONG_MAGIC);
        out.extend_from_slice(&self.nonce.to_le_bytes());
        out.extend_from_slice(&self.t1_us.to_le_bytes());
        out.extend_from_slice(&self.t2_us.to_le_bytes());
        out.extend_from_slice(&self.t3_us.to_le_bytes());
        out
    }

    pub fn decode(buffer: &[u8]) -> Option<LatPong> {
        if buffer.len() != LAT_PONG_LEN || &buffer[..8] != LAT_PONG_MAGIC {
            return None;
        }
        Some(LatPong {
            nonce: u64::from_le_bytes(buffer[8..16].try_into().ok()?),
            t1_us: u64::from_le_bytes(buffer[16..24].try_into().ok()?),
            t2_us: u64::from_le_bytes(buffer[24..32].try_into().ok()?),
            t3_us: u64::from_le_bytes(buffer[32..40].try_into().ok()?),
        })
    }
}

/// Clock offset (sender minus receiver, microseconds) and round-trip time.
pub fn clock_offset_us(t1_us: u64, t2_us: u64, t3_us: u64, t4_us: u64) -> (i64, u64) {
    let rtt = t4_us.saturating_sub(t1_us).saturating_sub(t3_us.saturating_sub(t2_us));
    let forward = t2_us as i64 - t1_us as i64;
    let backward = t3_us as i64 - t4_us as i64;
    ((forward + backward) / 2, rtt)
}

/// A selective retransmission request for one frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Nack {
    pub session: u32,
    pub frame_id: u32,
    pub count: u16,
    pub missing: Vec<usize>,
}

impl Nack {
    pub fn encode(&self) -> Vec<u8> {
        let bytes = (self.count as usize).div_ceil(8).max(1);
        let mut bitmask = vec![0u8; bytes];
        for &index in &self.missing {
            if index < self.count as usize {
                bitmask[index / 8] |= 1 << (index % 8);
            }
        }
        Packet {
            session: self.session,
            frame_id: self.frame_id,
            seq: 0,
            count: self.count,
            flags: FLAG_NACK,
            timestamp_100ns: 0,
            payload: bitmask,
        }
        .encode()
    }

    pub fn from_packet(packet: &Packet) -> Option<Nack> {
        if packet.flags & FLAG_NACK == 0 || packet.count == 0 {
            return None;
        }
        let expected = (packet.count as usize).div_ceil(8).max(1);
        if packet.payload.len() != expected {
            return None;
        }
        let mut missing = Vec::new();
        for index in 0..packet.count as usize {
            if packet.payload[index / 8] & (1 << (index % 8)) != 0 {
                missing.push(index);
            }
        }
        if missing.is_empty() {
            return None;
        }
        Some(Nack {
            session: packet.session,
            frame_id: packet.frame_id,
            count: packet.count,
            missing,
        })
    }
}

/// Ring buffer of recently sent frames (encoded data packets only) used to
/// answer NACKs. Bounded by frame count; ~48 frames is a couple of MB at
/// typical streaming bitrates.
pub struct PacketHistory {
    frames: std::collections::VecDeque<(u32, Vec<Vec<u8>>)>,
    capacity: usize,
}

impl PacketHistory {
    pub fn new(capacity: usize) -> Self {
        Self {
            frames: std::collections::VecDeque::new(),
            capacity: capacity.max(1),
        }
    }

    pub fn push(&mut self, frame_id: u32, packets: Vec<Vec<u8>>) {
        if self.frames.len() == self.capacity {
            self.frames.pop_front();
        }
        self.frames.push_back((frame_id, packets));
    }

    pub fn get(&self, frame_id: u32) -> Option<&Vec<Vec<u8>>> {
        self.frames.iter().find(|(id, _)| *id == frame_id).map(|(_, packets)| packets)
    }

    pub fn len(&self) -> usize {
        self.frames.len()
    }
}

/// Splits one access unit into data packets plus per-block XOR parity packets.
pub fn packetize(
    session: u32,
    frame_id: u32,
    flags: u8,
    timestamp_100ns: u64,
    payload: &[u8],
) -> Vec<Packet> {
    let chunk_size = DEFAULT_PAYLOAD;
    let data_count = payload.len().max(1).div_ceil(chunk_size);
    // Nonce domain separation reserves 0x8000_0000 for FEC parity packets; a
    // data-only payload can never reach 32768 packets (the encoder's output
    // capacity is 8 MiB ≈ 7000 packets), so this guard only catches bugs.
    assert!(data_count <= 0x7fff, "access unit too large for the nonce layout");
    let mut packets = Vec::with_capacity(data_count + data_count.div_ceil(FEC_BLOCK));

    for index in 0..data_count {
        let start = index * chunk_size;
        let end = (start + chunk_size).min(payload.len());
        packets.push(Packet {
            session,
            frame_id,
            seq: index as u16,
            count: data_count as u16,
            flags,
            timestamp_100ns,
            payload: payload[start..end].to_vec(),
        });
    }

    for (block_index, block) in (0..data_count).step_by(FEC_BLOCK).enumerate() {
        let block_end = (block + FEC_BLOCK).min(data_count);
        let block_packets = &packets[block..block_end];
        let max_len = block_packets.iter().map(|p| p.payload.len()).max().unwrap_or(0);
        let mut parity = vec![0u8; PARITY_LEN_PREFIX + max_len];
        parity[..PARITY_LEN_PREFIX].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        for packet in block_packets {
            for (i, byte) in packet.payload.iter().enumerate() {
                parity[PARITY_LEN_PREFIX + i] ^= byte;
            }
        }
        packets.push(Packet {
            session,
            frame_id,
            seq: block_index as u16,
            count: data_count as u16,
            flags: flags | FLAG_FEC,
            timestamp_100ns,
            payload: parity,
        });
    }

    packets
}

struct FrameBuf {
    flags: u8,
    timestamp_100ns: u64,
    count: usize,
    first_seen: Instant,
    last_progress: Instant,
    data: Vec<Option<Vec<u8>>>,
    parity: BTreeMap<usize, Vec<u8>>,
    received: usize,
}

impl FrameBuf {
    fn new(packet: &Packet, now: Instant) -> Self {
        let count = packet.count as usize;
        Self {
            flags: packet.flags & !FLAG_FEC,
            timestamp_100ns: packet.timestamp_100ns,
            count,
            first_seen: now,
            last_progress: now,
            data: vec![None; count],
            parity: BTreeMap::new(),
            received: 0,
        }
    }

    /// Returns `Some(recovered)` when the frame is complete (`recovered` tells
    /// whether FEC reconstructed a lost packet), `None` while still incomplete.
    fn complete_or_recover(&mut self) -> Option<bool> {
        if self.received == self.count {
            return Some(false);
        }
        let mut missing = Vec::new();
        for (index, slot) in self.data.iter().enumerate() {
            if slot.is_none() {
                missing.push(index);
            }
        }
        if missing.len() != 1 {
            return None;
        }
        let missing_index = missing[0];
        let block_start = (missing_index / FEC_BLOCK) * FEC_BLOCK;
        let block_end = (block_start + FEC_BLOCK).min(self.count);
        let block_index = missing_index / FEC_BLOCK;
        let parity = self.parity.get(&block_index)?;
        if parity.len() < PARITY_LEN_PREFIX {
            return None;
        }
        let total_len = u32::from_le_bytes(parity[..PARITY_LEN_PREFIX].try_into().ok()?) as usize;
        let mut recovered = parity[PARITY_LEN_PREFIX..].to_vec();
        for index in block_start..block_end {
            if index == missing_index {
                continue;
            }
            let Some(payload) = &self.data[index] else {
                return None;
            };
            if payload.len() > recovered.len() {
                recovered.resize(payload.len(), 0);
            }
            for (i, byte) in payload.iter().enumerate() {
                recovered[i] ^= byte;
            }
        }
        let chunk_size = DEFAULT_PAYLOAD;
        let expected_len = if missing_index == self.count - 1 {
            total_len.saturating_sub(missing_index * chunk_size)
        } else {
            chunk_size
        };
        recovered.truncate(expected_len.min(recovered.len()));
        self.data[missing_index] = Some(recovered);
        self.received += 1;
        Some(true)
    }

    fn assemble(&mut self) -> Vec<u8> {
        self.data
            .iter_mut()
            .flat_map(|slot| slot.take().unwrap_or_default())
            .collect()
    }
}

#[derive(Clone, Debug)]
pub struct Delivered {
    pub frame_id: u32,
    pub flags: u8,
    pub timestamp_100ns: u64,
    pub payload: Vec<u8>,
    /// When this completed frame entered the reorder buffer (used for gap timeouts).
    pub ready_since: Instant,
    /// When the frame's packets were fully received (latency diagnostics).
    pub received_at: Instant,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReassemblerStats {
    pub delivered: u64,
    pub recovered_frames: u64,
    pub lost_frames: u64,
    pub duplicate_packets: u64,
    pub stale_packets: u64,
    pub invalid_packets: u64,
    pub foreign_session_packets: u64,
}

pub struct Reassembler {
    session: Option<u32>,
    next_expected: u32,
    /// Highest frame id seen; a pending frame older than this is provably not
    /// in flight anymore (fast-retransmit rule, like TCP's triple-ACK).
    max_frame_seen: u32,
    pending: BTreeMap<u32, FrameBuf>,
    ready: Vec<Delivered>,
    last_ingest: Option<Instant>,
    stats: ReassemblerStats,
}

impl Default for Reassembler {
    fn default() -> Self {
        Self::new()
    }
}

impl Reassembler {
    pub fn new() -> Self {
        Self {
            session: None,
            next_expected: 0,
            max_frame_seen: 0,
            pending: BTreeMap::new(),
            ready: Vec::new(),
            last_ingest: None,
            stats: ReassemblerStats::default(),
        }
    }

    pub fn stats(&self) -> ReassemblerStats {
        self.stats
    }

    /// Session id learned from the first data packet (for NACK framing).
    pub fn session(&self) -> Option<u32> {
        self.session
    }

    /// Data-packet indices still missing for the oldest pending frames.
    ///
    /// A frame is reported when either
    /// - it stopped making progress for [NACK_GRACE] (safe fallback), or
    /// - a NEWER frame has already been seen (fast retransmit): packets of the
    ///   older frame are no longer in flight, so waiting is pure latency.
    pub fn missing_candidates(&self, now: Instant) -> Vec<(u32, u16, Vec<usize>)> {
        self.pending
            .iter()
            .filter_map(|(&frame_id, frame)| {
                // Fast retransmit with a triple-ACK-like margin: only when the
                // sender demonstrably moved 2+ frames ahead. One frame ahead can
                // simply mean reordered packets still in flight.
                let ahead = self.max_frame_seen.wrapping_sub(frame_id);
                let overtaken = ahead >= 2 && ahead < u32::MAX / 2;
                if !overtaken && now.duration_since(frame.last_progress) < NACK_GRACE {
                    return None;
                }
                let missing: Vec<usize> = (0..frame.count).filter(|&index| frame.data[index].is_none()).collect();
                if missing.is_empty() {
                    None
                } else {
                    Some((frame_id, frame.count as u16, missing))
                }
            })
            .collect()
    }

    pub fn ingest(&mut self, packet: &Packet, now: Instant) -> Vec<Delivered> {
        if let Some(session) = self.session {
            if session != packet.session {
                let idle = self
                    .last_ingest
                    .map(|last| now.duration_since(last) >= SESSION_IDLE_RESET)
                    .unwrap_or(true);
                if !idle {
                    self.stats.foreign_session_packets += 1;
                    return Vec::new();
                }
                self.session = None;
                self.next_expected = 0;
                self.pending.clear();
                self.ready.clear();
            }
        }
        if self.session.is_none() && packet.flags & FLAG_FEC == 0 && packet.count > 0 {
            self.session = Some(packet.session);
            self.next_expected = packet.frame_id;
            // A new session restarts frame ids: the old high-water mark must not
            // mark every fresh frame as overtaken (that would disable the grace
            // window right after a sender restart).
            self.max_frame_seen = packet.frame_id;
        }
        let Some(session) = self.session else {
            return Vec::new();
        };
        if packet.session != session {
            return Vec::new();
        }
        self.last_ingest = Some(now);

        if index_before(packet.frame_id, self.next_expected) {
            // Late FEC parity packets of already-delivered frames land here by
            // design (delivery completes on data packets); data-packet dupes
            // after a NACK race are counted the same way.
            self.stats.stale_packets += 1;
            return Vec::new();
        }
        let count = packet.count as usize;
        if count == 0 || count > MAX_PACKETS_PER_FRAME {
            self.stats.invalid_packets += 1;
            return Vec::new();
        }
        if packet.is_fec() && packet.seq as usize >= count.div_ceil(FEC_BLOCK) {
            self.stats.invalid_packets += 1;
            return Vec::new();
        }

        // Advancing the high-water mark only after the sanity checks prevents
        // a single corrupted/forged frame id from marking everything as lost.
        if !packet.is_fec() && frame_id_is_ahead(self.max_frame_seen, packet.frame_id) {
            self.max_frame_seen = packet.frame_id;
        }
        let frame = self
            .pending
            .entry(packet.frame_id)
            .or_insert_with(|| FrameBuf::new(packet, now));
        frame.last_progress = now;

        if packet.is_fec() {
            let block_index = packet.seq as usize;
            match frame.parity.entry(block_index) {
                std::collections::btree_map::Entry::Occupied(_) => {
                    self.stats.duplicate_packets += 1;
                }
                std::collections::btree_map::Entry::Vacant(slot) => {
                    slot.insert(packet.payload.clone());
                }
            }
        } else {
            let index = packet.seq as usize;
            if index < frame.count {
                if frame.data[index].is_some() {
                    self.stats.duplicate_packets += 1;
                } else {
                    frame.data[index] = Some(packet.payload.clone());
                    frame.received += 1;
                }
            }
        }

        if let Some(recovered) = frame.complete_or_recover() {
            let mut frame = self.pending.remove(&packet.frame_id).unwrap();
            if recovered {
                self.stats.recovered_frames += 1;
            }
            self.ready.push(Delivered {
                frame_id: packet.frame_id,
                flags: frame.flags,
                timestamp_100ns: frame.timestamp_100ns,
                payload: frame.assemble(),
                ready_since: now,
                received_at: now,
            });
        }

        self.deliver_in_order(now)
    }

    pub fn poll(&mut self, now: Instant) -> Vec<Delivered> {
        self.deliver_in_order(now)
    }

    fn deliver_in_order(&mut self, now: Instant) -> Vec<Delivered> {
        let stale_pending: Vec<u32> = self
            .pending
            .iter()
            .filter(|(id, frame)| {
                now.duration_since(frame.first_seen) >= FRAME_TIMEOUT
                    && (index_before(self.next_expected, **id) || index_before(**id, self.next_expected))
            })
            .map(|(id, _)| *id)
            .collect();
        for id in stale_pending {
            self.pending.remove(&id);
            if index_before(self.next_expected, id) {
                self.stats.lost_frames += 1;
            }
        }

        let mut out = Vec::new();
        loop {
            let next = self.next_expected;
            if let Some(pos) = self.ready.iter().position(|d| d.frame_id == next) {
                let frame = self.ready.remove(pos);
                self.next_expected = next.wrapping_add(1);
                self.stats.delivered += 1;
                out.push(frame);
                continue;
            }
            match self.pending.get(&next) {
                Some(frame) => {
                    if now.duration_since(frame.first_seen) >= FRAME_TIMEOUT {
                        self.pending.remove(&next);
                        self.stats.lost_frames += 1;
                        self.next_expected = next.wrapping_add(1);
                        continue;
                    }
                    break;
                }
                None => {
                    let later_ready_timed_out = self
                        .ready
                        .iter()
                        .filter(|d| index_before(next, d.frame_id))
                        .any(|d| now.duration_since(d.ready_since) >= FRAME_TIMEOUT);
                    if later_ready_timed_out {
                        self.stats.lost_frames += 1;
                        self.next_expected = next.wrapping_add(1);
                        continue;
                    }
                    break;
                }
            }
        }
        out
    }
}

/// True when `candidate` is strictly ahead of `reference` (wrap-safe).
fn frame_id_is_ahead(reference: u32, candidate: u32) -> bool {
    candidate != reference && candidate.wrapping_sub(reference) < u32::MAX / 2
}
fn index_before(a: u32, b: u32) -> bool {
    b.wrapping_sub(a) < u32::MAX / 2 && a != b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> Instant {
        Instant::now()
    }

    fn test_key() -> [u8; 32] {
        [7u8; 32]
    }

    #[test]
    fn sealed_payload_roundtrips_and_detects_tampering() {
        let cipher = cipher_from_key(&test_key()).unwrap();
        let mut packet = Packet {
            session: 9,
            frame_id: 3,
            seq: 1,
            count: 2,
            flags: FLAG_KEYFRAME,
            timestamp_100ns: 42,
            payload: b"screen content".to_vec(),
        };
        assert!(seal_packet(&cipher, &mut packet), "sealing must succeed");
        assert_ne!(packet.payload, b"screen content".to_vec(), "payload is encrypted");
        assert_eq!(packet.payload.len(), 14 + AEAD_TAG_LEN);

        // Wire round trip then decrypt.
        let mut received = Packet::decode(&packet.encode()).unwrap();
        assert!(open_packet(&cipher, &mut received));
        assert_eq!(received.payload, b"screen content".to_vec());

        // Tampered ciphertext must fail authentication.
        let mut tampered = Packet::decode(&packet.encode()).unwrap();
        tampered.payload[0] ^= 0xff;
        assert!(!open_packet(&cipher, &mut tampered));

        // Tampered header (frame id) must also fail: the header is AAD.
        let mut shifted = Packet::decode(&packet.encode()).unwrap();
        shifted.frame_id += 1;
        assert!(!open_packet(&cipher, &mut shifted), "header is authenticated");

        // A different key cannot decrypt.
        let other = cipher_from_key(&[8u8; 32]).unwrap();
        let mut foreign = Packet::decode(&packet.encode()).unwrap();
        assert!(!open_packet(&other, &mut foreign));

        assert!(cipher_from_key(&[0u8; 31]).is_none(), "only 32-byte keys");
    }

    #[test]
    fn nonce_differs_for_data_parity_and_frames() {
        let base = Packet {
            session: 1,
            frame_id: 2,
            seq: 3,
            count: 4,
            flags: 0,
            timestamp_100ns: 0,
            payload: vec![],
        };
        let data = packet_nonce(&base);
        let parity = packet_nonce(&Packet { flags: FLAG_FEC, ..base.clone() });
        let other_frame = packet_nonce(&Packet { frame_id: 3, ..base.clone() });
        assert_ne!(data, parity);
        assert_ne!(data, other_frame);
    }
    #[test]
    fn latency_probe_roundtrip() {
        let ping = LatPing {
            nonce: 42,
            t1_us: 1_000_000,
        };
        assert_eq!(LatPing::decode(&ping.encode()), Some(ping));
        assert!(LatPing::decode(b"nope").is_none());
        // A data packet must never decode as a probe.
        let packet = packetize(1, 1, 0, 0, &[0u8; 10]);
        assert!(LatPing::decode(&packet[0].encode()).is_none());

        let pong = LatPong {
            nonce: 42,
            t1_us: 1_000_000,
            t2_us: 1_000_030,
            t3_us: 1_000_030,
        };
        assert_eq!(LatPong::decode(&pong.encode()), Some(pong));
    }

    #[test]
    fn clock_offset_handles_symmetric_and_skewed_clocks() {
        // Same clock, 30 us one way: no offset, 60 us RTT.
        let (offset, rtt) = clock_offset_us(1_000_000, 1_000_030, 1_000_030, 1_000_060);
        assert_eq!(offset, 0);
        assert_eq!(rtt, 60);

        // Sender clock 5 s ahead. True offset must be recovered regardless of
        // the (symmetric) path delay.
        let sender_ahead = 5_000_000i64;
        let t1 = 10_000_000u64;
        let d = 250u64;
        let t2 = (t1 as i64 + d as i64 + sender_ahead) as u64;
        let t3 = t2;
        let t4 = t1 + 2 * d;
        let (offset, rtt) = clock_offset_us(t1, t2, t3, t4);
        assert_eq!(offset, sender_ahead as i64);
        assert_eq!(rtt, 2 * d);
    }
    #[test]
    fn packet_roundtrip() {
        let packet = Packet {
            session: 42,
            frame_id: 7,
            seq: 3,
            count: 10,
            flags: FLAG_KEYFRAME | FLAG_DISCONTINUITY,
            timestamp_100ns: 123456789,
            payload: vec![1, 2, 3, 4],
        };
        let bytes = packet.encode();
        let decoded = Packet::decode(&bytes).unwrap();
        assert_eq!(decoded, packet);
    }

    #[test]
    fn packetize_splits_and_creates_parity() {
        let payload = vec![0xAB; DEFAULT_PAYLOAD * 2 + 10];
        let packets = packetize(1, 1, FLAG_KEYFRAME, 100, &payload);
        let data: Vec<_> = packets.iter().filter(|p| !p.is_fec()).collect();
        let parity: Vec<_> = packets.iter().filter(|p| p.is_fec()).collect();
        assert_eq!(data.len(), 3);
        assert_eq!(parity.len(), 1);
        assert_eq!(data[0].count, 3);
    }

    #[test]
    fn fec_recovers_single_loss() {
        let payload: Vec<u8> = (0..DEFAULT_PAYLOAD * 3).map(|i| (i % 251) as u8).collect();
        let packets = packetize(9, 1, FLAG_KEYFRAME, 0, &payload);
        let mut receiver = Reassembler::new();
        let t = now();
        let mut delivered = Vec::new();
        let mut dropped_once = false;
        for packet in &packets {
            if !packet.is_fec() && packet.seq == 1 && !dropped_once {
                dropped_once = true;
                continue;
            }
            delivered.extend(receiver.ingest(packet, t));
        }
        assert_eq!(delivered.len(), 1);
        assert_eq!(delivered[0].payload, payload);
    }

    #[test]
    fn fec_gives_up_on_double_loss() {
        let payload: Vec<u8> = (0..DEFAULT_PAYLOAD * 3).map(|i| (i % 251) as u8).collect();
        let packets = packetize(9, 5, FLAG_KEYFRAME, 0, &payload);
        let mut receiver = Reassembler::new();
        let t = now();
        let mut delivered = Vec::new();
        for packet in &packets {
            if !packet.is_fec() && (packet.seq == 1 || packet.seq == 2) {
                continue;
            }
            delivered.extend(receiver.ingest(packet, t));
        }
        assert!(delivered.is_empty());
        let _ = receiver.poll(t);
    }

    #[test]
    fn gap_fill_delivers_in_sequence() {
        let mut receiver = Reassembler::new();
        let t = now();
        let frame1 = packetize(4, 1, FLAG_KEYFRAME, 1, &[1u8; 100]);
        let frame2 = packetize(4, 2, 0, 2, &[2u8; 100]);
        let frame3 = packetize(4, 3, 0, 3, &[3u8; 100]);

        let mut delivered = Vec::new();
        for packet in &frame1 {
            delivered.extend(receiver.ingest(packet, t));
        }
        for packet in &frame3 {
            delivered.extend(receiver.ingest(packet, t));
        }
        assert_eq!(delivered.iter().map(|d| d.frame_id).collect::<Vec<_>>(), vec![1]);

        for packet in &frame2 {
            delivered.extend(receiver.ingest(packet, t));
        }
        assert_eq!(delivered.iter().map(|d| d.frame_id).collect::<Vec<_>>(), vec![1, 2, 3]);
    }

    #[test]
    fn new_session_accepted_after_idle() {
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in packetize(1, 1, 0, 0, &[1u8; 100]) {
            let _ = receiver.ingest(&packet, t);
        }
        let second = packetize(2, 1, 0, 0, &[2u8; 100]);
        let mut delivered = receiver.ingest(&second[0], t + Duration::from_millis(500));
        assert!(delivered.is_empty(), "session change before idle timeout must be rejected");
        assert_eq!(receiver.stats().foreign_session_packets, 1);

        delivered = receiver.ingest(&second[0], t + SESSION_IDLE_RESET + Duration::from_millis(100));
        for packet in &second[1..] {
            delivered.extend(receiver.ingest(packet, t + SESSION_IDLE_RESET + Duration::from_millis(100)));
        }
        assert_eq!(delivered.iter().map(|d| d.frame_id).collect::<Vec<_>>(), vec![1]);
        assert_eq!(delivered[0].payload, vec![2u8; 100]);
    }

    #[test]
    fn short_chunk_recovery_is_exact() {
        let payload: Vec<u8> = (0..DEFAULT_PAYLOAD + 100).map(|i| (i % 199) as u8).collect();
        let packets = packetize(3, 1, FLAG_KEYFRAME, 0, &payload);
        let mut receiver = Reassembler::new();
        let t = now();
        let mut delivered = Vec::new();
        for packet in &packets {
            if !packet.is_fec() && packet.seq == 1 {
                continue;
            }
            delivered.extend(receiver.ingest(packet, t));
        }
        assert_eq!(delivered.len(), 1);
        assert_eq!(delivered[0].payload, payload, "recovered short chunk must not gain trailing zeros");
        assert_eq!(receiver.stats().recovered_frames, 1);
    }

    #[test]
    fn stale_parity_after_completion_is_dropped() {
        let mut receiver = Reassembler::new();
        let t = now();
        let packets = packetize(5, 1, 0, 0, &[1u8; 100]);
        for packet in &packets {
            let _ = receiver.ingest(packet, t);
        }
        let parity = packets.iter().find(|p| p.is_fec()).unwrap();
        let delivered = receiver.ingest(parity, t);
        assert!(delivered.is_empty());
        assert_eq!(
            receiver.stats().stale_packets, 2,
            "parity arriving after completion (loop + re-ingest) must both be dropped as stale"
        );
        assert!(receiver.pending.is_empty(), "no zombie entries after completion");
        assert!(receiver.ready.is_empty());
    }

    #[test]
    fn ready_timeout_skips_missing_frame() {
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in packetize(6, 1, 0, 0, &[1u8; 100]) {
            let _ = receiver.ingest(&packet, t);
        }
        for packet in packetize(6, 3, 0, 0, &[3u8; 100]) {
            let _ = receiver.ingest(&packet, t);
        }
        assert!(receiver.poll(t).is_empty(), "frame 3 must wait while frame 2 could still arrive");
        let later = t + FRAME_TIMEOUT + Duration::from_millis(1);
        let delivered = receiver.poll(later);
        assert_eq!(delivered.iter().map(|d| d.frame_id).collect::<Vec<_>>(), vec![3]);
        assert_eq!(receiver.stats().lost_frames, 1);
    }

    #[test]
    fn lost_frame_times_out_and_does_not_block() {
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in packetize(8, 1, 0, 0, &[1u8; 100]) {
            let _ = receiver.ingest(&packet, t);
        }
        assert_eq!(receiver.next_expected, 2);

        let frame2: Vec<Packet> = packetize(8, 2, 0, 0, &vec![2u8; DEFAULT_PAYLOAD * 2]);
        for packet in frame2.iter().filter(|p| !p.is_fec()) {
            if packet.seq == 0 {
                continue;
            }
            let _ = receiver.ingest(packet, t);
        }

        let frame3 = packetize(8, 3, 0, 0, &[3u8; 100]);
        let mut delivered = Vec::new();
        for packet in &frame3 {
            delivered.extend(receiver.ingest(packet, t));
        }
        assert!(delivered.is_empty(), "frame 3 must wait for frame 2 resolution");

        let later = t + FRAME_TIMEOUT + Duration::from_millis(1);
        let mut more = receiver.poll(later);
        delivered.append(&mut more);
        let ids: Vec<u32> = delivered.iter().map(|d| d.frame_id).collect();
        assert_eq!(ids, vec![3]);
        assert_eq!(receiver.stats().lost_frames, 1);
    }

    #[test]
    fn nack_roundtrip_bits() {
        let nack = Nack {
            session: 5,
            frame_id: 9,
            count: 11,
            missing: vec![0, 3, 10],
        };
        let bytes = nack.encode();
        let packet = Packet::decode(&bytes).unwrap();
        assert_eq!(packet.flags & FLAG_NACK, FLAG_NACK);
        assert_eq!(Nack::from_packet(&packet).unwrap(), nack);
        // A NACK without any set bit is rejected.
        let empty = Nack {
            session: 5,
            frame_id: 9,
            count: 11,
            missing: vec![],
        };
        assert!(Nack::from_packet(&Packet::decode(&empty.encode()).unwrap()).is_none());
    }

    #[test]
    fn missing_candidates_reports_gap() {
        let packets = packetize(3, 7, 0, 0, &vec![0x5A; DEFAULT_PAYLOAD * 3]);
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in packets.iter().filter(|p| !p.is_fec() && p.seq != 1) {
            let _ = receiver.ingest(packet, t);
        }
        // Packets may still be in flight: no candidate before the grace.
        assert!(receiver.missing_candidates(t + Duration::from_millis(1)).is_empty());
        let after_grace = t + NACK_GRACE + Duration::from_millis(1);
        let candidates = receiver.missing_candidates(after_grace);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].0, 7);
        assert_eq!(candidates[0].1, packets.iter().filter(|p| !p.is_fec()).count() as u16);
        assert_eq!(candidates[0].2, vec![1]);
    }

    #[test]
    fn fast_retransmit_needs_two_frames_ahead() {
        // Frame 7 is missing one packet. One newer frame (8) may just be
        // reordered packets, so nothing is requested before the grace window.
        // Once the sender demonstrably moved two frames ahead (9), frame 7's
        // missing packet is no longer in flight and must be reported at once.
        let frame7 = packetize(3, 7, 0, 0, &vec![0x5A; DEFAULT_PAYLOAD * 3]);
        let frame8 = packetize(3, 8, 0, 0, &vec![0x33; DEFAULT_PAYLOAD]);
        let frame9 = packetize(3, 9, 0, 0, &vec![0x44; DEFAULT_PAYLOAD]);
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in frame7.iter().filter(|p| !p.is_fec() && p.seq != 1) {
            let _ = receiver.ingest(packet, t);
        }
        assert!(receiver.missing_candidates(t + Duration::from_millis(1)).is_empty());

        let one_ahead = frame8.iter().find(|p| !p.is_fec()).unwrap();
        let _ = receiver.ingest(one_ahead, t + Duration::from_millis(2));
        assert!(
            receiver.missing_candidates(t + Duration::from_millis(2)).is_empty(),
            "a single newer frame could still be reordering"
        );

        let two_ahead = frame9.iter().find(|p| !p.is_fec()).unwrap();
        let _ = receiver.ingest(two_ahead, t + Duration::from_millis(3));
        let candidates = receiver.missing_candidates(t + Duration::from_millis(3));
        assert_eq!(candidates.len(), 1, "two frames ahead -> fast retransmit");
        assert_eq!(candidates[0].0, 7);
        assert_eq!(candidates[0].2, vec![1]);
    }

    #[test]
    fn session_restart_resets_the_frame_high_water_mark() {
        // Session 1 reaches frame 50, so the high-water mark is 50. A new
        // session starts at frame 0 again: its frames must NOT be treated as
        // "overtaken" (that would disable the NACK grace window entirely).
        let mut receiver = Reassembler::new();
        let t = now();
        for packet in packetize(1, 50, 0, 0, &vec![0x01; DEFAULT_PAYLOAD]) {
            let _ = receiver.ingest(&packet, t);
        }
        let restart = t + SESSION_IDLE_RESET + Duration::from_millis(1);
        let frame0 = packetize(2, 0, 0, 0, &vec![0x02; DEFAULT_PAYLOAD * 2]);
        for packet in frame0.iter().filter(|p| !p.is_fec() && p.seq != 1) {
            let _ = receiver.ingest(packet, restart);
        }
        assert!(
            receiver.missing_candidates(restart + Duration::from_millis(1)).is_empty(),
            "fresh session must respect the grace window"
        );
    }
    #[test]
    fn missing_candidates_ignores_stalled_frame_prefix() {
        // Only the first packet of a frame has arrived: every other slot is
        // empty, but nothing may be NACKed while packets can still arrive.
        let packets = packetize(4, 2, 0, 0, &vec![0x11; DEFAULT_PAYLOAD * 4]);
        let mut receiver = Reassembler::new();
        let t = now();
        let first = packets.iter().find(|p| !p.is_fec() && p.seq == 0).unwrap();
        let _ = receiver.ingest(first, t);
        assert!(receiver.missing_candidates(t + Duration::from_millis(5)).is_empty());
        assert_eq!(receiver.missing_candidates(t + NACK_GRACE + Duration::from_millis(1)).len(), 1);
    }

    #[test]
    fn packet_history_evicts_oldest() {
        let mut history = PacketHistory::new(2);
        history.push(1, vec![vec![1]]);
        history.push(2, vec![vec![2]]);
        history.push(3, vec![vec![3]]);
        assert_eq!(history.len(), 2);
        assert!(history.get(1).is_none());
        assert_eq!(history.get(3), Some(&vec![vec![3]]));
    }
}
