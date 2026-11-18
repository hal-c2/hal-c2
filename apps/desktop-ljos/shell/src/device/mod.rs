//! The Device tab: a device's live screen and input over the MC's device hub
//! (desktop-qt's DeviceDecoder, DeviceStream and ThreadDevices).
//!
//! Decoders work on threads of their own. One with a picture or news says so
//! on the "device-frames" side stream ([`wire`]), keyed by its screen: a
//! newer picture of a screen whose last the UI has not shown yet replaces
//! that notice (the Observer counts it `replaced`), so the UI shows each
//! screen's newest and never queues behind. The UI thread then calls
//! [`deliver`]: every stream takes what its decoder has. A headless host (a
//! test) may call [`deliver`] itself.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use ljos::prelude::{Engine, ObjectId};
use ljos::{BatchPolicy, BatchSender, CoalesceKey};

use crate::streams::Wire;

pub mod decoder;
pub mod devices;
pub mod stream;
pub mod tools;

use decoder::{Decode, Decoder, Notify};

type Decoders = Rc<dyn Fn(Notify) -> Box<dyn Decode>>;

/// How many screens' notices wait at most. More screens than this open at
/// once is past what the Device tab shows; a notice refused then is not
/// lost, as a full stream is drained soon and every drain looks at every
/// screen.
pub const FRAMES_CAPACITY: usize = 16;

/// The engine's streams, the side stream their decoders tell, and what
/// makes their decoders.
#[derive(Default)]
struct Hub {
    frames: RefCell<Option<BatchSender<u64>>>,
    next_screen: Cell<u64>,
    streams: RefCell<Vec<ObjectId>>,
    decoders: RefCell<Option<Decoders>>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Adds the Device tab's types to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    // QtQuick3D, for the device tab's 3D body.
    ljos_quick3d::register(engine);
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [
        stream::DeviceStream,
        devices::ThreadDevices,
        devices::DeviceTab,
        tools::DeviceTools,
    ]));
}

/// Makes the "device-frames" stream the decoders made from now on tell,
/// handled by [`deliver`]. DECISION: coalesced per screen, not the oldest
/// dropped across screens: one busy screen never pushes out another's only
/// picture.
pub fn wire(engine: &Engine, wire: &mut impl Wire) {
    let frames = wire.stream(
        "device-frames",
        FRAMES_CAPACITY,
        BatchPolicy::Coalesce(|screen: &u64| CoalesceKey(*screen)),
        // The run only says which screens have a picture; deliver looks at
        // each screen's newest, and the batch drops the run's items.
        |engine, _screens| deliver(engine),
    );
    *Hub::of(engine).frames.borrow_mut() = Some(frames);
}

/// Hands each stream what its decoder made. On the Engine thread.
pub fn deliver(engine: &Engine) {
    let streams = {
        let hub = Hub::of(engine);
        let mut streams = hub.streams.borrow_mut();
        streams.retain(|s| engine.is_alive(*s));
        streams.clone()
    };
    for stream in streams {
        stream::DeviceStream::poll(engine, stream);
    }
}

/// Tests: what makes the streams' decoders from now on, instead of Ljós's
/// [`Decoder`]. It is given what to call when the decoder has news.
pub fn set_decoders(engine: &Engine, make: impl Fn(Notify) -> Box<dyn Decode> + 'static) {
    *Hub::of(engine).decoders.borrow_mut() = Some(Rc::new(make));
}

/// A decoder for a new stream, which tells the shell when it has news.
fn decoder(engine: &Engine) -> Box<dyn Decode> {
    let hub = Hub::of(engine);
    let screen = hub.next_screen.get() + 1;
    hub.next_screen.set(screen);
    let frames = hub.frames.borrow().clone();
    let notify: Notify = Arc::new(move || {
        if let Some(frames) = &frames {
            // Refused only when full, and a full stream is drained soon.
            let _ = frames.send(screen);
        }
    });
    let make = hub.decoders.borrow().clone();
    match make {
        Some(make) => make(notify),
        None => Box::new(Decoder::new(notify)),
    }
}

/// `text` percent-encoded as `QUrl::toPercentEncoding` does: all but
/// letters, digits and `-._~`.
pub fn percent(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn percent_keeps_only_unreserved_characters() {
        assert_eq!(super::percent("emulator-5554"), "emulator-5554");
        assert_eq!(super::percent("a b/c?é"), "a%20b%2Fc%3F%C3%A9");
    }
}
