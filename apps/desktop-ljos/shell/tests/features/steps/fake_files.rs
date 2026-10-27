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
    pub read_fails_once: HashSet<String>,
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
            read_fails_once: HashSet::new(),
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
    pub fn downloads(&self) -> MutexGuard<'_, Downloads> {
        self.downloads.lock().unwrap_or_else(|e| e.into_inner())
    }
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
    if !fake.files.contains_key(&path) && !fake.outside.contains_key(&path) {
        mc.refuse(rpc, "Workspace file was not found.");
        return true;
    }
    let body = if is_image(&path) {
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
                    let name = path.rsplit('/').next().unwrap_or_default();
                    if name.to_lowercase().contains(&query) {
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
        mc.reply(
            rpc,
            json!({"contents": contents, "byteLength": size as f64, "truncated": truncated}),
        );
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
