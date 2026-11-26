//! Reading QR codes off a camera's picture, mobile-qt's QrReader
//! (zxing-cpp there) in pure Rust: the other half of the desktop's
//! qr::encode. The detector is the classic one — a locally
//! thresholded picture searched for finder patterns, an alignment
//! pattern, a perspective sample of the grid — and the decoder the
//! spec's: format and version BCH, unmasking, Reed-Solomon over
//! GF(256), and the numeric, alphanumeric and byte segments. The
//! block tables are the QR specification's, as the encoder's
//! (qrcodegen, MIT) tables in the shell also record them.

/// One byte of brightness a pixel, which is all a reader looks at.
#[derive(Clone, Debug)]
pub struct Gray {
    pub width: usize,
    pub height: usize,
    /// Row-major, `stride` bytes a row (at least width).
    pub stride: usize,
    pub data: Vec<u8>,
}

impl Gray {
    pub fn new(width: usize, height: usize, data: Vec<u8>) -> Option<Gray> {
        (data.len() >= width.saturating_mul(height) && width > 0 && height > 0).then_some(Gray {
            width,
            height,
            stride: width,
            data,
        })
    }

    fn at(&self, x: usize, y: usize) -> u8 {
        self.data[y * self.stride + x]
    }
}

/// A camera frame's pixel format, the ones a phone delivers first:
/// most carry brightness as their first plane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameFormat {
    Yuv420p,
    Yuv422p,
    Yv12,
    Nv12,
    Nv21,
    Imc1,
    Imc2,
    Imc3,
    Imc4,
    Y8,
    /// Four bytes a pixel, R, G, B then alpha (or B, G, R: the same
    /// brightness either way round for a reader).
    Rgba8888,
    Bgra8888,
    /// Already one byte of brightness a pixel.
    Gray8,
    Other,
}

impl FrameFormat {
    fn starts_with_luminance(self) -> bool {
        matches!(
            self,
            FrameFormat::Yuv420p
                | FrameFormat::Yuv422p
                | FrameFormat::Yv12
                | FrameFormat::Nv12
                | FrameFormat::Nv21
                | FrameFormat::Imc1
                | FrameFormat::Imc2
                | FrameFormat::Imc3
                | FrameFormat::Imc4
                | FrameFormat::Y8
                | FrameFormat::Gray8
        )
    }
}

/// A frame as a camera hands it over: its planes and their strides.
#[derive(Clone, Debug)]
pub struct Frame {
    pub format: FrameFormat,
    pub width: usize,
    pub height: usize,
    pub planes: Vec<(Vec<u8>, usize)>,
}

/// What a frame shows as one byte of brightness a pixel. Most
/// cameras' formats carry that as their first plane, which is
/// copied as it is; any other frame's pixels are converted. None
/// for a frame that cannot be read.
pub fn luminance(frame: &Frame) -> Option<Gray> {
    if frame.width == 0 || frame.height == 0 || frame.planes.is_empty() {
        return None;
    }
    let (plane, stride) = &frame.planes[0];
    if frame.format.starts_with_luminance() {
        if *stride < frame.width || plane.len() < stride * frame.height {
            return None;
        }
        let mut data = Vec::with_capacity(frame.width * frame.height);
        for y in 0..frame.height {
            data.extend_from_slice(&plane[y * stride..y * stride + frame.width]);
        }
        return Gray::new(frame.width, frame.height, data);
    }
    match frame.format {
        FrameFormat::Rgba8888 | FrameFormat::Bgra8888 => {
            if *stride < frame.width * 4 || plane.len() < stride * frame.height {
                return None;
            }
            let mut data = Vec::with_capacity(frame.width * frame.height);
            for y in 0..frame.height {
                for x in 0..frame.width {
                    let at = y * stride + x * 4;
                    let (r, g, b) = (plane[at] as u32, plane[at + 1] as u32, plane[at + 2] as u32);
                    // QImage's grayscale conversion (ITU-R 601 luma).
                    data.push(((r * 11 + g * 16 + b * 5) / 32) as u8);
                }
            }
            Gray::new(frame.width, frame.height, data)
        }
        _ => None,
    }
}

/// Brightness from RGBA bytes, for a picture a test or a producer
/// already hold as one.
pub fn luminance_rgba(width: usize, height: usize, rgba: Vec<u8>) -> Option<Gray> {
    luminance(&Frame {
        format: FrameFormat::Rgba8888,
        width,
        height,
        planes: vec![(rgba, width * 4)],
    })
}

/// The text of every QR code in the picture, however it is turned
/// and wherever it sits; none when there is none. Slow enough (some
/// milliseconds a megapixel) to belong off the thread that draws.
pub fn read(picture: &Gray) -> Vec<String> {
    let mut bits = binarize(picture);
    let mut texts = Vec::new();
    for _ in 0..4 {
        let Some(found) = detect(&bits) else {
            break;
        };
        let quad = found.quad;
        if let Some(text) = decode(&bits, &found)
            && !texts.contains(&text)
        {
            texts.push(text);
        }
        blank(&mut bits, &quad);
    }
    texts
}

/// A binarized picture: true is dark.
struct Bits {
    width: usize,
    height: usize,
    dark: Vec<bool>,
}

impl Bits {
    fn at(&self, x: i32, y: i32) -> bool {
        x >= 0
            && y >= 0
            && (x as usize) < self.width
            && (y as usize) < self.height
            && self.dark[y as usize * self.width + x as usize]
    }
}

/// A local threshold, as zxing's hybrid binarizer: the mean of each
/// 8x8 block, averaged with its neighbours, less a little.
fn binarize(picture: &Gray) -> Bits {
    const BLOCK: usize = 8;
    let (w, h) = (picture.width, picture.height);
    let bw = w.div_ceil(BLOCK);
    let bh = h.div_ceil(BLOCK);
    let mut means = vec![0f32; bw * bh];
    for by in 0..bh {
        for bx in 0..bw {
            let mut sum = 0u32;
            let mut count = 0u32;
            for y in by * BLOCK..((by + 1) * BLOCK).min(h) {
                for x in bx * BLOCK..((bx + 1) * BLOCK).min(w) {
                    sum += picture.at(x, y) as u32;
                    count += 1;
                }
            }
            means[by * bw + bx] = sum as f32 / count.max(1) as f32;
        }
    }
    let mut dark = vec![false; w * h];
    for by in 0..bh {
        for bx in 0..bw {
            let mut sum = 0f32;
            let mut count = 0u32;
            for dy in -2i32..=2 {
                for dx in -2i32..=2 {
                    let (nx, ny) = (bx as i32 + dx, by as i32 + dy);
                    if nx >= 0 && ny >= 0 && (nx as usize) < bw && (ny as usize) < bh {
                        sum += means[ny as usize * bw + nx as usize];
                        count += 1;
                    }
                }
            }
            let threshold = sum / count.max(1) as f32 - 5.0;
            for y in by * BLOCK..((by + 1) * BLOCK).min(h) {
                for x in bx * BLOCK..((bx + 1) * BLOCK).min(w) {
                    if (picture.at(x, y) as f32) < threshold {
                        dark[y * w + x] = true;
                    }
                }
            }
        }
    }
    Bits {
        width: w,
        height: h,
        dark,
    }
}

fn blank(bits: &mut Bits, quad: &[(f32, f32); 4]) {
    let min_x = quad.iter().map(|p| p.0).fold(f32::INFINITY, f32::min) as i32;
    let max_x = quad.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max) as i32;
    let min_y = quad.iter().map(|p| p.1).fold(f32::INFINITY, f32::min) as i32;
    let max_y = quad.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max) as i32;
    for y in min_y.max(0)..=max_y.min(bits.height as i32 - 1) {
        for x in min_x.max(0)..=max_x.min(bits.width as i32 - 1) {
            bits.dark[y as usize * bits.width + x as usize] = false;
        }
    }
}

/// A found code: its finder centres in image coordinates (top-left,
/// top-right, bottom-left), its module size in pixels, and the
/// quad to blank when looking for the next one.
struct Found {
    tl: (f32, f32),
    tr: (f32, f32),
    bl: (f32, f32),
    module: f32,
    quad: [(f32, f32); 4],
}

#[derive(Clone, Copy)]
struct Finder {
    x: f32,
    y: f32,
    module: f32,
    count: u32,
}

fn ratio_ok(counts: &[u32; 5]) -> Option<(f32, f32)> {
    let total: u32 = counts.iter().sum();
    if total < 7 {
        return None;
    }
    let module = total as f32 / 7.0;
    let tolerance = module / 2.0;
    for (i, count) in counts.iter().enumerate() {
        let want = if i == 2 { module * 3.0 } else { module };
        if (*count as f32 - want).abs() > tolerance * if i == 2 { 3.0 } else { 1.0 } {
            return None;
        }
    }
    Some((module, total as f32))
}

/// The centre of a run of counts ending at `end` (exclusive): the
/// middle of the middle run.
fn centre(end: i32, counts: &[u32; 5]) -> f32 {
    end as f32 - counts[4] as f32 - counts[3] as f32 - counts[2] as f32 / 2.0
}

/// Runs along a line of pixels: (dark, length, end exclusive).
fn runs(mut next: impl FnMut(i32) -> Option<bool>, from: i32, to: i32) -> Vec<(bool, u32, i32)> {
    let mut out: Vec<(bool, u32, i32)> = Vec::new();
    let mut at = from;
    while let Some(dark) = next(at) {
        if at >= to {
            break;
        }
        match out.last_mut() {
            Some((held, len, end)) if *held == dark => {
                *len += 1;
                *end = at + 1;
            }
            _ => out.push((dark, 1, at + 1)),
        }
        at += 1;
    }
    out
}

fn cross_vertical(bits: &Bits, x: i32, y: i32, half: i32) -> Option<(f32, f32)> {
    let col = runs(
        |at| {
            (0..bits.height as i32)
                .contains(&at)
                .then(|| bits.at(x, at))
        },
        (y - half).max(0),
        (y + half).min(bits.height as i32),
    );
    for window in col.windows(5) {
        if !window[0].0 {
            continue;
        }
        let counts = [
            window[0].1,
            window[1].1,
            window[2].1,
            window[3].1,
            window[4].1,
        ];
        let top = window[0].2 - window[0].1 as i32;
        let bottom = window[4].2;
        if top > y || bottom <= y {
            continue;
        }
        let (module, _) = ratio_ok(&counts)?;
        return Some((centre(bottom, &counts), module));
    }
    None
}

fn finders(bits: &Bits) -> Vec<Finder> {
    let mut candidates: Vec<Finder> = Vec::new();
    for y in 0..bits.height as i32 {
        let row = runs(
            |at| (0..bits.width as i32).contains(&at).then(|| bits.at(at, y)),
            0,
            bits.width as i32,
        );
        for window in row.windows(5) {
            if !window[0].0 {
                continue;
            }
            let counts = [
                window[0].1,
                window[1].1,
                window[2].1,
                window[3].1,
                window[4].1,
            ];
            let Some((module, _)) = ratio_ok(&counts) else {
                continue;
            };
            let cx = centre(window[4].2, &counts);
            if let Some((cy, vmodule)) =
                cross_vertical(bits, cx as i32, y, (module * 4.0) as i32 + 2)
            {
                candidates.push(Finder {
                    x: cx,
                    y: cy,
                    module: (module + vmodule) / 2.0,
                    count: 1,
                });
            }
        }
    }
    // Cluster: a finder is seen on many rows around one centre.
    let mut clustered: Vec<Finder> = Vec::new();
    for cand in candidates {
        let mut merged = false;
        for held in &mut clustered {
            let dx = (held.x - cand.x).abs();
            let dy = (held.y - cand.y).abs();
            if dx < cand.module * 2.0 && dy < cand.module * 2.0 {
                let n = held.count as f32;
                held.x = (held.x * n + cand.x) / (n + 1.0);
                held.y = (held.y * n + cand.y) / (n + 1.0);
                held.module = (held.module * n + cand.module) / (n + 1.0);
                held.count += 1;
                merged = true;
                break;
            }
        }
        if !merged {
            clustered.push(cand);
        }
    }
    clustered.retain(|f| f.count >= 2);
    clustered
}

fn dist(a: (f32, f32), b: (f32, f32)) -> f32 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

/// Orders three finders as top-left, top-right, bottom-left: the
/// right angle is the corner, and the cross product says which of
/// the other two is which.
fn order(a: Finder, b: Finder, c: Finder) -> Option<(Finder, Finder, Finder, f32)> {
    let pts = [a, b, c];
    let sides = [
        dist((pts[1].x, pts[1].y), (pts[2].x, pts[2].y)),
        dist((pts[0].x, pts[0].y), (pts[2].x, pts[2].y)),
        dist((pts[0].x, pts[0].y), (pts[1].x, pts[1].y)),
    ];
    // The longest side is the hypotenuse; its opposite point is the corner.
    let corner = if sides[0] >= sides[1] && sides[0] >= sides[2] {
        0
    } else if sides[1] >= sides[2] {
        1
    } else {
        2
    };
    let others: Vec<usize> = (0..3).filter(|i| *i != corner).collect();
    let (p, q) = (pts[others[0]], pts[others[1]]);
    let corner_f = pts[corner];
    let cross = (p.x - corner_f.x) * (q.y - corner_f.y) - (p.y - corner_f.y) * (q.x - corner_f.x);
    if cross == 0.0 {
        return None;
    }
    // In image coordinates (y down), going corner -> right -> down
    // is clockwise on the page, which is a positive cross product.
    let (tr, bl) = if cross > 0.0 { (p, q) } else { (q, p) };
    let modules = (corner_f.module + tr.module + bl.module) / 3.0;
    // A score for how square the triple is, and how far its
    // finders' module sizes agree: a split cluster's stray piece
    // can be as square as the true corner, but not as even.
    let legs = [
        dist((corner_f.x, corner_f.y), (tr.x, tr.y)),
        dist((corner_f.x, corner_f.y), (bl.x, bl.y)),
    ];
    let sizes = [corner_f.module, tr.module, bl.module];
    let spread = (sizes.iter().cloned().fold(f32::MIN, f32::max)
        - sizes.iter().cloned().fold(f32::MAX, f32::min))
        / modules.max(1.0);
    let score = (legs[0] - legs[1]).abs() / legs[0].max(legs[1]).max(1.0) + spread;
    Some((corner_f, tr, bl, score))
}

/// Alignment pattern centre positions for a version (the spec's,
/// as the encoder computes them).
fn alignment_positions(version: usize, dimension: usize) -> Vec<i32> {
    if version == 1 {
        return Vec::new();
    }
    let num_align = version as i32 / 7 + 2;
    let step = if version == 32 {
        26
    } else {
        (version as i32 * 4 + num_align * 2 + 1) / (num_align * 2 - 2) * 2
    };
    let mut result: Vec<i32> = (0..num_align - 1)
        .map(|i| dimension as i32 - 7 - i * step)
        .collect();
    result.push(6);
    result.reverse();
    result
}

/// A projective transform from module coordinates to image ones,
/// as nine coefficients with the last fixed at 1.
#[derive(Clone, Copy)]
struct Transform([f64; 8]);

impl Transform {
    #[allow(clippy::needless_range_loop)]
    fn from_points(from: [(f64, f64); 4], to: [(f64, f64); 4]) -> Option<Transform> {
        // Gaussian elimination on the eight equations of four point
        // pairs.
        let mut a = [[0f64; 9]; 8];
        for (i, ((x, y), (u, v))) in from.iter().zip(to.iter()).enumerate() {
            a[i * 2] = [*x, *y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, *u];
            a[i * 2 + 1] = [0.0, 0.0, 0.0, *x, *y, 1.0, -v * x, -v * y, *v];
        }
        for col in 0..8 {
            let pivot = (col..8).max_by(|r, s| {
                a[*r][col]
                    .abs()
                    .partial_cmp(&a[*s][col].abs())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })?;
            if a[pivot][col].abs() < 1e-12 {
                return None;
            }
            a.swap(col, pivot);
            let head = a[col][col];
            for j in col..9 {
                a[col][j] /= head;
            }
            for row in 0..8 {
                if row != col && a[row][col] != 0.0 {
                    let factor = a[row][col];
                    for j in col..9 {
                        a[row][j] -= factor * a[col][j];
                    }
                }
            }
        }
        Some(Transform([
            a[0][8], a[1][8], a[2][8], a[3][8], a[4][8], a[5][8], a[6][8], a[7][8],
        ]))
    }

    fn map(&self, x: f64, y: f64) -> (f64, f64) {
        let [a, b, c, d, e, f, g, h] = self.0;
        let w = g * x + h * y + 1.0;
        ((a * x + b * y + c) / w, (d * x + e * y + f) / w)
    }
}

/// Searches a small window for an alignment pattern centre: a dark
/// module with the counts of one around it, both ways.
fn find_alignment(bits: &Bits, near: (f32, f32), module: f32) -> Option<(f32, f32)> {
    let radius = (module * 4.0) as i32 + 2;
    let (cx, cy) = (near.0.round() as i32, near.1.round() as i32);
    let mut best: Option<(f32, f32, f32)> = None;
    for y in (cy - radius).max(0)..=(cy + radius).min(bits.height as i32 - 1) {
        let row = runs(
            |at| (0..bits.width as i32).contains(&at).then(|| bits.at(at, y)),
            (cx - radius).max(0),
            (cx + radius).min(bits.width as i32),
        );
        for window in row.windows(5) {
            if !window[0].0 {
                continue;
            }
            let counts: Vec<u32> = window.iter().map(|r| r.1).collect();
            // 1:1:1:1:1 around the centre module.
            let total: u32 = counts.iter().sum();
            if total == 0 {
                continue;
            }
            let unit = total as f32 / 5.0;
            if counts
                .iter()
                .any(|c| (*c as f32 - unit).abs() > unit * 0.9 + 1.0)
            {
                continue;
            }
            let mid_x =
                window[4].2 as f32 - counts[4] as f32 - counts[3] as f32 - counts[2] as f32 / 2.0;
            if let Some((mid_y, _)) =
                cross_vertical(bits, mid_x as i32, y, (module * 4.0) as i32 + 2)
            {
                let score = (mid_x - near.0).abs() + (mid_y - near.1).abs();
                if best.is_none_or(|(_, _, held)| score < held) {
                    best = Some((mid_x, mid_y, score));
                }
            }
        }
    }
    // Only a centre near where the pattern must be counts: a data
    // pattern that merely looks like one would pull the whole
    // sampling with it, where the guessed corner would not.
    best.filter(|(_, _, score)| *score <= module * 2.0)
        .map(|(x, y, _)| (x, y))
}

/// Samples the module grid of `dimension` under `transform`:
/// the middle of each module, averaged over a small patch while
/// modules are big enough for one.
fn sample(bits: &Bits, transform: &Transform, dimension: usize, module_px: f32) -> Vec<bool> {
    let mut grid = vec![false; dimension * dimension];
    let patch = if module_px >= 5.0 { 1 } else { 0 };
    for y in 0..dimension {
        for x in 0..dimension {
            let (px, py) = transform.map(x as f64 + 0.5, y as f64 + 0.5);
            let mut dark = 0u32;
            let mut seen = 0u32;
            for dy in -patch..=patch {
                for dx in -patch..=patch {
                    let (sx, sy) = (px.round() as i32 + dx, py.round() as i32 + dy);
                    if (0..bits.width as i32).contains(&sx) && (0..bits.height as i32).contains(&sy)
                    {
                        seen += 1;
                        dark += bits.at(sx, sy) as u32;
                    }
                }
            }
            grid[y * dimension + x] = seen > 0 && dark * 2 > seen;
        }
    }
    grid
}

fn detect(bits: &Bits) -> Option<Found> {
    let found = finders(bits);
    let mut best: Option<(Finder, Finder, Finder, f32)> = None;
    for i in 0..found.len() {
        for j in i + 1..found.len() {
            for k in j + 1..found.len() {
                let Some((tl, tr, bl, score)) = order(found[i], found[j], found[k]) else {
                    continue;
                };
                if score > 0.6 {
                    continue;
                }
                if best.is_none_or(|(_, _, _, held)| score < held) {
                    best = Some((tl, tr, bl, score));
                }
            }
        }
    }
    let (tl, tr, bl, _) = best?;
    let module = (tl.module + tr.module + bl.module) / 3.0;
    let br = (tr.x + bl.x - tl.x, tr.y + bl.y - tl.y);
    let pad = module * 3.5;
    Some(Found {
        tl: (tl.x, tl.y),
        tr: (tr.x, tr.y),
        bl: (bl.x, bl.y),
        module,
        quad: [
            (tl.x - pad, tl.y - pad),
            (tr.x + pad, tr.y - pad),
            (br.0 + pad, br.1 + pad),
            (bl.x - pad, bl.y + pad),
        ],
    })
}

/// The transform and grid for every plausible dimension of a found
/// code, nearest the measured one first.
fn grids(bits: &Bits, found: &Found) -> Vec<(usize, Vec<bool>)> {
    let top = dist(found.tl, found.tr);
    let left = dist(found.tl, found.bl);
    let estimated = ((top + left) / 2.0 / found.module).round() as i32 + 7;
    // Every valid dimension near the estimate, nearest first: a
    // turned finder's measured module size is off by enough to
    // land between versions.
    let mut dimensions: Vec<usize> = (21..=177usize)
        .filter(|d| (d - 17) % 4 == 0 && (*d as i32 - estimated).abs() <= 8)
        .collect();
    dimensions.sort_by_key(|d| (*d as i32 - estimated).abs());
    let mut out = Vec::new();
    for dimension in dimensions {
        let version = (dimension - 17) / 4;
        let d = dimension as f64;
        let far = (d - 3.5, d - 3.5);
        let br = (
            found.tr.0 + found.bl.0 - found.tl.0,
            found.tr.1 + found.bl.1 - found.tl.1,
        );
        // With an alignment pattern, the transform is exact at its
        // centre instead of at a guessed fourth corner.
        let positions = alignment_positions(version, dimension);
        let transform = if let Some(last) = positions.last().copied() {
            let affine = Transform::from_points(
                [(3.5, 3.5), (far.0, 3.5), (3.5, far.1), (far.0, far.1)],
                [
                    (found.tl.0 as f64, found.tl.1 as f64),
                    (found.tr.0 as f64, found.tr.1 as f64),
                    (found.bl.0 as f64, found.bl.1 as f64),
                    (br.0 as f64, br.1 as f64),
                ],
            );
            let aligned = affine.and_then(|approx| {
                let expected = approx.map(last as f64 + 0.5, last as f64 + 0.5);
                let centre =
                    find_alignment(bits, (expected.0 as f32, expected.1 as f32), found.module)?;
                Transform::from_points(
                    [
                        (3.5, 3.5),
                        (far.0, 3.5),
                        (3.5, far.1),
                        (last as f64 + 0.5, last as f64 + 0.5),
                    ],
                    [
                        (found.tl.0 as f64, found.tl.1 as f64),
                        (found.tr.0 as f64, found.tr.1 as f64),
                        (found.bl.0 as f64, found.bl.1 as f64),
                        (centre.0 as f64, centre.1 as f64),
                    ],
                )
            });
            aligned.or(affine)
        } else {
            Transform::from_points(
                [(3.5, 3.5), (far.0, 3.5), (3.5, far.1), (far.0, far.1)],
                [
                    (found.tl.0 as f64, found.tl.1 as f64),
                    (found.tr.0 as f64, found.tr.1 as f64),
                    (found.bl.0 as f64, found.bl.1 as f64),
                    (br.0 as f64, br.1 as f64),
                ],
            )
        };
        if let Some(transform) = transform {
            out.push((dimension, sample(bits, &transform, dimension, found.module)));
        }
    }
    out
}

/// ECC codewords a block (the QR specification's tables, as the
/// encoder's qrcodegen tables record them). Rows are L, M, Q, H;
/// index 0 is padding.
#[rustfmt::skip]
static ECC_PER_BLOCK: [[i8; 41]; 4] = [
    [-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];

#[rustfmt::skip]
static NUM_BLOCKS: [[i8; 41]; 4] = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];

fn raw_modules(version: usize) -> usize {
    let mut result = (16 * version + 128) * version + 64;
    if version >= 2 {
        let num_align = version / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if version >= 7 {
            result -= 36;
        }
    }
    result
}

/// GF(256) with the QR field polynomial 0x11D and generator 2.
mod gf {
    pub fn tables() -> ([u8; 512], [u8; 256]) {
        let mut exp = [0u8; 512];
        let mut log = [0u8; 256];
        let mut x = 1u16;
        for (i, slot) in exp.iter_mut().enumerate().take(255) {
            *slot = x as u8;
            log[x as usize] = i as u8;
            x <<= 1;
            if x & 0x100 != 0 {
                x ^= 0x11D;
            }
        }
        for i in 255..512 {
            exp[i] = exp[i - 255];
        }
        (exp, log)
    }

    /// Corrects `block` (data then `ecc` check bytes) in place;
    /// false when it is beyond repair. Syndromes at the generator's
    /// roots, Berlekamp-Massey for the error locator, a Chien search
    /// for its roots, and Forney's formula for the magnitudes, all
    /// with polynomials written lowest degree first.
    pub fn correct(block: &mut [u8], ecc: usize) -> bool {
        if ecc == 0 || block.len() <= ecc || block.len() > 255 {
            return false;
        }
        let (exp, log) = tables();
        let mul = |a: u8, b: u8| -> u8 {
            if a == 0 || b == 0 {
                0
            } else {
                exp[log[a as usize] as usize + log[b as usize] as usize]
            }
        };
        let div = |a: u8, b: u8| -> u8 {
            if a == 0 {
                0
            } else {
                exp[(log[a as usize] as usize + 255 - log[b as usize] as usize) % 255]
            }
        };
        fn evaluate(block: &[u8], at: u8, mul: &impl Fn(u8, u8) -> u8) -> u8 {
            let mut sum = 0u8;
            for byte in block.iter() {
                sum = mul(sum, at) ^ byte;
            }
            sum
        }
        // S_k = r(a^k) for k in 0..ecc, the generator's roots.
        let syndromes: Vec<u8> = (0..ecc).map(|k| evaluate(block, exp[k], &mul)).collect();
        if syndromes.iter().all(|s| *s == 0) {
            return true;
        }
        // Berlekamp-Massey: the shortest recurrence the syndromes
        // follow is the error locator.
        let mut locator = vec![1u8];
        let mut previous = vec![1u8];
        let mut errors = 0usize;
        let mut shift = 1usize;
        let mut last = 1u8;
        for n in 0..ecc {
            let mut discrepancy = syndromes[n];
            for i in 1..=errors {
                if i < locator.len() {
                    discrepancy ^= mul(locator[i], syndromes[n - i]);
                }
            }
            if discrepancy == 0 {
                shift += 1;
                continue;
            }
            let scale = div(discrepancy, last);
            let mut next = vec![0u8; locator.len().max(previous.len() + shift)];
            next[..locator.len()].copy_from_slice(&locator);
            for (i, coef) in previous.iter().enumerate() {
                next[i + shift] ^= mul(scale, *coef);
            }
            if 2 * errors <= n {
                previous = locator.clone();
                errors = n + 1 - errors;
                last = discrepancy;
                shift = 1;
            } else {
                shift += 1;
            }
            locator = next;
        }
        if errors == 0 || errors * 2 > ecc {
            return false;
        }
        // The error evaluator: syndrome times locator, low terms.
        let mut evaluator = vec![0u8; errors];
        for i in 0..errors {
            let mut sum = 0u8;
            for j in 0..=i.min(locator.len() - 1) {
                sum ^= mul(locator[j], syndromes[i - j]);
            }
            evaluator[i] = sum;
        }
        let eval = |poly: &[u8], at: u8| -> u8 {
            poly.iter().rev().fold(0u8, |sum, coef| mul(sum, at) ^ coef)
        };
        // Chien search over the block's positions: the byte at index
        // i multiplies x^(len-1-i), whose location is a^(len-1-i).
        let len = block.len();
        let mut fixed = 0usize;
        for (index, byte) in block.iter_mut().enumerate() {
            let power = len - 1 - index;
            let location = exp[power % 255];
            let inverse = div(1, location);
            if eval(&locator, inverse) != 0 {
                continue;
            }
            // The locator's derivative keeps its odd terms.
            let mut derivative = 0u8;
            let mut term = 1u8;
            for (i, coef) in locator.iter().enumerate().skip(1) {
                if i % 2 == 1 {
                    derivative ^= mul(*coef, term);
                }
                term = mul(term, inverse);
            }
            if derivative == 0 {
                return false;
            }
            *byte ^= mul(location, div(eval(&evaluator, inverse), derivative));
            fixed += 1;
        }
        if fixed != errors {
            return false;
        }
        (0..ecc).all(|k| evaluate(block, exp[k], &mul) == 0)
    }
}

/// The function modules of a code of `dimension`: finders,
/// separators, timing, alignment, format and version areas.
fn function_modules(dimension: usize, version: usize) -> Vec<bool> {
    let mut map = vec![false; dimension * dimension];
    let mark = |x: i32, y: i32, map: &mut Vec<bool>| {
        if x >= 0 && y >= 0 && (x as usize) < dimension && (y as usize) < dimension {
            map[y as usize * dimension + x as usize] = true;
        }
    };
    for i in 0..dimension as i32 {
        mark(i, 6, &mut map);
        mark(6, i, &mut map);
    }
    let finder = |cx: i32, cy: i32, map: &mut Vec<bool>| {
        for dy in -4..=4 {
            for dx in -4..=4 {
                mark(cx + dx, cy + dy, map);
            }
        }
    };
    let d = dimension as i32;
    finder(3, 3, &mut map);
    finder(d - 4, 3, &mut map);
    finder(3, d - 4, &mut map);
    let positions = alignment_positions(version, dimension);
    for (i, x) in positions.iter().enumerate() {
        for (j, y) in positions.iter().enumerate() {
            if (i == 0 && j == 0)
                || (i == 0 && j == positions.len() - 1)
                || (i == positions.len() - 1 && j == 0)
            {
                continue;
            }
            for dy in -2..=2 {
                for dx in -2..=2 {
                    mark(x + dx, y + dy, &mut map);
                }
            }
        }
    }
    // Format bits, both copies, and the version areas.
    for i in 0..=8 {
        mark(i, 8, &mut map);
        mark(8, i, &mut map);
    }
    for i in 0..8 {
        mark(8, d - 1 - i, &mut map);
        mark(d - 8 + i, 8, &mut map);
    }
    mark(8, d - 8, &mut map);
    if version >= 7 {
        for y in 0..6 {
            for x in 0..3 {
                mark(d - 11 + x, y, &mut map);
                mark(y, d - 11 + x, &mut map);
            }
        }
    }
    map
}

fn format_bits(grid: &[bool], dimension: usize) -> Option<(usize, usize)> {
    let at = |x: usize, y: usize| grid[y * dimension + x] as u32;
    let mut first = 0u32;
    for i in 0..6 {
        first = (first << 1) | at(i, 8);
    }
    first = (first << 1) | at(7, 8);
    first = (first << 1) | at(8, 8);
    first = (first << 1) | at(8, 7);
    for i in (0..6).rev() {
        first = (first << 1) | at(8, i);
    }
    let mut second = 0u32;
    for i in 0..7 {
        second = (second << 1) | at(8, dimension - 1 - i);
    }
    for i in 0..8 {
        second = (second << 1) | at(dimension - 8 + i, 8);
    }
    // All 32 valid strings to their level and mask, by distance.
    let mut best: Option<(u32, usize, usize)> = None;
    for ecl in 0..4 {
        let ec_bits = [1u32, 0, 3, 2][ecl];
        for mask in 0..8usize {
            let data = (ec_bits << 3) | mask as u32;
            let mut rest = data;
            for _ in 0..10 {
                rest = (rest << 1) ^ if rest >> 9 != 0 { 0x537 } else { 0 };
            }
            let valid = ((data << 10) | (rest & 0x3FF)) ^ 0x5412;
            for read in [first, second] {
                let distance = (valid ^ read).count_ones();
                if best.is_none_or(|(held, _, _)| distance < held) {
                    best = Some((distance, ecl, mask));
                }
            }
        }
    }
    let (distance, ecl, mask) = best?;
    (distance <= 3).then_some((ecl, mask))
}

fn masked(mask: usize, x: usize, y: usize) -> bool {
    let (x, y) = (x as i32, y as i32);
    match mask {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        _ => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    }
}

struct BitReader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl BitReader<'_> {
    fn read(&mut self, bits: usize) -> Option<u32> {
        if self.at + bits > self.bytes.len() * 8 {
            return None;
        }
        let mut value = 0u32;
        for _ in 0..bits {
            value = (value << 1) | ((self.bytes[self.at / 8] >> (7 - self.at % 8)) & 1) as u32;
            self.at += 1;
        }
        Some(value)
    }
}

const ALPHANUMERIC: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

fn segments(data: &[u8], version: usize) -> Option<String> {
    let mut reader = BitReader { bytes: data, at: 0 };
    let count_bits = |mode: u32| -> usize {
        let range = if version <= 9 {
            [10, 9, 8, 8]
        } else if version <= 26 {
            [12, 11, 16, 10]
        } else {
            [14, 13, 16, 12]
        };
        match mode {
            1 => range[0],
            2 => range[1],
            4 => range[2],
            _ => range[3],
        }
    };
    let mut out = Vec::new();
    loop {
        if reader.bytes.len() * 8 - reader.at < 4 {
            break;
        }
        let mode = reader.read(4)?;
        match mode {
            0 => break,
            1 => {
                let mut left = reader.read(count_bits(1))? as usize;
                while left >= 3 {
                    out.extend_from_slice(format!("{:03}", reader.read(10)?).as_bytes());
                    left -= 3;
                }
                if left == 2 {
                    out.extend_from_slice(format!("{:02}", reader.read(7)?).as_bytes());
                } else if left == 1 {
                    out.extend_from_slice(format!("{}", reader.read(4)?).as_bytes());
                }
            }
            2 => {
                let mut left = reader.read(count_bits(2))? as usize;
                while left >= 2 {
                    let pair = reader.read(11)? as usize;
                    out.push(*ALPHANUMERIC.get(pair / 45)?);
                    out.push(*ALPHANUMERIC.get(pair % 45)?);
                    left -= 2;
                }
                if left == 1 {
                    out.push(*ALPHANUMERIC.get(reader.read(6)? as usize)?);
                }
            }
            4 => {
                let count = reader.read(count_bits(4))? as usize;
                for _ in 0..count {
                    out.push(reader.read(8)? as u8);
                }
            }
            7 => {
                // ECI designator: not a text segment.
                let first = reader.read(8)?;
                if first & 0x80 != 0 {
                    reader.read(8)?;
                    if first & 0xC0 == 0xC0 {
                        reader.read(8)?;
                    }
                }
            }
            _ => return None,
        }
    }
    String::from_utf8(out).ok()
}

/// Decodes one sampled grid in any orientation the finders gave.
fn decode_grid(grid: &[bool], dimension: usize) -> Option<String> {
    let version = (dimension - 17) / 4;
    if !(1..=40).contains(&version) {
        return None;
    }
    let (ecl, mask) = format_bits(grid, dimension)?;
    let function = function_modules(dimension, version);
    let raw = raw_modules(version) / 8;
    let mut bits: Vec<u8> = Vec::with_capacity(raw * 8);
    let mut upward = true;
    let mut x = dimension as i32 - 1;
    while x > 0 {
        if x == 6 {
            x -= 1;
        }
        for step in 0..dimension {
            let y = if upward { dimension - 1 - step } else { step };
            for dx in [0i32, -1] {
                let cx = (x + dx) as usize;
                if !function[y * dimension + cx] {
                    let dark = grid[y * dimension + cx] != masked(mask, cx, y);
                    bits.push(dark as u8);
                }
            }
        }
        upward = !upward;
        x -= 2;
    }
    bits.truncate(raw * 8);
    let mut codewords = vec![0u8; raw];
    for (i, bit) in bits.iter().enumerate() {
        codewords[i / 8] |= bit << (7 - i % 8);
    }
    // Deinterleave into blocks and correct each.
    let num_blocks = NUM_BLOCKS[ecl][version] as usize;
    let ec_len = ECC_PER_BLOCK[ecl][version] as usize;
    let num_short = num_blocks - raw % num_blocks;
    let short_len = raw / num_blocks;
    let mut blocks: Vec<Vec<u8>> = (0..num_blocks)
        .map(|i| Vec::with_capacity(short_len + usize::from(i >= num_short)))
        .collect();
    let mut at = 0usize;
    for i in 0..=short_len {
        for (j, block) in blocks.iter_mut().enumerate() {
            if (i != short_len - ec_len || j >= num_short) && at < codewords.len() {
                block.push(codewords[at]);
                at += 1;
            }
        }
    }
    let mut data = Vec::new();
    for mut block in blocks {
        if !gf::correct(&mut block, ec_len) {
            return None;
        }
        block.truncate(block.len() - ec_len);
        data.extend_from_slice(&block);
    }
    segments(&data, version)
}

fn decode(bits: &Bits, found: &Found) -> Option<String> {
    for (dimension, grid) in grids(bits, found) {
        if let Some(text) = decode_grid(&grid, dimension) {
            return Some(text);
        }
        // A mirrored code (a front camera) reads transposed.
        let mut mirrored = vec![false; grid.len()];
        for y in 0..dimension {
            for x in 0..dimension {
                mirrored[x * dimension + y] = grid[y * dimension + x];
            }
        }
        if let Some(text) = decode_grid(&mirrored, dimension) {
            return Some(text);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use qrcodegen::{QrCode, QrCodeEcc};

    const LINK: &str = "https://devbox.tailnet.ts.net/pair#token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA";

    /// A desk with no code on it, fixed as the C++ tests' is.
    fn desk(width: usize, height: usize) -> Gray {
        let mut data = vec![0u8; width * height];
        let mut state = 7u32;
        let mut next = move || {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            (state >> 16) as usize
        };
        for y in 0..height {
            for x in 0..width {
                data[y * width + x] = (70 + (x + y) * 126 / (width + height)) as u8;
            }
        }
        for i in 0..60 {
            let (x, y) = (next() % width, next() % height);
            let (w, h) = (8 + next() % (width / 5), 8 + next() % (height / 5));
            let value = (next() % 256) as u8;
            if i % 3 != 0 {
                for yy in y..(y + h).min(height) {
                    for xx in x..(x + w).min(width) {
                        data[yy * width + xx] = value;
                    }
                }
            }
        }
        Gray::new(width, height, data).unwrap()
    }

    /// The desk with `text`'s code on a screen: `side` pixels
    /// across, turned by `degrees`, off the picture's middle, drawn
    /// supersampled as QPainter's smooth transform draws it.
    fn sees(text: &str, width: usize, height: usize, side: usize, degrees: f32) -> Gray {
        let code = QrCode::encode_text(text, QrCodeEcc::Medium).unwrap();
        let modules = code.size() as usize;
        let quiet = 4usize;
        let span = (modules + quiet * 2) as f32;
        let mut picture = desk(width, height);
        let (cx, cy) = (width as f32 * 0.58, height as f32 * 0.46);
        let (sin, cos) = degrees.to_radians().sin_cos();
        let scale = side as f32 / span;
        for y in 0..height {
            for x in 0..width {
                // Four samples a pixel, averaged: the smooth turn.
                let mut sum = 0u32;
                let mut inside = 0u32;
                for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let (dx, dy) = (x as f32 + ox - cx, y as f32 + oy - cy);
                    let u = (dx * cos + dy * sin) / scale + span / 2.0;
                    let v = (-dx * sin + dy * cos) / scale + span / 2.0;
                    if u >= 0.0 && v >= 0.0 && u < span && v < span {
                        inside += 1;
                        let (mx, my) = (u as i32 - quiet as i32, v as i32 - quiet as i32);
                        let dark = (0..modules as i32).contains(&mx)
                            && (0..modules as i32).contains(&my)
                            && code.get_module(mx, my);
                        sum += if dark { 0 } else { 255 };
                    }
                }
                if inside > 0 {
                    let held = picture.at(x, y) as u32 * (4 - inside);
                    picture.data[y * width + x] = ((sum + held) / 4) as u8;
                }
            }
        }
        picture
    }

    #[test]
    fn an_encoder_grid_decodes() {
        let code = QrCode::encode_text(LINK, QrCodeEcc::Medium).unwrap();
        let dim = code.size() as usize;
        let mut grid = Vec::new();
        for y in 0..dim as i32 {
            for x in 0..dim as i32 {
                grid.push(code.get_module(x, y));
            }
        }
        assert_eq!(decode_grid(&grid, dim).as_deref(), Some(LINK));
    }

    #[test]
    fn codes_are_read_off_camera_frames() {
        for (size, side, degrees) in [
            ((1280, 720), 420, 0.0),
            ((1280, 720), 420, 90.0),
            ((1280, 720), 420, 180.0),
            ((1280, 720), 420, 270.0),
            ((1280, 720), 360, 17.0),
            ((1280, 720), 360, 45.0),
            ((1920, 1080), 190, 8.0),
            ((720, 1280), 300, 96.0),
            ((640, 480), 230, 3.0),
        ] {
            let picture = sees(LINK, size.0, size.1, side, degrees);
            assert_eq!(
                read(&picture),
                vec![LINK.to_string()],
                "{size:?} {side} {degrees}"
            );
        }
        let wrapped = format!(
            "hal-c2://pair?pairingUrl={}",
            LINK.bytes()
                .map(|b| format!("%{b:02X}"))
                .collect::<String>()
        );
        assert_eq!(read(&sees(&wrapped, 1280, 720, 420, 12.0)), vec![wrapped]);
        let local = "http://127.0.0.1:3797/?token=q8Jm2sT4vX6zB1dF3hK5nP7rW9yC0eG";
        assert_eq!(
            read(&sees(local, 1280, 720, 360, 200.0)),
            vec![local.to_string()]
        );
    }

    #[test]
    fn frames_convert_and_a_picture_without_a_code_reads_nothing() {
        let picture = sees(LINK, 1280, 720, 300, 33.0);
        // As an NV12 frame, what a phone's camera delivers.
        let mut y_plane = Vec::new();
        for y in 0..picture.height {
            y_plane.extend_from_slice(&picture.data[y * picture.width..(y + 1) * picture.width]);
            y_plane.extend_from_slice(&[0u8; 16]);
        }
        let frame = Frame {
            format: FrameFormat::Nv12,
            width: picture.width,
            height: picture.height,
            planes: vec![
                (y_plane, picture.width + 16),
                (vec![128; picture.width * picture.height / 2], picture.width),
            ],
        };
        assert_eq!(read(&luminance(&frame).unwrap()), vec![LINK.to_string()]);
        // As RGBA.
        let mut rgba = Vec::new();
        for value in &picture.data {
            rgba.extend_from_slice(&[*value, *value, *value, 255]);
        }
        let frame = Frame {
            format: FrameFormat::Rgba8888,
            width: picture.width,
            height: picture.height,
            planes: vec![(rgba, picture.width * 4)],
        };
        assert_eq!(read(&luminance(&frame).unwrap()), vec![LINK.to_string()]);
        assert!(read(&desk(1280, 720)).is_empty());
        assert!(
            luminance(&Frame {
                format: FrameFormat::Other,
                width: 4,
                height: 4,
                planes: vec![(vec![0; 64], 16)],
            })
            .is_none()
        );
    }
    #[test]
    fn reed_solomon_corrects_what_the_encoder_writes() {
        // Encode with the spec's remainder, corrupt, correct.
        let (exp, log) = gf::tables();
        let mul = |a: u8, b: u8| {
            if a == 0 || b == 0 {
                0
            } else {
                exp[log[a as usize] as usize + log[b as usize] as usize]
            }
        };
        let divisor = |degree: usize| -> Vec<u8> {
            let mut result = vec![0u8; degree - 1];
            result.push(1);
            let mut root = 1u8;
            for _ in 0..degree {
                for j in 0..result.len() {
                    result[j] = mul(result[j], root);
                    if j + 1 < result.len() {
                        let next = result[j + 1];
                        result[j] ^= next;
                    }
                }
                root = mul(root, 2);
            }
            result
        };
        let remainder = |data: &[u8], div: &[u8]| -> Vec<u8> {
            let mut result = vec![0u8; div.len()];
            for b in data {
                let factor = b ^ result.remove(0);
                result.push(0);
                for (i, coef) in div.iter().enumerate() {
                    result[i] ^= mul(*coef, factor);
                }
            }
            result
        };
        let data: Vec<u8> = (0..43u8).collect();
        let ecc = remainder(&data, &divisor(24));
        let mut block = [&data[..], &ecc[..]].concat();
        assert!(gf::correct(&mut block.clone(), 24), "clean block");
        block[0] ^= 0xFF;
        block[20] ^= 0x55;
        block[50] ^= 0x01;
        assert!(gf::correct(&mut block, 24), "corrupted block");
        assert_eq!(&block[..43], &data[..]);
    }
}
