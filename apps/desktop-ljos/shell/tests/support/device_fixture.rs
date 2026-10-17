//! desktop-qt's device fixture (a solid red 72x160 H.264 clip, Annex-B) as
//! the device hub sends it: serve-sim's AVCC body and serve-emu's SEMU
//! frames. Included by the device tests
//! (`#[path = "support/device_fixture.rs"] mod device_fixture;`).

#![allow(dead_code)]

/// The fixture's parameter sets and one slice per picture.
pub struct Fixture {
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
    pub slices: Vec<(Vec<u8>, bool)>,
}

pub fn fixture() -> Fixture {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../desktop-qt/tests/native/features/fixtures/device-72x160.h264"
    );
    let data = std::fs::read(path).expect("the device fixture");
    let mut starts = Vec::new();
    let mut at = 0;
    while at + 3 <= data.len() {
        if data[at..at + 3] == [0, 0, 1] {
            starts.push(at + 3);
            at += 3;
        } else {
            at += 1;
        }
    }
    let mut fixture = Fixture {
        sps: Vec::new(),
        pps: Vec::new(),
        slices: Vec::new(),
    };
    for (n, &start) in starts.iter().enumerate() {
        let mut end = starts.get(n + 1).map_or(data.len(), |next| next - 3);
        if n + 1 < starts.len() && data[end - 1] == 0 {
            end -= 1; // a four-byte start code
        }
        let nal = data[start..end].to_vec();
        match nal[0] & 0x1f {
            7 if fixture.sps.is_empty() => fixture.sps = nal,
            8 if fixture.pps.is_empty() => fixture.pps = nal,
            kind @ (1 | 5) => fixture.slices.push((nal, kind == 5)),
            _ => {}
        }
    }
    fixture
}

/// The avcC record of the fixture; `broken`, one no decoder starts from.
pub fn avcc(broken: bool) -> Vec<u8> {
    let f = fixture();
    let mut record = vec![1];
    record.extend_from_slice(&f.sps[1..4]);
    record.push(0xff); // four-byte lengths
    record.push(0xe1); // one SPS
    record.extend_from_slice(&(f.sps.len() as u16).to_be_bytes());
    record.extend_from_slice(&f.sps);
    record.push(1);
    record.extend_from_slice(&(f.pps.len() as u16).to_be_bytes());
    record.extend_from_slice(&f.pps);
    if broken {
        record.truncate(4);
    }
    record
}

/// One serve-sim envelope: length, tag, payload.
pub fn envelope(tag: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = ((payload.len() + 1) as u32).to_be_bytes().to_vec();
    out.push(tag);
    out.extend_from_slice(payload);
    out
}

/// The fixture's pictures as AVCC units (four-byte lengths), with whether
/// each is a keyframe.
pub fn avcc_units() -> Vec<(Vec<u8>, bool)> {
    fixture()
        .slices
        .into_iter()
        .map(|(slice, key)| {
            let mut unit = (slice.len() as u32).to_be_bytes().to_vec();
            unit.extend_from_slice(&slice);
            (unit, key)
        })
        .collect()
}

/// serve-sim's stream.avcc body: the avcC record, then every picture.
pub fn ios_video(broken: bool) -> Vec<u8> {
    let mut body = envelope(1, &avcc(broken));
    for (unit, key) in avcc_units() {
        body.extend(envelope(if key { 2 } else { 3 }, &unit));
    }
    body
}

/// serve-emu's frames: Annex-B access units behind a SEMU header.
pub fn android_video() -> Vec<(Vec<u8>, bool)> {
    let f = fixture();
    let start = [0u8, 0, 0, 1];
    f.slices
        .iter()
        .map(|(slice, key)| {
            let mut frame = 0x5345_4d55u32.to_be_bytes().to_vec();
            frame.extend_from_slice(&[0; 12]);
            frame[4] = 1;
            frame[5] = u8::from(*key);
            if *key {
                frame.extend_from_slice(&start);
                frame.extend_from_slice(&f.sps);
                frame.extend_from_slice(&start);
                frame.extend_from_slice(&f.pps);
            }
            frame.extend_from_slice(&start);
            frame.extend_from_slice(slice);
            (frame, *key)
        })
        .collect()
}
