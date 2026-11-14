//! A text as a QR code, desktop-qt's `qr`: for what a phone's camera is to
//! read off the screen (a pairing link). Nayuki's generator does the
//! encoding, as in desktop-qt, so a code is the same module for module.

use qrcodegen::{QrCode, QrCodeEcc};

/// The quiet zone a reader wants around a code, in modules.
const QUIET: usize = 4;

/// A QR code: `size` modules a side, the dark ones set.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Code {
    /// Modules along a side; 0 when the text did not fit a QR code.
    pub size: usize,
    /// The dark modules, row by row.
    modules: Vec<bool>,
}

impl Code {
    pub fn is_null(&self) -> bool {
        self.size == 0
    }

    pub fn dark(&self, x: usize, y: usize) -> bool {
        x < self.size && y < self.size && self.modules[y * self.size + x]
    }
}

/// Error correction M, which a screen needs no more than: the smallest
/// version that holds `text` as bytes. Null for no text and for more than
/// the largest QR code holds.
pub fn encode(text: &str) -> Code {
    if text.is_empty() {
        return Code::default();
    }
    let Ok(generated) = QrCode::encode_text(text, QrCodeEcc::Medium) else {
        return Code::default();
    };
    let size = generated.size() as usize;
    let modules = (0..size * size)
        .map(|i| generated.get_module((i % size) as i32, (i / size) as i32))
        .collect();
    Code { size, modules }
}

/// The dark modules as an SVG path of unit squares (`M3 0h1v1h-1z…`), runs of
/// them joined, for a Shape to fill at any size. Empty for a null code.
pub fn path(code: &Code) -> String {
    let mut path = String::new();
    for y in 0..code.size {
        let mut x = 0;
        while x < code.size {
            if !code.dark(x, y) {
                x += 1;
                continue;
            }
            let mut run = 1;
            while code.dark(x + run, y) {
                run += 1;
            }
            path += &format!("M{x} {y}h{run}v1h-{run}z");
            x += run;
        }
    }
    path
}

/// A picture: `side` by `side` pixels of RGBA, row by row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bitmap {
    pub side: usize,
    pub rgba: Vec<u8>,
}

/// Black on white, `scale` pixels a module, with the quiet zone of four
/// modules a reader wants around it. None for a null code or no scale.
pub fn image(code: &Code, scale: usize) -> Option<Bitmap> {
    if code.is_null() || scale == 0 {
        return None;
    }
    let side = (code.size + 2 * QUIET) * scale;
    let mut rgba = vec![255; side * side * 4];
    for y in 0..code.size {
        for x in 0..code.size {
            if !code.dark(x, y) {
                continue;
            }
            for row in (y + QUIET) * scale..(y + QUIET + 1) * scale {
                let start = (row * side + (x + QUIET) * scale) * 4;
                for pixel in rgba[start..start + scale * 4].as_chunks_mut::<4>().0 {
                    *pixel = [0, 0, 0, 255];
                }
            }
        }
    }
    Some(Bitmap { side, rgba })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_text_is_the_smallest_version() {
        // Version 1 at error correction M holds 14 bytes.
        let code = encode("hal-c2://pair");
        assert_eq!(code.size, 21);
        let code = encode("hal-c2://pair/0123456789");
        assert_eq!(code.size, 25);
    }

    #[test]
    fn a_code_has_the_finder_patterns_in_three_corners() {
        let code = encode("https://example.test/pair#token=abc");
        let last = code.size - 1;
        for (x, y) in [(0, 0), (last, 0), (0, last)] {
            let (x0, y0) = (
                if x == 0 { 0 } else { last - 6 },
                if y == 0 { 0 } else { last - 6 },
            );
            // The 7x7 ring, the light ring inside it and the dark centre.
            assert!(
                code.dark(x0, y0) && code.dark(x0 + 6, y0 + 6),
                "ring at {x},{y}"
            );
            assert!(!code.dark(x0 + 1, y0 + 1), "gap at {x},{y}");
            assert!(code.dark(x0 + 3, y0 + 3), "centre at {x},{y}");
        }
        assert!(!code.dark(code.size, 0));
    }

    #[test]
    fn what_does_not_fit_is_a_null_code() {
        assert!(encode("").is_null());
        assert!(encode(&"x".repeat(3000)).is_null());
        assert!(!encode(&"x".repeat(2000)).is_null());
        assert_eq!(path(&Code::default()), "");
        assert_eq!(image(&Code::default(), 4), None);
    }

    #[test]
    fn the_path_is_the_dark_modules_in_runs_of_unit_squares() {
        let code = encode("abc");
        let path = path(&code);
        assert!(path.starts_with("M0 0h7v1h-7z"), "{path}");
        // Every run is a unit-high rectangle, and together they cover
        // exactly the dark modules.
        let mut covered = 0;
        for run in path.split('z').filter(|r| !r.is_empty()) {
            let (head, rest) = run.split_once('h').unwrap();
            let (x, y) = head.trim_start_matches('M').split_once(' ').unwrap();
            let (width, _) = rest.split_once('v').unwrap();
            let (x, y, width): (usize, usize, usize) = (
                x.parse().unwrap(),
                y.parse().unwrap(),
                width.parse().unwrap(),
            );
            assert!((x..x + width).all(|x| code.dark(x, y)));
            assert!(
                x + width == code.size || !code.dark(x + width, y),
                "a run is whole"
            );
            covered += width;
        }
        let dark = (0..code.size)
            .flat_map(|y| (0..code.size).map(move |x| (x, y)))
            .filter(|&(x, y)| code.dark(x, y))
            .count();
        assert_eq!(covered, dark);
    }

    #[test]
    fn the_image_is_black_on_white_with_a_quiet_zone() {
        let code = encode("abc");
        let scale = 3;
        let bitmap = image(&code, scale).unwrap();
        assert_eq!(bitmap.side, (code.size + 8) * scale);
        assert_eq!(bitmap.rgba.len(), bitmap.side * bitmap.side * 4);
        let pixel = |x: usize, y: usize| bitmap.rgba[(y * bitmap.side + x) * 4..][..4].to_vec();
        // The corner of the quiet zone is white; the first module is dark.
        assert_eq!(pixel(0, 0), [255, 255, 255, 255]);
        assert_eq!(pixel(4 * scale, 4 * scale), [0, 0, 0, 255]);
        assert_eq!(
            pixel(4 * scale + scale - 1, 4 * scale + scale - 1),
            [0, 0, 0, 255]
        );
        // Every module is its colour all over.
        for y in 0..code.size {
            for x in 0..code.size {
                let want = if code.dark(x, y) {
                    [0, 0, 0, 255]
                } else {
                    [255, 255, 255, 255]
                };
                assert_eq!(pixel((x + 4) * scale + 1, (y + 4) * scale + 2), want);
            }
        }
        assert_eq!(image(&code, 0), None);
    }
}
