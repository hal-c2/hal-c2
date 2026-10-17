//! A device's H.264 screen, decoded off the UI thread with Ljós's stream
//! decoder (desktop-qt's src/native/DeviceDecoder.h): iOS sends AVCC
//! (length-prefixed NAL units after an avcC record), Android sends Annex-B
//! access units. Every unit is decoded, since later frames refer to earlier
//! ones, but only the newest picture of a batch is scaled and kept, so a
//! decoder that falls behind skips pictures, never queues them. A backlog
//! past [`MAX_QUEUED`] is dropped whole and decoding waits for the next
//! keyframe: [`Decode::push`] returns false and the stream asks the device
//! for one.
//!
//! [`Decoder`] runs on a thread of its own and calls its [`Notify`] there
//! when it has something to say; its owner then takes [`Decode::take_events`]
//! on the UI thread: [`Decoded::Frame`] once per new picture nobody has taken
//! yet ([`Decode::take_frame`] takes the newest). [`Decode`] is what the
//! stream sees of it, so tests can give it another.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use ljos::media::{self, DecodeError, StreamFormat, VideoFrame};

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

/// Ljós's stream decoder on a thread of its own.
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

/// The newest picture of a batch, scaled only once it is known to be.
enum Newest {
    Still((u32, u32), Picture),
    Video(VideoFrame),
}

/// The decoder's thread: decodes everything queued, then scales only the
/// newest picture, until the decoder is dropped.
fn work(shared: &Shared) {
    // The stream's decoder and the reset() generation it was opened for.
    let mut video: Option<(media::Decoder, u64)> = None;
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
        let mut failed = false;
        // No decoder to decode with: nothing later will do better.
        let mut unusable = None;
        // Units given to the decoder since the newest still.
        let mut fed = false;
        for unit in batch {
            if unit.epoch != epoch {
                continue;
            }
            if unit.jpeg {
                if let Some((size, still)) = jpeg(&unit.data, limit) {
                    newest = Some(Newest::Still(size, still));
                    fed = false;
                }
                continue;
            }
            if video.as_ref().is_none_or(|(_, opened)| *opened != epoch) {
                video = None;
                match open(avcc.as_deref()) {
                    Ok(opened) => video = Some((opened, epoch)),
                    Err(why) => {
                        unusable = why;
                        failed = true;
                        break;
                    }
                }
            }
            let Some((decoder, _)) = video.as_mut() else {
                failed = true;
                break;
            };
            match decoder.push(unit.data.get(unit.offset..).unwrap_or_default()) {
                Ok(mut frames) => {
                    fed = true;
                    if let Some(frame) = frames.pop() {
                        newest = Some(Newest::Video(frame));
                    }
                }
                Err(_) => {
                    failed = true;
                    break;
                }
            }
        }
        // TODO(ljos#71): the decoder holds a unit until the next one begins, and
        // a picture until its reorder window fills, which a screen that sends
        // nothing while it is still may never do. Finishing the batch hands
        // out every picture now; the stream decodes on after it.
        if fed
            && !failed
            && let Some((decoder, _)) = video.as_mut()
        {
            match decoder.finish() {
                Ok(mut frames) => {
                    if let Some(frame) = frames.pop() {
                        newest = Some(Newest::Video(frame));
                    }
                }
                Err(_) => failed = true,
            }
        }
        if failed {
            video = None;
        }
        let newest = match newest {
            Some(Newest::Video(frame)) if !failed => scaled(frame, limit),
            Some(Newest::Still(size, still)) => Some((size, still)),
            _ => None,
        };
        let said = {
            let mut state = shared.lock();
            if epoch != state.epoch {
                continue;
            }
            if failed {
                state.queue.clear();
                state.awaiting_keyframe = true;
            } else if let Some((source, picture)) = newest {
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

/// A decoder for a stream with `avcc` (None: Annex-B). Err(None) for an
/// avcC record no decoder starts from (every unit fails, as broken video),
/// Err(Some(why)) when this build cannot decode H.264 at all.
fn open(avcc: Option<&[u8]>) -> Result<media::Decoder, Option<String>> {
    let format = match avcc {
        None => StreamFormat::H264AnnexB,
        Some(config) => StreamFormat::H264Avcc {
            config: config.to_vec(),
        },
    };
    media::Decoder::new(&format).map_err(|why| match why {
        DecodeError::Codec(_) => None,
        _ => Some("This build has no H.264 decoder.".to_owned()),
    })
}

/// A decoded picture as RGBA, scaled down to `limit`, with its own size.
fn scaled(frame: VideoFrame, limit: (u32, u32)) -> Option<((u32, u32), Picture)> {
    let size = (frame.width(), frame.height());
    fitted(frame.into_rgba()?, size, limit)
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
    fitted(
        pixels,
        (u32::from(info.width), u32::from(info.height)),
        limit,
    )
}

/// RGBA `pixels` of `size` scaled down to `limit`, with their own size.
fn fitted(pixels: Vec<u8>, size: (u32, u32), limit: (u32, u32)) -> Option<((u32, u32), Picture)> {
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
    fn shrinking_averages_the_pixels_it_covers() {
        let pixels = [
            0, 0, 0, 255, 100, 100, 100, 255, //
            200, 200, 200, 255, 100, 100, 100, 255,
        ];
        assert_eq!(shrink(&pixels, (2, 2), (1, 1)), [100, 100, 100, 255]);
    }
}
