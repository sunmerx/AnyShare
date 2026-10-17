//! ss-send: CLI wrapper around the screen-stream sender library (Windows-only).
//! Usage: ss-send [--output <index|name>] [--target IP:PORT] [--bitrate BPS]
//!                [--seconds N] [--timeout-ms N]

fn main() {
    #[cfg(not(windows))]
    {
        eprintln!("ss-send: Windows-only tool (capture/encode layers are Windows for now)");
        std::process::exit(2);
    }

    #[cfg(windows)]
    {
        if let Err(e) = run() {
            eprintln!("ss-send: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    use std::time::{Duration, Instant};

    use screen_stream::events::{EndReason, StreamEvent};
    use screen_stream::sender::{start_sender, SenderConfig};

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
    let mut config = SenderConfig {
        target: "127.0.0.1:53320".to_string(),
        ..SenderConfig::default()
    };
    let mut seconds = 30u64;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--output" => config.output = Some(next_value(&args, &mut i, "--output")?),
            "--target" => config.target = next_value(&args, &mut i, "--target")?,
            "--bitrate" => {
                let raw = next_value(&args, &mut i, "--bitrate")?;
                config.bitrate_bps = raw.parse().map_err(|_| anyhow::anyhow!("invalid --bitrate {raw:?}"))?;
            }
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw.parse().map_err(|_| anyhow::anyhow!("invalid --seconds {raw:?}"))?;
            }
            "--timeout-ms" => {
                let raw = next_value(&args, &mut i, "--timeout-ms")?;
                config.timeout_ms = raw.parse().map_err(|_| anyhow::anyhow!("invalid --timeout-ms {raw:?}"))?;
            }
            other => anyhow::bail!(
                "unknown argument {other:?} (usage: ss-send [--output <index|name>] [--target IP:PORT] [--bitrate BPS] [--seconds N] [--timeout-ms N])"
            ),
        }
        i += 1;
    }

    let (event_tx, event_rx) = std::sync::mpsc::channel::<StreamEvent>();
    // Same semantics as before the refactor: --seconds 0 exits immediately.
    config.duration = Some(Duration::from_secs(seconds));
    let handle = start_sender(config, event_tx)?;

    let started = Instant::now();
    let mut failed = false;
    for event in event_rx {
        match event {
            StreamEvent::Status(_) => {}
            StreamEvent::Stats(stats) => {
                println!(
                    "t={:>3}s frames={} kf={} packets={} {:.2} Mbps",
                    started.elapsed().as_secs(),
                    stats.frames,
                    stats.keyframes,
                    stats.packets,
                    stats.mbps
                );
            }
            StreamEvent::Error(message) => {
                eprintln!("ss-send: {message}");
                failed = true;
            }
            StreamEvent::Ended(reason) => {
                if reason == EndReason::Error {
                    failed = true;
                }
                break;
            }
        }
    }
    handle.join();
    if failed {
        std::process::exit(1);
    }
    Ok(())
}
