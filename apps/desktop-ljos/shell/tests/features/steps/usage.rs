//! The usage page (UsageController), and the MC's side of it: the @shared
//! scenarios of features/settings/usage.feature (desktop-qt's
//! UsageSteps.cpp).

use std::collections::{HashMap, HashSet};

use chrono::{
    DateTime, Datelike, Duration, FixedOffset, Local, NaiveDate, SecondsFormat, TimeZone, Utc,
    Weekday,
};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::usage::{Usage, Zone};
use serde_json::{Map, Value, json};

use super::settings::{document_of, fake_config, save_elsewhere, save_on};
use crate::brick::{Brick, Shown, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// Each environment's session history, as apps/server-ex HalC2.Usage answers
/// `server.getUsageSummary`: one provider per environment, so what each one
/// contributes can be told apart.
struct FakeUsage {
    /// By environment; the MC's own is Codex.
    providers: HashMap<String, String>,
    /// Contract versions other than 5.
    versions: HashMap<String, i64>,
    /// Environments that never answer.
    scanning: HashSet<String>,
    /// The MC's own summary fails so.
    refusal: String,
    summaries: Vec<Rpc>,
    rates: i64,
    reads_at_refresh: usize,
    limit_checks: i64,
    followed_before: usize,
    price_writes: usize,
    /// The chart's day under the pointer.
    hovered_day: String,
    /// provider.consumeResetCredit: what the MC says, and what it was asked.
    credit_outcome: String,
    redeemed: Vec<Value>,
}

impl Default for FakeUsage {
    fn default() -> FakeUsage {
        FakeUsage {
            providers: HashMap::new(),
            versions: HashMap::new(),
            scanning: HashSet::new(),
            refusal: String::new(),
            summaries: Vec::new(),
            rates: 0,
            reads_at_refresh: 0,
            limit_checks: 0,
            followed_before: 0,
            price_writes: 0,
            hovered_day: String::new(),
            credit_outcome: "reset".into(),
            redeemed: Vec::new(),
        }
    }
}

fn fake(world: &mut World) -> &mut FakeUsage {
    world.mc.part::<FakeUsage>()
}

/// What the scenario has recorded so far, for a wait that only reads.
fn recorded(world: &World) -> FakeUsageRead<'_> {
    FakeUsageRead(world.mc.peek::<FakeUsage>())
}

struct FakeUsageRead<'a>(Option<&'a FakeUsage>);

impl FakeUsageRead<'_> {
    fn limit_checks(&self) -> i64 {
        self.0.map_or(0, |f| f.limit_checks)
    }

    fn rates(&self) -> i64 {
        self.0.map_or(0, |f| f.rates)
    }

    fn redeemed(&self) -> Vec<Value> {
        self.0.map(|f| f.redeemed.clone()).unwrap_or_default()
    }

    fn reads_at_refresh(&self) -> usize {
        self.0.map_or(0, |f| f.reads_at_refresh)
    }
}

fn environment_of(mc: &FakeMc, rpc: &Rpc) -> String {
    if rpc.environment.is_empty() {
        mc.environment_id.clone()
    } else {
        rpc.environment.clone()
    }
}

fn provider_of(mc: &FakeMc, environment: &str) -> String {
    mc.peek::<FakeUsage>()
        .and_then(|f| f.providers.get(environment).cloned())
        .unwrap_or_else(|| "codex".into())
}

fn version_of(mc: &FakeMc, environment: &str) -> i64 {
    mc.peek::<FakeUsage>()
        .and_then(|f| f.versions.get(environment).copied())
        .unwrap_or(5)
}

/// A time as the MC spells it: ISO 8601 with milliseconds, in UTC.
pub fn iso_ms(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn summary(mc: &FakeMc, environment: &str, input: &Value) -> Value {
    let provider = provider_of(mc, environment);
    let mut bucket = json!({
        "day": input["untilDay"],
        "provider": provider,
        "model": format!("model-{provider}"),
        "totals": {
            "uncachedInputTokens": 1000,
            "cachedInputTokens": 500,
            "cacheCreationTokens": 0,
            "outputTokens": 200,
            "reasoningTokens": 50,
        },
        "costUsd": 1.5,
        "cacheSavingsUsd": 0.25,
        "costSource": "modelPriced",
        "records": 3,
        "unpricedRecords": 0,
        "sessions": 1,
    });
    if input["resolution"] == json!("hour") {
        bucket["hourStart"] = input["sinceTime"].clone();
    }
    let source = json!({
        "fingerprint": {
            "hostId": environment,
            "provider": provider,
            "resolvedHomePath": format!("/home/sam/.{provider}"),
            "volumeId": "disk",
        },
        "status": "ok",
        "distinctSessions": 2,
    });
    json!({
        "contractVersion": version_of(mc, environment),
        // An hourly read is as new as the window it was asked over.
        "readAt": input["untilTime"].as_str().unwrap_or("2026-09-23T10:00:00.000Z"),
        "timeZone": input["timeZone"],
        "sinceDay": input["sinceDay"],
        "untilDay": input["untilDay"],
        "buckets": [bucket],
        "sources": [source],
        "pricing": {"status": "fresh"},
    })
}

fn extend(mc: &mut FakeMc) {
    mc.on_rpc("server.getUsageSummary", |mc, rpc| {
        let environment = environment_of(mc, rpc);
        let fake = mc.part::<FakeUsage>();
        fake.summaries.push(rpc.clone());
        if fake.scanning.contains(&environment) {
            return Ok(());
        }
        let refusal = fake.refusal.clone();
        if !refusal.is_empty() && environment == mc.environment_id {
            mc.refuse_with(rpc, &refusal, json!({"_tag": "UsageReadError"}));
            return Ok(());
        }
        let answer = summary(mc, &environment, &rpc.payload);
        mc.reply(rpc, answer);
        Ok(())
    });
    mc.on_rpc("server.refreshUsageRates", |mc, rpc| {
        mc.part::<FakeUsage>().rates += 1;
        mc.reply(rpc, json!({"status": "fresh"}));
        Ok(())
    });
    mc.on_rpc("provider.consumeResetCredit", |mc, rpc| {
        let fake = mc.part::<FakeUsage>();
        fake.redeemed.push(rpc.payload.clone());
        let outcome = fake.credit_outcome.clone();
        if outcome == "reset" {
            // The credit is spent and the windows clear.
            let config = &mut fake_config(mc).config;
            if let Some(Value::Array(providers)) = config.get_mut("providers") {
                for provider in providers.iter_mut() {
                    if provider["instanceId"] != rpc.payload["instanceId"] {
                        continue;
                    }
                    let mut limits = provider["usageLimits"].clone();
                    if !limits.is_object() {
                        limits = json!({});
                    }
                    limits["resetCredits"] = json!({"availableCount": 0});
                    provider["usageLimits"] = limits;
                }
            }
        }
        mc.reply(rpc, json!({"outcome": outcome}));
        Ok(())
    });
    mc.on_rpc("server.refreshProviders", |mc, rpc| {
        mc.part::<FakeUsage>().limit_checks += 1;
        // Each environment re-reads its own providers.
        let config = fake_config(mc);
        let own = config
            .elsewhere
            .get(&rpc.environment)
            .unwrap_or(&config.config);
        let providers = own.get("providers").cloned().unwrap_or(Value::Null);
        mc.reply(rpc, json!({"providers": providers}));
        Ok(())
    });
}

fn usage(world: &World) -> Value {
    world.state("usage")
}

fn ensure_connected(world: &mut World) -> Outcome {
    if world.shell_subscriptions() > 0 {
        return Ok(());
    }
    world.connect()?;
    world.sync()
}

fn show_usage(world: &mut World, metric: &str, days: i64) -> Outcome {
    ensure_connected(world)?;
    world.dispatch("usage.open", Value::Null)?;
    world.dispatch("usage.metric", json!({"metric": metric}))?;
    if days > 0 {
        world.dispatch("usage.window", json!({"days": days}))?;
    }
    world.wait_for_with(
        |w| {
            let page = usage(w);
            page["open"] == json!(true)
                && page["metric"] == json!(metric)
                && (days == 0 || page["windowDays"].as_i64() == Some(days))
        },
        |w| format!("usage to show {metric}; it is {}", show(&usage(w))),
    )
}

fn environment_row(world: &World, id: &str) -> Value {
    usage(world)["environments"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["id"] == json!(id))
        .cloned()
        .unwrap_or(Value::Null)
}

fn counted(world: &World, provider: &str) -> bool {
    at(&usage(world), "summary.providers")
        .as_array()
        .into_iter()
        .flatten()
        .any(|row| row["id"] == json!(provider))
}

fn expect_shown(world: &mut World, environment: &str) -> Outcome {
    let provider = provider_of(&world.mc, environment);
    world.wait_for_with(
        |w| environment_row(w, environment)["status"] == json!("ready") && counted(w, &provider),
        |w| {
            format!(
                "the usage of {environment} to be shown; the page is {}",
                show(&usage(w))
            )
        },
    )
}

fn join(world: &mut World, environment: &str, provider: &str) {
    fake(world)
        .providers
        .insert(environment.to_owned(), provider.to_owned());
    world.mc.join_named(environment);
}

fn summaries_for(world: &World, environment: &str) -> Vec<Rpc> {
    world
        .mc
        .peek::<FakeUsage>()
        .map(|f| f.summaries.as_slice())
        .unwrap_or_default()
        .iter()
        .filter(|rpc| environment_of(&world.mc, rpc) == environment)
        .cloned()
        .collect()
}

fn limits_window(label: &str, used: f64, resets_at: DateTime<Utc>) -> Value {
    json!({
        "id": "five-hour",
        "kind": "session",
        "label": label,
        "usedPercent": used,
        "resetsAt": iso_ms(resets_at),
        "windowDurationMins": 300,
    })
}

fn codex(instance_id: &str, name: &str, email: &str, limits: Value) -> Value {
    json!({
        "instanceId": instance_id,
        "driver": "codex",
        "displayName": name,
        "enabled": true,
        "installed": true,
        "status": "ready",
        "auth": {"status": "authenticated", "email": email},
        "usageLimits": limits,
    })
}

/// A subscription's limits: one 5-hour window, read now.
fn limits_now(world: &World, used: f64, resets_in: Duration) -> Value {
    let now = world.now();
    json!({
        "checkedAt": iso_ms(now),
        "windows": [limits_window("5-hour", used, now + resets_in)],
    })
}

/// The Codex account's banked reset credits as the page shows them.
fn credit(world: &World) -> Value {
    for pool in at(&usage(world), "limits.pools")
        .as_array()
        .into_iter()
        .flatten()
    {
        let credits = pool["credits"].as_array().cloned().unwrap_or_default();
        if pool["driver"] == json!("codex") && !credits.is_empty() {
            return credits[0].clone();
        }
    }
    Value::Null
}

fn set_providers(world: &mut World, providers: Vec<Value>) {
    fake_config(&mut world.mc)
        .config
        .insert("providers".into(), Value::Array(providers));
}

/// One hub (a usage-limit source) on this MC, as HalC2.UsageLimitSources
/// publishes it.
fn set_hub(world: &mut World, label: &str, accounts: Vec<Value>, error: &str) {
    let mut hub = json!({
        "id": "team-hub",
        "kind": "cliproxy",
        "label": label,
        "checkedAt": iso_ms(world.now()),
        "accounts": accounts,
    });
    if !error.is_empty() {
        hub["error"] = json!(error);
    }
    let environment = world.mc.environment_id.clone();
    fake_config(&mut world.mc)
        .sources
        .insert(environment, vec![hub]);
}

fn hub_account(world: &World, email: &str, credit: bool) -> Value {
    let now = world.now();
    let mut limits = json!({
        "checkedAt": iso_ms(now),
        "windows": [limits_window("5-hour", 50.0, now + Duration::hours(2))],
    });
    if credit {
        limits["resetCredits"] = json!({"availableCount": 1, "nextCreditId": "credit-1"});
    }
    let mut account = json!({
        "id": "codex-ops.json",
        "driver": "codex",
        "usageLimits": limits,
    });
    if !email.is_empty() {
        account["email"] = json!(email);
    }
    account
}

fn codex_accounts(world: &World) -> Vec<Value> {
    for pool in at(&usage(world), "limits.pools")
        .as_array()
        .into_iter()
        .flatten()
    {
        if pool["driver"] != json!("codex") {
            continue;
        }
        return pool["windows"][0]["accounts"]
            .as_array()
            .cloned()
            .unwrap_or_default();
    }
    Vec::new()
}

fn prices(world: &World) -> Value {
    world.state("usagePrices")
}

fn price_target(world: &World, id: &str) -> Value {
    prices(world)["targets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|target| target["id"] == json!(id))
        .cloned()
        .unwrap_or(Value::Null)
}

fn price_row(world: &World, model: &str) -> Value {
    prices(world)["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["model"] == json!(model))
        .cloned()
        .unwrap_or(Value::Null)
}

fn price(input: f64, output: f64) -> Value {
    json!({"inputCostPerMillionTokens": input, "outputCostPerMillionTokens": output})
}

/// From the usage page, with `count` environments chosen.
fn open_prices(world: &mut World, count: usize) -> Outcome {
    show_usage(world, "cost", 0)?;
    world.dispatch("usagePrices.open", Value::Null)?;
    world.wait_for_with(
        |w| {
            let dialog = prices(w);
            dialog["open"] == json!(true)
                && dialog["targets"].as_array().map(Vec::len) == Some(count)
        },
        |w| {
            format!(
                "Model prices for {count} environments; the dialog is {}",
                show(&prices(w))
            )
        },
    )
}

fn edit_price(world: &mut World, model: &str, field: &str, value: &str) -> Outcome {
    world.dispatch(
        "usagePrices.edit",
        json!({"model": model, "field": field, "value": value}),
    )
}

/// What the environment's settings hold as my-model's input price; negative
/// when none.
fn saved_price(world: &mut World, environment: &str) -> f64 {
    let settings: Map<String, Value> = if environment == world.mc.environment_id {
        fake_config(&mut world.mc).settings.clone()
    } else {
        document_of(&mut world.mc, environment).settings.clone()
    };
    settings
        .get("usagePriceOverrides")
        .and_then(|saved| saved.get("my-model"))
        .map_or(-1.0, |saved| {
            saved["inputCostPerMillionTokens"].as_f64().unwrap_or(0.0)
        })
}

fn price_writes(world: &World, environment: &str) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "hal-c2.writeSettings" && environment_of(&world.mc, rpc) == environment
        })
        .count()
}

fn prices_brick(world: &mut World) -> Outcome<Brick> {
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nUsageModelPrices { width: 900; height: 500 }\n",
        900.0,
        500.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

/// The window's local day, as the page reads it (this machine's zone).
fn local_today(world: &World) -> NaiveDate {
    world.now().with_timezone(&Local).date_naive()
}

fn day_text(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

/// `time` with its seconds dropped.
fn minute_floor(time: DateTime<Utc>) -> DateTime<Utc> {
    let seconds = time.timestamp();
    Utc.timestamp_opt(seconds - seconds.rem_euclid(60), 0)
        .single()
        .unwrap_or(time)
}

/// QtGlobal's qFuzzyCompare for doubles.
fn fuzzy(a: f64, b: f64) -> bool {
    (a - b).abs() * 1e12 <= a.abs().min(b.abs())
}

/// New York's offset, with the United States' rule: daylight time runs from
/// 2 AM on the second Sunday of March to 2 AM on the first of November.
fn new_york(at: DateTime<Utc>) -> FixedOffset {
    let year = at.year();
    let sunday = |month, nth| {
        NaiveDate::from_weekday_of_month_opt(year, month, Weekday::Sun, nth)
            .and_then(|day| day.and_hms_opt(0, 0, 0))
            .map(|day| day.and_utc())
    };
    let (Some(start), Some(end)) = (sunday(3, 2), sunday(11, 1)) else {
        return FixedOffset::west_opt(5 * 3600).unwrap_or(FixedOffset::east_opt(0).unwrap());
    };
    // 2 AM standard time is 7 AM UTC; 2 AM daylight time is 6 AM UTC.
    let (start, end) = (start + Duration::hours(7), end + Duration::hours(6));
    let hours = if start <= at && at < end { 4 } else { 5 };
    FixedOffset::west_opt(hours * 3600).unwrap_or(FixedOffset::east_opt(0).unwrap())
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // providers/usage.feature: this machine's history is Codex's, and the
    // other environment, "Studio", has Claude's.
    steps.step(
        "a connected environment with Codex, Claude and Grok history",
        |world, _, _| ensure_connected(world),
    );
    steps.step(
        "two connected environments(, one slow to scan)?",
        |world, c, _| {
            let limits = limits_now(world, 40.0, Duration::hours(1));
            let mut claude = codex("claudeAgent", "Claude", "sam@example.com", limits.clone());
            claude["driver"] = json!("claudeAgent");
            set_providers(
                world,
                vec![codex("codex", "Codex", "sam@example.com", limits)],
            );
            fake_config(&mut world.mc).elsewhere.insert(
                "Studio".into(),
                Map::from_iter([("providers".to_owned(), json!([claude]))]),
            );
            document_of(&mut world.mc, "Studio");
            join(world, "Studio", "claude");
            if !c[0].is_empty() {
                fake(world).scanning.insert("Studio".into());
            }
            Ok(())
        },
    );
    steps.step(
        "the user selects only one environment in Usage",
        |world, _, _| {
            show_usage(world, "cost", 0)?;
            world.wait_for_with(
                |w| !environment_row(w, "Studio").is_null(),
                |w| format!("Studio to be offered; the page is {}", show(&usage(w))),
            )?;
            world.dispatch("usage.environment", json!({"id": "Studio"}))
        },
    );
    steps.step(
        "costs, tokens and limits are shown for that environment only",
        |world, _, _| {
            // One environment's history is one provider's: 1.5 dollars and 1700 tokens.
            for metric in ["cost", "tokens"] {
                show_usage(world, metric, 0)?;
                world.wait_for_with(
                    |w| {
                        let page = usage(w);
                        let providers = at(&page, "summary.providers")
                            .as_array()
                            .cloned()
                            .unwrap_or_default();
                        page["environmentId"] == json!("Studio")
                            && providers.len() == 1
                            && providers[0]["id"] == json!("claude")
                            && at(&page, "summary.costUsd").as_f64() == Some(1.5)
                            && at(&page, "summary.totalTokens").as_f64() == Some(1700.0)
                    },
                    |w| format!("only Studio's {metric}; the page is {}", show(&usage(w))),
                )?;
            }
            show_usage(world, "limits", 0)?;
            world.wait_for_with(
                |w| {
                    let pools = at(&usage(w), "limits.pools")
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    pools.len() == 1 && pools[0]["driver"] == json!("claudeAgent")
                },
                |w| format!("only Studio's limits; the page is {}", show(&usage(w))),
            )
        },
    );
    steps.step("the user opens Usage", |world, _, _| {
        show_usage(world, "cost", 0)
    });
    steps.step(
        "the fast environment's results appear first",
        |world, _, _| {
            let own = world.mc.environment_id.clone();
            expect_shown(world, &own)?;
            expect!(
                !counted(world, "claude"),
                "Studio's usage is counted already: {}",
                show(&usage(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the slow environment is shown as still scanning until it responds",
        |world, _, _| {
            let slow = "Studio";
            world.wait_for_with(
                |w| {
                    environment_row(w, slow)["status"] == json!("scanning")
                        && usage(w)["scanning"] == json!(true)
                },
                |w| format!("Studio to be scanning; the page is {}", show(&usage(w))),
            )?;
            let asked = summaries_for(world, slow);
            expect!(!asked.is_empty(), "Studio was not asked for its usage");
            fake(world).scanning.remove(slow);
            let last = asked.last().cloned().unwrap_or_else(|| unreachable!());
            let answer = summary(&world.mc, slow, &last.payload);
            world.mc.reply(&last, answer);
            expect_shown(world, slow)?;
            expect!(
                usage(world)["scanning"] != json!(true) && counted(world, "codex"),
                "both environments to be shown; the page is {}",
                show(&usage(world))
            );
            Ok(())
        },
    );

    // Model prices (UsagePricesController), for this machine and "Studio".
    steps.step(
        "one of two selected environments is offline",
        |world, _, _| {
            document_of(&mut world.mc, "Studio");
            join(world, "Studio", "claude");
            world.mc.set_online("Studio", false);
            world.sync()
        },
    );
    steps.step(
        &format!("the user saves a custom price(?: for {Q})? to both"),
        |world, _, _| {
            open_prices(world, 2)?;
            world.dispatch("usagePrices.add", json!({"model": "my-model"}))?;
            edit_price(world, "my-model", "inputCostPerMillionTokens", "3")?;
            edit_price(world, "my-model", "outputCostPerMillionTokens", "15")?;
            world.dispatch("usagePrices.save", Value::Null)?;
            world.wait_for_with(
                |w| {
                    let own = w.mc.environment_id.clone();
                    prices(w)["saving"] != json!(true)
                        && !text(&price_target(w, &own)["status"]).is_empty()
                },
                |w| format!("the save to settle; the dialog is {}", show(&prices(w))),
            )
        },
    );
    steps.step(
        "each environment reports that the price saved",
        |world, _, _| {
            let own = world.mc.environment_id.clone();
            for id in [own.as_str(), "Studio"] {
                let held = saved_price(world, id);
                expect!(
                    price_target(world, id)["status"] == json!("Saved") && held == 3.0,
                    "{id} holds {held}; the dialog is {}",
                    show(&prices(world))
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the offline environment is marked {Q}"),
        |world, c, _| {
            let own = world.mc.environment_id.clone();
            let (own_price, studio_price) =
                (saved_price(world, &own), saved_price(world, "Studio"));
            expect!(
                price_target(world, "Studio")["status"] == json!(c[0])
                    && price_target(world, &own)["status"] == json!("Saved")
                    && own_price == 3.0
                    && studio_price < 0.0,
                "the dialog is {}",
                show(&prices(world))
            );
            let brick = prices_brick(world)?;
            expect!(
                brick.shows(world, &c[0])? && brick.shows(world, "Retry failed saves")?,
                "the dialog does not say \"{}\"",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the environment reconnects and the user chooses {Q}"),
        |world, c, _| {
            let own = world.mc.environment_id.clone();
            fake(world).price_writes = price_writes(world, &own);
            world.mc.set_online("Studio", true);
            world.sync()?;
            let brick = shown(world)?;
            expect!(
                brick.shows(world, &c[0])?,
                "the dialog does not offer \"{}\"",
                c[0]
            );
            brick.click(world, "pricesRetry")
        },
    );
    steps.step(
        "the price is saved there without writing again to the other environment",
        |world, _, _| {
            world.wait_for_with(
                |w| price_target(w, "Studio")["status"] == json!("Saved"),
                |w| format!("Studio to save; the dialog is {}", show(&prices(w))),
            )?;
            let own = world.mc.environment_id.clone();
            let held = saved_price(world, "Studio");
            let writes = price_writes(world, &own);
            let before = fake(world).price_writes;
            expect!(
                held == 3.0 && writes == before,
                "Studio holds {held}; this machine was written {writes} times, {before} before"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("two environments with different prices for {Q}"),
        |world, c, _| {
            document_of(&mut world.mc, "Studio");
            join(world, "Studio", "claude");
            save_elsewhere(
                &mut world.mc,
                "usagePriceOverrides",
                json!({ c[0].clone(): price(3.0, 15.0) }),
                false,
            );
            save_on(
                &mut world.mc,
                "Studio",
                "usagePriceOverrides",
                json!({ c[0].clone(): price(5.0, 15.0) }),
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens Model prices with both selected",
        |world, _, _| open_prices(world, 2),
    );
    steps.step(
        &format!("the price of {Q} is shown as {Q}"),
        |world, c, _| {
            let cell = |w: &World, field: &str| price_row(w, &c[0])["cells"][field].clone();
            world.wait_for_with(
                |w| cell(w, "inputCostPerMillionTokens")["placeholder"] == json!(c[1]),
                |w| {
                    format!(
                        "{} to read {}; the dialog is {}",
                        c[0],
                        c[1],
                        show(&prices(w))
                    )
                },
            )?;
            // Only the rate that differs: both charge the same for output.
            expect!(
                text(&cell(world, "inputCostPerMillionTokens")["value"]).is_empty()
                    && cell(world, "outputCostPerMillionTokens")["value"] == json!("15"),
                "the row is {}",
                show(&price_row(world, &c[0]))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user marked {Q} to reset to automatic"),
        |world, c, _| {
            save_elsewhere(
                &mut world.mc,
                "usagePriceOverrides",
                json!({ c[0].clone(): price(3.0, 15.0) }),
                false,
            );
            open_prices(world, 1)?;
            world.wait_for_with(
                |w| !price_row(w, &c[0]).is_null(),
                |w| format!("{} to be listed; the dialog is {}", c[0], show(&prices(w))),
            )?;
            world.dispatch("usagePrices.remove", json!({"model": c[0]}))?;
            expect!(
                price_row(world, &c[0])["removed"] == json!(true),
                "the row is {}",
                show(&price_row(world, &c[0]))
            );
            Ok(())
        },
    );
    steps.step("the user undoes the reset before saving", |world, _, _| {
        let brick = prices_brick(world)?;
        expect!(
            brick.shows(world, "Undo")?,
            "the dialog does not offer to undo the reset"
        );
        brick.click(world, "priceReset-claude-sonnet")?;
        world.dispatch("usagePrices.save", Value::Null)?;
        world.wait_for_with(
            |w| {
                let own = w.mc.environment_id.clone();
                price_target(w, &own)["status"] == json!("Saved")
            },
            |w| format!("the save to settle; the dialog is {}", show(&prices(w))),
        )
    });
    steps.step(
        &format!("the custom price of {Q} is kept"),
        |world, c, _| {
            let saved = fake_config(&mut world.mc).settings["usagePriceOverrides"][&c[0]].clone();
            let row = price_row(world, &c[0]);
            expect!(
                saved == price(3.0, 15.0)
                    && row["removed"] != json!(true)
                    && at(&row, "cells.inputCostPerMillionTokens.value") == &json!("3"),
                "the environment holds {}; the row is {}",
                show(&saved),
                show(&row)
            );
            Ok(())
        },
    );

    // Reading usage.
    steps.step(
        "the user views (cost|tokens) for the past (24 hours|7 days|30 days|90 days)",
        |world, c, _| {
            let days = if c[1] == "24 hours" {
                1
            } else {
                c[1].split(' ')
                    .next()
                    .and_then(|n| n.parse().ok())
                    .unwrap_or(0)
            };
            show_usage(world, &c[0], days)
        },
    );
    steps.step("the numbers cover that window", |world, _, _| {
        let days = usage(world)["windowDays"].as_i64().unwrap_or(0);
        let now = world.now();
        let expected = if days == 1 {
            let until = minute_floor(now);
            json!({
                "resolution": "hour",
                "sinceTime": iso_ms(until - Duration::hours(24)),
                "untilTime": iso_ms(until),
            })
        } else {
            let today = local_today(world);
            json!({
                "resolution": "day",
                "sinceDay": day_text(today - Duration::days(days - 1)),
                "untilDay": day_text(today),
            })
        };
        let own = world.mc.environment_id.clone();
        world.wait_for_with(
            |w| {
                let calls = summaries_for(w, &own);
                let Some(last) = calls.last() else {
                    return false;
                };
                let asked = expected.as_object().into_iter().flatten();
                if asked
                    .into_iter()
                    .any(|(key, value)| &last.payload[key] != value)
                {
                    return false;
                }
                let page = usage(w);
                if at(&page, "summary.periods")
                    .as_array()
                    .is_none_or(|periods| periods.is_empty())
                {
                    return false;
                }
                // The chart has every period of the window, and what was spent falls inside it.
                let chart = at(&page, "summary.chart")
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let charted: f64 = chart
                    .iter()
                    .flat_map(|period| period["costUsd"].as_array().cloned().unwrap_or_default())
                    .map(|cost| cost.as_f64().unwrap_or(0.0))
                    .sum();
                chart.len() as i64 == if days == 1 { 24 } else { days }
                    && fuzzy(
                        charted,
                        at(&page, "summary.costUsd").as_f64().unwrap_or(0.0),
                    )
            },
            |w| {
                let calls = summaries_for(w, &own);
                format!(
                    "usage to be read over {}; it was asked for {} and shows {}",
                    show(&expected),
                    calls
                        .last()
                        .map_or("nothing".to_owned(), |last| show(&last.payload)),
                    show(&usage(w))
                )
            },
        )
    });
    // The chart. Drawing it and following the pointer are UsageChart.qml's
    // (tst_UsagePage.qml); these read what the page is given to draw.
    steps.step(
        "Codex and Claude both have usage in the past (?:7 days|24 hours)",
        |world, _, _| {
            // This environment's history is Codex's; another brings Claude's.
            join(world, "laptop", "claude");
            Ok(())
        },
    );
    steps.step(
        "the chart draws Codex and Claude over all (\\d+) days",
        |world, c, _| {
            let today = day_text(local_today(world));
            let want: usize = c[0].parse().unwrap_or(0);
            world.wait_for_with(
                |w| {
                    let chart = at(&usage(w), "summary.chart")
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    if chart.len() != want
                        || chart.last().is_none_or(|last| last["key"] != json!(today))
                    {
                        return false;
                    }
                    if !counted(w, "codex") || !counted(w, "claude") {
                        return false;
                    }
                    chart
                        .iter()
                        .all(|day| day["costUsd"].as_array().map(Vec::len) == Some(2))
                },
                |w| {
                    format!(
                        "a chart of {} days ending {today} for Codex and Claude; the page is {}",
                        c[0],
                        show(&usage(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("(\\d+) minutes pass and {Q} is slow to answer"),
        |world, c, _| {
            let own = world.mc.environment_id.clone();
            expect_shown(world, &own)?;
            expect_shown(world, &c[1])?;
            let minutes: i64 = c[0].parse().unwrap_or(0);
            world.set_time(world.now() + Duration::minutes(minutes));
            fake(world).scanning.insert(c[1].clone());
            Ok(())
        },
    );
    steps.step("the chart still draws Codex and Claude", |world, _, _| {
        // This environment's new read has landed: the chart starts where its window does.
        let until = minute_floor(world.now());
        let since = iso_ms(until - Duration::hours(24));
        let chart = |w: &World| {
            at(&usage(w), "summary.chart")
                .as_array()
                .cloned()
                .unwrap_or_default()
        };
        world.wait_for_with(
            |w| {
                chart(w)
                    .first()
                    .is_some_and(|first| first["key"] == json!(since))
            },
            |w| format!("a chart from {since}; the page is {}", show(&usage(w))),
        )?;
        let (mut codex_cost, mut claude_cost) = (0.0, 0.0);
        for hour in chart(world) {
            let cost = hour["costUsd"].as_array().cloned().unwrap_or_default();
            codex_cost += cost.first().and_then(Value::as_f64).unwrap_or(0.0);
            claude_cost += cost.get(1).and_then(Value::as_f64).unwrap_or(0.0);
        }
        expect!(
            codex_cost > 0.0 && claude_cost > 0.0,
            "both providers on the chart; the page is {}",
            show(&usage(world))
        );
        Ok(())
    });
    // 1 AM comes twice there on 1 November 2026; it is half past three, after both.
    steps.step(
        &format!("the user is in {Q} on the night its clocks fall back"),
        |world, c, _| {
            // The zones the scenarios name; the others need a time zone database.
            if c[0] != "America/New_York" {
                fail!("the zone {} to be known", c[0]);
            }
            world.with::<Usage, _>(|u, _| {
                u.set_zone(Zone::changing("America/New_York", new_york))
            })?;
            let night = Utc
                .with_ymd_and_hms(2026, 11, 1, 8, 30, 0)
                .single()
                .unwrap_or_else(|| unreachable!());
            world.set_time(night);
            Ok(())
        },
    );
    steps.step(
        "the chart tells the two hours labelled 1 AM apart",
        |world, _, _| {
            world.wait_for_with(
                |w| at(&usage(w), "summary.chart").as_array().map(Vec::len) == Some(24),
                |w| format!("a chart of 24 hours; the page is {}", show(&usage(w))),
            )?;
            let (mut labels, mut headings) = (Vec::new(), Vec::new());
            for hour in at(&usage(world), "summary.chart")
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                if !text(&hour["label"]).starts_with("1 AM") {
                    continue;
                }
                labels.push(text(&hour["label"]));
                headings.push(text(&hour["heading"]));
            }
            expect!(
                labels.len() == 2 && labels[0] != labels[1],
                "two different 1 AM labels; they are {}",
                labels.join(", ")
            );
            expect!(
                headings.len() == 2 && headings[0] != headings[1],
                "two different 1 AM headings; they are {}",
                headings.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the user hovers a day", |world, _, _| {
        let today = day_text(local_today(world));
        fake(world).hovered_day = today;
        Ok(())
    });
    steps.step(
        "that day's cost for each provider is read out",
        |world, _, _| {
            let hovered = fake(world).hovered_day.clone();
            for day in at(&usage(world), "summary.chart")
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                if day["key"] != json!(hovered) {
                    continue;
                }
                // Codex first, as the page lists them; each history spent 1.5 that day.
                expect!(
                    day["costUsd"] == json!([1.5, 1.5]),
                    "Codex and Claude to have spent 1.5 each on {hovered}; the day is {}",
                    show(&day)
                );
                return Ok(());
            }
            fail!(
                "the chart to have {hovered}; the page is {}",
                show(&usage(world))
            )
        },
    );
    steps.step(
        &format!("{Q} is still scanning and {Q} has finished"),
        |world, c, _| {
            join(world, &c[0], "grok");
            join(world, &c[1], "claude");
            fake(world).scanning.insert(c[0].clone());
            Ok(())
        },
    );
    steps.step(&format!("{Q} is offline"), |world, c, _| {
        join(world, &c[0], "claude");
        world.mc.set_online(&c[0], false);
        Ok(())
    });
    steps.step(
        &format!("{Q} runs an older server version"),
        |world, c, _| {
            join(world, &c[0], "claude");
            fake(world).versions.insert(c[0].clone(), 3);
            Ok(())
        },
    );
    steps.step(
        "the user views usage for all environments",
        |world, _, _| {
            show_usage(world, "cost", 0)?;
            world.dispatch("usage.environment", json!({"id": ""}))
        },
    );
    steps.step(&format!("the user views usage for {Q}"), |world, c, _| {
        show_usage(world, "cost", 0)?;
        world.wait_for_with(
            |w| !environment_row(w, &c[0]).is_null(),
            |w| format!("{} to be offered; the page is {}", c[0], show(&usage(w))),
        )?;
        world.dispatch("usage.environment", json!({"id": c[0]}))
    });
    steps.step(
        &format!("(?:the usage of {Q}|{Q} usage) is shown"),
        |world, c, _| {
            let environment = if c[0].is_empty() { &c[1] } else { &c[0] };
            expect_shown(world, environment)
        },
    );
    steps.step("the usage of this environment is shown", |world, _, _| {
        let own = world.mc.environment_id.clone();
        expect_shown(world, &own)
    });
    steps.step(&format!("{Q} is shown as still scanning"), |world, c, _| {
        world.wait_for_with(
            |w| {
                environment_row(w, &c[0])["status"] == json!("scanning")
                    && usage(w)["scanning"] == json!(true)
            },
            |w| format!("{} to be scanning; the page is {}", c[0], show(&usage(w))),
        )
    });
    steps.step(
        &format!("the usage of (this environment|{Q}) is not counted"),
        |world, c, _| {
            let environment = if c.len() < 2 || c[1].is_empty() {
                world.mc.environment_id.clone()
            } else {
                c[1].clone()
            };
            // What is counted has landed.
            world.wait_for_with(
                |w| !at(&usage(w), "summary").is_null(),
                |w| format!("usage to be shown; the page is {}", show(&usage(w))),
            )?;
            world.sync()?;
            let provider = provider_of(&world.mc, &environment);
            expect!(
                !counted(world, &provider),
                "the usage of {environment} to be left out; the page is {}",
                show(&usage(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told some environments could not report usage",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    usage(w)["notices"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|notice| text(notice).ends_with("could not report usage."))
                },
                |w| {
                    format!(
                        "a notice that usage could not be reported; the page is {}",
                        show(&usage(w))
                    )
                },
            )
        },
    );
    steps.step(&format!("usage says {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let page = usage(w);
                let mut said = page["notices"].as_array().cloned().unwrap_or_default();
                said.extend(
                    at(&page, "limits.notices")
                        .as_array()
                        .cloned()
                        .unwrap_or_default(),
                );
                said.push(page["message"].clone());
                said.contains(&json!(c[0]))
            },
            |w| format!("usage to say {}; the page is {}", c[0], show(&usage(w))),
        )
    });
    steps.step("the MC cannot read usage", |world, _, _| {
        fake(world).refusal =
            "Usage read failed (scanFailed): Transcripts could not be scanned.".into();
        Ok(())
    });
    steps.step("the MC can read usage again", |world, _, _| {
        fake(world).refusal.clear();
        Ok(())
    });
    steps.step("the user refreshes usage", |world, _, _| {
        world.wait_for("no refresh to be running", |w| {
            usage(w)["refreshing"] != json!(true)
        })?;
        let own = world.mc.environment_id.clone();
        fake(world).reads_at_refresh = summaries_for(world, &own).len();
        world.dispatch("usage.refresh", Value::Null)
    });
    steps.step(
        "the MC is asked for the latest model prices",
        |world, _, _| {
            world.wait_for_with(
                |w| recorded(w).rates() == 1,
                |w| {
                    format!(
                        "prices to be fetched once; they were fetched {} times",
                        recorded(w).rates()
                    )
                },
            )
        },
    );
    steps.step("usage is read again", |world, _, _| {
        let before = recorded(world).reads_at_refresh();
        let own = world.mc.environment_id.clone();
        world.wait_for_with(
            |w| summaries_for(w, &own).len() == before + 1 && usage(w)["refreshing"] != json!(true),
            |w| {
                format!(
                    "usage to be read once more than {before} times; it was read {} times",
                    summaries_for(w, &own).len()
                )
            },
        )
    });
    steps.step("the user switched usage to tokens", |world, _, _| {
        show_usage(world, "tokens", 0)
    });
    steps.step("the user opens usage again", |world, _, _| {
        world.restart()?;
        world.connect()?;
        world.dispatch("usage.open", Value::Null)
    });
    steps.step("it shows tokens", |world, _, _| {
        world.wait_for_with(
            |w| usage(w)["open"] == json!(true) && usage(w)["metric"] == json!("tokens"),
            |w| format!("usage to show tokens; it is {}", show(&usage(w))),
        )
    });

    // Limits.
    steps.step("two Codex accounts", |world, _, _| {
        let providers = vec![
            codex(
                "codex",
                "Codex",
                "sam@example.com",
                limits_now(world, 40.0, Duration::hours(3)),
            ),
            codex(
                "codex-work",
                "Codex Work",
                "sam@work.example",
                limits_now(world, 20.0, Duration::hours(1)),
            ),
        ];
        set_providers(world, providers);
        Ok(())
    });
    steps.step("Codex could not read its limits", |world, _, _| {
        let limits = json!({
            "checkedAt": iso_ms(world.now()),
            "windows": [],
            "unavailable": {"reason": "probeFailed"},
        });
        set_providers(
            world,
            vec![codex("codex", "Codex", "sam@example.com", limits)],
        );
        Ok(())
    });
    steps.step("no provider reports limits", |world, _, _| {
        set_providers(world, Vec::new());
        Ok(())
    });
    steps.step("the user views limits", |world, _, _| {
        ensure_connected(world)?;
        let followed = world.mc.subscribers("config").len();
        fake(world).followed_before = followed;
        show_usage(world, "limits", 0)?;
        world.wait_for("limits to be followed", |w| {
            w.mc.subscribers("config").len() > followed
        })
    });
    steps.step(
        "Codex shows one 5-hour number made up of both accounts",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let pools = at(&usage(w), "limits.pools")
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    if pools.len() != 1 || pools[0]["label"] != json!("Codex") {
                        return false;
                    }
                    let windows = pools[0]["windows"].as_array().cloned().unwrap_or_default();
                    windows.len() == 1
                        && windows[0]["label"] == json!("5-hour")
                        && windows[0]["remainingPercent"].as_i64() == Some(70)
                        && windows[0]["accounts"].as_array().map(Vec::len) == Some(2)
                },
                |w| {
                    format!(
                        "one Codex 5-hour pool at 70% from two accounts; the page is {}",
                        show(&usage(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the account that resets soonest comes first",
        |world, _, _| {
            let accounts = at(&usage(world), "limits.pools")[0]["windows"][0]["accounts"].clone();
            expect!(
                accounts[0]["name"] == json!("Codex Work"),
                "Codex Work, which resets in an hour, to come first; the accounts are {}",
                show(&accounts)
            );
            Ok(())
        },
    );
    steps.step(
        "(?:limits were checked|the user opened Limits) two minutes ago",
        |world, _, _| {
            show_usage(world, "limits", 0)?;
            world.wait_for("limits to be checked", |w| recorded(w).limit_checks() == 1)?;
            world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
            world.set_time(world.now() + Duration::minutes(2));
            Ok(())
        },
    );
    steps.step("the user opens limits", |world, _, _| {
        show_usage(world, "limits", 0)
    });
    steps.step(
        "the (?:limits are not checked again|environment is not checked again yet)",
        |world, _, _| {
            world.sync()?;
            let checks = recorded(world).limit_checks();
            expect!(
                checks == 1,
                "limits to be checked once; they were checked {checks} times"
            );
            Ok(())
        },
    );
    steps.step("the limits are checked again", |world, _, _| {
        world.wait_for_with(
            |w| recorded(w).limit_checks() == 2,
            |w| {
                format!(
                    "limits to be checked twice; they were checked {} times",
                    recorded(w).limit_checks()
                )
            },
        )
    });
    steps.step("the user leaves usage", |world, _, _| {
        world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))
    });
    steps.step("limits are no longer followed", |world, _, _| {
        let followed = fake(world).followed_before;
        world.wait_for_with(
            |w| w.mc.subscribers("config").len() == followed,
            |w| {
                format!(
                    "only the shell's own config to be followed; {} are",
                    w.mc.subscribers("config").len()
                )
            },
        )
    });
    // Reset credits.
    steps.step("Codex has a reset credit banked", |world, _, _| {
        let now = world.now();
        let limits = json!({
            "checkedAt": iso_ms(now),
            "windows": [limits_window("5-hour", 90.0, now + Duration::hours(1))],
            "resetCredits": {
                "availableCount": 1,
                "nextExpiresAt": iso_ms(now + Duration::days(27)),
            },
        });
        set_providers(
            world,
            vec![codex("codex", "Codex", "sam@example.com", limits)],
        );
        Ok(())
    });
    steps.step(
        "(no rate-limit window is in use|the account has no credit left|the credit was redeemed on another device)",
        |world, c, _| {
            let outcome = if c[0].starts_with("no rate") {
                "nothingToReset"
            } else if c[0].starts_with("the account") {
                "noCredit"
            } else {
                "alreadyRedeemed"
            };
            fake(world).credit_outcome = outcome.into();
            Ok(())
        },
    );
    steps.step(
        "limits show (\\d+) reset credits? banked for Codex",
        |world, c, _| {
            let want: i64 = c[0].parse().unwrap_or(0);
            world.wait_for_with(
                |w| credit(w)["available"].as_i64() == Some(want),
                |w| format!("{} banked; the credits are {}", c[0], show(&credit(w))),
            )
        },
    );
    steps.step(
        "the user uses the reset credit and confirms",
        |world, _, _| {
            show_usage(world, "limits", 0)?;
            world.wait_for_with(
                |w| credit(w)["available"].as_i64().unwrap_or(0) > 0,
                |w| format!("a banked credit to spend; the page is {}", show(&usage(w))),
            )?;
            let key = credit(world)["key"].clone();
            world.dispatch("usage.resetCredit", json!({"key": key}))
        },
    );
    steps.step(
        "the credit is spent on the Codex instance",
        |world, _, _| {
            let redeemed = recorded(world).redeemed();
            expect!(
                redeemed.len() == 1 && redeemed[0]["instanceId"] == json!("codex"),
                "one redemption on the codex instance; the MC was asked {} times",
                redeemed.len()
            );
            Ok(())
        },
    );
    steps.step("the credit is still banked", |world, _, _| {
        world.wait_for_with(
            |w| credit(w)["available"].as_i64() == Some(1),
            |w| format!("one credit banked; the credits are {}", show(&credit(w))),
        )?;
        expect!(
            recorded(world).redeemed().is_empty(),
            "no credit to be spent"
        );
        Ok(())
    });

    // providers/usage-limits.feature: the desktop half.
    steps.step(
        "a connected environment with Codex and Claude signed in with subscriptions",
        |world, _, _| {
            ensure_connected(world)?;
            let limits = limits_now(world, 40.0, Duration::hours(1));
            let mut claude = codex("claudeAgent", "Claude", "sam@example.com", limits.clone());
            claude["driver"] = json!("claudeAgent");
            set_providers(
                world,
                vec![codex("codex", "Codex", "sam@example.com", limits), claude],
            );
            Ok(())
        },
    );
    steps.step(
        "the same Codex account is signed in on two environments and reported by a hub",
        |world, _, _| {
            let now = world.now();
            let limits = |used: f64, minutes_ago: i64| {
                json!({
                    "checkedAt": iso_ms(now - Duration::minutes(minutes_ago)),
                    "windows": [
                        limits_window("5-hour", used, now + Duration::hours(1)),
                        {
                            "id": "weekly",
                            "kind": "weekly",
                            "label": "Weekly",
                            "usedPercent": used / 2.0,
                            "resetsAt": iso_ms(now + Duration::days(3)),
                            "windowDurationMins": 10080,
                        },
                    ],
                })
            };
            set_providers(
                world,
                vec![codex("codex", "Codex", "sam@example.com", limits(40.0, 3))],
            );
            fake_config(&mut world.mc).elsewhere.insert(
                "Studio".into(),
                Map::from_iter([(
                    "providers".to_owned(),
                    json!([codex("codex", "Codex", "sam@example.com", limits(60.0, 1))]),
                )]),
            );
            world.mc.join_named("Studio");
            // The hub's read is the oldest, the other environment's the freshest.
            let mut account = hub_account(world, "sam@example.com", false);
            account["usageLimits"]["checkedAt"] = json!(iso_ms(now - Duration::minutes(5)));
            set_hub(world, "Team hub", vec![account], "");
            Ok(())
        },
    );
    steps.step("the user opens Limits(?: again)?", |world, _, _| {
        show_usage(world, "limits", 0)
    });
    steps.step(
        "that account is counted once in each window",
        |world, _, _| {
            let pool = |w: &World| {
                at(&usage(w), "limits.pools")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|found| found["driver"] == json!("codex"))
                    .cloned()
                    .unwrap_or(Value::Null)
            };
            // The other environment's read, the freshest, shows once both have reported.
            world.wait_for_with(
                |w| {
                    let windows = pool(w)["windows"].as_array().cloned().unwrap_or_default();
                    windows.len() == 2 && windows[0]["remainingPercent"].as_i64() == Some(40)
                },
                |w| {
                    format!(
                        "the freshest read's two Codex windows; the page is {}",
                        show(&usage(w))
                    )
                },
            )?;
            world.sync()?;
            for window in pool(world)["windows"]
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                expect!(
                    window["accounts"].as_array().map(Vec::len) == Some(1),
                    "one account in {}; the pool is {}",
                    text(&window["label"]),
                    show(&pool(world))
                );
            }
            Ok(())
        },
    );

    // Usage-limit sources (hubs).
    steps.step("an MC the user administers", |world, _, _| {
        ensure_connected(world)
    });
    steps.step(
        &format!("the hub {Q} reports a Codex account"),
        |world, c, _| {
            let account = hub_account(world, "", false);
            set_hub(world, &c[0], vec![account], "");
            Ok(())
        },
    );
    steps.step(
        &format!("the hub {Q} reports the Codex account {Q}( with a banked reset credit)?"),
        |world, c, _| {
            let account = hub_account(world, &c[1], c.len() > 2 && !c[2].is_empty());
            set_hub(world, &c[0], vec![account], "");
            Ok(())
        },
    );
    steps.step(
        &format!("the hub {Q} cannot be read: {Q}"),
        |world, c, _| {
            set_hub(world, &c[0], Vec::new(), &c[1]);
            Ok(())
        },
    );
    steps.step(&format!("Codex is signed in here as {Q}"), |world, c, _| {
        let now = world.now();
        let limits = json!({
            "checkedAt": iso_ms(now - Duration::seconds(60)),
            "windows": [limits_window("5-hour", 40.0, now + Duration::hours(1))],
        });
        set_providers(world, vec![codex("codex", "Codex", &c[0], limits)]);
        Ok(())
    });
    steps.step(
        &format!("Codex limits include the account {Q} of the hub"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    codex_accounts(w)
                        .iter()
                        .any(|account| account["name"] == json!(c[0]))
                },
                |w| {
                    format!(
                        "the hub's {} in Codex limits; the page is {}",
                        c[0],
                        show(&usage(w))
                    )
                },
            )
        },
    );
    steps.step("Codex limits count one account", |world, _, _| {
        world.wait_for_with(
            |w| !codex_accounts(w).is_empty(),
            |w| format!("Codex limits; the page is {}", show(&usage(w))),
        )?;
        world.sync()?;
        let accounts = codex_accounts(world);
        expect!(
            accounts.len() == 1,
            "one Codex account; they are {}",
            show(&Value::Array(accounts))
        );
        Ok(())
    });
    // A hub the user added, its key sealed on the MC, its account in limits.
    steps.step(&format!("a hub {Q}"), |world, c, _| {
        let config = fake_config(&mut world.mc);
        config.settings.insert(
            "usageLimitSources".into(),
            json!({"team-hub": {
                "kind": "cliproxy",
                "label": c[0],
                "url": "https://hub.example",
                "managementKey": "••••••",
                "enabled": true,
            }}),
        );
        config
            .secrets
            .insert("hub/team-hub".into(), "hub-key".into());
        let account = hub_account(world, "", false);
        set_hub(world, &c[0], vec![account], "");
        show_usage(world, "limits", 0)?;
        world.wait_for_with(
            |w| !codex_accounts(w).is_empty(),
            |w| {
                format!(
                    "the hub's account in limits; the page is {}",
                    show(&usage(w))
                )
            },
        )
    });
    steps.step("its accounts leave limits", |world, _, _| {
        world.wait_for_with(
            |w| codex_accounts(w).is_empty(),
            |w| format!("no hub account in limits; the page is {}", show(&usage(w))),
        )
    });
    steps.step("the credit is spent through the hub", |world, _, _| {
        world.wait_for("a credit to be spent", |w| {
            !recorded(w).redeemed().is_empty()
        })?;
        let input = recorded(world).redeemed()[0].clone();
        expect!(
            input["sourceId"] == json!("team-hub")
                && input["accountId"] == json!("codex-ops.json")
                && input["creditId"] == json!("credit-1"),
            "the hub's credit to be spent; the MC was asked {}",
            show(&input)
        );
        Ok(())
    });
}
