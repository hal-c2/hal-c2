//! `DeviceScreen` in `HalC2.Shell`, desktop-qt's item of the same name
//! (src/native/DeviceScreen.h): a device's live picture, the newest frame
//! stretched over the item.
//!
//! Where Qt's item pulls pictures from a `DeviceStream`'s decoder, this one
//! is pushed them: a [`DeviceStream`](crate::device::stream::DeviceStream)
//! set as `stream` hands it each picture ([`show_image`]) and drops it
//! ([`drop_frame`]) when the picture no longer shows the device (a
//! reconnect, a new target). A frame reaches the screen as an image in the
//! item's display list, like a `VideoOutput`'s, so the renderer owns the
//! texture and uploads only what changed.
//!
//! `stream` is kept as written, an object or null. Setting it drops the
//! frame, as Qt's `setStream` does, and shows the new stream's newest
//! picture. How large a picture to make (Qt's `limit()`: the item's size in
//! device pixels) the stream reads off the item itself.

use std::fmt;
use std::rc::Rc;

use ljos::item::{self, DisplayListBuilder, ImageHandle, Item, ItemPaint, TextEngine, kurbo};
use ljos::prelude::{Cx, Engine, EngineError, ObjectId, QmlObject, Value, qml_impl};

use crate::device::stream;

/// Adds the type to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [DeviceScreen]));
    item::register_paint_item::<DeviceScreen>(engine, read_paint);
}

#[derive(QmlObject)]
#[qml(
    module = "HalC2.Shell",
    name = "DeviceScreen",
    extends = Item,
    default = "data"
)]
pub struct DeviceScreen {
    #[qml(base)]
    pub item: Item,
    /// A device tab's stream, which this item does not read.
    #[qml(notify)]
    pub stream: Value,
    /// Whether a picture is shown: one arrived since the stream was set or
    /// the frame was last dropped.
    #[qml(notify, readonly)]
    pub has_frame: bool,
    /// Counts the frames shown and dropped; the paint reads it, so each
    /// one repaints the item. Not Qt's: Ljós repaints an item only when a
    /// property its paint read changes, and has no private property for
    /// it (hal-c2/ljos-ui#62), so the counter shows in QML.
    #[qml(notify, readonly)]
    pub frames: i32,
    #[qml(skip)]
    frame: Option<ImageHandle>,
    /// The `DeviceStream` this item shows, when `stream` is one.
    #[qml(skip)]
    attached: Option<ObjectId>,
}

impl fmt::Debug for DeviceScreen {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeviceScreen")
            .field("has_frame", &self.has_frame)
            .finish_non_exhaustive()
    }
}

impl Default for DeviceScreen {
    fn default() -> Self {
        DeviceScreen {
            item: Item::default(),
            stream: Value::Undefined,
            has_frame: false,
            frames: 0,
            frame: None,
            attached: None,
        }
    }
}

#[qml_impl]
impl DeviceScreen {
    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let (e, me) = (cx.engine, cx.this);
        e.watch(me, Self::STREAM.index, move |e, _| stream_changed(e, me))?;
        stream_changed(e, me);
        Ok(())
    }
}

/// `stream` was set: the picture goes, and the new stream's comes.
fn stream_changed(engine: &Engine, screen: ObjectId) {
    drop_frame(engine, screen);
    let Ok((stream, old)) =
        engine.with::<DeviceScreen, _>(screen, |s| (s.stream.as_object(), s.attached))
    else {
        return;
    };
    if let Some(old) = old {
        stream::detach_screen(engine, old, screen);
    }
    let attached = stream.filter(|s| stream::attach_screen(engine, *s, screen));
    let _ = engine.with_mut::<DeviceScreen, _>(screen, |s| s.attached = attached);
}

/// Shows a picture of `width` by `height` pixels, `rgba` bytes in row
/// order, stretched over `screen`. Whether it was taken: not a size the
/// pixels fill, or `screen` is gone, it was not.
pub fn show_frame(
    engine: &Engine,
    screen: ObjectId,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
) -> bool {
    match ImageHandle::from_straight(width, height, rgba) {
        Ok(image) => show_image(engine, screen, image),
        Err(_) => false,
    }
}

/// Shows `image` stretched over `screen`; false when `screen` is gone.
pub fn show_image(engine: &Engine, screen: ObjectId, image: ImageHandle) -> bool {
    if !engine.is_alive(screen) {
        return false;
    }
    if engine
        .with_mut::<DeviceScreen, _>(screen, |s| s.frame = Some(image))
        .is_err()
    {
        return false;
    }
    engine.batch(|| {
        let _ = engine.set_internal(screen, DeviceScreen::HAS_FRAME, true);
        repaint(engine, screen);
    });
    true
}

/// Takes the picture away: it no longer shows the device.
pub fn drop_frame(engine: &Engine, screen: ObjectId) {
    if !engine.is_alive(screen) {
        return;
    }
    let Ok(had) = engine.with_mut::<DeviceScreen, _>(screen, |s| s.frame.take().is_some()) else {
        return;
    };
    engine.batch(|| {
        let _ = engine.set_internal(screen, DeviceScreen::HAS_FRAME, false);
        if had {
            repaint(engine, screen);
        }
    });
}

/// Moves `frames`, which the paint reads.
fn repaint(engine: &Engine, screen: ObjectId) {
    let frames = engine.get(screen, DeviceScreen::FRAMES).unwrap_or(0);
    let _ = engine.set_internal(screen, DeviceScreen::FRAMES, frames.wrapping_add(1));
}

/// What a screen paints: its frame over the whole item.
#[derive(Debug)]
struct FramePaint(Option<ImageHandle>);

impl ItemPaint for FramePaint {
    fn paint(&self, size: kurbo::Size, _: &mut TextEngine, out: &mut DisplayListBuilder) {
        let Some(image) = &self.0 else { return };
        if size.width > 0.0 && size.height > 0.0 {
            out.image(
                image.clone(),
                kurbo::Rect::new(0.0, 0.0, size.width, size.height),
            );
        }
    }
}

/// Read tracked: `frames` moving repaints the item.
fn read_paint(engine: &Engine, me: ObjectId) -> Rc<dyn ItemPaint> {
    item::prop(engine, me, DeviceScreen::FRAMES);
    let frame = engine
        .with::<DeviceScreen, _>(me, |s| s.frame.clone())
        .ok()
        .flatten();
    Rc::new(FramePaint(frame))
}
