//! desktop-qt's PlatformWindow: what the shell asks of the platform about
//! the window's looks and the user's preferences. Every function is a no-op
//! or false off macOS in desktop-qt too; the compositor owns blur elsewhere
//! (docs/internals/desktop-qt.md).
//!
//! Of the three, Ljós gives the shell the application's colour scheme
//! (`Qt.styleHints.colorScheme`), which is all `applyApplicationAppearance`
//! does. Reduced motion is read from Ljós's accessibility hints, which a
//! host fills in; the window host does not fill in macOS's yet. The window's
//! blur and liquid glass have no Ljós API at all. Each says so where it is.

use ljos::prelude::{Engine, Value};

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
    let Some(hints) = ljos_quick::style_hints(engine) else {
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

/// Whether the system asks apps to reduce motion: Ljós's accessibility
/// hint, which follows the host as it changes (desktop-qt read it once, at
/// start).
///
/// TODO(ljos#?): the window host (ljos_egui) feeds `set_system_prefs` the
/// colour scheme but not the motion preference, so this is false on macOS
/// where `NSWorkspace.accessibilityDisplayShouldReduceMotion` says
/// otherwise; the app's own "Reduce motion" setting still works. Linux and
/// Windows have no system hint here either, as in Qt.
pub fn system_reduced_motion(engine: &Engine) -> bool {
    ljos_quick::reduced_motion(engine)
}

/// The frosted backdrop behind a transparent window, with the theme's
/// `windowBlur`: `enabled` blurs, `dark` picks the material, `liquid_glass`
/// the macOS 26 glass instead.
///
/// TODO(ljos#?): Ljós has no way to ask the platform for a blurred or
/// vibrant backdrop, nor to reach the native window to do it (the shell's
/// setup closure holds the engine only). A window is transparent when its
/// `color` has alpha, and that is all; the picture is the theme's alpha over
/// whatever the compositor shows. So this does nothing on every platform,
/// where desktop-qt blurred on macOS (CGS blur, NSVisualEffectView, qt-liquid-glass).
pub fn apply_window_blur(_engine: &Engine, _enabled: bool, _dark: bool, _liquid_glass: bool) {}

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
    use ljos_a11y::ColorScheme;

    use super::*;

    fn engine() -> Engine {
        ljos::engine()
    }

    #[test]
    fn the_application_asks_for_a_scheme_and_gives_it_back() {
        let engine = engine();
        ljos_quick::update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        set_color_scheme(&engine, true, true);
        assert_eq!(ljos_quick::color_scheme(&engine), ColorScheme::Dark);
        set_color_scheme(&engine, true, false);
        assert_eq!(ljos_quick::color_scheme(&engine), ColorScheme::Light);
        ljos_quick::update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Dark);
        set_color_scheme(&engine, true, false);
        assert_eq!(ljos_quick::color_scheme(&engine), ColorScheme::Light);
        // Not asking is the system's again.
        set_color_scheme(&engine, false, false);
        assert_eq!(ljos_quick::color_scheme(&engine), ColorScheme::Dark);
    }

    #[test]
    fn only_macos_lets_the_theme_decide_the_applications_scheme() {
        let engine = engine();
        ljos_quick::update_system_prefs(&engine, |p| p.color_scheme = ColorScheme::Light);
        apply_window_theme(&engine, true, true, true, false, true);
        let wanted = if cfg!(target_os = "macos") {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        };
        assert_eq!(ljos_quick::color_scheme(&engine), wanted);
        // A theme that follows the system never overrides it.
        apply_window_theme(&engine, true, true, true, true, true);
        let wanted = if cfg!(target_os = "macos") {
            ColorScheme::Light
        } else {
            wanted
        };
        assert_eq!(ljos_quick::color_scheme(&engine), wanted);
    }

    #[test]
    fn reduced_motion_is_what_the_host_said() {
        let engine = engine();
        assert!(!system_reduced_motion(&engine));
        ljos_quick::update_system_prefs(&engine, |p| p.reduced_motion = true);
        assert!(system_reduced_motion(&engine));
    }
}
