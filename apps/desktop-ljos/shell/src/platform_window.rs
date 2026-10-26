//! desktop-qt's PlatformWindow: what the shell asks of the platform about
//! the window's looks and the user's preferences. desktop-qt did all of it
//! on macOS only and left blur to the compositor elsewhere
//! (docs/internals/desktop-qt.md).
//!
//! Ljós gives the shell the application's colour scheme
//! (`Qt.styleHints.colorScheme`), which is all `applyApplicationAppearance`
//! does; the system's motion preference, which Ljós's host reads and
//! follows on every platform it has; and a blurred or glass backdrop behind
//! the window (`Window.backdrop`), which the host maps to each platform's
//! own and gives the light or dark material of the colour scheme in effect.

use std::cell::Cell;

use ljos::prelude::{Engine, ObjectId, Platform, Value};

/// Makes the application's colour scheme `dark` or light when `enabled`, and
/// the system's again when not: native controls follow it, and so does the
/// backdrop's material (which the window system draws, not the theme), so
/// that it matches the theme and not the system. Only cocoa and Windows have
/// a light or dark material; elsewhere there is nothing the theme asks of
/// the platform.
pub fn apply_application_appearance(engine: &Engine, enabled: bool, dark: bool) {
    if cfg!(any(target_os = "macos", target_os = "windows")) {
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

/// `Window.NoBackdrop`, `Window.BlurBackdrop` and `Window.GlassBackdrop`.
const NO_BACKDROP: i32 = 0;
const BLUR_BACKDROP: i32 = 1;
const GLASS_BACKDROP: i32 = 2;

/// The backdrop the theme asks for, and the shell's window once the host
/// has opened it.
#[derive(Default)]
struct Backdrop {
    kind: Cell<i32>,
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
        show_backdrop(engine, window, state.kind.get());
    });
}

/// The next generation of the shell (`crate::runtime`) takes the platform
/// window `old` had, which the host does not open again: it takes the
/// backdrop too. Without it the host would take the backdrop away, and the
/// theme's next one would go to the generation that went.
pub fn root_replaced(engine: &Engine, old: ObjectId, new: ObjectId) {
    let state = engine.extension::<Backdrop>();
    if state.window.get() != Some(old) {
        return;
    }
    state.window.set(Some(new));
    show_backdrop(engine, new, state.kind.get());
}

/// The frosted backdrop behind a transparent window, with the theme's
/// `windowBlur`: `enabled` blurs what is behind the shell's window
/// (`backdrop: Window.BlurBackdrop`), or, with `liquid_glass`, asks for the
/// system's glass (`Window.GlassBackdrop`: macOS 26's, the blur elsewhere).
/// The host asks the window system for it where there is a blur (KDE's on
/// Wayland and X11, macOS's window server, Windows' system backdrop) and
/// leaves it be where not; the theme's colour is what lets it through.
///
/// desktop-qt also chose the material by `dark`. Ljós takes it from the
/// colour scheme in effect instead, so `dark` reaches it through
/// [`apply_application_appearance`], which [`apply_window_theme`] calls.
pub fn apply_window_blur(engine: &Engine, enabled: bool, liquid_glass: bool) {
    let kind = match (enabled, liquid_glass) {
        (false, _) => NO_BACKDROP,
        (true, false) => BLUR_BACKDROP,
        (true, true) => GLASS_BACKDROP,
    };
    let state = engine.extension::<Backdrop>();
    state.kind.set(kind);
    if let Some(window) = state.window.get().filter(|w| engine.is_alive(*w)) {
        show_backdrop(engine, window, kind);
    }
}

/// Asks for `kind` (`Window.backdrop`'s value) behind `window`.
fn show_backdrop(engine: &Engine, window: ObjectId, kind: i32) {
    let _ = engine.write_by_name(window, "backdrop", Value::Int(kind));
}

/// What the theme asks of the window and the application, as
/// ShellRuntime::applyWindowTheme did when it changed: its blur or liquid
/// glass, and the scheme that gives the backdrop its material (when the
/// theme, not the system, decides the appearance).
pub fn apply_window_theme(
    engine: &Engine,
    transparent: bool,
    blur: bool,
    liquid_glass: bool,
    follows_system: bool,
    dark: bool,
) {
    let backdrop = transparent && blur;
    apply_application_appearance(engine, (backdrop || liquid_glass) && !follows_system, dark);
    apply_window_blur(engine, backdrop, liquid_glass);
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
    fn only_platforms_with_a_material_let_the_theme_decide_the_applications_scheme() {
        let has_material = cfg!(any(target_os = "macos", target_os = "windows"));
        let engine = engine();
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        apply_window_theme(&engine, true, true, true, false, true);
        let wanted = if has_material {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        };
        assert_eq!(ljos::color_scheme(&engine), wanted);
        // A theme that follows the system never overrides it.
        apply_window_theme(&engine, true, true, true, true, true);
        let wanted = if has_material {
            ColorScheme::Light
        } else {
            wanted
        };
        assert_eq!(ljos::color_scheme(&engine), wanted);
    }

    #[test]
    fn a_blurred_backdrop_takes_the_themes_material_through_the_scheme() {
        let has_material = cfg!(any(target_os = "macos", target_os = "windows"));
        let engine = engine();
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        let scheme = |dark| {
            apply_window_theme(&engine, true, true, false, false, dark);
            ljos::color_scheme(&engine)
        };
        // A dark theme on a light system: the material is the theme's.
        assert_eq!(
            scheme(true),
            if has_material {
                ColorScheme::Dark
            } else {
                ColorScheme::Light
            }
        );
        assert_eq!(scheme(false), ColorScheme::Light);
        // No backdrop, no scheme of the theme's own: the system's again.
        update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Dark);
        apply_window_theme(&engine, true, false, false, false, false);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Dark);
        apply_window_theme(&engine, false, true, false, false, false);
        assert_eq!(ljos::color_scheme(&engine), ColorScheme::Dark);
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
        apply_window_blur(&engine, true, false);
        assert_eq!(backdrop(&engine, window), 0.0);
        Platform::of(&engine).native_window_opened(&engine, Some(window), &Opened);
        assert_eq!(backdrop(&engine, window), 1.0, "Window.BlurBackdrop");
        // A theme without blur, then one with liquid glass, while it is open.
        apply_window_blur(&engine, false, false);
        assert_eq!(backdrop(&engine, window), 0.0);
        apply_window_blur(&engine, true, true);
        assert_eq!(backdrop(&engine, window), 2.0, "Window.GlassBackdrop");
        // Glass is a kind of blur: it needs the blur.
        apply_window_blur(&engine, false, true);
        assert_eq!(backdrop(&engine, window), 0.0);
        // A window the shell's window owns keeps its own.
        let owned = engine
            .create_by_name("QtQuick", "Window", None)
            .expect("a window");
        let _ = engine.write_by_name(owned, "transientParent", Value::Object(window));
        Platform::of(&engine).native_window_opened(&engine, Some(owned), &Opened);
        apply_window_blur(&engine, true, false);
        assert_eq!(backdrop(&engine, owned), 0.0);
        assert_eq!(backdrop(&engine, window), 1.0);

        // A reload's next generation takes the platform window, which the
        // host does not open again: it takes the backdrop, and the theme's
        // next one reaches it.
        let next = engine
            .create_by_name("QtQuick", "Window", None)
            .expect("a window");
        root_replaced(&engine, owned, next);
        assert_eq!(backdrop(&engine, next), 0.0, "not the shell's window");
        root_replaced(&engine, window, next);
        assert_eq!(backdrop(&engine, next), 1.0);
        engine.destroy(window);
        apply_window_blur(&engine, true, true);
        assert_eq!(backdrop(&engine, next), 2.0);
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
