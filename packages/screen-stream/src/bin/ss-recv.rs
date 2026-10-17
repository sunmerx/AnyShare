//! ss-recv: UDP receiver — reassembles AUs and writes Annex-B to stdout.
//! Usage: ss-recv [--port N] [--seconds N]
//! Example: ss-recv | ffplay -f h264 -

use std::io::Write;
use std::net::UdpSocket;
use std::time::{Duration, Instant};

use screen_stream::transport::{Delivered, Packet, Reassembler};

fn main() {
    if let Err(e) = run() {
        eprintln!("ss-recv: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    fn next_value(args: &[String], i: &mut usize, name: &str) -> anyhow::Result<String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing value for {name}"))
    }

    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let mut port: u16 = 53320;
    let mut seconds: u64 = 0;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--port" => {
                let raw = next_value(&args, &mut i, "--port")?;
                port = raw.parse().map_err(|_| anyhow::anyhow!("invalid --port {raw:?}"))?;
            }
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw.parse().map_err(|_| anyhow::anyhow!("invalid --seconds {raw:?}"))?;
            }
            other => anyhow::bail!("unknown argument {other:?} (usage: ss-recv [--port N] [--seconds N])"),
        }
        i += 1;
    }

    let socket = UdpSocket::bind(("0.0.0.0", port))?;
    socket.set_read_timeout(Some(Duration::from_millis(50)))?;
    eprintln!("ss-recv: listening on udp/{port}, writing Annex-B to stdout");

    let mut reassembler = Reassembler::new();
    let mut buffer = vec![0u8; 65536];
    let mut stdout = std::io::stdout().lock();
    let started = Instant::now();
    let mut last_stats = Instant::now();
    let mut bytes_out: u64 = 0;

    loop {
        let now = Instant::now();
        if seconds > 0 && started.elapsed() >= Duration::from_secs(seconds) {
            break;
        }
        match socket.recv_from(&mut buffer) {
            Ok((len, _)) => {
                if let Some(packet) = Packet::decode(&buffer[..len]) {
                    let delivered = reassembler.ingest(&packet, now);
                    bytes_out += write_delivered(&mut stdout, delivered)?;
                }
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                let delivered = reassembler.poll(now);
                bytes_out += write_delivered(&mut stdout, delivered)?;
            }
            Err(e) => return Err(e).map_err(|e| anyhow::anyhow!("recv_from failed: {e}")),
        }

        if last_stats.elapsed() >= Duration::from_secs(1) {
            let stats = reassembler.stats();
            eprintln!(
                "t={:>3}s delivered={} recovered={} lost={} dup={} stale={} invalid={} foreign={} out={:.2} MiB",
                started.elapsed().as_secs(),
                stats.delivered,
                stats.recovered_frames,
                stats.lost_frames,
                stats.duplicate_packets,
                stats.stale_packets,
                stats.invalid_packets,
                stats.foreign_session_packets,
                bytes_out as f64 / 1048576.0
            );
            last_stats = Instant::now();
        }
    }

    let stats = reassembler.stats();
    eprintln!(
        "summary: delivered={} recovered={} lost={} dup={} stale={} invalid={} out={:.2} MiB",
        stats.delivered,
        stats.recovered_frames,
        stats.lost_frames,
        stats.duplicate_packets,
        stats.stale_packets,
        stats.invalid_packets,
        bytes_out as f64 / 1048576.0
    );
    Ok(())
}

fn write_delivered(stdout: &mut impl Write, delivered: Vec<Delivered>) -> anyhow::Result<u64> {
    let mut written = 0u64;
    for frame in delivered {
        stdout.write_all(&frame.payload)?;
        written += frame.payload.len() as u64;
    }
    if written > 0 {
        stdout.flush()?;
    }
    Ok(written)
}
