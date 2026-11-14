//! The device decoder: a clip that turns from red to blue, from Annex-B and
//! from AVCC, decoded to its newest picture as it arrives, scaled to the
//! view; and a stream whose video cannot be decoded says so.

#[path = "support/device_fixture.rs"]
mod device_fixture;

use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

use hal_c2_shell::device::decoder::{Decode, Decoded, Decoder, Picture};

/// Waits for the decoder to say something (a guard, not a pace: the worker
/// notifies when it is done) and returns what it said.
fn said(decoder: &mut Decoder, notified: &Receiver<()>) -> Vec<Decoded> {
    loop {
        let events = decoder.take_events();
        if !events.is_empty() {
            return events;
        }
        notified
            .recv_timeout(Duration::from_secs(60))
            .expect("the decoder says something");
    }
}

/// Takes pictures as the decoder says it has them until one is all
/// `colour`; it says nothing else on the way.
fn until(decoder: &mut Decoder, notified: &Receiver<()>, colour: Colour) -> Picture {
    loop {
        assert_eq!(said(decoder, notified), [Decoded::Frame]);
        let picture = decoder.take_frame().expect("a picture");
        assert_eq!(
            picture.rgba.len(),
            (picture.width * picture.height * 4) as usize
        );
        if picture.rgba.chunks(4).all(|pixel| colour.is(pixel)) {
            return picture;
        }
    }
}

#[derive(Clone, Copy)]
enum Colour {
    Red,
    Blue,
}

impl Colour {
    fn is(self, pixel: &[u8]) -> bool {
        let [r, g, b, a] = pixel else { return false };
        let (on, off) = match self {
            Colour::Red => (*r, [*g, *b]),
            Colour::Blue => (*b, [*r, *g]),
        };
        on > 200 && off.iter().all(|c| *c < 60) && *a == 255
    }
}

fn decoder() -> (Decoder, Receiver<()>) {
    let (tell, notified) = channel();
    let tell = std::sync::Mutex::new(tell);
    let decoder = Decoder::new(Arc::new(move || {
        let _ = tell.lock().map(|t| t.send(()));
    }));
    (decoder, notified)
}

#[test]
fn annex_b_is_decoded_to_its_newest_picture_as_it_arrives() {
    let (mut decoder, notified) = decoder();
    decoder.reset(None);
    let mut frames = device_fixture::android_video_of(&device_fixture::red_blue()).into_iter();
    // The red keyframe and the red picture after it: shown before the
    // device sends anything more.
    for (frame, key) in frames.by_ref().take(2) {
        assert!(decoder.push(frame, 16, key));
    }
    let red = until(&mut decoder, &notified, Colour::Red);
    assert_eq!((red.width, red.height), (72, 160));
    assert_eq!(decoder.source_size(), (72, 160));
    // The blue pictures refer to the red ones: decoding goes on.
    for (frame, key) in frames {
        assert!(decoder.push(frame, 16, key));
    }
    let blue = until(&mut decoder, &notified, Colour::Blue);
    assert_eq!((blue.width, blue.height), (72, 160));
}

#[test]
fn avcc_is_decoded_from_its_first_keyframe_and_scaled_to_the_view() {
    let (mut decoder, notified) = decoder();
    let clip = device_fixture::red_blue();
    decoder.set_maximum_size((36, 200));
    decoder.reset(Some(device_fixture::avcc_of(&clip, false)));
    let units = device_fixture::avcc_units_of(&clip);
    // Before a keyframe nothing is decoded, and nothing is said of it.
    let (delta, _) = units.iter().find(|(_, key)| !key).expect("a delta");
    assert!(decoder.push(delta.clone(), 0, false));
    for (unit, key) in units {
        assert!(decoder.push(unit, 0, key));
    }
    let picture = until(&mut decoder, &notified, Colour::Blue);
    assert_eq!((picture.width, picture.height), (36, 80));
    assert_eq!(decoder.source_size(), (72, 160));
}

#[test]
fn pictures_of_many_slices_decode_from_both_framings() {
    // desktop-qt's clip: six slices a picture, each sent on its own.
    let (mut decoder, notified) = decoder();
    decoder.reset(None);
    for (frame, key) in device_fixture::android_video() {
        assert!(decoder.push(frame, 16, key));
    }
    let picture = until(&mut decoder, &notified, Colour::Red);
    assert_eq!((picture.width, picture.height), (72, 160));

    decoder.reset(Some(device_fixture::avcc(false)));
    for (unit, key) in device_fixture::avcc_units() {
        assert!(decoder.push(unit, 0, key));
    }
    let picture = until(&mut decoder, &notified, Colour::Red);
    assert_eq!((picture.width, picture.height), (72, 160));
}

#[test]
fn an_avcc_record_no_decoder_starts_from_is_broken_video() {
    let (mut decoder, notified) = decoder();
    decoder.reset(Some(device_fixture::avcc(true)));
    let (unit, key) = device_fixture::avcc_units().remove(0);
    assert!(key);
    assert!(decoder.push(unit, 0, key));
    assert_eq!(said(&mut decoder, &notified), [Decoded::Broken]);
    assert_eq!(decoder.take_frame(), None);
}
