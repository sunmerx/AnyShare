//! ss-probe: enumerate display outputs and run a Desktop Duplication session,
//! reporting frame / idle / dirty-rect statistics once per second.
//!
//! Usage:
//!   ss-probe [--list] [--vfr] [--output <index|name-substr>] [--seconds N] [--timeout-ms N]

use std::time::{Duration, Instant};

fn main() {
    #[cfg(not(windows))]
    {
        let _ = (Duration::from_secs(1), Instant::now());
        eprintln!("ss-probe: Windows-only tool (capture layer is Windows for now)");
        std::process::exit(2);
    }

    #[cfg(windows)]
    {
        if let Err(e) = run() {
            eprintln!("ss-probe: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    use screen_stream::{enumerate_outputs, types::Acquire, Duplicator};

    fn next_value(args: &[String], i: &mut usize, name: &str) -> anyhow::Result<String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing value for {name}"))
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut list_only = false;
    let mut vfr_enabled = false;
    let mut want_output: Option<String> = None;
    let mut seconds = 10u64;
    let mut timeout_ms = 500u32;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--list" => list_only = true,
            "--vfr" => vfr_enabled = true,
            "--output" => want_output = Some(next_value(&args, &mut i, "--output")?),
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --seconds value {raw:?}"))?;
            }
            "--timeout-ms" => {
                let raw = next_value(&args, &mut i, "--timeout-ms")?;
                timeout_ms = raw
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --timeout-ms value {raw:?}"))?;
            }
            other => anyhow::bail!("unknown argument {other:?} (usage: ss-probe [--list] [--vfr] [--output <index|name>] [--seconds N] [--timeout-ms N])"),
        }
        i += 1;
    }

    let outputs = enumerate_outputs()?;
    if outputs.is_empty() {
        anyhow::bail!("no display outputs found");
    }

    println!("outputs ({}):", outputs.len());
    for o in &outputs {
        println!(
            "  [{}] {} {} {}x{} at ({},{}) rotation={} attached={}",
            o.index,
            o.device_name,
            o.adapter_name,
            o.desktop_rect.width(),
            o.desktop_rect.height(),
            o.desktop_rect.left,
            o.desktop_rect.top,
            screen_stream::windows_capture::rotation_name(o.rotation),
            o.attached
        );
    }

    if list_only {
        return Ok(());
    }

    let target = match &want_output {
        Some(spec) => {
            if let Ok(idx) = spec.parse::<usize>() {
                outputs
                    .iter()
                    .find(|o| o.index == idx)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("output index {idx} not found"))?
            } else {
                outputs
                    .iter()
                    .find(|o| o.device_name.to_ascii_lowercase().contains(&spec.to_ascii_lowercase()))
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("no output name matches {spec:?}"))?
            }
        }
        None => outputs
            .iter()
            .filter(|o| o.attached)
            .min_by_key(|o| o.desktop_rect.area())
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no attached output to auto-pick"))?,
    };

    println!();
    println!(
        "capturing output [{}] {} {}x{} for {seconds}s (auto-pick = smallest attached output; override with --output)",
        target.index,
        target.device_name,
        target.desktop_rect.width(),
        target.desktop_rect.height()
    );
    println!("(stdout is line-buffered per second; move windows on this display to see dirty rects)");

    let mut dup = Duplicator::new(target.index)?;
    let area = target.desktop_rect.area().max(1);

    let mut gate = if vfr_enabled {
        use screen_stream::vfr::{VfrConfig, VfrGate};
        Some(VfrGate::new(VfrConfig::default()))
    } else {
        None
    };

    let started = Instant::now();
    let mut window_start = Instant::now();

    let mut win_frames = 0u64;
    let mut win_idle = 0u64;
    let mut win_dirty_rects = 0u64;
    let mut win_dirty_area = 0i64;
    let mut win_moved = 0u64;
    let mut win_pointer = 0u64;
    let mut win_present_zero = 0u64;
    let mut win_vfr_enc = 0u64;
    let mut win_vfr_kf = 0u64;

    let mut tot_frames = 0u64;
    let mut tot_idle = 0u64;

    while started.elapsed() < Duration::from_secs(seconds) {
        match dup.acquire(timeout_ms)? {
            Acquire::Idle => {
                win_idle += 1;
                tot_idle += 1;
                if let Some(gate) = gate.as_mut() {
                    use screen_stream::types::FrameMeta;
                    let _ = gate.decide(&FrameMeta::default(), Instant::now());
                }
            }
            Acquire::Frame(meta) => {
                win_frames += 1;
                tot_frames += 1;
                win_dirty_rects += meta.dirty.len() as u64;
                win_dirty_area += meta.dirty.iter().map(|r| r.area()).sum::<i64>();
                win_moved += meta.moved.len() as u64;
                if meta.pointer_shape_updated {
                    win_pointer += 1;
                }
                if meta.last_present_time == 0 {
                    win_present_zero += 1;
                }
                if let Some(gate) = gate.as_mut() {
                    use screen_stream::vfr::EncodeDecision;
                    if let EncodeDecision::Encode { keyframe } = gate.decide(&meta, Instant::now()) {
                        win_vfr_enc += 1;
                        if keyframe {
                            win_vfr_kf += 1;
                        }
                    }
                }
            }
        }

        if window_start.elapsed() >= Duration::from_secs(1) {
            let dirty_pct = (win_dirty_area as f64) / (area as f64) * 100.0;
            let vfr_part = if gate.is_some() {
                format!(" vfr_enc={win_vfr_enc:<4} kf={win_vfr_kf}")
            } else {
                String::new()
            };
            println!(
                "t={:>3}s frames={win_frames:<4} idle={win_idle:<4} dirty={win_dirty_rects:<4}({:>5.1}% area) moved={win_moved:<3} pointer_upd={win_pointer:<3} zero_present={win_present_zero}{vfr_part}",
                started.elapsed().as_secs(),
                dirty_pct
            );
            window_start = Instant::now();
            win_frames = 0;
            win_idle = 0;
            win_dirty_rects = 0;
            win_dirty_area = 0;
            win_moved = 0;
            win_pointer = 0;
            win_present_zero = 0;
            win_vfr_enc = 0;
            win_vfr_kf = 0;
        }
    }

    let total = tot_frames + tot_idle;
    println!();
    println!(
        "summary: {total} acquire iterations, frames={tot_frames} idle={tot_idle} ({:.1}% idle), access_lost_rebuilds={}",
        if total == 0 { 0.0 } else { (tot_idle as f64) / (total as f64) * 100.0 },
        dup.rebuild_count()
    );
    if let Some(gate) = gate.as_ref() {
        let stats = gate.stats();
        println!(
            "vfr summary: encoded={} keyframes={} skipped={} (static={}, rate_limited={})",
            stats.encoded, stats.keyframes, stats.skipped, stats.skipped_static, stats.skipped_rate_limited
        );
    }
    Ok(())
}
