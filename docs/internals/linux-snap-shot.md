# Linux window capture

Wayland only. The Qt desktop captures through the Screenshot portal
(`apps/desktop-qt/src/native/PortalSnapShot`), or on Niri outside a sandbox over its socket
(`NiriSnapShot`), GNOME adding its extension for the active window when the portal cannot take it,
and never falls back to another backend on failure, cancellation, or denial. Session detection comes
from `XDG_CURRENT_DESKTOP`: a stale `NIRI_SOCKET` or a reachable GNOME extension must not select
another desktop's backend.

The helpers `native/kde-snap-shot` and `native/hyprland-snap-shot` are the compositor-specific
backends the desktop does not call yet (`@backlog-desktop`). The traps below bind them when it does.

## KDE

KWin authorizes `org.kde.KWin.ScreenShot2` by resolving the calling PID's executable against its
application registry, so the helper is installed at a stable path under the XDG data home with a
hidden desktop entry, not run from the AppImage mount. Two traps:

- `X-KDE-DBUS-Restricted-Interfaces` uses KConfig's comma-separated list syntax. A trailing
  semicolon becomes part of the interface name and KWin rejects it.
- KService's cache key includes search paths and locale. Refresh with `kbuildsycoca6` both directly
  and through `systemd-run --user`; refreshing only inside the AppImage environment can leave KWin
  reading stale permissions.

Readiness is checked by calling `CaptureWindow` with an invalid ID and expecting `InvalidWindow`,
which runs after KWin's authorization check. Files on disk alone never mean ready.

Plasma consumes Shift for shifted digits and produces a punctuation keysym, so a successfully bound
`Ctrl+Shift+2` may never fire on some layouts. Letter chords work around it. A general fix needs
layout-aware encoding.

## Hyprland

The helper maps a foreign-toplevel handle to the full 64-bit window address with
`hyprland-toplevel-mapping-v1` before exporting through `hyprland-toplevel-export-v1`. Never
truncate the address or pick a window by title.

Hyprland 0.56.2 renders an access-denied texture instead of failing the export frame when consent
is rejected or a `no_screen_share` rule applies. `ready` is not a permission grant, and pixels must
not be inspected to guess one. See
[ScreenshareFrame](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/managers/screenshare/ScreenshareFrame.cpp).

Hyprland's GlobalShortcuts portal registers actions, not key chords. `shortcutActionRegistered` is
distinct from `shortcutRegistered`; nothing in the UI may claim the keys are reserved.

The bundled protocol XML ships with the helper because its BSD license requires the notice.

## GNOME extension

Source in `native/gnome-snap-shot`, UUID `snap-shot@hal-c2.example`. GNOME only discovers a newly
installed extension at login, so setup distinguishes "installed, needs logout" from "discovered but
disabled" and compares loaded and installed versions.

The extension trusts callers that own `io.github.halc2.HalC2.SnapShot` (or the `.Development`
variant) on the same connection. This is GNOME's trusted-session-client pattern, not authentication
against a hostile process on the user's bus.

Toolkits do not position overlay windows on Wayland, so the flash and flight run as Shell actors
inside the extension with coordinates relative to HAL-C2's content area.

GNOME 50 removed `Meta.is_wayland_compositor`. Shell internals change across majors; verify each
version before adding it to `metadata.json`.

## Qt desktop

`apps/desktop-qt` captures through the portal (`PortalSnapShot`, over QtDBus) on any Wayland desktop
without a backend of its own, with the window picker unless the portal offers the active-window target.
Outside a sandbox, Niri captures through its socket, and KDE and Hyprland through their helpers
(`HelperSnapShot`, `CaptureHelper`) with the shortcut still in the portal. The helpers' capture effects
are not driven yet: setup says they are unavailable, and captures go without them. On GNOME
`GnomeSnapShot` wraps the portal and installs the extension from a Qt resource; a capture takes the bus
name on a connection of its own, so it is held only for that capture. The landing flight is not wired
yet: captures ask only for the flash.

On Niri and Hyprland the capture shortcut lives in the compositor's config, written only after the
user reviews the diff (`CaptureShortcutConfig`). Hyprland's binding still reaches HAL-C2 through a
GlobalShortcuts session, so the controller opens one even when the saved keys cannot name a portal
trigger. A sandbox reaches neither the config nor the endpoint, and uses the portal alone.
