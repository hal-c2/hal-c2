//! The C functions desktop-qt and the phone call (`hal_c2_syntax.h` beside
//! this crate). A handle is one [`Highlighter`]; the caller frees it.

use std::ffi::c_void;
use std::slice;

use crate::{Highlighter, Span};

/// A [`Span`] for C: `theme` 0 is the light colouring, 1 the dark; `flags`
/// bit 0 bold, bit 1 italic, bit 2 underline.
#[repr(C)]
pub struct HalC2SyntaxSpan {
    pub start: u32,
    pub length: u32,
    pub color: u32,
    pub theme: u8,
    pub flags: u8,
}

pub type HalC2SyntaxEmit = extern "C" fn(context: *mut c_void, span: *const HalC2SyntaxSpan);

/// # Safety
/// `code` points at `len` bytes. or is null with `len` 0.
unsafe fn text<'a>(text: *const u8, len: usize) -> &'a str {
    if text.is_null() || len == 0 {
        return "";
    }
    // SAFETY: the caller hands `len` readable bytes.
    let bytes = unsafe { slice::from_raw_parts(text, len) };
    std::str::from_utf8(bytes).unwrap_or("")
}

fn handle(highlighter: Option<Highlighter>) -> *mut Highlighter {
    highlighter.map_or(std::ptr::null_mut(), |highlighter| Box::into_raw(Box::new(highlighter)))
}

/// A highlighter for a fence's language, or null for plain text.
///
/// # Safety
/// `language` points at `len` bytes of UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hal_c2_syntax_for_language(language: *const u8, len: usize) -> *mut Highlighter {
    // SAFETY: as this function's.
    handle(Highlighter::for_language(unsafe { text(language, len) }))
}

/// A highlighter for a file by its path, or null when its kind has no syntax.
///
/// # Safety
/// `path` points at `len` bytes of UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hal_c2_syntax_for_path(path: *const u8, len: usize) -> *mut Highlighter {
    // SAFETY: as this function's.
    handle(Highlighter::for_path(unsafe { text(path, len) }))
}

/// A copy of `highlighter` that goes on from where it got to.
///
/// # Safety
/// `highlighter` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hal_c2_syntax_clone(highlighter: *const Highlighter) -> *mut Highlighter {
    // SAFETY: as this function's.
    handle(unsafe { highlighter.as_ref() }.cloned())
}

/// # Safety
/// `highlighter` is a live handle or null; it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hal_c2_syntax_free(highlighter: *mut Highlighter) {
    if !highlighter.is_null() {
        // SAFETY: made by Box::into_raw, freed once.
        drop(unsafe { Box::from_raw(highlighter) });
    }
}

/// Reads `len` bytes of UTF-8 code going on from the last call, and calls
/// `emit` with each coloured run. Returns 0 once a line was too long to
/// colour, after which nothing more is.
///
/// # Safety
/// `highlighter` is a live handle; `code` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hal_c2_syntax_feed(
    highlighter: *mut Highlighter,
    code: *const u8,
    len: usize,
    emit: HalC2SyntaxEmit,
    context: *mut c_void,
) -> u8 {
    // SAFETY: as this function's.
    let Some(highlighter) = (unsafe { highlighter.as_mut() }) else {
        return 0;
    };
    // SAFETY: as this function's.
    highlighter.feed(unsafe { text(code, len) }, |span: Span| {
        let flags = u8::from(span.bold) | u8::from(span.italic) << 1 | u8::from(span.underline) << 2;
        let span = HalC2SyntaxSpan {
            start: span.start,
            length: span.len,
            color: span.color,
            theme: span.theme as u8,
            flags,
        };
        emit(context, &span);
    });
    u8::from(!highlighter.stopped())
}
