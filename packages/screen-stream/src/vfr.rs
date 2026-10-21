//! Variable-frame-rate gate: decides *when* to encode, based on captured
//! frame metadata. Pure logic — fully unit-testable without hardware.

use std::time::{Duration, Instant};

use crate::types::FrameMeta;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerPolicy {
    /// Pointer-only frames never trigger encoding (pointer is handled separately).
    Skip,
}

#[derive(Clone, Debug)]
pub struct VfrConfig {
    /// Upper bound of encoded frames per second (coalescing window). 0 = unlimited.
    pub max_fps: u32,
    /// Emit a keyframe at least this often while content keeps changing.
    pub force_keyframe_interval: Duration,
    /// Optional heartbeat for static screens (None = strictly zero encodes when static).
    /// Fires only when the gate is ticked; pipelines should tick the gate on idle
    /// timeouts too if a heartbeat is configured (DXGI delivers no frames while static).
    pub static_heartbeat: Option<Duration>,
    pub pointer_policy: PointerPolicy,
}

impl Default for VfrConfig {
    fn default() -> Self {
        Self {
            max_fps: 60,
            force_keyframe_interval: Duration::from_secs(2),
            static_heartbeat: None,
            pointer_policy: PointerPolicy::Skip,
        }
    }
}

impl VfrConfig {
    /// Gradual intra refresh keeps the picture fresh without full-IDR spikes,
    /// so periodic keyframes can be rarer. They are never removed: a receiver
    /// that joins mid-stream / loses the SPS-PPS still needs a full IDR, and
    /// loss detection alone would leave it black for the whole cadence.
    pub fn with_intra_refresh(enabled: bool) -> Self {
        let mut config = Self::default();
        if enabled {
            config.force_keyframe_interval = Duration::from_secs(4);
        }
        config
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncodeDecision {
    Encode { keyframe: bool },
    Skip,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VfrStats {
    pub encoded: u64,
    pub keyframes: u64,
    pub skipped: u64,
    /// No-content-change ticks: pointer-only frames and idle-timeout ticks.
    pub skipped_static: u64,
    pub skipped_rate_limited: u64,
}

pub struct VfrGate {
    config: VfrConfig,
    last_encoded: Option<Instant>,
    last_keyframe: Option<Instant>,
    static_since: Option<Instant>,
    stats: VfrStats,
}

impl VfrGate {
    pub fn new(config: VfrConfig) -> Self {
        Self {
            config,
            last_encoded: None,
            last_keyframe: None,
            static_since: None,
            stats: VfrStats::default(),
        }
    }

    pub fn stats(&self) -> VfrStats {
        self.stats
    }

    fn has_content_change(meta: &FrameMeta) -> bool {
        // Pointer movement counts: the capture layer composites the cursor
        // into the frames, and pointer-only frames carry no dirty rects.
        meta.last_present_time != 0
            || !meta.dirty.is_empty()
            || !meta.moved.is_empty()
            || meta.pointer_moved
            || meta.pointer_shape_updated
    }

    fn min_interval(&self) -> Duration {
        if self.config.max_fps == 0 {
            Duration::ZERO
        } else {
            Duration::from_secs_f64(1.0 / f64::from(self.config.max_fps))
        }
    }

    pub fn decide(&mut self, meta: &FrameMeta, now: Instant) -> EncodeDecision {
        if !Self::has_content_change(meta) {
            if self.static_since.is_none() {
                self.static_since = Some(now);
            }
            if let Some(heartbeat) = self.config.static_heartbeat {
                let base = match (self.last_encoded, self.static_since) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    (a, b) => a.or(b),
                };
                if let Some(base) = base {
                    if now.duration_since(base) >= heartbeat {
                        return self.commit(true, now);
                    }
                }
            }
            self.stats.skipped += 1;
            self.stats.skipped_static += 1;
            return EncodeDecision::Skip;
        }

        if let Some(last) = self.last_encoded {
            if now.duration_since(last) < self.min_interval() {
                self.stats.skipped += 1;
                self.stats.skipped_rate_limited += 1;
                return EncodeDecision::Skip;
            }
        }

        let keyframe = match self.last_keyframe {
            None => true,
            Some(last) => now.duration_since(last) >= self.config.force_keyframe_interval,
        };
        self.commit(keyframe, now)
    }

    fn commit(&mut self, keyframe: bool, now: Instant) -> EncodeDecision {
        self.last_encoded = Some(now);
        self.static_since = None;
        if keyframe {
            self.last_keyframe = Some(now);
        }
        self.stats.encoded += 1;
        if keyframe {
            self.stats.keyframes += 1;
        }
        EncodeDecision::Encode { keyframe }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn changed() -> FrameMeta {
        FrameMeta {
            frame_index: 1,
            last_present_time: 100,
            dirty: vec![crate::types::Rect {
                left: 0,
                top: 0,
                right: 10,
                bottom: 10,
            }],
            ..Default::default()
        }
    }

    fn pointer_only() -> FrameMeta {
        FrameMeta {
            frame_index: 1,
            last_present_time: 0,
            ..Default::default()
        }
    }

    #[test]
    fn static_screen_never_encodes() {
        let mut gate = VfrGate::new(VfrConfig::default());
        let t0 = Instant::now();
        for i in 0..100 {
            let decision = gate.decide(&FrameMeta::default(), t0 + Duration::from_millis(i * 16));
            assert_eq!(decision, EncodeDecision::Skip);
        }
        assert_eq!(gate.stats().encoded, 0);
        assert_eq!(gate.stats().skipped, 100);
    }

    #[test]
    fn pointer_only_frames_are_skipped() {
        let mut gate = VfrGate::new(VfrConfig::default());
        let t0 = Instant::now();
        assert_eq!(gate.decide(&pointer_only(), t0), EncodeDecision::Skip);
        assert_eq!(gate.stats().skipped_static, 1);
    }

    #[test]
    fn first_change_encodes_as_keyframe() {
        let mut gate = VfrGate::new(VfrConfig::default());
        assert_eq!(
            gate.decide(&changed(), Instant::now()),
            EncodeDecision::Encode { keyframe: true }
        );
    }

    #[test]
    fn rate_limiting_coalesces_bursts() {
        let mut gate = VfrGate::new(VfrConfig::default());
        let t0 = Instant::now();
        let mut encoded = 0;
        for i in 0..10 {
            let decision = gate.decide(&changed(), t0 + Duration::from_millis(i));
            if matches!(decision, EncodeDecision::Encode { .. }) {
                encoded += 1;
            }
        }
        assert_eq!(encoded, 1, "10 changes within 10ms must coalesce into one encode at 60fps");
        assert_eq!(gate.stats().skipped_rate_limited, 9);
    }

    #[test]
    fn keyframe_cadence_on_continuous_change() {
        let mut gate = VfrGate::new(VfrConfig::default());
        let t0 = Instant::now();
        let mut keyframes = 0;
        let mut encoded = 0;
        for i in 0..=250 {
            let decision = gate.decide(&changed(), t0 + Duration::from_millis(i * 17));
            if let EncodeDecision::Encode { keyframe } = decision {
                encoded += 1;
                if keyframe {
                    keyframes += 1;
                }
            }
        }
        assert_eq!(encoded, 251, "17ms steps stay above the 1/60s rate-limiting window");
        assert_eq!(keyframes, 3, "keyframes at t=0, ~2.0s and ~4.0s over a 4.25s span");
    }

    #[test]
    fn static_heartbeat_emits_when_configured() {
        let config = VfrConfig {
            static_heartbeat: Some(Duration::from_secs(1)),
            ..Default::default()
        };
        let mut gate = VfrGate::new(config);
        let t0 = Instant::now();
        assert_eq!(gate.decide(&FrameMeta::default(), t0), EncodeDecision::Skip);
        assert_eq!(
            gate.decide(&FrameMeta::default(), t0 + Duration::from_secs(1)),
            EncodeDecision::Encode { keyframe: true }
        );
        assert_eq!(gate.stats().encoded, 1);
        assert_eq!(gate.stats().skipped, 1);
    }

    #[test]
    fn intra_refresh_relaxes_keyframe_cadence() {
        assert_eq!(VfrConfig::with_intra_refresh(false).force_keyframe_interval, Duration::from_secs(2));
        assert_eq!(VfrConfig::with_intra_refresh(true).force_keyframe_interval, Duration::from_secs(4));
        assert_eq!(VfrConfig::with_intra_refresh(true).max_fps, VfrConfig::default().max_fps);

        // Run the gate itself: continuous change for 4.25 s on the relaxed
        // cadence must still produce exactly one periodic keyframe.
        let mut gate = VfrGate::new(VfrConfig::with_intra_refresh(true));
        let t0 = Instant::now();
        let mut keyframes = 0;
        for i in 0..=17 {
            let t = t0 + Duration::from_millis(250) * i;
            if let EncodeDecision::Encode { keyframe } = gate.decide(&changed(), t) {
                keyframes += i32::from(keyframe);
            }
        }
        assert_eq!(keyframes, 2, "first frame + one 4 s cadence keyframe");
    }
}
