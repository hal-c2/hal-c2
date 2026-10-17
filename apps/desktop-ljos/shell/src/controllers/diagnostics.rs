//! `diagnostics`, desktop-qt's DiagnosticsController: Settings →
//! Diagnostics. What this MC started and how much it uses, its resource
//! history, and its recent trace failures, from the MC's
//! `server.getProcessDiagnostics`, `server.getProcessResourceHistory`,
//! `server.getTraceDiagnostics` and `server.signalProcess` (apps/server-ex
//! HalC2.Diagnostics). Read when the page opens and on refresh.
//!
//! Publishes `diagnostics`: {
//!   processes: {loading, error, serverPid, count, cpu, memory,
//!     rows: [{pid, name, command, cpu, memory, type, depth, signaling}],
//!     groups: [{id (server | provider | terminal), label, count, collapsed, rows}]},
//!   history: {loading, error, windowMs, windows: [{label, windowMs}],
//!     cpuTime, samples, interval, count,
//!     rows: [{pid, name, command, avgCpu, maxCpu, maxMemory, cpuTime}]},
//!   traces: {loading, error, spans, failures, slowSpans, parseErrors,
//!     latestFailures: [{name, cause, duration}],
//!     commonFailures: [{name, cause, count}], slowestSpans: [{name, duration}]},
//!   logs: {available, error}}
//! with numbers formatted for reading (sizes, durations, percentages).
//!
//! Actions: `diagnostics.refresh`, `diagnostics.window {windowMs}`,
//! `diagnostics.group {id}` (folds a group of processes, or opens it again),
//! `diagnostics.signal {pid, signal}` (SIGINT, or SIGKILL once the user
//! confirms), `diagnostics.openLogs` (the logs folder in the preferred
//! editor).

use std::collections::BTreeSet;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::Menus;
use crate::controllers::settings::{Map, Settings};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::settings_page;

const SECTION: &str = "/settings/diagnostics";
const LAST_EDITOR: &str = "lastEditor";

struct Window {
    label: &'static str,
    window_ms: i64,
    bucket_ms: i64,
}

const WINDOWS: [Window; 4] = [
    Window {
        label: "5m",
        window_ms: 5 * 60_000,
        bucket_ms: 30_000,
    },
    Window {
        label: "15m",
        window_ms: 15 * 60_000,
        bucket_ms: 60_000,
    },
    Window {
        label: "30m",
        window_ms: 30 * 60_000,
        bucket_ms: 2 * 60_000,
    },
    Window {
        label: "1h",
        window_ms: 60 * 60_000,
        bucket_ms: 5 * 60_000,
    },
];

// -- Formatting: numbers as the page reads them ----------------------------

/// `QLocale(English).toString(qint64)`: digits in groups of three.
pub fn count(value: f64) -> String {
    let n = value as i64;
    let digits = n.unsigned_abs().to_string();
    let mut grouped = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(c);
    }
    if n < 0 {
        format!("-{grouped}")
    } else {
        grouped
    }
}

pub fn duration(ms: f64) -> String {
    if ms < 1000.0 {
        return format!("{} ms", ms.round() as i64);
    }
    let places = if ms >= 10_000.0 { 1 } else { 2 };
    format!("{:.places$} s", ms / 1000.0)
}

pub fn bytes(value: f64) -> String {
    if value < 1024.0 {
        return format!("{} B", value as i64);
    }
    const UNITS: [&str; 3] = ["KB", "MB", "GB"];
    let mut value = value;
    let mut unit = 0;
    loop {
        value /= 1024.0;
        if value < 1024.0 || unit == 2 {
            break;
        }
        unit += 1;
    }
    let places = if value >= 10.0 { 1 } else { 2 };
    format!("{value:.places$} {}", UNITS[unit])
}

pub fn cpu_time(seconds: f64) -> String {
    if seconds < 60.0 {
        let places = if seconds >= 10.0 { 1 } else { 2 };
        return format!("{seconds:.places$}s");
    }
    let minutes = seconds / 60.0;
    if minutes < 60.0 {
        let places = if minutes >= 10.0 { 1 } else { 2 };
        return format!("{minutes:.places$}m");
    }
    format!("{:.2}h", minutes / 60.0)
}

pub fn percent(value: f64) -> String {
    format!("{value:.1}%")
}

/// The executable's name.
pub fn process_name(command: &str) -> String {
    let first = command.split_whitespace().next().unwrap_or_default();
    if first.is_empty() {
        return command.to_owned();
    }
    let first = first.strip_prefix(['"', '\'']).unwrap_or(first);
    let first = first.strip_suffix(['"', '\'']).unwrap_or(first);
    first
        .split(['\\', '/'])
        .rfind(|s| !s.is_empty())
        .unwrap_or(first)
        .to_owned()
}

/// Whether `text` holds one of `words` whole (`\b(a|b)\b`, ASCII).
fn has_word(text: &str, words: &[&str]) -> bool {
    let lower = text.to_lowercase();
    let bytes = lower.as_bytes();
    let word_char = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    words.iter().any(|word| {
        lower.match_indices(word).any(|(at, _)| {
            let before = at == 0 || !word_char(bytes[at - 1]);
            let end = at + word.len();
            let after = end >= bytes.len() || !word_char(bytes[end]);
            before && after
        })
    })
}

fn int_of(object: &Json, key: &str) -> i64 {
    match object.get(key) {
        Some(Json::Number(n)) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f as i64))
            .unwrap_or(0),
        _ => 0,
    }
}

fn num_of(object: &Json, key: &str) -> f64 {
    object.get(key).and_then(Json::as_f64).unwrap_or(0.0)
}

pub fn process_type(process: &Json) -> &'static str {
    if int_of(process, "depth") > 0 {
        return "Subprocess";
    }
    if has_word(
        settings_page::text(process, "command"),
        &["codex", "claude", "opencode", "cursor"],
    ) {
        "Agent"
    } else {
        "Process"
    }
}

/// What a process the MC started is for, as HalC2.Diagnostics categorises
/// its telemetry (the row's own `category` when it has one): a provider's
/// agent, a terminal's shell, or the server's own; a child is its parent's.
pub fn process_group(process: &Json) -> &'static str {
    match settings_page::text(process, "category") {
        "provider-root" => return "provider",
        "terminal-root" => return "terminal",
        "" => {}
        _ => return "server",
    }
    let command = settings_page::text(process, "command");
    let first = command.split(' ').next().unwrap_or_default();
    let name = first.rsplit('/').next().unwrap_or_default();
    if ["sh", "bash", "zsh", "fish", "nu", "pwsh"].contains(&name) {
        return "terminal";
    }
    let lower = name.to_lowercase();
    let agent = ["codex", "claude", "opencode", "cursor", "grok", "gemini"]
        .iter()
        .any(|a| {
            lower
                .strip_prefix(a)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('-'))
        });
    if agent { "provider" } else { "server" }
}

/// An Option's value (`{_tag: "Some", value}`), or null.
fn option(value: Option<&Json>) -> Json {
    match value {
        Some(object) if object.get("_tag").and_then(Json::as_str) == Some("Some") => {
            object.get("value").cloned().unwrap_or(Json::Null)
        }
        _ => Json::Null,
    }
}

fn nullable(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        json!(value)
    }
}

/// The message of a read's `error` option.
fn failure_of(data: &Json) -> String {
    option(data.get("error"))
        .get("message")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

#[derive(Clone, Copy)]
enum Slot {
    Processes,
    History,
    Traces,
}

#[derive(Default)]
struct Read {
    loading: bool,
    error: String,
    data: Json,
    generation: u64,
}

impl Read {
    /// Whether anything was read.
    fn read(&self) -> bool {
        self.data.as_object().is_some_and(|o| !o.is_empty())
    }
}

pub struct Diagnostics {
    bridge: Bridge,
    me: Me<Diagnostics>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    window_ms: i64,
    signaling: i64,
    /// The process groups the user folded.
    collapsed: BTreeSet<String>,
    logs_error: String,
    processes: Read,
    history: Read,
    traces: Read,
}

impl Controller for Diagnostics {
    fn new(init: Init<'_, Self>) -> Self {
        Diagnostics {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            window_ms: 15 * 60_000,
            signaling: 0,
            collapsed: BTreeSet::new(),
            logs_error: String::new(),
            processes: Read::default(),
            history: Read::default(),
            traces: Read::default(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = settings_page::shows(route, &[SECTION]);
            me.run(engine, |c, engine| {
                if open == c.open {
                    return;
                }
                c.open = open;
                if open {
                    c.refresh(engine);
                }
            });
        });
        let me = self.me.clone();
        Settings::of(engine).on_config_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.open = settings_page::shows(&route, &[SECTION]);
        if self.open {
            self.refresh(engine);
        }
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("diagnostics.") {
            return false;
        }
        match action {
            "diagnostics.refresh" => self.refresh(engine),
            "diagnostics.window" => {
                let window_ms = settings_page::int(payload.get("windowMs"));
                if WINDOWS.iter().any(|w| w.window_ms == window_ms) {
                    self.window_ms = window_ms;
                    self.read_history(engine);
                }
            }
            "diagnostics.group" => {
                // Folds a group of processes, or opens it again.
                let id = settings_page::text(payload, "id").to_owned();
                if !self.collapsed.remove(&id) {
                    self.collapsed.insert(id);
                }
                self.publish(engine);
            }
            "diagnostics.signal" => self.signal(
                engine,
                settings_page::int(payload.get("pid")),
                settings_page::text(payload, "signal"),
            ),
            "diagnostics.openLogs" => self.open_logs(engine),
            _ => {}
        }
        true
    }
}

impl Diagnostics {
    fn refresh(&mut self, engine: &Engine) {
        self.read_processes(engine);
        self.read_history(engine);
        self.read(
            engine,
            Slot::Traces,
            "server.getTraceDiagnostics",
            json!({}),
        );
    }

    fn read_processes(&mut self, engine: &Engine) {
        self.read(
            engine,
            Slot::Processes,
            "server.getProcessDiagnostics",
            json!({}),
        );
    }

    fn read_history(&mut self, engine: &Engine) {
        let bucket_ms = WINDOWS
            .iter()
            .find(|w| w.window_ms == self.window_ms)
            .map_or(60_000, |w| w.bucket_ms);
        self.read(
            engine,
            Slot::History,
            "server.getProcessResourceHistory",
            json!({"windowMs": self.window_ms, "bucketMs": bucket_ms}),
        );
    }

    fn slot(&mut self, slot: Slot) -> &mut Read {
        match slot {
            Slot::Processes => &mut self.processes,
            Slot::History => &mut self.history,
            Slot::Traces => &mut self.traces,
        }
    }

    /// Only the latest read of each lands.
    fn read(&mut self, engine: &Engine, slot: Slot, method: &str, payload: Json) {
        let target = self.slot(slot);
        target.loading = true;
        target.generation += 1;
        let generation = target.generation;
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            method,
            payload,
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    let target = c.slot(slot);
                    if generation != target.generation {
                        return;
                    }
                    target.loading = false;
                    match result {
                        Err(e) => target.error = e.message,
                        Ok(data) => {
                            target.error.clear();
                            target.data = if data.is_object() { data } else { json!({}) };
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    /// SIGKILL asks first, and a process that is no longer the one listed
    /// is left alone.
    fn signal(&mut self, engine: &Engine, pid: i64, signal: &str) {
        if signal != "SIGINT" && signal != "SIGKILL" {
            return;
        }
        if self.signaling != 0 {
            return;
        }
        let Some(process) = self.listed(pid) else {
            return;
        };
        let start_time_ms = int_of(&process, "startTimeMs");
        if signal == "SIGINT" {
            self.send_signal(engine, pid, signal, start_time_ms);
            return;
        }
        // Asked of the user: the answer comes from the menu, after this
        // controller is through.
        let signal = signal.to_owned();
        let me = self.me.clone();
        let send: Rc<dyn Fn(&Engine)> = Rc::new(move |engine: &Engine| {
            let signal = signal.clone();
            me.run(engine, move |c, engine| {
                c.send_signal(engine, pid, &signal, start_time_ms)
            });
        });
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &format!("Send SIGKILL to process {pid}? This cannot be handled by the process."),
                "",
                "Send SIGKILL",
                true,
                Some(send),
                None,
            );
        });
    }

    fn send_signal(&mut self, engine: &Engine, pid: i64, signal: &str, start_time_ms: i64) {
        if self.signaling != 0 {
            return;
        }
        let still = self
            .listed(pid)
            .is_some_and(|p| int_of(&p, "startTimeMs") == start_time_ms);
        if !still {
            return;
        }
        self.signaling = pid;
        self.publish(engine);
        let signal = signal.to_owned();
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "server.signalProcess",
            json!({"pid": pid, "startTimeMs": start_time_ms, "signal": signal}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    c.signaling = 0;
                    let title = format!("Could not send {signal}");
                    match result {
                        Err(e) => {
                            toast_error(engine, &title, &e.message);
                            c.publish(engine);
                            return;
                        }
                        Ok(answer) => {
                            if !answer.get("signaled").and_then(Json::as_bool).unwrap_or(false) {
                                let message = option(answer.get("message"))
                                    .as_str()
                                    .unwrap_or_default()
                                    .to_owned();
                                if message.contains("not a live descendant")
                                    || message == "That process has already exited."
                                {
                                    controller::with::<Toasts, _>(engine, |toasts, engine| {
                                        toasts.show(
                                            engine,
                                            "info",
                                            "Process already exited",
                                            "The process is not a child of the HAL-C2 Server. It might already have exited.",
                                            None,
                                            DEFAULT_TIMEOUT_MS,
                                        );
                                    });
                                } else if message.is_empty() {
                                    toast_error(engine, &title, &format!("Failed to send {signal}."));
                                } else {
                                    toast_error(engine, &title, &message);
                                }
                            }
                        }
                    }
                    c.read_processes(engine);
                });
            }),
        );
    }

    fn listed(&self, pid: i64) -> Option<Json> {
        self.processes
            .data
            .get("processes")?
            .as_array()?
            .iter()
            .find(|p| int_of(p, "pid") == pid)
            .cloned()
    }

    fn logs_path(&self, engine: &Engine) -> String {
        Settings::of(engine)
            .config()
            .get("observability")
            .and_then(|o| o.get("logsDirectoryPath"))
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    }

    /// The editor last used when the MC has it, else the first it has.
    fn open_logs(&mut self, engine: &Engine) {
        let path = self.logs_path(engine);
        if path.is_empty() {
            return;
        }
        let settings = Settings::of(engine);
        let available: Vec<Json> = settings
            .config()
            .get("availableEditors")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let last = settings
            .device_value(LAST_EDITOR)
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        let editor = if available
            .iter()
            .any(|e| e.as_str() == Some(last.as_str()) && !last.is_empty())
        {
            last
        } else {
            available
                .first()
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        if editor.is_empty() {
            self.logs_error = "No available editors found.".into();
            self.publish(engine);
            return;
        }
        settings.write_device(engine, LAST_EDITOR, json!(editor));
        self.logs_error.clear();
        self.publish(engine);
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "shell.openInEditor",
            json!({"cwd": path, "editor": editor}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                let Err(e) = result else { return };
                me.run(engine, |c, engine| {
                    c.logs_error = if e.message.is_empty() {
                        "Unable to open logs folder.".into()
                    } else {
                        e.message
                    };
                    c.publish(engine);
                });
            }),
        );
    }

    fn processes_state(&self) -> Json {
        let data = &self.processes.data;
        let read = self.processes.read();
        let mut rows = Vec::new();
        // By what each is for; a child goes with the process it runs under.
        let mut group_of: std::collections::HashMap<i64, &'static str> = Default::default();
        let mut grouped: std::collections::HashMap<&'static str, Vec<Json>> = Default::default();
        let list = data
            .get("processes")
            .and_then(Json::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        for process in list {
            let pid = int_of(process, "pid");
            let parent = int_of(process, "ppid");
            let group: &'static str = match group_of.get(&parent).copied() {
                Some(g) if int_of(process, "depth") > 0 => g,
                _ => process_group(process),
            };
            group_of.insert(pid, group);
            let command = settings_page::text(process, "command");
            let row = json!({
                "pid": pid,
                "name": process_name(command),
                "command": command,
                "cpu": percent(num_of(process, "cpuPercent")),
                "memory": bytes(num_of(process, "rssBytes")),
                "type": process_type(process),
                "depth": int_of(process, "depth"),
                "signaling": self.signaling == pid,
            });
            rows.push(row.clone());
            grouped.entry(group).or_default().push(row);
        }
        let failure = failure_of(data);
        let dots = "...";
        let shown = |f: &dyn Fn() -> String| if read { f() } else { dots.to_owned() };
        json!({
            "loading": self.processes.loading,
            "error": nullable(if self.processes.error.is_empty() { &failure } else { &self.processes.error }),
            "serverPid": shown(&|| int_of(data, "serverPid").to_string()),
            "count": shown(&|| count(num_of(data, "processCount"))),
            "cpu": shown(&|| percent(num_of(data, "totalCpuPercent"))),
            "memory": shown(&|| bytes(num_of(data, "totalRssBytes"))),
            "rows": rows,
            "groups": self.groups(&grouped),
        })
    }

    /// The groups there are processes of, each open until the user folds it.
    fn groups(&self, grouped: &std::collections::HashMap<&'static str, Vec<Json>>) -> Vec<Json> {
        [
            ("server", "Server"),
            ("provider", "Provider"),
            ("terminal", "Terminal"),
        ]
        .iter()
        .filter_map(|(id, label)| {
            let rows = grouped.get(id)?;
            Some(json!({
                "id": id,
                "label": label,
                "count": rows.len(),
                "collapsed": self.collapsed.contains(*id),
                "rows": rows,
            }))
        })
        .collect()
    }

    fn history_state(&self) -> Json {
        let data = &self.history.data;
        let read = self.history.read();
        let windows: Vec<Json> = WINDOWS
            .iter()
            .map(|w| json!({"label": w.label, "windowMs": w.window_ms}))
            .collect();
        let top = data
            .get("topProcesses")
            .and_then(Json::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let rows: Vec<Json> = top
            .iter()
            .map(|process| {
                let command = settings_page::text(process, "command");
                json!({
                    "pid": int_of(process, "pid"),
                    "name": process_name(command),
                    "command": command,
                    "avgCpu": percent(num_of(process, "avgCpuPercent")),
                    "maxCpu": percent(num_of(process, "maxCpuPercent")),
                    "maxMemory": bytes(num_of(process, "maxRssBytes")),
                    "cpuTime": cpu_time(num_of(process, "cpuSecondsApprox")),
                })
            })
            .collect();
        let failure = failure_of(data);
        let dots = "...";
        let shown = |f: &dyn Fn() -> String| if read { f() } else { dots.to_owned() };
        json!({
            "loading": self.history.loading,
            "error": nullable(if self.history.error.is_empty() { &failure } else { &self.history.error }),
            "windowMs": self.window_ms,
            "windows": windows,
            "cpuTime": shown(&|| cpu_time(num_of(data, "totalCpuSecondsApprox"))),
            "samples": shown(&|| count(num_of(data, "retainedSampleCount"))),
            "interval": shown(&|| duration(num_of(data, "sampleIntervalMs"))),
            "count": shown(&|| count(top.len() as f64)),
            "rows": rows,
        })
    }

    fn traces_state(&self) -> Json {
        let data = &self.traces.data;
        let read = self.traces.read();
        let rows = |key: &str, row: &dyn Fn(&Json) -> Json| -> Vec<Json> {
            data.get(key)
                .and_then(Json::as_array)
                .map(|list| list.iter().map(row).collect())
                .unwrap_or_default()
        };
        let text = |o: &Json, key: &str| settings_page::text(o, key).to_owned();
        let mut failure = failure_of(data);
        if !failure.is_empty()
            && option(data.get("partialFailure"))
                .as_bool()
                .unwrap_or(false)
        {
            failure = format!(
                "Some trace files could not be read, so diagnostics may be incomplete. {failure}"
            );
        }
        let dots = "...";
        let shown = |key: &str| {
            if read {
                count(num_of(data, key))
            } else {
                dots.to_owned()
            }
        };
        json!({
            "loading": self.traces.loading,
            "error": nullable(if self.traces.error.is_empty() { &failure } else { &self.traces.error }),
            "spans": shown("recordCount"),
            "failures": shown("failureCount"),
            "slowSpans": shown("slowSpanCount"),
            "parseErrors": shown("parseErrorCount"),
            "latestFailures": rows("latestFailures", &|o| json!({
                "name": text(o, "name"),
                "cause": text(o, "cause"),
                "duration": duration(num_of(o, "durationMs")),
            })),
            "commonFailures": rows("commonFailures", &|o| json!({
                "name": text(o, "name"),
                "cause": text(o, "cause"),
                "count": count(num_of(o, "count")),
            })),
            "slowestSpans": rows("slowestSpans", &|o| json!({
                "name": text(o, "name"),
                "duration": duration(num_of(o, "durationMs")),
            })),
        })
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let state: Map = [
            ("processes".to_owned(), self.processes_state()),
            ("history".to_owned(), self.history_state()),
            ("traces".to_owned(), self.traces_state()),
            (
                "logs".to_owned(),
                json!({
                    "available": !self.logs_path(engine).is_empty(),
                    "error": nullable(&self.logs_error),
                }),
            ),
        ]
        .into_iter()
        .collect();
        self.bridge
            .publish(engine, "diagnostics", Json::Object(state));
    }
}

fn toast_error(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.error(engine, title, description);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_read_as_the_page_formats_them() {
        assert_eq!(count(1234567.0), "1,234,567");
        assert_eq!(count(12.0), "12");
        assert_eq!(duration(512.4), "512 ms");
        assert_eq!(duration(2500.0), "2.50 s");
        assert_eq!(duration(12_340.0), "12.3 s");
        assert_eq!(bytes(512.0), "512 B");
        assert_eq!(bytes(1536.0), "1.50 KB");
        assert_eq!(bytes(5.0 * 1024.0 * 1024.0 * 1024.0), "5.00 GB");
        assert_eq!(bytes(5000.0 * 1024.0 * 1024.0 * 1024.0), "5000.0 GB");
        assert_eq!(cpu_time(5.0), "5.00s");
        assert_eq!(cpu_time(90.0), "1.50m");
        assert_eq!(cpu_time(7200.0), "2.00h");
        assert_eq!(percent(12.345), "12.3%");
    }

    #[test]
    fn a_process_is_named_typed_and_grouped_by_its_command() {
        assert_eq!(process_name("\"/usr/bin/claude\" --x"), "claude");
        assert_eq!(process_name("C:\\bin\\node.exe a"), "node.exe");
        assert_eq!(process_name("  "), "  ");
        assert_eq!(process_type(&json!({"command": "/bin/Codex run"})), "Agent");
        assert_eq!(process_type(&json!({"command": "codexish"})), "Process");
        assert_eq!(
            process_type(&json!({"command": "claude", "depth": 1})),
            "Subprocess"
        );
        assert_eq!(
            process_group(&json!({"command": "/bin/zsh -l"})),
            "terminal"
        );
        assert_eq!(
            process_group(&json!({"command": "claude-code x"})),
            "provider"
        );
        assert_eq!(process_group(&json!({"command": "claudette"})), "server");
        assert_eq!(
            process_group(&json!({"category": "provider-root"})),
            "provider"
        );
        assert_eq!(
            process_group(&json!({"category": "other", "command": "zsh"})),
            "server"
        );
    }
}
