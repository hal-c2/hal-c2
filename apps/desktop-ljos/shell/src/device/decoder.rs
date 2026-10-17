//! A device's H.264 screen, decoded off the UI thread with libavcodec
//! (desktop-qt's src/native/DeviceDecoder.h): iOS sends AVCC (length-prefixed
//! NAL units after an avcC record), Android sends Annex-B access units. Every
//! unit is decoded, since later frames refer to earlier ones, but only the
//! newest picture of a batch is converted to RGBA, so a decoder that falls
//! behind skips pictures, never queues them. A backlog past [`MAX_QUEUED`] is
//! dropped whole and decoding waits for the next keyframe: [`Decode::push`]
//! returns false and the stream asks the device for one.
//!
//! [`Decoder`] runs on a thread of its own and calls its [`Notify`] there
//! when it has something to say; its owner then takes [`Decode::take_events`]
//! on the UI thread: [`Decoded::Frame`] once per new picture nobody has taken
//! yet ([`Decode::take_frame`] takes the newest). [`Decode`] is what the
//! stream sees of it, so tests can give it another.

use std::collections::VecDeque;
use std::ffi::{c_int, c_void};
use std::ptr;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use super::ffmpeg::{self, Api, FrameHead, PADDING, SWS_BILINEAR};

/// Units queued before the backlog is dropped.
pub const MAX_QUEUED: usize = 8;

/// What a decoder runs, on its own thread, when it has news.
pub type Notify = Arc<dyn Fn() + Send + Sync>;

/// A picture: `width` by `height` pixels, `rgba` in row order.
#[derive(Clone, PartialEq, Eq)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for Picture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Picture({}x{})", self.width, self.height)
    }
}

/// What a decoder says, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decoded {
    /// A new picture nobody has taken yet.
    Frame,
    /// A unit the decoder could not take: the stream should start over from
    /// a keyframe.
    Broken,
    /// No H.264 decoder could start (why): retrying will not help.
    Unsupported(String),
}

/// A device stream's decoder, as the stream uses it.
pub trait Decode {
    /// Whether it can decode at all; the error says what to install.
    fn available(&self) -> Result<(), String>;
    /// A new stream: `avcc` is its avcC record (AVCC units follow), or None
    /// for Annex-B. Drops what is queued and the newest picture, and decodes
    /// nothing before a keyframe.
    fn reset(&mut self, avcc: Option<Vec<u8>>);
    /// Queues one access unit, the bytes of `unit` from `offset` on (a
    /// message's header skipped); false when the backlog was dropped
    /// instead.
    fn push(&mut self, unit: Vec<u8>, offset: usize, keyframe: bool) -> bool;
    /// A still picture (serve-sim's JPEG seed), shown until video arrives.
    fn push_jpeg(&mut self, jpeg: Vec<u8>);
    /// The largest picture worth converting to (the view's size in pixels);
    /// pictures are scaled down to fit it, never up. (0, 0): full size.
    fn set_maximum_size(&mut self, size: (u32, u32));
    /// What it said since last asked.
    fn take_events(&mut self) -> Vec<Decoded>;
    /// The newest picture, taken: the next [`Decoded::Frame`] is for the
    /// next one.
    fn take_frame(&mut self) -> Option<Picture>;
    /// The size the device sent the newest picture at.
    fn source_size(&self) -> (u32, u32);
}

/// `size` scaled down to fit `limit` keeping its aspect (QSize::scaled
/// with Qt::KeepAspectRatio), when it is larger; an empty limit leaves it.
pub fn fit((width, height): (u32, u32), (lw, lh): (u32, u32)) -> (u32, u32) {
    if lw == 0 || lh == 0 || width == 0 || height == 0 || (width <= lw && height <= lh) {
        return (width, height);
    }
    let (w, h, lw, lh) = (
        u64::from(width),
        u64::from(height),
        u64::from(lw),
        u64::from(lh),
    );
    let rw = lh * w / h;
    let (nw, nh) = if rw <= lw { (rw, lh) } else { (lw, lw * h / w) };
    (nw.max(1) as u32, nh.max(1) as u32)
}

struct Unit {
    data: Vec<u8>,
    offset: usize,
    keyframe: bool,
    jpeg: bool,
    /// The reset() generation it belongs to.
    epoch: u64,
}

/// What the stream's thread and the decoder's share.
struct State {
    queue: VecDeque<Unit>,
    epoch: u64,
    avcc: Option<Arc<[u8]>>,
    awaiting_keyframe: bool,
    notified: bool,
    maximum: (u32, u32),
    frame: Option<Picture>,
    source: (u32, u32),
    events: Vec<Decoded>,
    quit: bool,
}

struct Shared {
    state: Mutex<State>,
    work: Condvar,
    notify: Notify,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// libavcodec's decoder on a thread of its own.
pub struct Decoder {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

impl Decoder {
    /// Starts the decoder's thread; `notify` runs there whenever
    /// [`Decode::take_events`] has something.
    pub fn new(notify: Notify) -> Decoder {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                queue: VecDeque::new(),
                epoch: 0,
                avcc: None,
                awaiting_keyframe: true,
                notified: false,
                maximum: (0, 0),
                frame: None,
                source: (0, 0),
                events: Vec::new(),
                quit: false,
            }),
            work: Condvar::new(),
            notify,
        });
        let working = shared.clone();
        // Without a thread nothing decodes; the stream's first-frame timeout
        // says so.
        let worker = std::thread::Builder::new()
            .name("device-decoder".to_owned())
            .spawn(move || work(&working))
            .ok();
        Decoder { shared, worker }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        {
            let mut state = self.shared.lock();
            state.queue.clear();
            state.quit = true;
        }
        self.shared.work.notify_all();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Decode for Decoder {
    fn available(&self) -> Result<(), String> {
        ffmpeg::api().map(|_| ()).ok_or_else(ffmpeg::missing)
    }

    fn reset(&mut self, avcc: Option<Vec<u8>>) {
        let mut state = self.shared.lock();
        state.epoch += 1;
        state.avcc = avcc.map(Arc::from);
        state.queue.clear();
        state.awaiting_keyframe = true;
        // The last stream's picture is not this one's, nor what was said of it.
        state.frame = None;
        state.source = (0, 0);
        state.notified = false;
        state.events.clear();
    }

    fn push(&mut self, unit: Vec<u8>, offset: usize, keyframe: bool) -> bool {
        let mut state = self.shared.lock();
        if state.awaiting_keyframe {
            if !keyframe {
                return true;
            }
            state.awaiting_keyframe = false;
        }
        if state.queue.len() >= MAX_QUEUED {
            // Behind: what is queued is stale; start again from a keyframe.
            state.queue.clear();
            state.awaiting_keyframe = true;
            if !keyframe {
                return false;
            }
            state.awaiting_keyframe = false;
        }
        let epoch = state.epoch;
        state.queue.push_back(Unit {
            data: unit,
            offset,
            keyframe,
            jpeg: false,
            epoch,
        });
        drop(state);
        self.shared.work.notify_one();
        true
    }

    fn push_jpeg(&mut self, jpeg: Vec<u8>) {
        let mut state = self.shared.lock();
        let epoch = state.epoch;
        state.queue.push_back(Unit {
            data: jpeg,
            offset: 0,
            keyframe: false,
            jpeg: true,
            epoch,
        });
        drop(state);
        self.shared.work.notify_one();
    }

    fn set_maximum_size(&mut self, size: (u32, u32)) {
        self.shared.lock().maximum = size;
    }

    fn take_events(&mut self) -> Vec<Decoded> {
        std::mem::take(&mut self.shared.lock().events)
    }

    fn take_frame(&mut self) -> Option<Picture> {
        let mut state = self.shared.lock();
        state.notified = false;
        state.frame.take()
    }

    fn source_size(&self) -> (u32, u32) {
        self.shared.lock().source
    }
}

/// The decoder's thread: decodes everything queued, then converts only the
/// newest picture, until the decoder is dropped.
fn work(shared: &Shared) {
    let mut codec: Option<Codec> = None;
    let mut open_epoch: Option<u64> = None;
    loop {
        let (batch, limit, avcc, epoch) = {
            let mut state = shared.lock();
            while state.queue.is_empty() && !state.quit {
                state = shared
                    .work
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
            }
            if state.quit {
                return;
            }
            (
                std::mem::take(&mut state.queue),
                state.maximum,
                state.avcc.clone(),
                state.epoch,
            )
        };
        let mut newest = None;
        let mut source = (0, 0);
        let mut failed = false;
        // No decoder to decode with: nothing later will do better.
        let mut unusable = None;
        let mut decoded = false;
        for unit in batch {
            if unit.epoch != epoch {
                continue;
            }
            if unit.jpeg {
                if let Some((size, still)) = jpeg(&unit.data, limit) {
                    source = size;
                    newest = Some(still);
                    decoded = false;
                }
                continue;
            }
            if open_epoch != Some(epoch) {
                codec = None;
                match Codec::open(avcc.as_deref()) {
                    Ok(opened) => {
                        codec = Some(opened);
                        open_epoch = Some(epoch);
                    }
                    Err(why) => {
                        unusable = Some(why);
                        failed = true;
                        break;
                    }
                }
            }
            let Some(open) = codec.as_mut() else {
                failed = true;
                break;
            };
            match open.decode(
                unit.data.get(unit.offset..).unwrap_or_default(),
                unit.keyframe,
            ) {
                Ok(got) => decoded |= got,
                Err(()) => {
                    failed = true;
                    break;
                }
            }
        }
        if decoded
            && !failed
            && let Some(open) = codec.as_mut()
        {
            source = open.size();
            newest = open.convert(limit);
        }
        let said = {
            let mut state = shared.lock();
            if epoch != state.epoch {
                continue;
            }
            if failed {
                state.queue.clear();
                state.awaiting_keyframe = true;
                open_epoch = None;
            } else if let Some(picture) = newest {
                state.frame = Some(picture);
                state.source = source;
                if !state.notified {
                    state.notified = true;
                    state.events.push(Decoded::Frame);
                }
            }
            match unusable {
                Some(why) => state.events.push(Decoded::Unsupported(why)),
                None if failed => state.events.push(Decoded::Broken),
                None => {}
            }
            !state.events.is_empty()
        };
        if said {
            (shared.notify)();
        }
    }
}

/// A JPEG as RGBA, scaled down to `limit`, with its own size.
fn jpeg(bytes: &[u8], limit: (u32, u32)) -> Option<((u32, u32), Picture)> {
    use zune_jpeg::zune_core::{
        bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions,
    };
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(bytes), options);
    let pixels = decoder.decode().ok()?;
    let info = decoder.info()?;
    let size = (u32::from(info.width), u32::from(info.height));
    if size.0 == 0 || size.1 == 0 || pixels.len() != size.0 as usize * size.1 as usize * 4 {
        return None;
    }
    let (width, height) = fit(size, limit);
    let rgba = if (width, height) == size {
        pixels
    } else {
        shrink(&pixels, size, (width, height))
    };
    Some((
        size,
        Picture {
            width,
            height,
            rgba,
        },
    ))
}

/// RGBA pixels of `from` averaged down to `to` (smaller on both sides).
fn shrink(pixels: &[u8], from: (u32, u32), to: (u32, u32)) -> Vec<u8> {
    let (w, h) = (from.0 as usize, from.1 as usize);
    let (tw, th) = (to.0 as usize, to.1 as usize);
    let mut out = vec![0; tw * th * 4];
    for y in 0..th {
        let y0 = y * h / th;
        let y1 = ((y + 1) * h / th).max(y0 + 1);
        for x in 0..tw {
            let x0 = x * w / tw;
            let x1 = ((x + 1) * w / tw).max(x0 + 1);
            let mut sum = [0u64; 4];
            for row in pixels[y0 * w * 4..y1 * w * 4].chunks_exact(w * 4) {
                for pixel in row[x0 * 4..x1 * 4].as_chunks::<4>().0 {
                    for (s, &p) in sum.iter_mut().zip(pixel) {
                        *s += u64::from(p);
                    }
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u64;
            let at = (y * tw + x) * 4;
            for (o, s) in out[at..at + 4].iter_mut().zip(sum) {
                *o = ((s + n / 2) / n) as u8;
            }
        }
    }
    out
}

/// How a stream's units become what libavcodec is fed.
enum Framing {
    /// As they come.
    AnnexB,
    /// Length-prefixed NAL units, each `length_size` bytes long, become
    /// Annex-B; a keyframe gets the avcC record's parameter sets (`sets`,
    /// Annex-B already) before it.
    Avcc { length_size: usize, sets: Vec<u8> },
    /// An avcC record no decoder starts from: every unit fails.
    Broken,
}

const START: [u8; 4] = [0, 0, 0, 1];

/// The NAL unit length size and parameter sets (as Annex-B) of an avcC
/// record (ISO/IEC 14496-15 AVCDecoderConfigurationRecord).
fn parse_avcc(record: &[u8]) -> Option<(usize, Vec<u8>)> {
    if record.len() < 7 || record[0] != 1 {
        return None;
    }
    let length_size = usize::from(record[4] & 3) + 1;
    let mut sets = Vec::new();
    let mut at = 5;
    for mask in [0x1f, 0xff] {
        let count = record.get(at)? & mask;
        at += 1;
        for _ in 0..count {
            let length = usize::from(u16::from_be_bytes([*record.get(at)?, *record.get(at + 1)?]));
            at += 2;
            sets.extend_from_slice(&START);
            sets.extend_from_slice(record.get(at..at + length)?);
            at += length;
        }
    }
    Some((length_size, sets))
}

/// An AVCC unit as Annex-B behind `sets`; Err for one whose lengths run
/// past its end.
fn annex_b(unit: &[u8], length_size: usize, sets: &[u8]) -> Result<Vec<u8>, ()> {
    let mut out = Vec::with_capacity(sets.len() + unit.len() + 16);
    out.extend_from_slice(sets);
    let mut at = 0;
    while at < unit.len() {
        let prefix = unit.get(at..at + length_size).ok_or(())?;
        let length = prefix
            .iter()
            .fold(0usize, |n, &b| (n << 8) | usize::from(b));
        at += length_size;
        out.extend_from_slice(&START);
        out.extend_from_slice(unit.get(at..at + length).ok_or(())?);
        at += length;
    }
    Ok(out)
}

/// One stream's libavcodec decoder and swscale converter.
struct Codec {
    av: &'static Api,
    context: *mut c_void,
    packet: *mut c_void,
    picture: *mut FrameHead,
    /// The newest picture decoded.
    last: *mut FrameHead,
    scaler: *mut c_void,
    rgba: c_int,
    framing: Framing,
}

impl Codec {
    /// A decoder for a stream with `avcc` (None: Annex-B), or why none
    /// started.
    fn open(avcc: Option<&[u8]>) -> Result<Codec, String> {
        let av = ffmpeg::api().ok_or_else(ffmpeg::missing)?;
        // SAFETY: every call is FFmpeg's documented use of the pointers it
        // returned; Codec's Drop frees what was made.
        unsafe {
            let codec = (av.find_decoder_by_name)(c"h264".as_ptr());
            if codec.is_null() {
                return Err("This FFmpeg has no H.264 decoder.".to_owned());
            }
            let failed = || "The H.264 decoder did not start.".to_owned();
            let mut this = Codec {
                av,
                context: (av.alloc_context3)(codec),
                packet: ptr::null_mut(),
                picture: ptr::null_mut(),
                last: ptr::null_mut(),
                scaler: ptr::null_mut(),
                rgba: (av.get_pix_fmt)(c"rgba".as_ptr()),
                framing: match avcc {
                    None => Framing::AnnexB,
                    Some(record) => match parse_avcc(record) {
                        Some((length_size, sets)) => Framing::Avcc { length_size, sets },
                        None => Framing::Broken,
                    },
                },
            };
            if this.context.is_null() || this.rgba < 0 {
                return Err(failed());
            }
            // A live screen: no reordering delay, and slice threads (frame
            // threads hold pictures back one per thread). Options, not
            // AVCodecContext's fields, whose layout moves between releases.
            let mut options = ptr::null_mut();
            (av.dict_set)(&mut options, c"flags".as_ptr(), c"+low_delay".as_ptr(), 0);
            (av.dict_set)(&mut options, c"thread_type".as_ptr(), c"slice".as_ptr(), 0);
            (av.dict_set)(&mut options, c"threads".as_ptr(), c"auto".as_ptr(), 0);
            let opened = (av.open2)(this.context, codec, &mut options);
            (av.dict_free)(&mut options);
            if opened < 0 {
                return Err(failed());
            }
            this.packet = (av.packet_alloc)();
            this.picture = (av.frame_alloc)();
            this.last = (av.frame_alloc)();
            if this.packet.is_null() || this.picture.is_null() || this.last.is_null() {
                return Err(failed());
            }
            Ok(this)
        }
    }

    /// Decodes one unit; whether a picture came of it, or Err for one the
    /// decoder refused.
    fn decode(&mut self, unit: &[u8], keyframe: bool) -> Result<bool, ()> {
        let fed = match &self.framing {
            Framing::AnnexB => None,
            Framing::Avcc { length_size, sets } => Some(annex_b(
                unit,
                *length_size,
                if keyframe { sets } else { &[] },
            )?),
            Framing::Broken => return Err(()),
        };
        let fed = fed.as_deref().unwrap_or(unit);
        // An empty packet is no unit (libavcodec refuses one with data).
        let size = c_int::try_from(fed.len()).map_err(|_| ())?;
        if size == 0 || fed.len() > c_int::MAX as usize - PADDING {
            return Err(());
        }
        let av = self.av;
        // SAFETY: the packet takes the av_malloc'd data, padded and zeroed as
        // av_packet_from_data requires, or it is freed here. The keyframe flag
        // is not set: H.264's decoder finds keyframes in the units.
        unsafe {
            let data = (av.malloc)(fed.len() + PADDING).cast::<u8>();
            if data.is_null() {
                return Err(());
            }
            ptr::copy_nonoverlapping(fed.as_ptr(), data, fed.len());
            ptr::write_bytes(data.add(fed.len()), 0, PADDING);
            (av.packet_unref)(self.packet);
            if (av.packet_from_data)(self.packet, data, size) < 0 {
                (av.free)(data.cast());
                return Err(());
            }
            let sent = (av.send_packet)(self.context, self.packet);
            (av.packet_unref)(self.packet);
            if sent < 0 {
                return Err(());
            }
            // Keeps the newest picture; the ones before it are never shown.
            let mut got = false;
            while (av.receive_frame)(self.context, self.picture) == 0 {
                (av.frame_unref)(self.last);
                (av.frame_move_ref)(self.last, self.picture);
                got = true;
            }
            Ok(got)
        }
    }

    /// The newest picture's size.
    fn size(&self) -> (u32, u32) {
        // SAFETY: `last` is a live AVFrame; its head is FrameHead.
        let last = unsafe { &*self.last };
        (last.width.max(0) as u32, last.height.max(0) as u32)
    }

    /// The newest picture as RGBA, scaled down to `limit`.
    fn convert(&mut self, limit: (u32, u32)) -> Option<Picture> {
        let av = self.av;
        // SAFETY: `last` holds a decoded picture; swscale writes into a
        // buffer of aligned rows padded past the end, as its SIMD needs,
        // which is freed here.
        unsafe {
            let last = &*self.last;
            let source = (last.width.max(0) as u32, last.height.max(0) as u32);
            if source.0 == 0 || source.1 == 0 {
                return None;
            }
            let (width, height) = fit(source, limit);
            self.scaler = (av.get_cached_context)(
                self.scaler,
                last.width,
                last.height,
                last.format,
                width as c_int,
                height as c_int,
                self.rgba,
                SWS_BILINEAR,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null(),
            );
            if self.scaler.is_null() {
                return None;
            }
            let row = width as usize * 4;
            let stride = row.next_multiple_of(64);
            let bits = (av.malloc)(stride * height as usize + 64).cast::<u8>();
            if bits.is_null() {
                return None;
            }
            let planes = [bits, ptr::null_mut(), ptr::null_mut(), ptr::null_mut()];
            let strides = [stride as c_int, 0, 0, 0];
            (av.scale)(
                self.scaler,
                last.data.as_ptr().cast(),
                last.linesize.as_ptr(),
                0,
                last.height,
                planes.as_ptr(),
                strides.as_ptr(),
            );
            let mut rgba = Vec::with_capacity(row * height as usize);
            for y in 0..height as usize {
                rgba.extend_from_slice(std::slice::from_raw_parts(bits.add(y * stride), row));
            }
            (av.free)(bits.cast());
            Some(Picture {
                width,
                height,
                rgba,
            })
        }
    }
}

impl Drop for Codec {
    fn drop(&mut self) {
        let av = self.av;
        // SAFETY: each pointer is FFmpeg's or null, and freed once.
        unsafe {
            if !self.context.is_null() {
                (av.free_context)(&mut self.context);
            }
            if !self.packet.is_null() {
                (av.packet_free)(&mut self.packet);
            }
            if !self.picture.is_null() {
                (av.frame_free)(&mut self.picture);
            }
            if !self.last.is_null() {
                (av.frame_free)(&mut self.last);
            }
            if !self.scaler.is_null() {
                (av.free_scaler)(self.scaler);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_fits_its_limit_keeping_its_aspect() {
        assert_eq!(fit((72, 160), (0, 0)), (72, 160));
        assert_eq!(fit((72, 160), (100, 200)), (72, 160));
        assert_eq!(fit((72, 160), (36, 200)), (36, 80));
        assert_eq!(fit((72, 160), (100, 40)), (18, 40));
        assert_eq!(fit((1000, 1), (10, 10)), (10, 1));
    }

    #[test]
    fn an_avcc_record_and_units_become_annex_b() {
        let record = [
            1, 0x42, 0, 0x1e, 0xff, 0xe1, 0, 2, 0x67, 0xaa, 1, 0, 1, 0x68,
        ];
        let (length_size, sets) = parse_avcc(&record).expect("a record");
        assert_eq!(length_size, 4);
        assert_eq!(sets, [0, 0, 0, 1, 0x67, 0xaa, 0, 0, 0, 1, 0x68]);
        let unit = [0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41];
        assert_eq!(
            annex_b(&unit, 4, &sets).unwrap(),
            [
                0, 0, 0, 1, 0x67, 0xaa, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41
            ]
        );
        // A length past the end, or a record cut short, is no video.
        assert!(annex_b(&[0, 0, 0, 9, 1], 4, &[]).is_err());
        assert!(parse_avcc(&record[..4]).is_none());
        assert!(parse_avcc(&record[..9]).is_none());
    }

    #[test]
    fn shrinking_averages_the_pixels_it_covers() {
        let pixels = [
            0, 0, 0, 255, 100, 100, 100, 255, //
            200, 200, 200, 255, 100, 100, 100, 255,
        ];
        assert_eq!(shrink(&pixels, (2, 2), (1, 1)), [100, 100, 100, 255]);
    }
}
