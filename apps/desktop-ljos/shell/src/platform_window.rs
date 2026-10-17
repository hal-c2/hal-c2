//! desktop-qt's PlatformWindow: what the shell asks of the platform about
//! the window's looks and the user's preferences. desktop-qt did all of it
//! on macOS only and left blur to the compositor elsewhere
//! (docs/internals/desktop-qt.md).
//!
//! Ljós gives the shell the application's colour scheme
//! (`Qt.styleHints.colorScheme`), which is all `applyApplicationAppearance`
//! does; the system's motion preference, which Ljós's host reads and
//! follows on every platform it has; and a blurred backdrop behind the
//! window (`Window.backdrop`), which the host maps to each platform's own.
//! Liquid glass has no Ljós equivalent.

use std::cell::Cell;

use ljos::prelude::{Engine, ObjectId, Platform, Value};

/// Makes the application's colour scheme `dark` or light when `enabled`, and
/// the system's again when not: native controls follow it, so the liquid
/// glass backdrop (which is drawn by AppKit, not the theme) matches the
/// theme and not the system. Only cocoa does; elsewhere there is nothing the
/// theme asks of the platform.
pub fn apply_application_appearance(engine: &Engine, enabled: bool, dark: bool) {
    if cfg!(target_os = "macos") {
        set_color_scheme(engine, enabled, dark);
    }
}

/// `Qt.styleHints.colorScheme`: the scheme the application asks for, or the
/// system's own when it asks for none. The part of
/// [`apply_application_appearance`] that is not the platform's.
pub fn set_color_scheme(engine: &Engine, enabled: bool, dark: bool) {
    let Some(hints) = ljos::style_hints(engine) else {
        return;
    };
    // Qt::ColorScheme: Unknown, Light, Dark.
    let scheme = match (enabled, dark) {
        (false, _) => 0,
        (true, false) => 1,
        (true, true) => 2,
    };
    let _ = engine.write_by_name(hints, "colorScheme", Value::Int(scheme));
}

/// Whether the system asks apps to reduce motion: what Ljós's host reports
/// (the settings portal, NSWorkspace or Windows' own setting) as it
/// changes, where desktop-qt read macOS's once at start. Read when a panel
/// moves, so a change applies to the next one.
pub fn system_reduced_motion(engine: &Engine) -> bool {
    ljos::reduced_motion(engine)
}

/// The backdrop the theme asks for, and the shell's window once the host
/// has opened it.
#[derive(Default)]
struct Backdrop {
    blur: Cell<bool>,
    window: Cell<Option<ObjectId>>,
}

/// Hears of each window the host opens: the shell's own, which belongs to
/// no other window, takes the backdrop the theme asked for, as desktop-qt's
/// root window did. Once, before the root is made.
pub fn install(engine: &Engine) {
    Platform::of(engine).on_native_window(|engine, window, _| {
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
        let state = engine.extension::<Backdrop>();
        state.window.set(Some(window));
        show_backdrop(engine, window, state.blur.get());
    });
}

/// The frosted backdrop behind a transparent window, with the theme's
/// `windowBlur`: `enabled` blurs what is behind the shell's window
/// (`backdrop: Window.BlurBackdrop`). The host asks the window system for
/// it where there is a blur (KDE's on Wayland and X11, macOS's window
/// server, Windows' system backdrop) and leaves it be where not; the
/// theme's colour is what lets it through.
///
/// desktop-qt also chose the material by `dark` (NSVisualEffectView) and
/// drew macOS 26's liquid glass instead when `liquid_glass`
/// (qt-liquid-glass). Ljós's backdrop has one kind and no glass, so both
/// get the plain blur. TODO(ljos#66, ljos#67): a glass backdrop and a
/// material that follows the scheme.
pub fn apply_window_blur(engine: &Engine, enabled: bool, _dark: bool, _liquid_glass: bool) {
    let state = engine.extension::<Backdrop>();
    state.blur.set(enabled);
    if let Some(window) = state.window.get().filter(|w| engine.is_alive(*w)) {
        show_backdrop(engine, window, enabled);
    }
}

/// Asks for `Window.BlurBackdrop` or `Window.NoBackdrop` behind `window`.
fn show_backdrop(engine: &Engine, window: ObjectId, blur: bool) {
    let _ = engine.write_by_name(window, "backdrop", Value::Int(i32::from(blur)));
}

/// What the theme asks of the window and the application, as
/// ShellRuntime::applyWindowTheme did when it changed: its liquid glass
/// (when the theme, not the system, decides the appearance) and blur.
pub fn apply_window_theme(
    engine: &Engine,
    transparent: bool,
    blur: bool,
    liquid_glass: bool,
    follows_system: bool,
    dark: bool,
) {
    apply_application_appearance(engine, liquid_glass && !follows_system, dark);
    apply_window_blur(engine, transparent && blur, dark, liquid_glass);
}

#[cfg(test)]
mod tests {
    use ljos::prelude::ColorScheme;
    use ljos::system::{HostPrefs, report_system_prefs, update_system_prefs};
    use ljos::window::raw_window_handle::{
        DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle, RawDisplayHandle,
        RawWindowHandle, WindowHandle, XcbDisplayHandle, XcbWindowHandle,
    };
    use std::num::NonZeroU32;

    use super::*;

    fn engine() -> Engine {
        ljos::engine()
    }

    #[test]
    fn the_application_asks_for_a_scheme_and_gives_it_back() {
        let engine = engine();
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        set_color_scheme(&engine, true, true);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Dark);
        set_color_scheme(&engine, true, false);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Light);
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Dark);
        set_color_scheme(&engine, true, false);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Light);
        // Not asking is the system's again.
        set_color_scheme(&engine, false, false);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Dark);
    }

    #[test]
    fn only_macos_lets_the_theme_decide_the_applications_scheme() {
        let engine = engine();
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        apply_window_theme(&engine, true, true, true, false, true);
        let wanted = if cfg!(target_os = "macos") {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        };
        assert_eq!(ljos::color_scheme(&engine), wanted);
        // A theme that follows the system never overrides it.
        apply_window_theme(&engine, true, true, true, true, true);
        let wanted = if cfg!(target_os = "macos") {
            ColorScheme::Light
        } else {
            wanted
        };
        assert_eq!(ljos::color_scheme(&engine), wanted);
    }

    /// A window as a host hands it over, of an X server that is not there:
    /// the hook never uses the handles.
    struct Opened;

    impl HasWindowHandle for Opened {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            let id = NonZeroU32::new(7).expect("not zero");
            let raw = RawWindowHandle::Xcb(XcbWindowHandle::new(id));
            // SAFETY: the handle names no live window, and nothing uses it.
            Ok(unsafe { WindowHandle::borrow_raw(raw) })
        }
    }

    impl HasDisplayHandle for Opened {
        fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
            let raw = RawDisplayHandle::Xcb(XcbDisplayHandle::new(None, 0));
            // SAFETY: as for the window handle.
            Ok(unsafe { DisplayHandle::borrow_raw(raw) })
        }
    }

    fn backdrop(engine: &Engine, window: ObjectId) -> f64 {
        engine.read_by_name(window, "backdrop").to_number()
    }

    #[test]
    fn the_shells_window_takes_the_backdrop_the_theme_asks_for() {
        let engine = engine();
        install(&engine);
        let window = engine
            .create_by_name("QtQuick", "Window", None)
            .expect("a window");
        // The theme loads before the host opens the window.
        apply_window_blur(&engine, true, true, false);
        assert_eq!(backdrop(&engine, window), 0.0);
        Platform::of(&engine).native_window_opened(&engine, Some(window), &Opened);
        assert_eq!(backdrop(&engine, window), 1.0, "Window.BlurBackdrop");
        // A theme without blur, then one with liquid glass, while it is open.
        apply_window_blur(&engine, false, true, false);
        assert_eq!(backdrop(&engine, window), 0.0);
        apply_window_blur(&engine, true, false, true);
        assert_eq!(backdrop(&engine, window), 1.0);
        // A window the shell's window owns keeps its own.
        let owned = engine
            .create_by_name("QtQuick", "Window", None)
            .expect("a window");
        let _ = engine.write_by_name(owned, "transientParent", Value::Object(window));
        Platform::of(&engine).native_window_opened(&engine, Some(owned), &Opened);
        apply_window_blur(&engine, true, false, false);
        assert_eq!(backdrop(&engine, owned), 0.0);
        assert_eq!(backdrop(&engine, window), 1.0);
    }

    #[test]
    fn reduced_motion_follows_what_the_host_reports() {
        let engine = engine();
        assert!(!system_reduced_motion(&engine));
        let report = |reduced| {
            report_system_prefs(
                &engine,
                HostPrefs {
                    reduced_motion: Some(reduced),
                    ..HostPrefs::default()
                },
            );
        };
        report(true);
        assert!(system_reduced_motion(&engine));
        // The system changed its mind while the shell ran.
        report(false);
        assert!(!system_reduced_motion(&engine));
    }
}
