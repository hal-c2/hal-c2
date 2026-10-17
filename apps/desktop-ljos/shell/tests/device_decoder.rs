//! The device decoder: without FFmpeg it says what to install, and with it
//! (when this machine has it) it decodes desktop-qt's fixture from Annex-B
//! and AVCC to the newest picture, scaled to the view, and says when a
//! stream's video cannot be decoded.

#[path = "support/device_fixture.rs"]
mod device_fixture;

use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

use hal_c2_shell::device::decoder::{Decode, Decoded, Decoder, Picture};
use hal_c2_shell::device::ffmpeg;

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

fn decoder() -> (Decoder, Receiver<()>) {
    let (tell, notified) = channel();
    let tell = std::sync::Mutex::new(tell);
    let decoder = Decoder::new(Arc::new(move || {
        let _ = tell.lock().map(|t| t.send(()));
    }));
    (decoder, notified)
}

fn assert_red(picture: &Picture) {
    assert_eq!(
        picture.rgba.len(),
        (picture.width * picture.height * 4) as usize
    );
    let middle = ((picture.height / 2 * picture.width + picture.width / 2) * 4) as usize;
    let pixel = &picture.rgba[middle..middle + 4];
    assert!(
        pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60 && pixel[3] == 255,
        "{pixel:?} is red"
    );
}

// One test: pretending FFmpeg is missing holds for the whole process.
#[test]
fn decodes_the_fixture_or_says_what_to_install() {
    ffmpeg::pretend_missing(true);
    let (mut decoder, notified) = decoder();
    #[cfg(all(unix, not(target_os = "macos")))]
    assert_eq!(
        decoder.available(),
        Err("Install FFmpeg to watch device screens (libavcodec.so.63 was not found).".to_owned())
    );
    assert!(decoder.available().is_err());
    decoder.reset(None);
    for (frame, key) in device_fixture::android_video() {
        assert!(decoder.push(frame, 16, key));
    }
    let events = said(&mut decoder, &notified);
    assert!(
        matches!(&events[..], [Decoded::Unsupported(why)] if why.starts_with("Install FFmpeg")),
        "{events:?}"
    );
    assert_eq!(decoder.take_frame(), None);
    ffmpeg::pretend_missing(false);

    if ffmpeg::api().is_none() {
        eprintln!("FFmpeg is not installed: decoding is not tested");
        return;
    }
    assert_eq!(decoder.available(), Ok(()));

    // Annex-B (Android): every picture decoded, the newest kept, full size.
    decoder.reset(None);
    for (frame, key) in device_fixture::android_video() {
        assert!(decoder.push(frame, 16, key));
    }
    assert_eq!(said(&mut decoder, &notified), [Decoded::Frame]);
    let picture = decoder.take_frame().expect("a picture");
    assert_eq!((picture.width, picture.height), (72, 160));
    assert_eq!(decoder.source_size(), (72, 160));
    assert_red(&picture);

    // AVCC (iOS), scaled to fit the view.
    decoder.set_maximum_size((36, 200));
    decoder.reset(Some(device_fixture::avcc(false)));
    // Before a keyframe nothing is queued, and nothing is said of it.
    let units = device_fixture::avcc_units();
    let (delta, _) = units.iter().find(|(_, key)| !key).expect("a delta");
    assert!(decoder.push(delta.clone(), 0, false));
    for (unit, key) in units {
        assert!(decoder.push(unit, 0, key));
    }
    assert_eq!(said(&mut decoder, &notified), [Decoded::Frame]);
    let picture = decoder.take_frame().expect("a picture");
    assert_eq!((picture.width, picture.height), (36, 80));
    assert_eq!(decoder.source_size(), (72, 160));
    assert_red(&picture);

    // An avcC record no decoder starts from.
    decoder.reset(Some(device_fixture::avcc(true)));
    let (unit, key) = device_fixture::avcc_units().remove(0);
    assert!(key);
    assert!(decoder.push(unit, 0, key));
    assert_eq!(said(&mut decoder, &notified), [Decoded::Broken]);
    assert_eq!(decoder.take_frame(), None);
}
