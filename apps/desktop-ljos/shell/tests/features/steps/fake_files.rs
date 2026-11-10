//! The MC's workspace of the thread's project: desktop-qt's FakeFiles.
//! File paths to contents, and the folders git ignores, as apps/server-ex
//! lib/hal_c2/workspace.ex answers projects.listEntries, searchEntries,
//! searchContents and readFile. Also the environment's folders for
//! filesystem.browse (browser.ex): folder paths under `home`. While the MC
//! holds "search", file searches wait for `answer_held`. A file's address
//! ([`sign_file`]) serves its bytes: a small PNG for an image. It has no
//! steps of its own.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use fancy_regex::{Regex, RegexBuilder};
use serde_json::{Value, json};

use crate::fake_mc::{Download, FakeMc, Rpc};
use crate::harness::Steps;

pub struct FakeFiles {
    pub files: BTreeMap<String, String>,
    pub ignored: BTreeSet<String>,
    /// Files of the host outside every workspace, by their full path: read
    /// (readFile takes a full path), never listed.
    pub outside: BTreeMap<String, String>,
    /// Folders ("" the top) whose next listing fails.
    pub fail_once: HashSet<String>,
    pub cannot_list: bool,
    /// Folders listed as empty, as gone (`directory_not_found`), and as
    /// empty in a partial index (`truncated`).
    pub empty_folders: HashSet<String>,
    pub gone_folders: HashSet<String>,
    pub partial_folders: HashSet<String>,
    pub read_fails_once: HashSet<String>,
    /// Files the MC will not read as text, by their failure kind
    /// (`binary_file`, `not_utf8`).
    pub unreadable: HashMap<String, String>,
    /// Why no address can be signed, while it reads anything.
    pub unsignable: String,
    /// What the signed addresses serve ([`FakeFiles::downloads`]).
    downloads: Arc<Mutex<Downloads>>,
    /// The name searches (projects.searchEntries) the MC has received.
    pub searches: usize,
    /// A file larger than the MC reads whole, by its full size in bytes.
    pub truncated: HashMap<String, i64>,
    /// The machine's folders, absolute, for filesystem.browse; "~" is
    /// `home`.
    pub home: String,
    pub folders: BTreeSet<String>,
}

impl Default for FakeFiles {
    fn default() -> FakeFiles {
        FakeFiles {
            files: BTreeMap::new(),
            ignored: BTreeSet::new(),
            outside: BTreeMap::new(),
            fail_once: HashSet::new(),
            cannot_list: false,
            empty_folders: HashSet::new(),
            gone_folders: HashSet::new(),
            partial_folders: HashSet::new(),
            read_fails_once: HashSet::new(),
            unreadable: HashMap::new(),
            unsignable: String::new(),
            downloads: Arc::default(),
            searches: 0,
            truncated: HashMap::new(),
            home: "/home/sam".into(),
            folders: BTreeSet::new(),
        }
    }
}

/// The files the signed addresses serve, shared with the fake MC's I/O
/// thread, which answers their downloads.
#[derive(Default)]
pub struct Downloads {
    /// Files whose next download fails.
    pub load_fails_once: HashSet<String>,
    /// The file each signed address serves, by its token: its path and its
    /// bytes when signed.
    signed: HashMap<String, (String, Vec<u8>)>,
    /// The paths downloaded.
    pub downloaded: Vec<String>,
}

impl FakeFiles {
    /// Each signed address's token and the path it serves.
    pub fn signed_paths(&self) -> Vec<(String, String)> {
        self.downloads()
            .signed
            .iter()
            .map(|(token, (path, _))| (token.clone(), path.clone()))
            .collect()
    }

    pub fn downloads(&self) -> MutexGuard<'_, Downloads> {
        self.downloads.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// What the fake's file at `path` holds, read without the MC in hand.
pub fn contents_of(mc: &FakeMc, path: &str) -> Option<String> {
    mc.peek::<FakeFiles>()
        .and_then(|fake| fake.files.get(path).cloned())
}

pub fn fake_files(mc: &mut FakeMc) -> &mut FakeFiles {
    mc.part::<FakeFiles>()
}

/// `a/b/c` as `a`, `a/b`, `a/b/c`.
pub fn with_folders(path: &str) -> Vec<String> {
    let parts: Vec<&str> = path.split('/').collect();
    (1..=parts.len()).map(|i| parts[..i].join("/")).collect()
}

/// Answers `assets.createUrl` for a workspace or media file; false when the
/// call is for another kind of resource.
pub fn sign_file(mc: &mut FakeMc, rpc: &Rpc) -> bool {
    let resource = &rpc.payload["resource"];
    let tag = resource["_tag"].as_str().unwrap_or_default();
    if !matches!(
        tag,
        "workspace-file" | "draft-workspace-file" | "media-file"
    ) {
        return false;
    }
    let path = resource["path"].as_str().unwrap_or_default().to_owned();
    let fake = fake_files(mc);
    if !fake.unsignable.is_empty() {
        let why = fake.unsignable.clone();
        mc.refuse(rpc, &why);
        return true;
    }
    if !fake.files.contains_key(&path) && !fake.outside.contains_key(&path) {
        mc.refuse(rpc, "Workspace file was not found.");
        return true;
    }
    let media = media_fixture(&path);
    let body = if !media.is_empty() {
        media
    } else if is_image(&path) {
        png()
    } else {
        fake.files
            .get(&path)
            .or_else(|| fake.outside.get(&path))
            .cloned()
            .unwrap_or_default()
            .into_bytes()
    };
    let mut downloads = fake.downloads();
    let token = format!("file-{}", downloads.signed.len() + 1);
    downloads.signed.insert(token.clone(), (path.clone(), body));
    drop(downloads);
    let name = path.rsplit('/').next().unwrap_or_default();
    let now = chrono::Utc::now().timestamp_millis();
    mc.reply(
        rpc,
        json!({"relativeUrl": format!("/api/assets/{token}/{name}"), "expiresAt": (now + 3600 * 1000) as f64}),
    );
    true
}

/// Real, tiny media for the scenarios: what a player or a PDF reader opens
/// has to be the thing itself. Empty for any other file (desktop-qt's
/// MediaFixtures.h).
pub(super) fn media_fixture(path: &str) -> Vec<u8> {
    if path.ends_with(".mp4") {
        // One second of a 16x16 picture, from ffmpeg's lavfi "color" source.
        use base64::Engine;
        return base64::engine::general_purpose::STANDARD
            .decode("AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA2dtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACknRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAgptZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAoAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAG1bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABdXN0YmwAAADpc3RzZAAAAAAAAAABAAAA2W1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAESTGF2YzYzLjEuMTAxIG1wZWc0AAAAAAAAAAAAAAAAAAAY//8AAABfZXNkcwAAAAADgICATgABAASAgIBAIBEAAAAAAw1AAAABgAWAgIAuAAABsAEAAAG1iRMAAAEAAAABIADEjYgALQCEAhRjAAABskxhdmM2My4xLjEwMQaAgIABAgAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAw1AAAABgAAAABhzdHRzAAAAAAAAAAEAAAAFAAAIAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAFAAAAAQAAAChzdHN6AAAAAAAAAAAAAAAFAAAAFAAAAAcAAAAHAAAABwAAAAcAAAAUc3RjbwAAAAAAAAABAAADkwAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDEAAAAIZnJlZQAAADhtZGF0AAABswAQBwAAAbYRgUYXG2GYI78AAAG2U8CNAAABtlWAjQAAAbZXwI0AAAG2WYCN")
            .unwrap_or_default();
    }
    if path.ends_with(".mp3") {
        // A second of silence as WAV: what a player reads by its bytes, not
        // its name.
        const RATE: u32 = 8000;
        let mut wav = b"RIFF".to_vec();
        let mut number = |wav: &mut Vec<u8>, value: u32, size: usize| {
            for byte in 0..size {
                wav.push(((value >> (8 * byte)) & 0xFF) as u8);
            }
        };
        number(&mut wav, 36 + RATE, 4);
        wav.extend_from_slice(b"WAVEfmt ");
        number(&mut wav, 16, 4);
        number(&mut wav, 1, 2);
        number(&mut wav, 1, 2);
        number(&mut wav, RATE, 4);
        number(&mut wav, RATE, 4);
        number(&mut wav, 1, 2);
        number(&mut wav, 8, 2);
        wav.extend_from_slice(b"data");
        number(&mut wav, RATE, 4);
        wav.resize(wav.len() + RATE as usize, 0x80);
        return wav;
    }
    if path.ends_with(".pdf") {
        // Two blank pages. No cross-reference table: PDF readers rebuild one.
        return concat!(
            "%PDF-1.4\n",
            "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n",
            "2 0 obj<</Type/Pages/Kids[3 0 R 4 0 R]/Count 2>>endobj\n",
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n",
            "4 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n",
            "trailer<</Root 1 0 R>>\n%%EOF\n"
        )
        .as_bytes()
        .to_vec();
    }
    Vec::new()
}

/// A 4x3 PNG, what an image file holds.
fn png() -> Vec<u8> {
    let image = image::RgbImage::from_pixel(4, 3, image::Rgb([0, 139, 139]));
    let mut bytes = Vec::new();
    let _ = image::DynamicImage::ImageRgb8(image).write_to(
        &mut std::io::Cursor::new(&mut bytes),
        image::ImageFormat::Png,
    );
    bytes
}

fn not_found() -> Download {
    Download {
        status: 404,
        content_type: "text/plain",
        body: Vec::new(),
    }
}

fn entry(fake: &FakeFiles, path: &str) -> Value {
    let directory = !fake.files.contains_key(path);
    let ignored = with_folders(path)
        .iter()
        .any(|folder| fake.ignored.contains(folder));
    json!({"path": path, "kind": if directory { "directory" } else { "file" }, "ignored": ignored})
}

fn is_image(path: &str) -> bool {
    let lower = path.to_lowercase();
    ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
        .iter()
        .any(|ext| lower.ends_with(&format!(".{ext}")))
}

/// A UTF-16 offset, as QRegularExpression reports one.
fn utf16(line: &str, byte: usize) -> usize {
    line[..byte].encode_utf16().count()
}

fn extension(mc: &mut FakeMc) {
    // A signed file's bytes, or a 404 once when its download fails.
    let downloads = fake_files(mc).downloads.clone();
    mc.on_download("/api/assets/file-", move |target| {
        let token = target.split('/').nth(3).unwrap_or_default();
        let mut downloads = downloads.lock().unwrap_or_else(|e| e.into_inner());
        let Some((path, body)) = downloads.signed.get(token).cloned() else {
            return not_found();
        };
        if downloads.load_fails_once.remove(&path) {
            return not_found();
        }
        downloads.downloaded.push(path.clone());
        Download {
            status: 200,
            content_type: if is_image(&path) {
                "image/png"
            } else {
                "application/octet-stream"
            },
            body,
        }
    });
    mc.on_rpc("projects.listEntries", |mc, rpc| {
        let folder = rpc.payload["directoryPath"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let fake = fake_files(mc);
        if fake.cannot_list || fake.fail_once.remove(&folder) {
            let what = if folder.is_empty() {
                "the project"
            } else {
                &folder
            };
            mc.refuse(rpc, &format!("Could not list {what}."));
            return Ok(());
        }
        if fake.gone_folders.contains(&folder) {
            mc.refuse_with(
                rpc,
                &format!("'{folder}' does not exist."),
                json!({"failure": "directory_not_found"}),
            );
            return Ok(());
        }
        if fake.empty_folders.contains(&folder) || fake.partial_folders.contains(&folder) {
            let truncated = fake.partial_folders.contains(&folder);
            mc.reply(rpc, json!({"entries": [], "truncated": truncated}));
            return Ok(());
        }
        let mut children = BTreeSet::new();
        for key in fake.files.keys() {
            for path in with_folders(key) {
                let parent = path.rfind('/').map_or("", |slash| &path[..slash]);
                if parent == folder {
                    children.insert(path);
                }
            }
        }
        let entries: Vec<Value> = children.iter().map(|path| entry(fake, path)).collect();
        mc.reply(rpc, json!({"entries": entries, "truncated": false}));
        Ok(())
    });
    // By name; `kind` narrows to files or folders.
    mc.on_rpc("projects.searchEntries", |mc, rpc| {
        fake_files(mc).searches += 1;
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            let query = rpc.payload["query"]
                .as_str()
                .unwrap_or_default()
                .to_lowercase();
            let kind = rpc.payload["kind"].as_str().unwrap_or_default();
            let fake = fake_files(mc);
            let mut matches = BTreeSet::new();
            for key in fake.files.keys() {
                for path in with_folders(key) {
                    // The MC's rank: by name, else anywhere in the path.
                    if path.to_lowercase().contains(&query) {
                        matches.insert(path);
                    }
                }
            }
            let mut entries = Vec::new();
            for path in &matches {
                let found = entry(fake, path);
                if kind == "file" && found["kind"] != "file" {
                    continue;
                }
                entries.push(found);
            }
            mc.reply(&rpc, json!({"entries": entries, "truncated": false}));
        };
        if mc.holding("search") {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
    // Line by line; an unparseable regular expression falls back to the
    // text.
    mc.on_rpc("projects.searchContents", |mc, rpc| {
        let query = rpc.payload["query"].as_str().unwrap_or_default();
        let case_sensitive = rpc.payload["caseSensitive"].as_bool().unwrap_or(false);
        let mut pattern = fancy_regex::escape(query).into_owned();
        let mut answer = serde_json::Map::new();
        if rpc.payload["useRegex"].as_bool().unwrap_or(false) {
            if Regex::new(query).is_ok() {
                pattern = query.to_owned();
            } else {
                answer.insert("regexFallbackError".into(), json!("Unmatched parenthesis"));
            }
        }
        if rpc.payload["wholeWord"].as_bool().unwrap_or(false) {
            pattern = format!("\\b(?:{pattern})\\b");
        }
        let fake = fake_files(mc);
        let expression = RegexBuilder::new(&pattern)
            .case_insensitive(!case_sensitive)
            .build()
            .ok();
        let mut matches = Vec::new();
        if let Some(expression) = expression {
            for (path, contents) in &fake.files {
                for (line, text) in contents.split('\n').enumerate() {
                    let Ok(Some(found)) = expression.find(text) else {
                        continue;
                    };
                    matches.push(json!({
                        "path": path,
                        "lineNumber": line + 1,
                        "lineContent": text,
                        "matchRanges": [{
                            "start": utf16(text, found.start()),
                            "end": utf16(text, found.end()),
                        }],
                    }));
                }
            }
        }
        answer.insert("matches".into(), Value::Array(matches));
        answer.insert("truncated".into(), json!(false));
        mc.reply(rpc, Value::Object(answer));
        Ok(())
    });
    mc.on_rpc("projects.readFile", |mc, rpc| {
        let path = rpc.payload["relativePath"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let fake = fake_files(mc);
        if let Some(kind) = fake.unreadable.get(&path).cloned() {
            mc.refuse_with(
                rpc,
                &format!("'{path}' is not a text file."),
                json!({"failure": kind}),
            );
            return Ok(());
        }
        let known = fake.files.contains_key(&path) || fake.outside.contains_key(&path);
        if fake.read_fails_once.remove(&path) || !known {
            mc.refuse(rpc, &format!("Could not read {path}."));
            return Ok(());
        }
        let contents = fake
            .files
            .get(&path)
            .or_else(|| fake.outside.get(&path))
            .cloned()
            .unwrap_or_default();
        let size = fake
            .truncated
            .get(&path)
            .copied()
            .unwrap_or(contents.len() as i64);
        let truncated = fake.truncated.contains_key(&path);
        let answer =
            json!({"contents": contents, "byteLength": size as f64, "truncated": truncated});
        if mc.holding("read") {
            let rpc = rpc.clone();
            mc.defer(move |mc| mc.reply(&rpc, answer));
        } else {
            mc.reply(rpc, answer);
        }
        Ok(())
    });
    // The folders in the typed path's parent whose names start with its last
    // segment; a path ending in "/" lists the whole folder.
    mc.on_rpc("filesystem.browse", |mc, rpc| {
        let fake = fake_files(mc);
        let mut partial = rpc.payload["partialPath"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if partial == "~" {
            partial = "~/".into();
        }
        if let Some(rest) = partial.strip_prefix('~') {
            partial = format!("{}{rest}", fake.home);
        }
        let slash = partial.rfind('/');
        let mut parent = slash.map_or(String::new(), |s| partial[..s].to_owned());
        if parent.is_empty() {
            parent = "/".into();
        }
        let prefix = slash.map_or(partial.as_str(), |s| &partial[s + 1..]);
        let prefix = prefix.to_lowercase();
        let mut entries = Vec::new();
        for folder in &fake.folders {
            let at = folder.rfind('/');
            let within = match at {
                Some(at) if at > 0 => folder[..at].to_owned(),
                _ => "/".to_owned(),
            };
            let name = at.map_or(folder.as_str(), |at| &folder[at + 1..]);
            if within == parent && name.to_lowercase().starts_with(&prefix) {
                entries.push(json!({"name": name, "fullPath": folder}));
            }
        }
        mc.reply(rpc, json!({"parentPath": parent, "entries": entries}));
        Ok(())
    });
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
}
