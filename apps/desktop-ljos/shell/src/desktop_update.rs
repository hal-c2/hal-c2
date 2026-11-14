//! The desktop app's own updates, the pure half (desktop-qt's
//! DesktopUpdateLogic): the state the update button shows and the steps
//! that change it, which releases a track offers, release notes as the
//! popover lists them, what a server-asked update does next, and the
//! button's words. [`crate::controllers::desktop_update`] runs it. An
//! empty string stands for upstream's null.

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::json::Json;

pub const STABLE: &str = "latest";
pub const NIGHTLY: &str = "nightly";
pub const RELEASE_HISTORY_URL: &str = "https://github.com/hal-c2/hal-c2/releases";
pub const CONFIRMATION_DETAIL: &str =
    "Any running tasks will be interrupted. Make sure you're ready before continuing.";

const MAX_GROUPS: usize = 6;
const MAX_ITEMS: usize = 8;
const MAX_ITEM_LENGTH: usize = 220;
const MAX_REMOTE_CHECKS: i32 = 2;
const MAX_REMOTE_DOWNLOADS: i32 = 3;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReleaseNote {
    pub version: String,
    /// At most eight, the last ones of the release, newest first.
    pub items: Vec<String>,
    pub total_items: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State {
    pub enabled: bool,
    /// disabled, idle, checking, up-to-date, available, downloading,
    /// downloaded, error
    pub status: String,
    pub channel: String,
    pub current_version: String,
    pub host_arch: String,
    pub app_arch: String,
    pub running_under_arm64_translation: bool,
    pub available_version: String,
    pub downloaded_version: String,
    pub release_notes: Vec<ReleaseNote>,
    pub omitted_release_count: i64,
    /// -1: none.
    pub download_percent: i64,
    pub checked_at: String,
    pub message: String,
    /// check, download or install: the step that failed.
    pub error_context: String,
    pub can_retry: bool,
}

impl Default for State {
    fn default() -> State {
        State {
            enabled: false,
            status: "disabled".into(),
            channel: STABLE.into(),
            current_version: String::new(),
            host_arch: String::new(),
            app_arch: String::new(),
            running_under_arm64_translation: false,
            available_version: String::new(),
            downloaded_version: String::new(),
            release_notes: Vec::new(),
            omitted_release_count: 0,
            download_percent: -1,
            checked_at: String::new(),
            message: String::new(),
            error_context: String::new(),
            can_retry: false,
        }
    }
}

fn or_null(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        json!(value)
    }
}

impl State {
    /// The contracts' DesktopUpdateState.
    pub fn to_json(&self) -> Json {
        let notes: Vec<Json> = self
            .release_notes
            .iter()
            .map(|note| {
                json!({"version": note.version, "items": note.items,
                       "totalItems": note.total_items})
            })
            .collect();
        json!({
            "enabled": self.enabled,
            "status": self.status,
            "channel": self.channel,
            "currentVersion": self.current_version,
            "hostArch": self.host_arch,
            "appArch": self.app_arch,
            "runningUnderArm64Translation": self.running_under_arm64_translation,
            "availableVersion": or_null(&self.available_version),
            "downloadedVersion": or_null(&self.downloaded_version),
            "releaseNotes": notes,
            "omittedReleaseCount": self.omitted_release_count,
            "downloadPercent": if self.download_percent < 0 { Json::Null } else { json!(self.download_percent) },
            "checkedAt": or_null(&self.checked_at),
            "message": or_null(&self.message),
            "errorContext": or_null(&self.error_context),
            "canRetry": self.can_retry,
        })
    }
}

/// "nightly" for a nightly build's version (1.4.0-nightly.20260101.3),
/// else "latest".
pub fn channel_of(version: &str) -> &'static str {
    // ^[^-+]+-nightly\.\d{8}\.\d+$
    let nightly = (|| {
        let (core, rest) = version.split_once("-nightly.")?;
        if core.is_empty() || core.contains(['-', '+']) {
            return None;
        }
        let (date, count) = rest.split_once('.')?;
        (date.len() == 8
            && date.chars().all(|c| c.is_ascii_digit())
            && !count.is_empty()
            && count.chars().all(|c| c.is_ascii_digit()))
        .then_some(())
    })();
    if nightly.is_some() { NIGHTLY } else { STABLE }
}

/// major.minor.patch and the dot-separated prerelease after "-".
struct Semver {
    core: Vec<i64>,
    pre: Vec<String>,
}

fn parse(version: &str) -> Semver {
    let version = version.strip_prefix('v').unwrap_or(version);
    let version = version.split('+').next().unwrap_or_default();
    let (core, pre) = match version.find('-') {
        Some(dash) => (
            &version[..dash],
            version[dash + 1..].split('.').map(str::to_owned).collect(),
        ),
        None => (version, Vec::new()),
    };
    // QVersionNumber::fromString: leading numeric segments.
    let mut segments = Vec::new();
    for part in core.split('.') {
        let digits: String = part.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() {
            break;
        }
        segments.push(digits.parse().unwrap_or(0));
        if digits.len() != part.len() {
            break;
        }
    }
    Semver {
        core: segments,
        pre,
    }
}

/// Orders versions as semver does: <0, 0, >0.
pub fn compare_versions(a: &str, b: &str) -> i32 {
    let left = parse(a);
    let right = parse(b);
    let len = left.core.len().max(right.core.len());
    for i in 0..len {
        let l = left.core.get(i).copied().unwrap_or(0);
        let r = right.core.get(i).copied().unwrap_or(0);
        if l != r {
            return if l < r { -1 } else { 1 };
        }
    }
    // A prerelease comes before its release.
    if left.pre.is_empty() || right.pre.is_empty() {
        return i32::from(left.pre.is_empty()) - i32::from(right.pre.is_empty());
    }
    for i in 0..left.pre.len().min(right.pre.len()) {
        let l = left.pre[i].parse::<u64>();
        let r = right.pre[i].parse::<u64>();
        match (l, r) {
            (Ok(l), Ok(r)) => {
                if l != r {
                    return if l < r { -1 } else { 1 };
                }
            }
            (Ok(_), Err(_)) => return -1,
            (Err(_), Ok(_)) => return 1,
            (Err(_), Err(_)) => {
                let order = left.pre[i].cmp(&right.pre[i]);
                if order.is_ne() {
                    return if order.is_lt() { -1 } else { 1 };
                }
            }
        }
    }
    match left.pre.len().cmp(&right.pre.len()) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }
}

pub fn initial(current_version: &str, channel: &str, enabled: bool) -> State {
    State {
        current_version: current_version.to_owned(),
        channel: channel.to_owned(),
        enabled,
        status: if enabled { "idle" } else { "disabled" }.into(),
        ..State::default()
    }
}

pub fn on_check_start(mut state: State, checked_at: &str) -> State {
    let downloaded = !state.downloaded_version.is_empty();
    state.status = "checking".into();
    state.checked_at = checked_at.to_owned();
    if !downloaded {
        state.release_notes.clear();
        state.omitted_release_count = 0;
    }
    state.message.clear();
    state.download_percent = if downloaded { 100 } else { -1 };
    state.error_context.clear();
    state.can_retry = false;
    state
}

pub fn on_check_failure(mut state: State, message: &str, checked_at: &str) -> State {
    state.checked_at = checked_at.to_owned();
    state.can_retry = true;
    if !state.downloaded_version.is_empty() {
        state.status = "downloaded".into();
        state.message.clear();
        state.download_percent = 100;
        state.error_context.clear();
        return state;
    }
    state.status = "error".into();
    state.message = message.to_owned();
    state.download_percent = -1;
    state.error_context = "check".into();
    state
}

pub fn on_update_available(
    mut state: State,
    version: &str,
    checked_at: &str,
    notes: Vec<ReleaseNote>,
    omitted: i64,
) -> State {
    let downloaded = state.downloaded_version == version;
    let keep_notes = downloaded && notes.is_empty();
    state.status = if downloaded {
        "downloaded"
    } else {
        "available"
    }
    .into();
    state.available_version = version.to_owned();
    state.downloaded_version = if downloaded {
        version.to_owned()
    } else {
        String::new()
    };
    if !keep_notes {
        state.release_notes = notes;
        state.omitted_release_count = omitted;
    }
    state.download_percent = if downloaded { 100 } else { -1 };
    state.checked_at = checked_at.to_owned();
    state.message.clear();
    state.error_context.clear();
    state.can_retry = downloaded;
    state
}

pub fn on_no_update(mut state: State, checked_at: &str) -> State {
    state.checked_at = checked_at.to_owned();
    state.message.clear();
    state.error_context.clear();
    if !state.downloaded_version.is_empty() {
        state.status = "downloaded".into();
        state.available_version = state.downloaded_version.clone();
        state.download_percent = 100;
        state.can_retry = true;
        return state;
    }
    state.status = "up-to-date".into();
    state.available_version.clear();
    state.downloaded_version.clear();
    state.release_notes.clear();
    state.omitted_release_count = 0;
    state.download_percent = -1;
    state.can_retry = false;
    state
}

pub fn on_download_start(mut state: State) -> State {
    state.status = "downloading".into();
    state.download_percent = 0;
    state.message.clear();
    state.error_context.clear();
    state.can_retry = false;
    state
}

pub fn on_download_failure(mut state: State, message: &str) -> State {
    state.status = if state.available_version.is_empty() {
        "error"
    } else {
        "available"
    }
    .into();
    state.message = message.to_owned();
    state.download_percent = -1;
    state.error_context = "download".into();
    state.can_retry = !state.available_version.is_empty();
    state
}

pub fn on_download_progress(mut state: State, percent: i64) -> State {
    state.status = "downloading".into();
    state.download_percent = percent;
    state.message.clear();
    state.error_context.clear();
    state.can_retry = false;
    state
}

pub fn on_download_complete(mut state: State, version: &str) -> State {
    state.status = "downloaded".into();
    state.available_version = version.to_owned();
    state.downloaded_version = version.to_owned();
    state.download_percent = 100;
    state.message.clear();
    state.error_context.clear();
    state.can_retry = true;
    state
}

pub fn on_install_failure(mut state: State, message: &str) -> State {
    state.status = "downloaded".into();
    state.message = message.to_owned();
    state.error_context = "install".into();
    state.can_retry = true;
    state
}

/// Whether a new percent changes what is shown: a whole ten percent, or done.
pub fn shows_progress(state: &State, percent: i64) -> bool {
    if state.status != "downloading" || state.download_percent < 0 {
        return true;
    }
    state.download_percent / 10 != percent / 10 || percent == 100
}

/// A release of the update feed (a GitHub releases list).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    pub notes: String,
    pub prerelease: bool,
    /// The asset this machine installs.
    pub asset: String,
    pub size: i64,
    /// The asset's published digest, lowercase hex.
    pub sha256: String,
}

/// GitHub's `digest` of a release asset, "sha256:<hex>"; "" without a
/// usable one.
fn digest_of(asset: &Json) -> String {
    let digest = asset
        .get("digest")
        .and_then(Json::as_str)
        .unwrap_or_default();
    let Some(hex) = digest.strip_prefix("sha256:") else {
        return String::new();
    };
    if hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
        hex.to_lowercase()
    } else {
        String::new()
    }
}

/// Whether `bytes` have the digest.
pub fn matches_digest(bytes: &[u8], sha256: &str) -> bool {
    let digest = Sha256::digest(bytes);
    digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()
        == sha256
}

/// Hex digest of what a hasher was fed, as it goes.
pub fn digest_hex(hasher: &Sha256) -> String {
    hasher
        .clone()
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The feed's releases that are not drafts and have an asset for
/// `platform` (linux, macos) and `arch` (x64, arm64), newest first. The
/// app runs what it downloads, so an asset that is not https or has no
/// sha256 digest does not count.
pub fn parse_feed(json: &[u8], platform: &str, arch: &str) -> Vec<Release> {
    let Ok(Json::Array(values)) = serde_json::from_slice::<Json>(json) else {
        return Vec::new();
    };
    let mut releases = Vec::new();
    for value in &values {
        if value.get("draft").and_then(Json::as_bool) == Some(true) {
            continue;
        }
        let tag = value
            .get("tag_name")
            .and_then(Json::as_str)
            .unwrap_or_default();
        let version = tag.strip_prefix('v').unwrap_or(tag).to_owned();
        if version.is_empty() {
            continue;
        }
        // The AppImage, or the macOS zip: this arch's when there are several.
        let mut chosen: Option<&Json> = None;
        for asset in value
            .get("assets")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
        {
            let url = asset
                .get("browser_download_url")
                .and_then(Json::as_str)
                .unwrap_or_default();
            if !url.starts_with("https://") || digest_of(asset).is_empty() {
                continue;
            }
            let name = asset
                .get("name")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_lowercase();
            let fits = match platform {
                "linux" => name.ends_with(".appimage"),
                "macos" => name.ends_with(".zip") && name.contains("macos"),
                _ => false,
            };
            if !fits {
                continue;
            }
            let arch_named =
                name.contains("arm64") || name.contains("x64") || name.contains("x86_64");
            let ours =
                !arch_named || name.contains(arch) || (arch == "x64" && name.contains("x86_64"));
            if ours && (chosen.is_none() || arch_named) {
                chosen = Some(asset);
            }
        }
        let Some(asset) = chosen else { continue };
        releases.push(Release {
            version,
            notes: value
                .get("body")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned(),
            prerelease: value
                .get("prerelease")
                .and_then(Json::as_bool)
                .unwrap_or(false),
            asset: asset
                .get("browser_download_url")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned(),
            size: asset
                .get("size")
                .and_then(Json::as_f64)
                .map_or(0, |n| n as i64),
            sha256: digest_of(asset),
        });
    }
    releases.sort_by(|a, b| compare_versions(&b.version, &a.version).cmp(&0));
    releases
}

/// Where the app runs, as far as updating itself goes (desktop-qt's
/// DesktopUpdater::Environment).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Environment {
    pub app_version: String,
    /// linux, macos, or another platform this app cannot update itself on.
    pub platform: String,
    /// $APPIMAGE: the AppImage the app runs from on Linux.
    pub app_image: String,
    /// A release build, from its bundle on macOS.
    pub packaged: bool,
    /// HAL_C2_DISABLE_AUTO_UPDATE=1.
    pub disabled_by_env: bool,
    pub feed_url: String,
    /// x64 or arm64: the machine's and the build's.
    pub host_arch: String,
    pub app_arch: String,
    pub translated: bool,
    /// Updates are off and no reason is given.
    pub unexplained: bool,
}

impl Environment {
    /// This process's.
    pub fn system() -> Environment {
        let arch = |name: &str| {
            if name == "x86_64" {
                "x64".to_owned()
            } else {
                name.to_owned()
            }
        };
        let platform = if cfg!(target_os = "linux") {
            "linux"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else if cfg!(any(target_os = "android", target_os = "ios")) {
            "mobile"
        } else {
            "other"
        };
        let app_arch = arch(std::env::consts::ARCH);
        Environment {
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            platform: platform.into(),
            app_image: std::env::var("APPIMAGE").unwrap_or_default(),
            // A release build stamps this in; a dev build cannot update.
            packaged: option_env!("HAL_C2_RELEASE_BUILD").is_some()
                && (platform != "macos"
                    || std::env::current_exe()
                        .is_ok_and(|exe| exe.to_string_lossy().contains(".app/Contents/MacOS/"))),
            disabled_by_env: std::env::var("HAL_C2_DISABLE_AUTO_UPDATE").as_deref() == Ok("1"),
            feed_url: std::env::var("HAL_C2_UPDATE_FEED")
                .unwrap_or_else(|_| option_env!("HAL_C2_UPDATE_FEED").unwrap_or("").to_owned()),
            host_arch: app_arch.clone(),
            app_arch,
            translated: false,
            unexplained: false,
        }
    }
}

/// Why `environment` cannot update itself; empty when it can (and when it
/// says nothing).
pub fn disabled_reason(environment: &Environment) -> String {
    if environment.unexplained {
        return String::new();
    }
    if environment.feed_url.trim().is_empty() {
        return "Automatic updates are not available because no update feed is configured.".into();
    }
    if !environment.feed_url.trim().starts_with("https://") {
        return "Automatic updates are not available because the update feed is not https.".into();
    }
    if !environment.packaged || (environment.platform != "linux" && environment.platform != "macos")
    {
        return "Automatic updates are only available in packaged production builds.".into();
    }
    if environment.disabled_by_env {
        return "Automatic updates are disabled by the HAL_C2_DISABLE_AUTO_UPDATE setting.".into();
    }
    if environment.platform == "linux" && environment.app_image.is_empty() {
        return "Automatic updates on Linux require running the AppImage build.".into();
    }
    String::new()
}

pub fn enabled_for(environment: &Environment) -> bool {
    !environment.unexplained && disabled_reason(environment).is_empty()
}

pub struct Offer {
    pub release: Release,
    pub notes: Vec<ReleaseNote>,
    pub omitted: i64,
}

/// The release `channel` offers a build at `current_version`: the newest
/// of the track when it is newer, or, with `allow_downgrade`, when it is
/// another.
pub fn select(
    releases: &[Release],
    current_version: &str,
    channel: &str,
    allow_downgrade: bool,
) -> Option<Offer> {
    let mut track: Vec<&Release> = releases
        .iter()
        .filter(|release| {
            if channel == NIGHTLY {
                channel_of(&release.version) == NIGHTLY
            } else {
                !release.prerelease && !release.version.contains('-')
            }
        })
        .collect();
    track.sort_by(|a, b| compare_versions(&b.version, &a.version).cmp(&0));
    let newest = *track.first()?;
    let order = compare_versions(&newest.version, current_version);
    if order < 0 && !allow_downgrade {
        return None;
    }
    if order == 0 {
        return None;
    }
    // Nightly lists every release since this build (its full changelog);
    // stable, the offered one's.
    let mut sources = Vec::new();
    for release in &track {
        let is_newest = std::ptr::eq(*release, newest);
        if !is_newest
            && (channel != NIGHTLY || compare_versions(&release.version, current_version) <= 0)
        {
            continue;
        }
        sources.push(NoteSource {
            version: release.version.clone(),
            note: release.notes.clone(),
        });
    }
    let notes = normalize_release_notes(&sources, channel);
    Some(Offer {
        release: newest.clone(),
        notes: notes.release_notes,
        omitted: notes.omitted_release_count,
    })
}

pub struct Notes {
    pub release_notes: Vec<ReleaseNote>,
    pub omitted_release_count: i64,
}

pub struct NoteSource {
    pub version: String,
    pub note: String,
}

/// Release notes as plain lines: markup and GitHub boilerplate gone, each
/// cut at 220 characters, releases of another track and empty ones left
/// out, six at most.
pub fn normalize_release_notes(sources: &[NoteSource], channel: &str) -> Notes {
    let mut notes = Vec::new();
    for source in sources {
        if channel_of(&source.version) != channel {
            continue;
        }
        let note = extract_items(&source.version, &source.note);
        if note.total_items > 0 {
            notes.push(note);
        }
    }
    let omitted = notes.len().saturating_sub(MAX_GROUPS) as i64;
    notes.truncate(MAX_GROUPS);
    Notes {
        release_notes: notes,
        omitted_release_count: omitted,
    }
}

fn decode_entity(entity: &str) -> String {
    let named = match entity {
        "amp" => Some("&"),
        "apos" => Some("'"),
        "gt" => Some(">"),
        "lt" => Some("<"),
        "nbsp" => Some(" "),
        "quot" => Some("\""),
        _ => None,
    };
    if let Some(text) = named {
        return text.to_owned();
    }
    let code = if let Some(hex) = entity.strip_prefix("#x") {
        i64::from_str_radix(hex, 16).ok()
    } else if let Some(decimal) = entity.strip_prefix('#') {
        decimal.parse::<i64>().ok()
    } else {
        None
    };
    match code
        .and_then(|c| u32::try_from(c).ok())
        .and_then(char::from_u32)
    {
        Some(point) => point.to_string(),
        None => format!("&{entity};"),
    }
}

fn strip_markup(text: &str) -> String {
    use regex::Regex;
    let ci = |pattern: String| Regex::new(&format!("(?i){pattern}")).expect("a pattern");
    let mut text = ci(r"<br\s*/?>".into()).replace_all(text, "\n").into_owned();
    text = ci(r"<li\b[^>]*>".into())
        .replace_all(&text, "\n- ")
        .into_owned();
    let heading = ci(r"<h([1-6])\b[^>]*>".into());
    text = heading
        .replace_all(&text, |caps: &regex::Captures| {
            let level: usize = caps[1].parse().unwrap_or(1);
            format!("\n{} ", "#".repeat(level))
        })
        .into_owned();
    text = ci(r"</(?:p|div|li|h[1-6]|ul|ol|blockquote)>".into())
        .replace_all(&text, "\n")
        .into_owned();
    text = Regex::new(r"<[^>]*>")
        .expect("a pattern")
        .replace_all(&text, "")
        .into_owned();
    text = Regex::new(r"\[([^\]]+)\]\([^)]+\)")
        .expect("a pattern")
        .replace_all(&text, "$1")
        .into_owned();
    text = Regex::new(r"\*\*([^*]+)\*\*")
        .expect("a pattern")
        .replace_all(&text, "$1")
        .into_owned();
    let entity = Regex::new(r"&([a-zA-Z]+|#\d+|#x[0-9a-fA-F]+);").expect("a pattern");
    entity
        .replace_all(&text, |caps: &regex::Captures| decode_entity(&caps[1]))
        .into_owned()
}

fn normalized_line(line: &str) -> String {
    line.to_lowercase()
        .replace(['*', '_', '`', '#'], "")
        .trim()
        .to_owned()
}

fn extract_items(version: &str, note: &str) -> ReleaseNote {
    use regex::Regex;
    let bullet = Regex::new(r"^[-*]\s+").expect("a pattern");
    let numbered = Regex::new(r"^\d+[.)]\s+").expect("a pattern");
    let spaces = Regex::new(r"\s+").expect("a pattern");
    let heading_line = Regex::new(r"^#{1,6}\s+").expect("a pattern");
    let mut result = ReleaseNote {
        version: version.to_owned(),
        ..ReleaseNote::default()
    };
    for raw in strip_markup(note).split('\n') {
        let mut item = raw.trim().to_owned();
        item = bullet.replace(&item, "").into_owned();
        item = numbered.replace(&item, "").into_owned();
        item = spaces.replace_all(&item, " ").into_owned();
        let normalized = normalized_line(&item);
        if normalized == "new contributors" || normalized == "full changelog" {
            break;
        }
        if heading_line.is_match(&item) {
            continue;
        }
        if normalized.is_empty()
            || normalized == "what's changed"
            || normalized == "whats changed"
            || normalized.starts_with("compare: ")
            || normalized.contains("/compare/")
        {
            continue;
        }
        result.total_items += 1;
        if item.chars().count() > MAX_ITEM_LENGTH {
            let mut cut: String = item.chars().take(MAX_ITEM_LENGTH - 3).collect();
            while cut.ends_with(char::is_whitespace) {
                cut.pop();
            }
            item = format!("{cut}...");
        }
        result.items.push(item);
        if result.items.len() > MAX_ITEMS {
            result.items.remove(0);
        }
    }
    result.items.reverse();
    result
}

/// A server-asked update's next step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteKind {
    Check,
    Download,
    Install,
    Wait,
    Done,
    Failed,
}

pub struct RemoteStep {
    pub kind: RemoteKind,
    /// Done: up-to-date. Failed: why.
    pub reason: String,
}

pub fn next_remote_step(
    state: &State,
    checks: i32,
    downloads: i32,
    disabled_reason: &str,
) -> RemoteStep {
    let failed = |reason: &str, fallback: &str| {
        let trimmed = reason.trim();
        RemoteStep {
            kind: RemoteKind::Failed,
            reason: if trimmed.is_empty() {
                fallback.to_owned()
            } else {
                trimmed.to_owned()
            },
        }
    };
    if !state.enabled || state.status == "disabled" {
        return failed(
            disabled_reason,
            "Automatic updates are disabled on this machine.",
        );
    }
    if installable(state) {
        return RemoteStep {
            kind: RemoteKind::Install,
            reason: String::new(),
        };
    }
    if state.status == "downloading" || state.status == "checking" {
        return RemoteStep {
            kind: RemoteKind::Wait,
            reason: String::new(),
        };
    }
    if state.status == "available" {
        if downloads >= MAX_REMOTE_DOWNLOADS {
            return failed(
                &state.message,
                "The desktop app failed to download the update.",
            );
        }
        return RemoteStep {
            kind: RemoteKind::Download,
            reason: String::new(),
        };
    }
    // An earlier check's answer is stale: a request looks again first.
    if state.status == "up-to-date" {
        return if checks == 0 {
            RemoteStep {
                kind: RemoteKind::Check,
                reason: String::new(),
            }
        } else {
            RemoteStep {
                kind: RemoteKind::Done,
                reason: "up-to-date".into(),
            }
        };
    }
    if state.status == "error" {
        return if checks == 0 {
            RemoteStep {
                kind: RemoteKind::Check,
                reason: String::new(),
            }
        } else {
            failed(&state.message, "The desktop app update failed.")
        };
    }
    if checks >= MAX_REMOTE_CHECKS {
        return RemoteStep {
            kind: RemoteKind::Failed,
            reason: "The desktop app did not report an update result.".into(),
        };
    }
    RemoteStep {
        kind: RemoteKind::Check,
        reason: String::new(),
    }
}

/// Whether the downloaded update can be installed now.
pub fn installable(state: &State) -> bool {
    !state.downloaded_version.is_empty()
        && (state.status == "downloaded"
            || (state.status == "error"
                && (state.error_context.is_empty() || state.error_context == "install")))
}

/// The update button: what a press does (install, download, none).
pub fn button_action(state: &State) -> &'static str {
    if installable(state) {
        return "install";
    }
    if state.status == "available" {
        return "download";
    }
    if state.status == "error"
        && state.error_context == "download"
        && !state.available_version.is_empty()
    {
        return "download";
    }
    "none"
}

/// "1.4.0" as the button says it: "v1.4.0".
fn shown(version: &str) -> String {
    if version.starts_with('v') {
        version.to_owned()
    } else {
        format!("v{version}")
    }
}

// getDesktopUpdateButtonTooltip, except that a failed download or install
// says so first: their reducers leave the status available or downloaded.
pub fn tooltip(state: &State) -> String {
    if state.error_context == "download" && !state.available_version.is_empty() {
        return format!(
            "Download failed for {}. Click to retry.",
            shown(&state.available_version)
        );
    }
    if state.error_context == "install" && !state.downloaded_version.is_empty() {
        return format!(
            "Install failed for {}. Click to retry.",
            shown(&state.downloaded_version)
        );
    }
    if state.status == "available" {
        return format!(
            "Update {} ready to download",
            if state.available_version.is_empty() {
                "available".to_owned()
            } else {
                shown(&state.available_version)
            }
        );
    }
    if state.status == "downloading" {
        return if state.download_percent < 0 {
            "Downloading update".into()
        } else {
            format!("Downloading update ({}%)", state.download_percent)
        };
    }
    let downloaded = if !state.downloaded_version.is_empty() {
        shown(&state.downloaded_version)
    } else if !state.available_version.is_empty() {
        shown(&state.available_version)
    } else {
        "ready".to_owned()
    };
    if state.status == "downloaded"
        || (state.status == "error" && !state.downloaded_version.is_empty())
    {
        return format!("Update {downloaded} downloaded. Click to restart and install.");
    }
    if state.status == "error" {
        return if state.message.is_empty() {
            "Update failed".into()
        } else {
            state.message.clone()
        };
    }
    "Up to date".into()
}

pub fn shows_details(state: &State) -> bool {
    button_action(state) != "none" || state.status == "downloading"
}

/// What the button says when pointed at.
pub fn label(state: &State) -> String {
    if shows_details(state) {
        return tooltip(state);
    }
    if state.status == "checking" {
        "Checking for updates…".into()
    } else {
        "Check for updates".into()
    }
}

pub fn can_check(state: &State) -> bool {
    state.enabled
        && state.status != "checking"
        && state.status != "downloading"
        && state.status != "disabled"
}

pub fn confirmation_title(state: &State) -> String {
    let version = if state.downloaded_version.is_empty() {
        &state.available_version
    } else {
        &state.downloaded_version
    };
    if version.is_empty() {
        "Install update and restart HAL-C2?".into()
    } else {
        format!("Install update {} and restart HAL-C2?", shown(version))
    }
}

pub fn shows_intel_warning(state: &State) -> bool {
    state.host_arch == "arm64" && state.app_arch == "x64"
}

pub fn intel_warning(state: &State) -> String {
    if !shows_intel_warning(state) {
        return String::new();
    }
    let prefix =
        "This Mac has Apple Silicon, but HAL-C2 is still running the Intel build under Rosetta.";
    match button_action(state) {
        "download" => format!(
            "{prefix} Download the available update to switch to the native Apple Silicon build."
        ),
        "install" => {
            format!("{prefix} Restart to install the downloaded Apple Silicon build.")
        }
        _ => format!(
            "{prefix} The next app update will replace it with the native Apple Silicon build."
        ),
    }
}

pub fn release_url(version: &str) -> String {
    let trimmed = version.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // QUrl::toPercentEncoding leaves alphanumerics and -._~ plus, by
    // default, nothing else of a version's alphabet unescaped.
    let mut encoded = String::new();
    for byte in trimmed.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    format!("{RELEASE_HISTORY_URL}/tag/v{encoded}")
}

/// The nightly popover (empty when there is none): {header,
/// groups:[{title, version, items, link, url}], footer, footerUrl}.
pub fn popover(state: &State) -> Json {
    if !shows_details(state) || state.channel != NIGHTLY || state.release_notes.is_empty() {
        return json!({});
    }
    let groups: Vec<Json> = state
        .release_notes
        .iter()
        .enumerate()
        .map(|(i, note)| {
            let more = note.total_items - note.items.len() as i64;
            json!({
                "title": if i == 0 { "What's changed".to_owned() } else { format!("Changes in {}", note.version) },
                "version": note.version,
                "items": note.items,
                "link": if more <= 0 {
                    "View release on GitHub".to_owned()
                } else {
                    format!("{more} more {} on GitHub", if more == 1 { "change" } else { "changes" })
                },
                "url": release_url(&note.version),
            })
        })
        .collect();
    let mut view = json!({
        "header": if state.status == "available" && !state.available_version.is_empty() {
            "Update ready to download".to_owned()
        } else {
            tooltip(state)
        },
        "version": if state.status == "available" { state.available_version.clone() } else { String::new() },
        "groups": groups,
    });
    if state.omitted_release_count > 0 {
        view["footer"] = json!(format!(
            "{} older {} on GitHub",
            state.omitted_release_count,
            if state.omitted_release_count == 1 {
                "release"
            } else {
                "releases"
            }
        ));
        view["footerUrl"] = json!(RELEASE_HISTORY_URL);
    }
    view
}
