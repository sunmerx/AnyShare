fn main() {
    // `cfg(desktop)` = the platforms where the screen-stream engine is linked.
    println!("cargo:rustc-check-cfg=cfg(desktop)");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if matches!(target_os.as_str(), "windows" | "linux" | "macos") {
        println!("cargo:rustc-cfg=desktop");
    }
}
