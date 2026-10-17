//! ss-encoders: list H.264 encoder MFTs (hardware candidates first, then software).

fn main() {
    #[cfg(not(windows))]
    {
        eprintln!("ss-encoders: Windows-only tool");
        std::process::exit(2);
    }

    #[cfg(windows)]
    {
        if let Err(e) = run() {
            eprintln!("ss-encoders: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    use screen_stream::{list_h264_encoders, EncoderKind};

    let encoders = list_h264_encoders()?;
    if encoders.is_empty() {
        eprintln!("ss-encoders: no H.264 encoder MFTs found (exit 3)");
        std::process::exit(3);
    }

    println!("H.264 encoder candidates (priority chain: discrete GPU > integrated GPU > CPU;");
    println!("dGPU-vs-iGPU is decided by trial-encode in a later step):");
    for (i, e) in encoders.iter().enumerate() {
        let kind = match e.kind {
            EncoderKind::Hardware => "hardware",
            EncoderKind::Software => "software",
        };
        println!("  [{}] ({kind}) {}", i, e.friendly_name);
    }
    Ok(())
}
