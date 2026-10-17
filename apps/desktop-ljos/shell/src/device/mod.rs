//! The Device tab: a device's live screen and input over the MC's device hub
//! (desktop-qt's FFmpeg, DeviceDecoder, DeviceStream and ThreadDevices).
//!
//! Decoders work on threads of their own. One with a picture or news wakes
//! the shell through the waker ([`set_wake`]), which then calls [`deliver`]
//! on the Engine thread: every stream takes what its decoder has. A headless
//! host (a test) calls [`deliver`] itself.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};

use ljos::prelude::{Engine, ObjectId};

pub mod decoder;
pub mod ffmpeg;
pub mod stream;

use decoder::{Decode, Decoder, Notify};

type Wake = Arc<dyn Fn() + Send + Sync>;
type Decoders = Rc<dyn Fn(Notify) -> Box<dyn Decode>>;

/// The engine's streams, the waker their decoders share, and what makes
/// their decoders.
#[derive(Default)]
struct Hub {
    wake: Arc<Mutex<Option<Wake>>>,
    streams: RefCell<Vec<ObjectId>>,
    decoders: RefCell<Option<Decoders>>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Adds `DeviceStream` to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [
        stream::DeviceStream,
    ]));
}

/// Says what to run, on any thread, when a decoder has something for
/// [`deliver`]: post a message to the Engine thread, which calls it.
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    let wake: Wake = Arc::new(wake);
    *Hub::of(engine)
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(wake);
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

/// Tests: what makes the streams' decoders from now on, instead of FFmpeg's
/// [`Decoder`]. It is given what to call when the decoder has news.
pub fn set_decoders(engine: &Engine, make: impl Fn(Notify) -> Box<dyn Decode> + 'static) {
    *Hub::of(engine).decoders.borrow_mut() = Some(Rc::new(make));
}

/// A decoder for a new stream, which wakes the shell when it has news.
fn decoder(engine: &Engine) -> Box<dyn Decode> {
    let hub = Hub::of(engine);
    let wake = hub.wake.clone();
    let notify: Notify = Arc::new(move || {
        let wake = wake.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(wake) = wake {
            wake();
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
