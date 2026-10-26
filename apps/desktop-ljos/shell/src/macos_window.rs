//! What the shell's window needs from AppKit that Ljós does not give it yet:
//! a frameless window its user can resize from its edge.
//!
//! A frameless window is borderless to winit, and AppKit takes a borderless
//! window's resize drag only from just inside its edge, where a titled
//! window's starts on the edge or just past it (TODO(ljos#140)). So the
//! shell's frameless window is a titled one here, as Electron's and Tauri's
//! are: its title bar clear, without its title or buttons, under the
//! content, and not a handle of its own, so that a drag over the shell's
//! header is the header's. The shell moves the window from its own handles
//! (`startSystemMove`), which AppKit allows an unmovable window.

use std::cell::{Cell, RefCell};

use ljos::prelude::{Engine, ObjectId, Platform, Timer, Value};
use ljos::window::NativeWindow;
use ljos::window::raw_window_handle::RawWindowHandle;
use objc2::rc::{Retained, Weak};
use objc2_app_kit::{NSView, NSWindow, NSWindowButton, NSWindowStyleMask, NSWindowTitleVisibility};

/// The shell's window as AppKit has it, and the window whose flags are
/// followed.
#[derive(Default)]
struct Shown {
    window: RefCell<Weak<NSWindow>>,
    followed: Cell<Option<ObjectId>>,
}

/// Hears of each window the host opens: the shell's own, which belongs to
/// no other window, takes a title bar that fits it. Once, before the root
/// is made.
pub fn install(engine: &Engine) {
    Platform::of(engine).on_native_window(|engine, window, native| {
        let Some(window) = window else {
            return;
        };
        let owned = engine
            .read_by_name(window, "transientParent")
            .as_object()
            .is_some();
        if owned {
            return;
        }
        let shown = engine.extension::<Shown>();
        let Some(ns_window) = ns_window(native) else {
            return;
        };
        fit_title_bar(&ns_window);
        *shown.window.borrow_mut() = Weak::from_retained(&ns_window);
        follow_flags(engine, window, |engine| {
            if let Some(window) = engine.extension::<Shown>().window.borrow().load() {
                fit_title_bar(&window);
            }
        });
    });
}

/// Calls `refit` once the host has told the platform of the window's new
/// flags (the theme's `frameless` changed): a timer's turn comes after the
/// pass that applies them. Once per window.
fn follow_flags(engine: &Engine, window: ObjectId, refit: impl Fn(&Engine) + 'static) {
    let shown = engine.extension::<Shown>();
    if shown.followed.replace(Some(window)) == Some(window) {
        return;
    }
    let timer = Timer {
        interval: 0,
        repeat: false,
        running: false,
        ..Timer::default()
    };
    let Ok(timer) = engine.create_native(timer, None) else {
        return;
    };
    let _ = engine.connect_by_name(timer, "triggered", move |engine, _| refit(engine));
    let _ = engine.connect_by_name(window, "flagsChanged", move |engine, _| {
        let _ = engine.write_by_name(timer, "running", Value::Bool(false));
        let _ = engine.write_by_name(timer, "running", Value::Bool(true));
    });
}

fn ns_window(native: &dyn NativeWindow) -> Option<Retained<NSWindow>> {
    let RawWindowHandle::AppKit(handle) = native.window_handle().ok()?.as_raw() else {
        return None;
    };
    // SAFETY: an AppKit handle's view is an NSView, alive while the host
    // hands the window over, on the main thread.
    let view: &NSView = unsafe { handle.ns_view.cast().as_ref() };
    view.window()
}

/// A borderless window (frameless) gets a titled frame whose bar is clear,
/// empty and under the content; a titled one (framed) gets the system's own
/// bar back.
fn fit_title_bar(window: &NSWindow) {
    let mask = window.styleMask();
    let frameless = !mask.contains(NSWindowStyleMask::Titled);
    if !frameless && mask.contains(NSWindowStyleMask::FullSizeContentView) {
        return;
    }
    if frameless {
        window.setStyleMask(
            mask | NSWindowStyleMask::Titled | NSWindowStyleMask::FullSizeContentView,
        );
    }
    window.setTitlebarAppearsTransparent(frameless);
    window.setTitleVisibility(if frameless {
        NSWindowTitleVisibility::Hidden
    } else {
        NSWindowTitleVisibility::Visible
    });
    for button in [
        NSWindowButton::CloseButton,
        NSWindowButton::MiniaturizeButton,
        NSWindowButton::ZoomButton,
    ] {
        if let Some(button) = window.standardWindowButton(button) {
            button.setHidden(frameless);
        }
    }
    window.setMovable(!frameless);
    // A new style mask takes the keyboard from the content (as winit's own
    // style changes say).
    if let Some(content) = window.contentView() {
        window.makeFirstResponder(Some(&content));
    }
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use ljos::testing::TestWindow;

    use super::*;

    #[test]
    fn the_title_bar_is_fitted_again_after_the_window_takes_new_flags() {
        let engine = ljos::engine();
        let mut clock = TestWindow::new(&engine, 100.0, 100.0);
        let window = engine
            .create_by_name("QtQuick", "Window", None)
            .expect("a window");
        let fits = Rc::new(Cell::new(0));
        let counted = Rc::clone(&fits);
        follow_flags(&engine, window, move |_| counted.set(counted.get() + 1));
        // Opened again in its own place: still once.
        let again = Rc::clone(&fits);
        follow_flags(&engine, window, move |_| again.set(again.get() + 10));
        clock.advance(1).unwrap();
        assert_eq!(fits.get(), 0, "nothing changed");
        // Frameless (Qt.Window | Qt.FramelessWindowHint), then framed.
        let _ = engine.write_by_name(window, "flags", Value::Int(0x0801));
        assert_eq!(fits.get(), 0, "not before the host has applied them");
        clock.advance(1).unwrap();
        assert_eq!(fits.get(), 1);
        let _ = engine.write_by_name(window, "flags", Value::Int(0x0001));
        clock.advance(1).unwrap();
        assert_eq!(fits.get(), 2);
    }
}
