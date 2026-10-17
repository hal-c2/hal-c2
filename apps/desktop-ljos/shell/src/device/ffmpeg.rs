//! FFmpeg's libavcodec, libavutil and libswscale as the Device tab decodes
//! with them (desktop-qt's src/native/FFmpeg.h), loaded at run time: the app
//! is not linked to FFmpeg and ships none, so it starts without it and only
//! the Device tab's screen needs it.
//!
//! Without headers there is no build-time major version to load, so [`api`]
//! tries the releases in [`RELEASES`], newest first: libavcodec.so.61 on
//! Linux, libavcodec.61.dylib on macOS (also under Homebrew's and MacPorts'
//! prefixes), avcodec-61.dll on Windows. Only the functions the decoder calls
//! are declared, by hand, and the only struct read is [`FrameHead`].

use std::ffi::{c_char, c_int, c_uint, c_void};
use std::sync::{Mutex, PoisonError};

use libloading::Library;

/// The majors of libavcodec, libavutil and libswscale of each release the
/// decoder can use, newest first. All three load from one release or none.
///
/// Struct layouts: the decoder reads only the head of `AVFrame` ([`FrameHead`]),
/// which is the same in all of these (and has been since libavutil 56):
/// `data[8]`, `linesize[8]`, `extended_data`, `width`, `height`,
/// `nb_samples`, `format`. Everything else goes through functions:
/// `AVPacket` is filled by `av_packet_from_data`, the decoder's settings are
/// `avcodec_open2` options, and iOS's avcC record becomes Annex-B in Rust
/// rather than `AVCodecContext.extradata`. A release added here must keep
/// that head.
pub const RELEASES: &[(u32, u32, u32)] = &[(63, 61, 10), (62, 60, 9), (61, 59, 8), (60, 58, 7)];

/// `AVFrame`'s first fields, as [`RELEASES`] lay them out. Never made here,
/// only read through a pointer FFmpeg allocated.
#[repr(C)]
pub struct FrameHead {
    pub data: [*mut u8; 8],
    pub linesize: [c_int; 8],
    pub extended_data: *mut *mut u8,
    pub width: c_int,
    pub height: c_int,
    pub nb_samples: c_int,
    pub format: c_int,
}

/// `SWS_BILINEAR`, the same in every release.
pub const SWS_BILINEAR: c_int = 2;
/// `AV_INPUT_BUFFER_PADDING_SIZE`: the zeroed bytes a packet's data ends
/// with.
pub const PADDING: usize = 64;

/// The functions the decoder calls, from one release.
pub struct Api {
    pub find_decoder_by_name: unsafe extern "C" fn(*const c_char) -> *const c_void,
    pub alloc_context3: unsafe extern "C" fn(*const c_void) -> *mut c_void,
    pub open2: unsafe extern "C" fn(*mut c_void, *const c_void, *mut *mut c_void) -> c_int,
    pub free_context: unsafe extern "C" fn(*mut *mut c_void),
    pub send_packet: unsafe extern "C" fn(*mut c_void, *const c_void) -> c_int,
    pub receive_frame: unsafe extern "C" fn(*mut c_void, *mut FrameHead) -> c_int,
    pub packet_alloc: unsafe extern "C" fn() -> *mut c_void,
    pub packet_free: unsafe extern "C" fn(*mut *mut c_void),
    pub packet_unref: unsafe extern "C" fn(*mut c_void),
    pub packet_from_data: unsafe extern "C" fn(*mut c_void, *mut u8, c_int) -> c_int,
    pub frame_alloc: unsafe extern "C" fn() -> *mut FrameHead,
    pub frame_free: unsafe extern "C" fn(*mut *mut FrameHead),
    pub frame_unref: unsafe extern "C" fn(*mut FrameHead),
    pub frame_move_ref: unsafe extern "C" fn(*mut FrameHead, *mut FrameHead),
    pub malloc: unsafe extern "C" fn(usize) -> *mut c_void,
    pub free: unsafe extern "C" fn(*mut c_void),
    pub dict_set:
        unsafe extern "C" fn(*mut *mut c_void, *const c_char, *const c_char, c_int) -> c_int,
    pub dict_free: unsafe extern "C" fn(*mut *mut c_void),
    pub get_pix_fmt: unsafe extern "C" fn(*const c_char) -> c_int,
    pub get_cached_context: unsafe extern "C" fn(
        *mut c_void,
        c_int,
        c_int,
        c_int,
        c_int,
        c_int,
        c_int,
        c_int,
        *mut c_void,
        *mut c_void,
        *const f64,
    ) -> *mut c_void,
    pub scale: unsafe extern "C" fn(
        *mut c_void,
        *const *const u8,
        *const c_int,
        c_int,
        c_int,
        *const *mut u8,
        *const c_int,
    ) -> c_int,
    pub free_scaler: unsafe extern "C" fn(*mut c_void),
    /// Kept loaded for the life of the process.
    _libraries: [Library; 3],
}

struct State {
    pretending: bool,
    loaded: Option<&'static Api>,
    /// The first library (or symbol) that did not load, for [`missing`].
    absent: String,
}

static STATE: Mutex<State> = Mutex::new(State {
    pretending: false,
    loaded: None,
    absent: String::new(),
});

/// Where `name` (avcodec, avutil, swscale) at `major` may be, most likely
/// first.
fn candidates(name: &str, major: u32) -> Vec<String> {
    if cfg!(target_os = "macos") {
        let file = format!("lib{name}.{major}.dylib");
        // A bundle's own search path, then Homebrew on Apple silicon and
        // Intel, then MacPorts.
        [
            "",
            "/opt/homebrew/opt/ffmpeg/lib/",
            "/opt/homebrew/lib/",
            "/usr/local/opt/ffmpeg/lib/",
            "/usr/local/lib/",
            "/opt/local/lib/",
        ]
        .iter()
        .map(|prefix| format!("{prefix}{file}"))
        .collect()
    } else if cfg!(windows) {
        vec![format!("{name}-{major}.dll")]
    } else {
        vec![format!("lib{name}.so.{major}")]
    }
}

/// Loads one library, or says which was not found.
fn open(name: &str, major: u32) -> Result<Library, String> {
    let all = candidates(name, major);
    for candidate in &all {
        // SAFETY: FFmpeg's libraries run no initializers that need more
        // than the C runtime.
        if let Ok(library) = unsafe { Library::new(candidate) } {
            return Ok(library);
        }
    }
    Err(all.into_iter().next().unwrap_or_default())
}

/// A function of `library` as `T`, or which was not found.
fn resolve<T: Copy>(library: &Library, file: &str, symbol: &str) -> Result<T, String> {
    let name = format!("{symbol}\0");
    // SAFETY: each `T` is the function's C signature in every release of
    // RELEASES.
    unsafe { library.get::<T>(name.as_bytes()) }
        .map(|f| *f)
        .map_err(|_| format!("{symbol} in {file}"))
}

/// The libraries of one release, checked to be that release.
fn load_release((codec_major, util_major, scale_major): (u32, u32, u32)) -> Result<Api, String> {
    // libavutil first: the other two need it.
    let util = open("avutil", util_major)?;
    let scale = open("swscale", scale_major)?;
    let codec = open("avcodec", codec_major)?;
    let util_file = &candidates("avutil", util_major)[0];
    let scale_file = &candidates("swscale", scale_major)[0];
    let codec_file = &candidates("avcodec", codec_major)[0];
    // The file's name says its major; its version says it too.
    for (library, file, symbol, major) in [
        (&util, util_file, "avutil_version", util_major),
        (&scale, scale_file, "swscale_version", scale_major),
        (&codec, codec_file, "avcodec_version", codec_major),
    ] {
        let version: unsafe extern "C" fn() -> c_uint = resolve(library, file, symbol)?;
        // SAFETY: takes nothing, returns the packed version.
        let found = unsafe { version() } >> 16;
        if found != major {
            return Err(format!("{file} at version {major} (it is {found})"));
        }
    }
    macro_rules! c {
        ($symbol:literal) => {
            resolve(&codec, codec_file, $symbol)
        };
    }
    macro_rules! u {
        ($symbol:literal) => {
            resolve(&util, util_file, $symbol)
        };
    }
    macro_rules! s {
        ($symbol:literal) => {
            resolve(&scale, scale_file, $symbol)
        };
    }
    Ok(Api {
        find_decoder_by_name: c!("avcodec_find_decoder_by_name")?,
        alloc_context3: c!("avcodec_alloc_context3")?,
        open2: c!("avcodec_open2")?,
        free_context: c!("avcodec_free_context")?,
        send_packet: c!("avcodec_send_packet")?,
        receive_frame: c!("avcodec_receive_frame")?,
        packet_alloc: c!("av_packet_alloc")?,
        packet_free: c!("av_packet_free")?,
        packet_unref: c!("av_packet_unref")?,
        packet_from_data: c!("av_packet_from_data")?,
        frame_alloc: u!("av_frame_alloc")?,
        frame_free: u!("av_frame_free")?,
        frame_unref: u!("av_frame_unref")?,
        frame_move_ref: u!("av_frame_move_ref")?,
        malloc: u!("av_malloc")?,
        free: u!("av_free")?,
        dict_set: u!("av_dict_set")?,
        dict_free: u!("av_dict_free")?,
        get_pix_fmt: u!("av_get_pix_fmt")?,
        get_cached_context: s!("sws_getCachedContext")?,
        scale: s!("sws_scale")?,
        free_scaler: s!("sws_freeContext")?,
        _libraries: [codec, scale, util],
    })
}

/// The newest release that loads, or what the newest one lacks.
fn load() -> Result<Api, String> {
    let mut absent = None;
    for release in RELEASES {
        match load_release(*release) {
            Ok(api) => return Ok(api),
            Err(what) => {
                absent.get_or_insert(what);
            }
        }
    }
    Err(absent.unwrap_or_default())
}

/// The loaded libraries, or None when they are not installed. A failed load
/// is tried again on the next call, so installing FFmpeg needs no restart.
pub fn api() -> Option<&'static Api> {
    let mut state = STATE.lock().unwrap_or_else(PoisonError::into_inner);
    if state.pretending {
        state.absent = candidates("avcodec", RELEASES[0].0).swap_remove(0);
        return None;
    }
    if state.loaded.is_none() {
        match load() {
            // Loaded once, for the life of the process.
            Ok(api) => state.loaded = Some(Box::leak(Box::new(api))),
            Err(absent) => state.absent = absent,
        }
    }
    state.loaded
}

/// What the user should do when [`api`] is None.
pub fn missing() -> String {
    let state = STATE.lock().unwrap_or_else(PoisonError::into_inner);
    format!(
        "Install FFmpeg to watch device screens ({} was not found).",
        state.absent
    )
}

/// Tests: behave as if FFmpeg were not installed (for the whole process).
pub fn pretend_missing(missing: bool) {
    STATE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .pretending = missing;
}
