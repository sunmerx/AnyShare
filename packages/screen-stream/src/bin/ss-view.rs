//! ss-view: CLI wrapper around the screen-stream receiver library.
//! Usage: ss-view [--port N] [--seconds N] [--scale N]
//! Build: cargo build --release --features viewer --bin ss-view

fn main() {
    if let Err(e) = run() {
        eprintln!("ss-view: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    use std::time::Duration;

    use screen_stream::events::{EndReason, StreamEvent};
    use screen_stream::receiver::{start_receiver, ReceiverConfig, ReceiverDecoder};

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
    let mut scale: f32 = 1.0;
    let mut verbose = false;
    let mut decoder_kind = "ffmpeg".to_string();
    let mut ffmpeg_path = "ffmpeg".to_string();
    let mut hwaccel: Option<String> = None;
    let mut hwaccel_device: Option<String> = None;
    let mut vaapi_device = "/dev/dri/renderD128".to_string();
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
            "--scale" => {
                let raw = next_value(&args, &mut i, "--scale")?;
                scale = raw.parse().map_err(|_| anyhow::anyhow!("invalid --scale {raw:?}"))?;
            }
            "--decoder" => decoder_kind = next_value(&args, &mut i, "--decoder")?,
            "--ffmpeg-path" => ffmpeg_path = next_value(&args, &mut i, "--ffmpeg-path")?,
            "--hwaccel" => hwaccel = Some(next_value(&args, &mut i, "--hwaccel")?),
            "--hwaccel-device" => hwaccel_device = Some(next_value(&args, &mut i, "--hwaccel-device")?),
            "--vaapi-device" => vaapi_device = next_value(&args, &mut i, "--vaapi-device")?,
            "--verbose" => verbose = true,
            other => anyhow::bail!(
                "unknown argument {other:?} (usage: ss-view [--port N] [--seconds N] [--scale N] [--decoder ffmpeg|openh264|vaapi] [--ffmpeg-path PATH] [--hwaccel NAME] [--hwaccel-device PATH] [--vaapi-device PATH] [--verbose])"
            ),
        }
        i += 1;
    }
    let decoder = match decoder_kind.as_str() {
        "ffmpeg" => ReceiverDecoder::Ffmpeg {
            path: ffmpeg_path,
            hwaccel,
            hwaccel_device,
        },
        "openh264" => ReceiverDecoder::OpenH264,
        "vaapi" => ReceiverDecoder::Vaapi { device: vaapi_device },
        other => anyhow::bail!("unknown decoder {other:?} (expected ffmpeg, openh264 or vaapi)"),
    };

    let config = ReceiverConfig {
        port,
        decoder,
        window_title: "AnyShare Viewer".to_string(),
        scale,
        duration: (seconds > 0).then(|| Duration::from_secs(seconds)),
        verbose,
    };

    let (event_tx, event_rx) = std::sync::mpsc::channel::<StreamEvent>();
    let handle = start_receiver(config, event_tx)?;

    let mut failed = false;
    for event in event_rx {
        match event {
            StreamEvent::Status(_) => {}
            StreamEvent::Stats(stats) => {
                eprintln!("viewer: displayed={} ({} fps window)", stats.frames, stats.fps);
            }
            StreamEvent::Error(message) => {
                eprintln!("ss-view: {message}");
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
