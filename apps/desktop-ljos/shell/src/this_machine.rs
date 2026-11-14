//! Which environments run on the machine the user sits at, ported from
//! desktop-qt's ThisMachine. Only there may the shell start an editor or a
//! file manager, or read a folder by its path: anything else would start on,
//! or point into, a computer nobody is looking at.

use std::cell::RefCell;
use std::net::IpAddr;
use std::sync::OnceLock;

use ljos::prelude::*;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::bridge::Bridge;
use crate::controller;
use crate::store::{self, Row};

thread_local! {
    static PINNED: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// The lowercase hex SHA-256 of this machine's id as Qt's
/// `QSysInfo::machineUniqueId()` reads it: what an MC on this machine serves
/// as `platform.machineId`. Empty when this machine has none.
pub fn id() -> String {
    if let Some(id) = PINNED.with(|p| p.borrow().clone()) {
        return id;
    }
    static HASHED: OnceLock<String> = OnceLock::new();
    HASHED
        .get_or_init(|| raw_id().map(|raw| hash(&raw)).unwrap_or_default())
        .clone()
}

/// Pins [`id`] on this thread (tests); `None` goes back to this machine's own.
pub fn set_id_for_testing(id: Option<String>) {
    PINNED.with(|p| *p.borrow_mut() = id);
}

/// As the MC hashes it (apps/server-ex lib/hal_c2/environment/machine.ex).
fn hash(raw: &[u8]) -> String {
    if raw.is_empty() {
        return String::new();
    }
    Sha256::digest(raw)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// D-Bus's machine id, as Qt reads it: the first of the two paths that
/// exists (one that cannot be opened ends the search), its first 32 bytes.
/// Qt does not read /etc/machine-id, which D-Bus's usually links to.
#[cfg(all(unix, not(target_os = "macos")))]
fn raw_id() -> Option<Vec<u8>> {
    use std::io::Read;
    for path in [
        "/var/lib/dbus/machine-id",
        "/usr/local/var/lib/dbus/machine-id",
    ] {
        match std::fs::File::open(path) {
            Ok(file) => {
                let mut bytes = Vec::with_capacity(32);
                return file.take(32).read_to_end(&mut bytes).ok().map(|_| bytes);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return None,
        }
    }
    None
}

/// IOPlatformUUID, as Qt reads it.
#[cfg(target_os = "macos")]
fn raw_id() -> Option<Vec<u8>> {
    let out = std::process::Command::new("ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let rest = text.split("\"IOPlatformUUID\"").nth(1)?;
    let uuid = rest.split('"').nth(1)?;
    Some(uuid.as_bytes().to_vec())
}

/// The registry's MachineGuid in its 64-bit view, as Qt reads it.
#[cfg(windows)]
fn raw_id() -> Option<Vec<u8>> {
    let out = std::process::Command::new("reg")
        .args([
            "query",
            "HKLM\\SOFTWARE\\Microsoft\\Cryptography",
            "/v",
            "MachineGuid",
            "/reg:64",
        ])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().find(|l| l.contains("MachineGuid"))?;
    let guid = line.split_whitespace().last()?;
    Some(guid.as_bytes().to_vec())
}

#[cfg(not(any(unix, windows)))]
fn raw_id() -> Option<Vec<u8>> {
    None
}

/// Whether `host` names this machine's loopback: localhost, all of
/// 127.0.0.0/8, ::1 (also as an IPv4-mapped address). A DNS name that only
/// looks like one is not.
pub fn loopback_host(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    let bare = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    match bare.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => v4.is_loopback(),
        Ok(IpAddr::V6(v6)) => {
            v6.is_loopback() || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
        Err(_) => false,
    }
}

/// The host of an http(s)/ws(s) `origin`; empty when it has none.
pub fn origin_host(origin: &str) -> String {
    url::Url::parse(origin)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .unwrap_or_default()
}

/// Whether the environment `descriptor` describes runs here: its
/// `platform.machineId` is [`id`]. Without an id on both sides it is the MC
/// the shell is connected to (`own`), reached on loopback at `origin`. A
/// loopback origin alone is not enough when ids are known: an SSH port
/// forward is loopback too. An environment not described yet is not here.
pub fn hosts_described(descriptor: &Row, own: bool, origin: &str) -> bool {
    if descriptor.is_empty() {
        return false;
    }
    let theirs = descriptor
        .get("platform")
        .and_then(|p| p.get("machineId"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let ours = id();
    if !theirs.is_empty() && !ours.is_empty() {
        return theirs == ours;
    }
    own && loopback_host(&origin_host(origin))
}

/// [`hosts_described`] for an environment of the cluster the shell is
/// connected to.
pub fn hosts(engine: &Engine, environment_id: &str) -> bool {
    let descriptor = store::with(engine, |s| s.environment(environment_id));
    let own = controller::mc(engine).is_some_and(|mc| mc.environment() == environment_id);
    let origin = Bridge::main(engine).mc_origin(engine);
    hosts_described(&descriptor, own, &origin)
}

/// Whether the MC the shell is connected to runs here.
pub fn mc_here(engine: &Engine) -> bool {
    controller::mc(engine).is_some_and(|mc| hosts(engine, &mc.environment()))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const HERE: &str = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
    const ELSEWHERE: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

    fn on(machine: &str) -> Row {
        json!({"platform": {"machineId": machine}})
            .as_object()
            .cloned()
            .unwrap_or_default()
    }

    /// An MC from before `platform.machineId`.
    fn unsaid() -> Row {
        json!({"environmentId": "env-a"})
            .as_object()
            .cloned()
            .unwrap_or_default()
    }

    #[test]
    fn id_is_the_hash_the_mc_serves() {
        set_id_for_testing(None);
        match raw_id() {
            Some(raw) if !raw.is_empty() => {
                assert_eq!(id(), hash(&raw));
                assert_eq!(id().len(), 64);
                assert!(
                    id().chars()
                        .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
                );
            }
            _ => assert_eq!(id(), ""),
        }
        // The MC's own example: sha256 of the bytes as they are.
        assert_eq!(
            hash(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn loopback_hosts() {
        for host in [
            "localhost",
            "LOCALHOST",
            "127.0.0.1",
            "127.8.9.10",
            "::1",
            "[::1]",
            "::ffff:127.0.0.1",
            "::ffff:7f00:1",
        ] {
            assert!(loopback_host(host), "{host}");
        }
        for host in [
            "",
            "192.168.1.20",
            "100.64.0.7",
            "devbox",
            "localhost.example.com",
            "::2",
            // DNS names that only look like loopback addresses.
            "127.example.com",
            "127.0.0.1.nip.io",
        ] {
            assert!(!loopback_host(host), "{host}");
        }
    }

    #[test]
    fn ids_decide_when_both_are_known() {
        set_id_for_testing(Some(HERE.into()));
        // A cluster member on this machine, reached through another MC.
        assert!(hosts_described(&on(HERE), false, "ws://192.168.1.20:3773"));
        // An SSH port forward: loopback, but another machine.
        assert!(!hosts_described(
            &on(ELSEWHERE),
            true,
            "ws://127.0.0.1:3773"
        ));
        set_id_for_testing(None);
    }

    #[test]
    fn without_ids_only_the_own_mc_on_loopback_is_here() {
        set_id_for_testing(Some(HERE.into()));
        assert!(hosts_described(&unsaid(), true, "ws://localhost:3773"));
        assert!(hosts_described(&unsaid(), true, "ws://[::1]:3773"));
        assert!(!hosts_described(
            &unsaid(),
            true,
            "wss://devbox.tailnet.ts.net"
        ));
        assert!(!hosts_described(&unsaid(), false, "ws://127.0.0.1:3773"));
        // A machine with no id of its own (Android) goes by the address alone.
        set_id_for_testing(Some(String::new()));
        assert!(hosts_described(&on(ELSEWHERE), true, "ws://127.0.0.1:3773"));
        assert!(!hosts_described(&on(HERE), false, "ws://127.0.0.1:3773"));
        assert!(!hosts_described(&on(HERE), true, ""));
        set_id_for_testing(None);
    }

    /// Before the shell snapshot describes it, even the own MC on loopback
    /// could be an SSH forward.
    #[test]
    fn an_environment_not_described_yet_is_not_here() {
        set_id_for_testing(Some(HERE.into()));
        assert!(!hosts_described(&Row::new(), true, "ws://127.0.0.1:3773"));
        set_id_for_testing(Some(String::new()));
        assert!(!hosts_described(&Row::new(), true, "ws://localhost:3773"));
        set_id_for_testing(None);
    }
}
