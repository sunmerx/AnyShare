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

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.extend_from_slice(&MAGIC.to_le_bytes());
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.push(self.flags);
        out.push(0);
        out.extend_from_slice(&self.session.to_le_bytes());
        out.extend_from_slice(&self.frame_id.to_le_bytes());
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.count.to_le_bytes());
        out.extend_from_slice(&self.timestamp_100ns.to_le_bytes());
        out.extend_from_slice(&(self.payload.len() as u16).to_le_bytes());
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
    /// Only frames that stopped making progress ([NACK_GRACE]) are reported:
    /// empty slots while packets are still in flight are not losses.
    pub fn missing_candidates(&self, now: Instant) -> Vec<(u32, u16, Vec<usize>)> {
        self.pending
            .iter()
            .take(4)
            .filter_map(|(&frame_id, frame)| {
                if now.duration_since(frame.last_progress) < NACK_GRACE {
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

fn index_before(a: u32, b: u32) -> bool {
    b.wrapping_sub(a) < u32::MAX / 2 && a != b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> Instant {
        Instant::now()
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
