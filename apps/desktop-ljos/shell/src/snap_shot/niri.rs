//! Niri outside a sandbox, desktop-qt's NiriSnapShot: capture over its IPC
//! socket ($NIRI_SOCKET), which names the focused window without asking,
//! and the shortcut from a binding in Niri's own config
//! ([`config`](super::config)) that calls the D-Bus endpoint this backend
//! owns, `hal-c2.SnapShot`.
//!
//! `shortcut().registered` is that endpoint being up: HAL-C2 cannot see
//! whether the binding is in the config, so `bind` and `release` do
//! nothing. Niri and the bus are only spoken to on threads of this
//! backend's; what they say waits in an inbox for [`Backend::arrive`].

#[cfg(all(unix, not(target_os = "macos")))]
mod unix;
#[cfg(all(unix, not(target_os = "macos")))]
pub use unix::{Niri, create, socket_path};

/// Niri runs on Linux and the BSDs only.
#[cfg(not(all(unix, not(target_os = "macos"))))]
pub fn create(_platform: &super::Platform) -> Option<Box<dyn super::Backend>> {
    None
}
