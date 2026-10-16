//! A picture of the shell without a window (`hal-c2-ljos --render`): the
//! scene driven on a virtual clock until it rests, then drawn on the CPU.
//!
//! The facade has no headless picture, so this follows `ljos render`
//! (ljos_cli's render.rs) over the crates behind it.

use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use ljos::prelude::{Engine, ObjectId};
use ljos_quick::QuickScene;
use ljos_render::{FrameView, RasterConfig, Rgba, VelloCpuReference, kurbo};
use ljos_runtime::{Clock as _, Time, VirtualClock};

/// Frames a scene may take to come to rest, and timer firings before the
/// settle time is given up on, as `ljos render` allows.
const MAX_SETTLE_FRAMES: usize = 64;
const MAX_TIMER_STEPS: usize = 100_000;

/// Readies this thread and `engine` for a picture: the bundled font (the
/// same picture on every machine) and a clock that moves only when told.
/// Call it before anything measures text: before the QML loads.
pub fn prepare(engine: &Engine) -> Arc<VirtualClock> {
    ljos_quick::set_text_engine(ljos_quick::TextEngine::new());
    let clock = Arc::new(VirtualClock::new());
    engine.set_clock(Rc::new(clock.clone()));
    clock
}

/// A PNG of `root` at `size` logical pixels after `settle_ms` of its time.
pub fn picture(
    engine: &Engine,
    clock: &Arc<VirtualClock>,
    root: ObjectId,
    size: (u32, u32),
    settle_ms: u64,
) -> Result<Vec<u8>, String> {
    let (width, height) = size;
    let mut scene = QuickScene::new(kurbo::Size::new(f64::from(width), f64::from(height)));
    scene.set_root(engine, root).map_err(|e| e.to_string())?;
    // A window that leaves its size unsaid is as large as the picture, as
    // the shell sizes it to its platform window.
    let unsaid = |name| engine.read_by_name(root, name).to_number() <= 0.0;
    if unsaid("width") || unsaid("height") {
        ljos_controls::WindowSystem::of(engine).resized(
            engine,
            root,
            [f64::from(width), f64::from(height)],
        );
    }
    let mut run = Run {
        engine,
        scene: &mut scene,
        clock,
        wake: None,
    };
    run.settle()?;
    run.advance(settle_ms)?;
    run.settle()?;
    let out = run.scene.frame(engine, clock.now());
    let mut raster = VelloCpuReference::new(RasterConfig {
        background: Rgba::from_straight(0.0, 0.0, 0.0, 1.0),
        ..RasterConfig::default()
    });
    let image = raster
        .render(&FrameView::new(&out.snapshot, 1.0))
        .map_err(|e| e.to_string())?;
    image.to_png().map_err(|e| e.to_string())
}

struct Run<'a> {
    engine: &'a Engine,
    scene: &'a mut QuickScene,
    clock: &'a Arc<VirtualClock>,
    /// When the scene last said it next needs a frame.
    wake: Option<Time>,
}

impl Run<'_> {
    /// Frames until the scene is idle: layout, anchors, deferred deletes.
    fn settle(&mut self) -> Result<(), String> {
        for _ in 0..MAX_SETTLE_FRAMES {
            let now = self.clock.now();
            let out = self.scene.frame(self.engine, now);
            if !self.scene.needs_frame() && out.next_wake.is_none_or(|t| t > now) {
                self.wake = out.next_wake;
                return Ok(());
            }
        }
        Err(format!(
            "the scene did not settle in {MAX_SETTLE_FRAMES} frames"
        ))
    }

    /// Lets `ms` pass, firing each timer at its own deadline and settling in
    /// between, as a host woken at each deadline would.
    fn advance(&mut self, ms: u64) -> Result<(), String> {
        let images = ljos_quick::ImageStore::of(self.engine);
        images.finish(self.engine);
        let end = self.clock.now() + Duration::from_millis(ms);
        for _ in 0..MAX_TIMER_STEPS {
            let next = [self.engine.next_timer_deadline(), self.wake]
                .into_iter()
                .flatten()
                .min();
            match next {
                Some(t) if t <= end => {
                    if t > self.clock.now() {
                        self.clock.set(t);
                    }
                    self.engine.advance_timers(self.clock.now());
                    self.settle()?;
                }
                _ => {
                    self.clock.set(end);
                    self.engine.advance_timers(end);
                    images.finish(self.engine);
                    return self.settle();
                }
            }
        }
        Err(format!(
            "timers fired more than {MAX_TIMER_STEPS} times in {ms} ms"
        ))
    }
}
