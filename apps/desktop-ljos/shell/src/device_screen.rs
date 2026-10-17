//! `DeviceScreen` in `HalC2.Shell`, desktop-qt's item of the same name
//! (src/native/DeviceScreen.h): a device's live picture, the newest frame
//! stretched over the item.
//!
//! Where Qt's item pulls pictures from a `DeviceStream`'s decoder, this one
//! is pushed them: whatever decodes (the stream is not ported yet) calls
//! [`show_frame`] with RGBA pixels and [`drop_frame`] when the picture no
//! longer shows the device (a reconnect, a new target). A frame reaches the
//! screen as an image in the item's display list, like a `VideoOutput`'s, so
//! the renderer owns the texture and uploads only what changed.
//!
//! `stream` is kept as written, an object or null; the Bricks only hand it
//! on. Setting it drops the frame, as Qt's `setStream` does.
//!
//! Not done: telling the decoder how large a picture to make (Qt's
//! `limit()`: the item's size in device pixels). The decoder will read the
//! item's `width` and `height` itself.

use std::fmt;
use std::rc::Rc;

use ljos::prelude::{Cx, Engine, EngineError, ObjectId, QmlObject, QmlType, Value, qml_impl};
// The paint hook is ljos_quick's and speaks its engine-level types; the
// facade has no way to a custom item yet.
use ljos_engine::{MetaRef, NodeId};
use ljos_quick::{Item, ItemPaint};
use ljos_render::{DisplayListBuilder, ImageHandle, kurbo};

/// Adds the type to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [DeviceScreen]));
    let meta = MetaRef::Static(DeviceScreen::static_meta());
    ljos_quick::register_paint_item(engine, meta, read_paint);
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
    #[qml(skip)]
    frame: Option<ImageHandle>,
    /// Moves when the frame does, so the scene repaints the item.
    #[qml(skip)]
    serial: Option<NodeId>,
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
            frame: None,
            serial: None,
        }
    }
}

#[qml_impl]
impl DeviceScreen {
    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let (e, me) = (cx.engine, cx.this);
        let scope = e.object_scope(me).unwrap_or_else(|| e.graph().root());
        let serial = e.graph().property(scope, Value::Int(0)).ok();
        e.with_mut::<DeviceScreen, _>(me, |s| s.serial = serial)?;
        e.watch(me, Self::STREAM.index, move |e, _| drop_frame(e, me))?;
        Ok(())
    }
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
    if !engine.is_alive(screen) {
        return false;
    }
    let Ok(image) = ImageHandle::from_straight(width, height, rgba) else {
        return false;
    };
    let Ok(serial) = engine.with_mut::<DeviceScreen, _>(screen, |s| {
        s.frame = Some(image);
        s.serial
    }) else {
        return false;
    };
    engine.batch(|| {
        let _ = engine.set_internal(screen, DeviceScreen::HAS_FRAME, true);
        bump(engine, serial);
    });
    true
}

/// Takes the picture away: it no longer shows the device.
pub fn drop_frame(engine: &Engine, screen: ObjectId) {
    if !engine.is_alive(screen) {
        return;
    }
    let Ok((had, serial)) =
        engine.with_mut::<DeviceScreen, _>(screen, |s| (s.frame.take().is_some(), s.serial))
    else {
        return;
    };
    engine.batch(|| {
        let _ = engine.set_internal(screen, DeviceScreen::HAS_FRAME, false);
        if had {
            bump(engine, serial);
        }
    });
}

fn bump(engine: &Engine, serial: Option<NodeId>) {
    if let Some(n) = serial {
        let next = engine.graph().get_untracked(n).to_number() as i32 + 1;
        engine.graph().set(n, Value::Int(next));
    }
}

/// What a screen paints: its frame over the whole item.
#[derive(Debug)]
struct FramePaint(Option<ImageHandle>);

impl ItemPaint for FramePaint {
    fn paint(
        &self,
        size: kurbo::Size,
        _: &mut ljos_quick::TextEngine,
        out: &mut DisplayListBuilder,
    ) {
        let Some(image) = &self.0 else { return };
        if size.width > 0.0 && size.height > 0.0 {
            out.image(
                image.clone(),
                kurbo::Rect::new(0.0, 0.0, size.width, size.height),
            );
        }
    }
}

fn read_paint(engine: &Engine, me: ObjectId) -> Rc<dyn ItemPaint> {
    let serial = engine
        .with::<DeviceScreen, _>(me, |s| s.serial)
        .ok()
        .flatten();
    if let Some(n) = serial {
        // Read tracked: a new frame repaints the item.
        let _ = engine.graph().get(n);
    }
    let frame = engine
        .with::<DeviceScreen, _>(me, |s| s.frame.clone())
        .ok()
        .flatten();
    Rc::new(FramePaint(frame))
}
