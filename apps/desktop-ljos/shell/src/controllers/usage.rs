//! `usage`, desktop-qt's UsageController: the usage page, which the shell
//! owns (the route `usage`): token use and estimated cost from each
//! environment's session history, and how much of each provider's rate
//! limits is left. The prices that cost is estimated with are
//! [`usage_prices`](super::usage_prices)'.
//!
//! Usage: every chosen environment is asked for `server.getUsageSummary` over
//! the window, and the answers merge: the newest read owns a transcript
//! directory several environments share, an environment keeps only the
//! providers whose directories it owns, and one on an older contract is left
//! out and named. An environment still scanning does not hold back the
//! others.
//!
//! Limits: no call of their own. While limits show, each chosen
//! environment's `config` shape brings its providers' `usageLimits`, and
//! `server.refreshProviders` asks for them afresh: on showing, at most every
//! five minutes per environment, or whenever the user refreshes. The same
//! shape's `config.usageLimitSources` brings the accounts of its hubs.
//! Accounts of one driver pool per window.
//!
//! Publishes `usage`: {open, metric: cost | tokens | limits, windowDays: 1 |
//! 7 | 30 | 90, windowLabel, environmentId ("" for all), environments [{id,
//! label, status: scanning | ready | failed | outdated | offline}], scanning,
//! refreshing, notices [text], message (why there is nothing to show, or ""),
//! summary {costUsd, totalTokens, sessions, unpricedShare, cacheSavingsUsd,
//! cachedInputTokens, uncachedInputTokens, cacheCreationTokens, outputTokens,
//! providers [{id, label, costUsd, totalTokens, sessions}], models
//! [{provider, model, costUsd, totalTokens, unpriced}], periods [{key, label,
//! costUsd, totalTokens}] newest first, chart [{key, label, heading, costUsd
//! [one per provider], totalTokens [one per provider]}] every period of the
//! window, oldest first} | null, limits {pools [{driver, label, windows [{key,
//! label, remainingPercent, resetsAt, accounts [{name, usedPercent,
//! resetsAt}]}], credits [{key, name, available, nextExpiresAt, busy,
//! status}]}], notices [text]} ({} unless limits show)}.
//!
//! Actions: `usage.metric {metric}` and `usage.window {days}` (kept on this
//! device), `usage.environment {id}`, `usage.refresh`, and `usage.resetCredit
//! {key}`, which spends one of the account's banked reset credits. The
//! palette's "usage.refresh" opens the page first. `usage.open` is
//! Navigation's.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;

use chrono::{
    DateTime, Duration, FixedOffset, Local, NaiveDate, SecondsFormat, TimeZone as _, Utc,
};
use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me, Window};
use crate::controllers::navigation::{Navigation, Route, at_kind};
use crate::controllers::settings::Settings;
use crate::controllers::usage_prices::{Environment, environments_of};
use crate::json::Json;
use crate::keybindings as keymap;
use crate::mc::{Mc, McError, SubId};
use crate::store;

const KEY: &str = "usage";
/// Where the metric and window are kept on this device.
const PREFERENCES: &str = "usage";
const METRICS: [&str; 3] = ["cost", "tokens", "limits"];
const WINDOWS: [i64; 4] = [1, 7, 30, 90];
/// Limits are asked for afresh at most this often, unless the user asks.
const LIMITS_THROTTLE_SECS: i64 = 5 * 60;
/// The contract versions whose summaries merge.
const CONTRACT_SINCE: i64 = 4;
const CONTRACT: i64 = 5;

/// The providers usage reports, in the order the page lists them.
const USAGE_PROVIDERS: [(&str, &str); 3] = [
    ("codex", "Codex"),
    ("claude", "Claude Code"),
    ("grok", "Grok Build"),
];
const DRIVER_LABELS: [(&str, &str); 5] = [
    ("codex", "Codex"),
    ("claudeAgent", "Claude Code"),
    ("grok", "Grok Build"),
    ("cursor", "Cursor"),
    ("opencode", "OpenCode"),
];
const WINDOW_KINDS: [&str; 3] = ["session", "weekly", "monthly"];

fn driver_label(driver: &str) -> Option<&'static str> {
    DRIVER_LABELS
        .iter()
        .find(|(d, _)| *d == driver)
        .map(|(_, l)| *l)
}

/// The zone the window's days and the labels of its hours are read in.
#[derive(Clone)]
pub struct Zone {
    id: String,
    offset: Rc<dyn Fn(DateTime<Utc>) -> FixedOffset>,
    /// The machine's: the platform names it.
    local: bool,
}

impl Zone {
    /// This machine's, as the MC is told its name (`timeZone`).
    pub fn system() -> Zone {
        Zone {
            id: iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".into()),
            offset: Rc::new(|at| Local.offset_from_utc_datetime(&at.naive_utc())),
            local: true,
        }
    }

    /// A zone named `id` that is `seconds` east of UTC all year.
    pub fn fixed(id: &str, seconds: i32) -> Zone {
        let offset = FixedOffset::east_opt(seconds).unwrap_or(FixedOffset::east_opt(0).unwrap());
        Zone {
            id: id.to_owned(),
            offset: Rc::new(move |_| offset),
            local: false,
        }
    }

    /// A zone whose offset changes: `offset` says what it is at an instant.
    pub fn changing(id: &str, offset: impl Fn(DateTime<Utc>) -> FixedOffset + 'static) -> Zone {
        Zone {
            id: id.to_owned(),
            offset: Rc::new(offset),
            local: false,
        }
    }

    /// QDateTime::timeZoneAbbreviation at `instant`: the machine's zone as
    /// the zone database names it ("PST", "PDT"), another by its offset.
    pub fn abbreviation(&self, instant: DateTime<Utc>) -> String {
        if self.local {
            let names = ljos::locale::Locale::named("en_US").zone_names(instant.timestamp_millis());
            return names.abbreviation;
        }
        self.at(instant).offset().to_string()
    }

    fn at(&self, instant: DateTime<Utc>) -> DateTime<FixedOffset> {
        instant.with_timezone(&(self.offset)(instant))
    }
}

type Clock = Rc<dyn Fn() -> DateTime<Utc>>;

fn text(object: &Json, field: &str) -> String {
    object
        .get(field)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn number(object: &Json, field: &str) -> f64 {
    object.get(field).and_then(Json::as_f64).unwrap_or(0.0)
}

fn array(object: &Json, field: &str) -> Vec<Json> {
    object
        .get(field)
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

/// The object under `field`; null (which reads as empty) otherwise.
fn object(value: &Json, field: &str) -> Json {
    match value.get(field) {
        Some(o @ Json::Object(_)) => o.clone(),
        _ => Json::Null,
    }
}

fn empty(value: &Json) -> bool {
    value.as_object().is_none_or(Map::is_empty)
}

fn instant(text: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn day_of(text: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(text, "%Y-%m-%d").ok()
}

fn day_text(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

fn compatible(summary: &Json) -> bool {
    let version = summary
        .get("contractVersion")
        .and_then(Json::as_i64)
        .unwrap_or(0);
    (CONTRACT_SINCE..=CONTRACT).contains(&version)
}

fn fingerprint(source: &Json) -> String {
    let print = object(source, "fingerprint");
    [
        text(&print, "hostId"),
        text(&print, "provider"),
        text(&print, "resolvedHomePath"),
        text(&print, "volumeId"),
    ]
    .join(" ")
}

/// reasoningTokens are a part of outputTokens.
fn tokens(totals: &Json) -> f64 {
    number(totals, "uncachedInputTokens")
        + number(totals, "cachedInputTokens")
        + number(totals, "cacheCreationTokens")
        + number(totals, "outputTokens")
}

/// Which period of `window` a bucket falls in, counted from its first; -1 for
/// none.
fn place_of(bucket: &Json, window: &Json, hourly: bool) -> i64 {
    if hourly {
        let since = instant(&text(window, "sinceTime"));
        let hour = instant(&text(bucket, "hourStart"));
        return match (since, hour) {
            (Some(since), Some(hour)) if hour >= since => (hour - since).num_seconds() / (60 * 60),
            _ => -1,
        };
    }
    match (
        day_of(&text(window, "sinceDay")),
        day_of(&text(bucket, "day")),
    ) {
        (Some(since), Some(day)) if day >= since => (day - since).num_days(),
        _ => -1,
    }
}

/// `2 PM` in `zone`. An hour the clocks repeat when they fall back says its
/// zone too.
fn hour_name(at: DateTime<Utc>, zone: &Zone) -> String {
    let local = zone.at(at);
    let name = local.format("%-I %p").to_string();
    for away in [-60 * 60, 60 * 60] {
        let other = zone.at(at + Duration::seconds(away));
        if other.date_naive() == local.date_naive()
            && other.format("%H").to_string() == local.format("%H").to_string()
        {
            return format!("{name} {}", zone.abbreviation(at));
        }
    }
    name
}

fn month_day(day: NaiveDate) -> String {
    day.format("%b %-d").to_string()
}

fn month_day_hour(at: DateTime<FixedOffset>) -> String {
    at.format("%b %-d, %-I %p").to_string()
}

fn kind_rank(kind: &str) -> usize {
    WINDOW_KINDS
        .iter()
        .position(|k| *k == kind)
        .unwrap_or(WINDOW_KINDS.len())
}

#[derive(Clone, Default)]
struct Answer {
    /// scanning, ready, failed, offline
    status: String,
    summary: Json,
    /// What the summary was asked over.
    window: Json,
}

/// Where an account's reset credit is spent: `provider.consumeResetCredit`'s
/// input.
#[derive(Clone, Default)]
struct Redeem {
    environment_id: String,
    input: Json,
}

#[derive(Clone, Default)]
struct Sum {
    cost: f64,
    tokens: f64,
    sessions: f64,
    records: f64,
    unpriced: f64,
}

impl Sum {
    fn add(&mut self, cost: f64, tokens: f64, records: f64, unpriced: f64) {
        self.cost += cost;
        self.tokens += tokens;
        self.records += records;
        self.unpriced += unpriced;
    }
}

#[derive(Clone)]
struct Account {
    driver: String,
    name: String,
    checked_at: String,
    windows: Vec<Json>,
    /// The freshest read that knew the reset credits, and where to redeem
    /// them.
    credits_at: String,
    credits: Json,
    redeem: Redeem,
    /// Redeeming through a hub also clears the cooldown it holds for the
    /// account, so the freshest hub target wins the redemption outright.
    hub_at: String,
    hub_redeem: Redeem,
}

pub struct Usage {
    bridge: Bridge,
    me: Me<Usage>,
    mc: Rc<dyn Mc>,
    clock: Clock,
    zone: Zone,
    active: bool,
    open: bool,
    metric: String,
    window_days: i64,
    environment: String,
    answers: HashMap<String, Answer>,
    /// Bumped by every read; an answer lands only if nothing was asked since.
    generation: u64,
    refreshing: i32,
    /// Each followed environment's `config` shape, and its providers.
    configs: HashMap<String, SubId>,
    providers: HashMap<String, Vec<Json>>,
    /// And its usage-limit sources (hubs): `config.usageLimitSources`.
    sources: HashMap<String, Vec<Json>>,
    /// When each environment's limits were last asked for, and those in
    /// flight.
    limits_asked: HashMap<String, DateTime<Utc>>,
    limits_in_flight: HashSet<String>,
    /// Reset credits: each shown account's redemption target, those being
    /// spent, and what the last spend said. Bumped on every opening.
    redeems: HashMap<String, Redeem>,
    redeeming: HashSet<String>,
    redeem_status: HashMap<String, String>,
    openings: u64,
}

impl Controller for Usage {
    fn new(init: Init<'_, Self>) -> Self {
        Usage {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            clock: Rc::new(Utc::now),
            zone: Zone::system(),
            active: false,
            open: false,
            metric: "limits".into(),
            window_days: 30,
            environment: String::new(),
            answers: HashMap::new(),
            generation: 0,
            refreshing: 0,
            configs: HashMap::new(),
            providers: HashMap::new(),
            sources: HashMap::new(),
            limits_asked: HashMap::new(),
            limits_in_flight: HashSet::new(),
            redeems: HashMap::new(),
            redeeming: HashSet::new(),
            redeem_status: HashMap::new(),
            openings: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let kept = Settings::of(engine)
            .device_value(PREFERENCES)
            .unwrap_or(Json::Null);
        if let Some(metric) = kept.get("metric").and_then(Json::as_str)
            && METRICS.contains(&metric)
        {
            self.metric = metric.to_owned();
        }
        if let Some(days) = kept.get("windowDays").and_then(Json::as_i64)
            && WINDOWS.contains(&days)
        {
            self.window_days = days;
        }
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_kind(route, "usage");
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        // An environment that comes, goes, or drops changes who is asked.
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, _| {
            me.run(engine, |c, engine| {
                if c.open {
                    c.update(engine);
                }
            });
        }));
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                if c.open {
                    c.update(engine);
                }
            });
        });
        let route = self.bridge.published(engine, "route");
        self.set_open(engine, route.is_some_and(|r| at_kind(&r, "usage")));
        self.publish(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &Window) {
        // usage.open is Navigation's, with the other pages the palette offers.
        Commands::of(engine).add(
            engine,
            "usage.refresh",
            &keymap::command_label("usage.refresh"),
            |engine| {
                let bridge = Bridge::of(engine);
                if !bridge
                    .published(engine, "route")
                    .is_some_and(|r| at_kind(&r, "usage"))
                {
                    controller::with::<Navigation, _>(engine, |n, engine| {
                        n.open(engine, Route::Usage)
                    });
                }
                bridge.dispatch(engine, "usage.refresh", Json::Null);
            },
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("usage.") || action == "usage.open" {
            return false;
        }
        match action {
            "usage.metric" => {
                let metric = text(payload, "metric");
                if !METRICS.contains(&metric.as_str()) || metric == self.metric {
                    return true;
                }
                let from_limits = self.metric == "limits";
                self.metric = metric;
                self.keep(engine);
                // Usage is not read while limits show; what was read before
                // may be old.
                if self.open && from_limits {
                    self.read(engine, false);
                }
                if self.open {
                    self.update(engine);
                }
                self.publish(engine);
            }
            "usage.window" => {
                let days = payload.get("days").and_then(Json::as_i64).unwrap_or(0);
                if !WINDOWS.contains(&days) || days == self.window_days {
                    return true;
                }
                self.window_days = days;
                // The last window's numbers are not this one's.
                self.answers.clear();
                self.keep(engine);
                if self.open {
                    self.update(engine);
                }
                self.publish(engine);
            }
            "usage.environment" => {
                let id = text(payload, "id");
                if !id.is_empty() && !self.environments(engine).contains(&id) {
                    return true;
                }
                self.environment = id;
                if self.open {
                    self.update(engine);
                }
                self.publish(engine);
            }
            "usage.refresh" => {
                if !self.open || self.refreshing > 0 {
                    return true;
                }
                if self.metric == "limits" {
                    self.refresh_limits(engine, true);
                } else {
                    self.read(engine, true);
                }
            }
            "usage.resetCredit" => {
                if self.open {
                    self.redeem(engine, &text(payload, "key"));
                }
            }
            _ => return false,
        }
        true
    }
}

impl Usage {
    /// Reads the time from `clock` instead of the system's.
    pub fn set_clock(&mut self, clock: impl Fn() -> DateTime<Utc> + 'static) {
        self.clock = Rc::new(clock);
    }

    /// Reads the window's days and the labels of its hours in `zone`.
    pub fn set_zone(&mut self, zone: Zone) {
        self.zone = zone;
    }

    fn known(&self, engine: &Engine) -> Vec<Environment> {
        environments_of(engine, self.mc.as_ref())
    }

    fn environments(&self, engine: &Engine) -> Vec<String> {
        self.known(engine).into_iter().map(|e| e.id).collect()
    }

    fn online(&self, engine: &Engine, id: &str) -> bool {
        self.known(engine).iter().any(|e| e.id == id && e.online)
    }

    fn label(&self, engine: &Engine, id: &str) -> String {
        let label = self
            .known(engine)
            .into_iter()
            .find(|e| e.id == id)
            .map(|e| e.label)
            .unwrap_or_default();
        if label.is_empty() {
            id.to_owned()
        } else {
            label
        }
    }

    fn keep(&self, engine: &Engine) {
        Settings::of(engine).write_device(
            engine,
            PREFERENCES,
            json!({"metric": self.metric, "windowDays": self.window_days}),
        );
    }

    /// Open, the page reads and follows what it shows; closed, nothing is
    /// read or followed for a page nobody sees.
    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        if !open {
            self.generation += 1;
            self.openings += 1;
            self.redeem_status.clear();
            self.unfollow();
            self.publish(engine);
            return;
        }
        if self.metric != "limits" {
            self.read(engine, false);
        }
        self.update(engine);
    }

    /// Asks whoever is not yet asked: limits are followed while they show;
    /// usage is read again for environments that came, went, or came back.
    fn update(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        if !self.environment.is_empty() && !self.environments(engine).contains(&self.environment) {
            self.environment.clear();
        }
        if self.metric == "limits" {
            self.follow(engine);
            self.refresh_limits(engine, false);
        } else {
            self.unfollow();
            let mut asked: Vec<String> = self.answers.keys().cloned().collect();
            let mut wanted = self.targets(engine);
            asked.sort();
            wanted.sort();
            let mut changed = asked != wanted;
            for id in &wanted {
                let offline = self.answers.get(id).is_some_and(|a| a.status == "offline");
                if offline == self.online(engine, id) {
                    changed = true;
                }
            }
            if changed {
                self.read(engine, false);
            }
        }
        self.publish(engine);
    }

    fn targets(&self, engine: &Engine) -> Vec<String> {
        self.environments(engine)
            .into_iter()
            .filter(|id| self.environment.is_empty() || *id == self.environment)
            .collect()
    }

    /// The window drawn: whole local days ending today, or the past 24 hours
    /// to the minute, bucketed by hour.
    fn window(&self) -> Json {
        let now = (self.clock)();
        let mut window = Map::new();
        window.insert("timeZone".into(), self.zone.id.clone().into());
        if self.window_days == 1 {
            let until = Utc
                .timestamp_opt(now.timestamp() - now.timestamp().rem_euclid(60), 0)
                .single()
                .unwrap_or(now);
            let since = until - Duration::hours(24);
            window.insert("resolution".into(), "hour".into());
            window.insert("sinceTime".into(), iso(since).into());
            window.insert("untilTime".into(), iso(until).into());
            window.insert(
                "sinceDay".into(),
                day_text(self.zone.at(since).date_naive()).into(),
            );
            window.insert(
                "untilDay".into(),
                day_text(self.zone.at(until).date_naive()).into(),
            );
            return Json::Object(window);
        }
        let today = self.zone.at(now).date_naive();
        window.insert("resolution".into(), "day".into());
        window.insert(
            "sinceDay".into(),
            day_text(today - Duration::days(self.window_days - 1)).into(),
        );
        window.insert("untilDay".into(), day_text(today).into());
        Json::Object(window)
    }

    /// Every chosen environment is asked for its summary; `rescan` fetches
    /// prices first, as the user's refresh does. The last numbers stay until
    /// new ones land.
    fn read(&mut self, engine: &Engine, rescan: bool) {
        if !self.open {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        let mut answers = HashMap::new();
        for id in self.targets(engine) {
            let mut answer = self.answers.get(&id).cloned().unwrap_or_default();
            if !self.online(engine, &id) {
                answer = Answer {
                    status: "offline".into(),
                    ..Answer::default()
                };
            } else {
                answer.status = "scanning".into();
            }
            answers.insert(id, answer);
        }
        self.answers = answers;
        let input = self.window();
        let mut scanning: Vec<String> = self
            .answers
            .iter()
            .filter(|(_, a)| a.status == "scanning")
            .map(|(id, _)| id.clone())
            .collect();
        scanning.sort();
        for id in scanning {
            if !rescan {
                self.summarize(engine, generation, &id, &input, rescan);
                continue;
            }
            self.refreshing += 1;
            // New prices or not, the history is read again.
            let me = self.me.clone();
            let input = input.clone();
            let environment = id.clone();
            self.mc.call(
                &id,
                "server.refreshUsageRates",
                json!({}),
                Box::new(move |engine, _| {
                    me.run(engine, |c, engine| {
                        c.summarize(engine, generation, &environment, &input, rescan);
                    });
                }),
            );
        }
        self.publish(engine);
    }

    fn summarize(
        &mut self,
        engine: &Engine,
        generation: u64,
        environment: &str,
        input: &Json,
        rescan: bool,
    ) {
        if generation != self.generation {
            if rescan {
                self.refreshing -= 1;
            }
            self.publish(engine);
            return;
        }
        let me = self.me.clone();
        let (environment_id, input) = (environment.to_owned(), input.clone());
        self.mc.call(
            environment,
            "server.getUsageSummary",
            input.clone(),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    if rescan {
                        c.refreshing -= 1;
                    }
                    if generation != c.generation || !c.answers.contains_key(&environment_id) {
                        c.publish(engine);
                        return;
                    }
                    let answer = match result {
                        Err(_) => Answer {
                            status: "failed".into(),
                            ..Answer::default()
                        },
                        Ok(summary) => Answer {
                            status: "ready".into(),
                            summary: if summary.is_object() {
                                summary
                            } else {
                                Json::Null
                            },
                            window: input,
                        },
                    };
                    c.answers.insert(environment_id, answer);
                    c.publish(engine);
                });
            }),
        );
    }

    /// Each chosen environment re-reads its providers' limits; the answers
    /// come as `config.providers`. Unless the user asked, not within five
    /// minutes of the last.
    fn refresh_limits(&mut self, engine: &Engine, manual: bool) {
        let now = (self.clock)();
        for id in self.targets(engine) {
            if !self.online(engine, &id) || self.limits_in_flight.contains(&id) {
                continue;
            }
            if !manual
                && self
                    .limits_asked
                    .get(&id)
                    .is_some_and(|asked| (now - *asked).num_seconds() < LIMITS_THROTTLE_SECS)
            {
                continue;
            }
            self.limits_asked.insert(id.clone(), now);
            self.limits_in_flight.insert(id.clone());
            self.refreshing += 1;
            let me = self.me.clone();
            let environment = id.clone();
            self.mc.call(
                &id,
                "server.refreshProviders",
                json!({}),
                Box::new(move |engine, result: Result<Json, McError>| {
                    me.run(engine, |c, engine| {
                        c.limits_in_flight.remove(&environment);
                        c.refreshing -= 1;
                        if let Ok(result) = result
                            && let Some(providers) =
                                result.get("providers").and_then(Json::as_array)
                            && c.configs.contains_key(&environment)
                        {
                            c.providers.insert(environment, providers.clone());
                        }
                        c.publish(engine);
                    });
                }),
            );
        }
        self.publish(engine);
    }

    /// While limits show, each chosen environment's config says what its
    /// providers have left.
    fn follow(&mut self, engine: &Engine) {
        let environments: Vec<String> = self
            .targets(engine)
            .into_iter()
            .filter(|id| self.online(engine, id))
            .collect();
        let gone: Vec<String> = self
            .configs
            .keys()
            .filter(|id| !environments.contains(id))
            .cloned()
            .collect();
        for id in gone {
            if let Some(sub) = self.configs.remove(&id) {
                self.mc.unsubscribe(sub);
            }
            self.providers.remove(&id);
            self.sources.remove(&id);
        }
        for id in environments {
            if self.configs.contains_key(&id) {
                continue;
            }
            let shape = json!({"type": "config", "environment": id});
            let me = self.me.clone();
            let environment = id.clone();
            let sub = self.mc.subscribe(
                shape,
                Box::new(move |engine, frame| {
                    let frame = Json::Object(frame.clone());
                    me.run(engine, |c, engine| {
                        c.on_config(engine, &environment, &frame)
                    });
                }),
                None,
            );
            self.configs.insert(id, sub);
        }
    }

    fn on_config(&mut self, engine: &Engine, environment: &str, frame: &Json) {
        match text(frame, "t").as_str() {
            "config" => {
                let providers = array(&object(frame, "config"), "providers");
                self.providers.insert(environment.to_owned(), providers);
            }
            "config.providers" => {
                let providers = array(frame, "providers");
                self.providers.insert(environment.to_owned(), providers);
            }
            "config.usageLimitSources" => {
                let sources = array(frame, "sources");
                self.sources.insert(environment.to_owned(), sources);
            }
            _ => return,
        }
        self.publish(engine);
    }

    fn unfollow(&mut self) {
        for (_, sub) in self.configs.drain() {
            self.mc.unsubscribe(sub);
        }
        self.providers.clear();
        self.sources.clear();
    }

    /// The chosen environments' summaries merged, or null while none has
    /// answered. What was left out is said in `notices`.
    fn summary(&self, engine: &Engine, notices: &mut Vec<String>) -> Json {
        struct Contribution {
            id: String,
            summary: Json,
            window: Json,
        }
        let mut current: Vec<Contribution> = Vec::new();
        let mut ids: Vec<&String> = self.answers.keys().collect();
        ids.sort();
        let several = ids.len() > 1;
        for id in ids {
            let answer = &self.answers[id];
            if answer.status == "failed" || answer.status == "offline" {
                notices.push(if several {
                    format!("{} could not report usage.", self.label(engine, id))
                } else {
                    "This environment could not report usage.".into()
                });
                continue;
            }
            if empty(&answer.summary) {
                continue;
            }
            if !compatible(&answer.summary) {
                notices.push(format!(
                    "{} runs an older server version and is excluded from totals.",
                    self.label(engine, id)
                ));
                continue;
            }
            current.push(Contribution {
                id: id.clone(),
                summary: answer.summary.clone(),
                window: answer.window.clone(),
            });
        }
        if current.is_empty() {
            return Json::Null;
        }

        // The newest read owns each transcript directory; ties go to the
        // lower id.
        current.sort_by(|a, b| {
            let left = instant(&text(&a.summary, "readAt"));
            let right = instant(&text(&b.summary, "readAt"));
            right.cmp(&left).then_with(|| a.id.cmp(&b.id))
        });
        let mut owners: HashMap<String, String> = HashMap::new();
        let mut duplicates: Vec<String> = Vec::new();
        for contribution in &current {
            for source in array(&contribution.summary, "sources") {
                if text(&source, "status") == "missing" {
                    continue;
                }
                let key = fingerprint(&source);
                if owners.contains_key(&key) {
                    duplicates.push(format!(
                        "{}: {}",
                        self.label(engine, &contribution.id),
                        text(&object(&source, "fingerprint"), "resolvedHomePath")
                    ));
                    continue;
                }
                owners.insert(key, contribution.id.clone());
            }
        }
        if !duplicates.is_empty() {
            notices.push(format!(
                "Counted once across environments sharing a transcript directory: {}",
                duplicates.join(", ")
            ));
        }

        let mut total = Sum::default();
        let (mut cache_savings, mut cached, mut uncached, mut creation, mut output) =
            (0.0, 0.0, 0.0, 0.0, 0.0);
        let mut providers: HashMap<String, Sum> = HashMap::new();
        let mut models: BTreeMap<(String, String), Sum> = BTreeMap::new();
        let mut periods: BTreeMap<String, Sum> = BTreeMap::new();
        // Each provider's part of each period, which the chart draws. A
        // period is counted from the start of the window its summary was
        // asked over: while a read is in flight that environment still shows
        // its last answer, asked over an earlier window, and keeps its place
        // on the chart.
        let mut parts: HashMap<i64, HashMap<String, Sum>> = HashMap::new();
        let hourly = self.window_days == 1;
        for contribution in &current {
            let mut owned: HashSet<String> = HashSet::new();
            for source in array(&contribution.summary, "sources") {
                if text(&source, "status") == "missing"
                    || owners.get(&fingerprint(&source)) != Some(&contribution.id)
                {
                    continue;
                }
                let provider = text(&object(&source, "fingerprint"), "provider");
                // Distinct within a directory; buckets would count a
                // session once a day.
                let sessions = number(&source, "distinctSessions");
                providers.entry(provider.clone()).or_default().sessions += sessions;
                owned.insert(provider);
                total.sessions += sessions;
            }
            for bucket in array(&contribution.summary, "buckets") {
                let provider = text(&bucket, "provider");
                if !owned.contains(&provider) {
                    continue;
                }
                let totals = object(&bucket, "totals");
                let cost = number(&bucket, "costUsd");
                let used = tokens(&totals);
                let records = number(&bucket, "records");
                let unpriced = number(&bucket, "unpricedRecords");
                let period = if hourly {
                    text(&bucket, "hourStart")
                } else {
                    text(&bucket, "day")
                };
                total.add(cost, used, records, unpriced);
                providers
                    .entry(provider.clone())
                    .or_default()
                    .add(cost, used, records, unpriced);
                models
                    .entry((provider.clone(), text(&bucket, "model")))
                    .or_default()
                    .add(cost, used, records, unpriced);
                periods
                    .entry(period)
                    .or_default()
                    .add(cost, used, records, unpriced);
                parts
                    .entry(place_of(&bucket, &contribution.window, hourly))
                    .or_default()
                    .entry(provider)
                    .or_default()
                    .add(cost, used, records, unpriced);
                cache_savings += number(&bucket, "cacheSavingsUsd");
                cached += number(&totals, "cachedInputTokens");
                uncached += number(&totals, "uncachedInputTokens");
                creation += number(&totals, "cacheCreationTokens");
                output += number(&totals, "outputTokens");
            }
        }

        let mut provider_rows = Vec::new();
        let mut listed: Vec<&str> = Vec::new();
        for (id, name) in USAGE_PROVIDERS {
            let sum = providers.get(id).cloned().unwrap_or_default();
            if sum.tokens <= 0.0 && sum.cost <= 0.0 {
                continue;
            }
            listed.push(id);
            provider_rows.push(json!({
                "id": id,
                "label": name,
                "costUsd": sum.cost,
                "totalTokens": sum.tokens,
                "sessions": sum.sessions,
            }));
        }
        let mut model_list: Vec<((String, String), Sum)> = models.into_iter().collect();
        let by_tokens = self.metric == "tokens";
        model_list.sort_by(|(_, a), (_, b)| {
            if by_tokens {
                return b.tokens.total_cmp(&a.tokens);
            }
            if a.cost != b.cost {
                return b.cost.total_cmp(&a.cost);
            }
            b.tokens.total_cmp(&a.tokens)
        });
        let model_rows: Vec<Json> = model_list
            .iter()
            .map(|((provider, model), sum)| {
                json!({
                    "provider": provider,
                    "model": model,
                    "costUsd": sum.cost,
                    "totalTokens": sum.tokens,
                    "unpriced": sum.records > 0.0 && sum.unpriced >= sum.records,
                })
            })
            .collect();
        let zone = &self.zone;
        let name = |period: &str| -> String {
            if hourly {
                instant(period)
                    .map(|at| hour_name(at, zone))
                    .unwrap_or_default()
            } else {
                day_of(period).map(month_day).unwrap_or_default()
            }
        };
        let period_rows: Vec<Json> = periods
            .iter()
            .rev()
            .map(|(key, sum)| {
                json!({
                    "key": key,
                    "label": name(key),
                    "costUsd": sum.cost,
                    "totalTokens": sum.tokens,
                })
            })
            .collect();

        // The chart: every period of the window the newest read was asked
        // over, the quiet ones too, with each listed provider's part of it.
        let window = &current[0].window;
        let mut charted: Vec<String> = Vec::new();
        if hourly {
            if let (Some(since), Some(until)) = (
                instant(&text(window, "sinceTime")),
                instant(&text(window, "untilTime")),
            ) {
                let mut hour = since;
                while hour < until {
                    charted.push(iso(hour));
                    hour += Duration::hours(1);
                }
            }
        } else if let (Some(since), Some(until)) = (
            day_of(&text(window, "sinceDay")),
            day_of(&text(window, "untilDay")),
        ) {
            let mut day = since;
            while day <= until {
                charted.push(day_text(day));
                day += Duration::days(1);
            }
        }
        // An hour is read out against the day the window ends on
        // (formatRelativeHourShort).
        let today = instant(&text(window, "untilTime")).map(|at| zone.at(at).date_naive());
        let mut chart_rows = Vec::new();
        for (place, period) in charted.iter().enumerate() {
            let part = parts.get(&(place as i64));
            let part_of = |id: &str| part.and_then(|p| p.get(id)).cloned().unwrap_or_default();
            let cost: Vec<f64> = listed.iter().map(|id| part_of(id).cost).collect();
            let used: Vec<f64> = listed.iter().map(|id| part_of(id).tokens).collect();
            let label = name(period);
            let mut heading = label.clone();
            if hourly && let (Some(hour), Some(today)) = (instant(period), today) {
                let hour = zone.at(hour);
                heading = match (today - hour.date_naive()).num_days() {
                    0 => format!("{label} today"),
                    1 => format!("{label} yesterday"),
                    _ => month_day_hour(hour),
                };
            }
            chart_rows.push(json!({
                "key": period,
                "label": label,
                "heading": heading,
                "costUsd": cost,
                "totalTokens": used,
            }));
        }
        json!({
            "costUsd": total.cost,
            "totalTokens": total.tokens,
            "sessions": total.sessions,
            "unpricedShare": if total.records > 0.0 { total.unpriced / total.records } else { 0.0 },
            "cacheSavingsUsd": cache_savings,
            "cachedInputTokens": cached,
            "uncachedInputTokens": uncached,
            "cacheCreationTokens": creation,
            "outputTokens": output,
            "providers": provider_rows,
            "models": model_rows,
            "periods": period_rows,
            "chart": chart_rows,
        })
    }

    /// The followed environments' accounts, one per driver and email with the
    /// freshest read winning, pooled per driver and window. Remembers where
    /// each account's banked reset credit is redeemed.
    fn limits(&mut self, engine: &Engine) -> Json {
        let mut order: Vec<String> = Vec::new();
        let mut accounts: HashMap<String, Account> = HashMap::new();
        let mut notices: Vec<String> = Vec::new();
        let mut ids: Vec<String> = self.providers.keys().cloned().collect();
        for id in self.sources.keys() {
            if !ids.contains(id) {
                ids.push(id.clone());
            }
        }
        ids.sort();
        let several = self.environments(engine).len() > 1;
        let later = |a: &str, b: &str| instant(a) > instant(b);
        let mut merge = |key: String, next: Account| {
            let Some(known) = accounts.get_mut(&key) else {
                order.push(key.clone());
                accounts.insert(key, next);
                return;
            };
            if later(&next.checked_at, &known.checked_at) {
                known.checked_at = next.checked_at.clone();
                known.windows = next.windows.clone();
            }
            // Credits and their redemption target travel together.
            if !empty(&next.credits)
                && (empty(&known.credits) || later(&next.credits_at, &known.credits_at))
            {
                known.credits = next.credits.clone();
                known.credits_at = next.credits_at.clone();
                known.redeem = next.redeem.clone();
            }
            if !next.hub_redeem.environment_id.is_empty()
                && (known.hub_at.is_empty() || later(&next.hub_at, &known.hub_at))
            {
                known.hub_at = next.hub_at.clone();
                known.hub_redeem = next.hub_redeem.clone();
            }
        };
        for id in &ids {
            let prefix = if several {
                format!("{} · ", self.label(engine, id))
            } else {
                String::new()
            };
            for provider in self.providers.get(id).cloned().unwrap_or_default() {
                if !provider
                    .get("enabled")
                    .and_then(Json::as_bool)
                    .unwrap_or(true)
                    || !provider
                        .get("installed")
                        .and_then(Json::as_bool)
                        .unwrap_or(true)
                    || text(&provider, "availability") == "unavailable"
                    || provider.get("usageLimits").is_none()
                {
                    continue;
                }
                let limits = object(&provider, "usageLimits");
                let driver = text(&provider, "driver");
                let mut name = text(&provider, "displayName");
                if name.is_empty() {
                    name = driver_label(&driver)
                        .map(str::to_owned)
                        .unwrap_or_else(|| text(&provider, "instanceId"));
                }
                let unavailable = object(&limits, "unavailable");
                if !empty(&unavailable) {
                    if text(&unavailable, "reason") == "unsupported" {
                        continue;
                    }
                    let message = text(&unavailable, "message");
                    notices.push(format!(
                        "{prefix}{name}: {}",
                        if message.is_empty() {
                            "Could not read limits."
                        } else {
                            &message
                        }
                    ));
                    continue;
                }
                let windows = array(&limits, "windows");
                if windows.is_empty() {
                    notices.push(format!("{prefix}{name}: No limits reported."));
                    continue;
                }
                let email = text(&object(&provider, "auth"), "email").to_lowercase();
                let key = format!(
                    "{driver}:{}",
                    if email.is_empty() {
                        format!("{id}:{}", text(&provider, "instanceId"))
                    } else {
                        email
                    }
                );
                let checked_at = text(&limits, "checkedAt");
                merge(
                    key,
                    Account {
                        driver,
                        name,
                        checked_at: checked_at.clone(),
                        windows,
                        credits_at: checked_at,
                        credits: object(&limits, "resetCredits"),
                        redeem: Redeem {
                            environment_id: id.clone(),
                            input: json!({"instanceId": text(&provider, "instanceId")}),
                        },
                        hub_at: String::new(),
                        hub_redeem: Redeem::default(),
                    },
                );
            }
        }
        // Every hub account, those an environment also signs in to included:
        // the hub may hold the fresher read of the same subscription.
        for id in &ids {
            let prefix = if several {
                format!("{} · ", self.label(engine, id))
            } else {
                String::new()
            };
            for source in self.sources.get(id).cloned().unwrap_or_default() {
                let source_label = format!("{prefix}{}", text(&source, "label"));
                let source_accounts = array(&source, "accounts");
                if !text(&source, "error").is_empty() {
                    notices.push(format!("{source_label}: {}", text(&source, "error")));
                } else if source_accounts.is_empty() {
                    notices.push(format!("{source_label}: No accounts reported."));
                }
                for account in source_accounts {
                    let limits = object(&account, "usageLimits");
                    let windows = array(&limits, "windows");
                    if limits.get("unavailable").is_some() || windows.is_empty() {
                        continue;
                    }
                    let driver = text(&account, "driver");
                    let email = text(&account, "email").trim().to_lowercase();
                    let account_id = text(&account, "id");
                    let key = format!(
                        "{driver}:{}",
                        if email.is_empty() {
                            format!("{}:{account_id}", text(&source, "id"))
                        } else {
                            email.clone()
                        }
                    );
                    // A hub only names the account by its file when it has no
                    // address.
                    let mut name = account_id.clone();
                    if name.to_lowercase().ends_with(".json") {
                        name.truncate(name.len() - 5);
                    }
                    if !email.is_empty() {
                        name = source_label.clone();
                    }
                    let checked_at = text(&limits, "checkedAt");
                    let credits = object(&limits, "resetCredits");
                    let credit_id = text(&credits, "nextCreditId");
                    let redeem = if credit_id.is_empty() {
                        Redeem::default()
                    } else {
                        Redeem {
                            environment_id: id.clone(),
                            input: json!({
                                "sourceId": text(&source, "id"),
                                "accountId": account_id,
                                "creditId": credit_id,
                            }),
                        }
                    };
                    merge(
                        key,
                        Account {
                            driver,
                            name,
                            checked_at: checked_at.clone(),
                            windows,
                            credits_at: checked_at.clone(),
                            credits,
                            redeem: redeem.clone(),
                            hub_at: checked_at,
                            hub_redeem: redeem,
                        },
                    );
                }
            }
        }

        // Each account's session reset orders it within its pool, soonest
        // first.
        let session_reset = |account: &Account| {
            account
                .windows
                .iter()
                .filter(|w| text(w, "kind") == "session")
                .filter_map(|w| instant(&text(w, "resetsAt")))
                .min()
        };
        order.sort_by(
            |a, b| match (session_reset(&accounts[a]), session_reset(&accounts[b])) {
                (Some(left), Some(right)) => left.cmp(&right),
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (None, None) => Ordering::Equal,
            },
        );

        let mut drivers: Vec<String> = Vec::new();
        for key in &order {
            let driver = &accounts[key].driver;
            if !drivers.contains(driver) {
                drivers.push(driver.clone());
            }
        }
        // The drivers the page knows come first.
        drivers.sort_by_key(|d| usize::from(driver_label(d).is_none()));
        self.redeems.clear();
        let mut pools = Vec::new();
        for driver in &drivers {
            let mut window_keys: Vec<String> = Vec::new();
            let mut members: HashMap<String, Vec<Json>> = HashMap::new();
            let mut firsts: HashMap<String, Json> = HashMap::new();
            let mut credits = Vec::new();
            for key in &order {
                let account = &accounts[key];
                if account.driver != *driver {
                    continue;
                }
                for window in &account.windows {
                    let window_key = format!("{}:{}", text(window, "kind"), text(window, "id"));
                    if !window_keys.contains(&window_key) {
                        window_keys.push(window_key.clone());
                        firsts.insert(window_key.clone(), window.clone());
                    }
                    members.entry(window_key).or_default().push(json!({
                        "name": account.name,
                        "usedPercent": number(window, "usedPercent"),
                        "resetsAt": text(window, "resetsAt"),
                    }));
                }
                // Banked reset credits, and what came of the last redemption.
                let available = account
                    .credits
                    .get("availableCount")
                    .and_then(Json::as_i64)
                    .unwrap_or(0);
                let status = self.redeem_status.get(key).cloned().unwrap_or_default();
                if available == 0 && status.is_empty() && !self.redeeming.contains(key) {
                    continue;
                }
                let target = if account.hub_redeem.environment_id.is_empty() {
                    &account.redeem
                } else {
                    &account.hub_redeem
                };
                if !target.environment_id.is_empty() {
                    self.redeems.insert(key.clone(), target.clone());
                }
                credits.push(json!({
                    "key": key,
                    "name": account.name,
                    "available": available,
                    "nextExpiresAt": text(&account.credits, "nextExpiresAt"),
                    "busy": self.redeeming.contains(key),
                    "status": status,
                }));
            }
            window_keys.sort_by(|a, b| {
                let (left, right) = (&firsts[a], &firsts[b]);
                kind_rank(&text(left, "kind"))
                    .cmp(&kind_rank(&text(right, "kind")))
                    .then_with(|| text(left, "id").cmp(&text(right, "id")))
            });
            let mut windows = Vec::new();
            for window_key in &window_keys {
                let list = &members[window_key];
                let mut used = 0.0;
                let mut soonest: Option<(DateTime<Utc>, String)> = None;
                for member in list {
                    used += number(member, "usedPercent");
                    let at = text(member, "resetsAt");
                    if at.is_empty() {
                        continue;
                    }
                    let parsed = instant(&at);
                    // An unreadable time is first only when none is readable.
                    let sooner = match (&soonest, parsed) {
                        (None, _) => true,
                        (Some((known, _)), Some(parsed)) => parsed < *known,
                        _ => false,
                    };
                    if sooner && let Some(parsed) = parsed {
                        soonest = Some((parsed, at));
                    }
                }
                windows.push(json!({
                    "key": window_key,
                    "label": text(&firsts[window_key], "label"),
                    "remainingPercent": (100.0 - used / list.len() as f64).round() as i64,
                    "resetsAt": soonest.map(|(_, at)| at).unwrap_or_default(),
                    "accounts": list,
                }));
            }
            pools.push(json!({
                "driver": driver,
                "label": driver_label(driver)
                    .map(str::to_owned)
                    .unwrap_or_else(|| accounts[&order[0]].name.clone()),
                "windows": windows,
                "credits": credits,
            }));
        }
        json!({"pools": pools, "notices": notices})
    }

    /// Spends one banked reset credit of the account `key`, where its credits
    /// were read. What came of it stays beside the credits until the page
    /// closes.
    fn redeem(&mut self, engine: &Engine, key: &str) {
        let Some(target) = self.redeems.get(key).cloned() else {
            return;
        };
        if self.redeeming.contains(key) {
            return;
        }
        self.redeeming.insert(key.to_owned());
        self.redeem_status.remove(key);
        let session = self.openings;
        let me = self.me.clone();
        let key = key.to_owned();
        self.mc.call(
            &target.environment_id,
            "provider.consumeResetCredit",
            target.input,
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.redeeming.remove(&key);
                    if session != c.openings {
                        return;
                    }
                    let ok = result.is_ok();
                    let mut status = match &result {
                        Err(error) => error.message.clone(),
                        Ok(answer) => text(answer, "warning"),
                    };
                    if let Ok(answer) = &result
                        && status.is_empty()
                    {
                        status = match text(answer, "outcome").as_str() {
                            "reset" => "Reset applied. Your windows have cleared.",
                            "nothingToReset" => "Nothing to reset right now.",
                            "noCredit" => "No reset credit left.",
                            "alreadyRedeemed" => "That credit was already redeemed.",
                            _ => "",
                        }
                        .into();
                    }
                    if status.is_empty() {
                        status = "Could not use the reset credit.".into();
                    }
                    c.redeem_status.insert(key, status);
                    // The windows and the balance are read again.
                    if ok {
                        c.refresh_limits(engine, true);
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let limits_shown = self.metric == "limits";
        let chosen = self.targets(engine);
        let mut environments = Vec::new();
        let mut scanning = false;
        for id in self.environments(engine) {
            let answer = self.answers.get(&id).cloned().unwrap_or_default();
            let mut status = if self.online(engine, &id) {
                answer.status.clone()
            } else {
                "offline".into()
            };
            if status.is_empty() {
                status = "scanning".into();
            }
            if status == "ready" && !compatible(&answer.summary) {
                status = "outdated".into();
            }
            if chosen.contains(&id) && status == "scanning" {
                scanning = true;
            }
            environments.push(json!({
                "id": id,
                "label": self.label(engine, &id),
                "status": status,
            }));
        }
        let mut notices = Vec::new();
        let merged = if self.open && !limits_shown {
            self.summary(engine, &mut notices)
        } else {
            Json::Null
        };
        let limits = if self.open && limits_shown {
            self.limits(engine)
        } else {
            json!({})
        };
        // Why there is nothing to show.
        let mut message = "";
        if chosen.is_empty() {
            message = if limits_shown {
                "Connect an environment to see limits."
            } else {
                "Connect an environment to see usage."
            };
        } else if limits_shown {
            if self.open
                && array(&limits, "pools").is_empty()
                && array(&limits, "notices").is_empty()
            {
                message = "No provider on the selected environments reports subscription limits.";
            }
        } else if merged.is_null() {
            if scanning {
                message = "Reading session history…";
            }
        } else if array(&merged, "periods").is_empty() {
            message = "No activity in this window.";
        }
        let now = self.zone.at((self.clock)());
        let window_label = if self.window_days == 1 {
            format!(
                "{} to {}",
                month_day_hour(now - Duration::hours(24)),
                month_day_hour(now)
            )
        } else {
            format!(
                "{} to {}",
                month_day(now.date_naive() - Duration::days(self.window_days - 1)),
                month_day(now.date_naive())
            )
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "metric": self.metric,
                "windowDays": self.window_days,
                "windowLabel": window_label,
                "environmentId": self.environment,
                "environments": environments,
                "scanning": !limits_shown && scanning,
                "refreshing": self.refreshing > 0,
                "notices": notices,
                "message": message,
                "summary": merged,
                "limits": limits,
            }),
        );
    }
}
