//! CLIProxyAPI's page (features/plugins/cliproxyapi.feature): its real
//! package from plugins/cliproxyapi, drawn by the desktop against a fake of
//! its MC part that answers `status`, `signIn`, `finishSignIn` and `retry`
//! as the MC part does and publishes `status`, `accounts`, `usage`, `keys`
//! and `logs`. The proxy itself is the MC's scenarios'
//! (apps/server-ex/test/steps/plugins/cliproxyapi_steps.exs).
//! desktop-qt's CliProxyApiSteps.cpp.

use std::rc::Rc;

use ljos::prelude::{ObjectId, Value};
use serde_json::{Map, Value as Json, json};

use super::mc_plugin::{
    FakePluginPart, entry_of, fake_plugin_part, manifest, named, package, publish_topic,
    run_fake_plugin, shown_named, switch_to_tab,
};
use super::plugin::{click_item, shell};
use crate::brick::Brick;
use crate::expect;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

const ID: &str = "cliproxyapi";
const SIGN_IN_URL: &str = "https://claude.ai/oauth/authorize?code=true&state=st-1";

/// The MC part's state: the proxy's, its accounts and the sign-in under way.
struct FakeCliProxyApi {
    mode: String,
    state: String,
    message: String,
    address: String,
    /// Why the proxy gives no usage, when it gives none.
    usage_note: String,
    /// Why the host did not add Codex via CLIProxyAPI, when it did not.
    codex_taken: String,
    email: String,
    sign_in: Json,
    pasted: String,
}

impl Default for FakeCliProxyApi {
    fn default() -> Self {
        Self {
            mode: "run".into(),
            state: "running".into(),
            message: String::new(),
            address: "http://127.0.0.1:8317".into(),
            usage_note: String::new(),
            codex_taken: String::new(),
            email: String::new(),
            sign_in: Json::Null,
            pasted: String::new(),
        }
    }
}

fn state(mc: &mut FakeMc) -> &mut FakeCliProxyApi {
    mc.part::<FakeCliProxyApi>()
}

fn instance(name: &str, label: &str) -> Json {
    json!({"name": name, "instanceId": format!("plugin_cliproxyapi_{name}"),
           "label": label, "state": "added"})
}

fn status(mc: &mut FakeMc) -> Json {
    let fake = state(mc);
    let mut codex = instance("codex", "Codex via CLIProxyAPI");
    if !fake.codex_taken.is_empty() {
        codex["state"] = json!("taken");
        codex["message"] = json!(fake.codex_taken);
    }
    json!({"mode": fake.mode, "state": fake.state, "message": fake.message,
           "pid": 4242, "restarts": 0, "output": [], "version": "8.0.79",
           "pinned": "8.0.79", "latest": null,
           "binary": "/data/cliproxyapi/bin/cli-proxy-api", "source": "download",
           "address": fake.address, "error": null,
           "instances": [instance("claude", "Claude via CLIProxyAPI"), codex]})
}

fn account_name(email: &str) -> String {
    format!("claude-{email}.json")
}

fn accounts(mc: &mut FakeMc) -> Json {
    let email = state(mc).email.clone();
    if email.is_empty() {
        return json!([]);
    }
    json!([{"id": account_name(&email), "name": account_name(&email),
            "provider": "claude", "email": email, "status": "active",
            "message": "", "disabled": false, "unavailable": false}])
}

fn usage(mc: &mut FakeMc) -> Json {
    let email = state(mc).email.clone();
    if email.is_empty() {
        return json!([]);
    }
    json!([{"day": "2026-11-19", "account": email, "model": "claude-sonnet-4",
            "requests": 2, "failed": 1, "inputTokens": 150, "outputTokens": 25,
            "cachedTokens": 0, "reasoningTokens": 0, "totalTokens": 175}])
}

fn keys(mc: &mut FakeMc) -> Json {
    if state(mc).email.is_empty() {
        return json!([]);
    }
    json!([{"provider": "claude", "id": "k1", "name": "", "baseUrl": "",
            "keys": ["sk-a…mnop"]}])
}

fn logs(mc: &mut FakeMc) -> Json {
    if state(mc).email.is_empty() {
        return json!([]);
    }
    json!(["POST /v1/messages 200"])
}

/// What `status`, `refresh` and `retry` answer: everything the page shows.
fn view(mc: &mut FakeMc) -> Json {
    json!({"status": status(mc), "accounts": accounts(mc),
           "signIn": state(mc).sign_in.clone(), "usage": usage(mc),
           "usageNote": state(mc).usage_note.clone(),
           "logs": logs(mc), "keys": keys(mc)})
}

fn publish(mc: &mut FakeMc) -> Outcome {
    let topics: [(&str, Json); 5] = [
        ("status", status(mc)),
        (
            "accounts",
            json!({"accounts": accounts(mc), "signIn": state(mc).sign_in.clone()}),
        ),
        (
            "usage",
            json!({"rows": usage(mc), "days": 7, "note": state(mc).usage_note.clone()}),
        ),
        ("keys", json!({"keys": keys(mc)})),
        ("logs", json!({"lines": logs(mc)})),
    ];
    let names: Vec<String> = topics.iter().map(|(name, _)| name.to_string()).collect();
    {
        let part = fake_plugin_part(mc, ID)?;
        for (name, value) in topics {
            part.topics.insert(name.into(), value);
        }
    }
    for name in &names {
        publish_topic(mc, ID, name)?;
    }
    Ok(())
}

/// The calls the page makes, answered as the MC part answers them.
fn answer(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let method = text(&rpc.payload["method"]);
    let input = rpc.payload["input"].clone();
    if method == "status" || method == "refresh" {
        let answer = view(mc);
        mc.reply(rpc, answer);
        return Ok(());
    }
    if method == "retry" {
        let fake = state(mc);
        fake.state = "running".into();
        fake.message.clear();
        let answer = view(mc);
        mc.reply(rpc, answer);
        return publish(mc);
    }
    if state(mc).state != "running" {
        mc.refuse(rpc, "CLIProxyAPI is not running.");
        return Ok(());
    }
    if method == "signIn" {
        state(mc).sign_in = json!({"provider": input["provider"], "state": "st-1",
                                   "url": SIGN_IN_URL, "status": "wait", "error": null});
        mc.reply(rpc, json!({"url": SIGN_IN_URL}));
        return publish(mc);
    }
    if method == "finishSignIn" {
        let sign_in = state(mc).sign_in.clone();
        mc.reply(rpc, json!({"signIn": sign_in}));
        return Ok(());
    }
    mc.refuse(rpc, &format!("Unknown method {method}."));
    Ok(())
}

/// The calls of `method` the page made, with their input.
fn asked(mc: &FakeMc, method: &str) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.call" && text(&rpc.payload["method"]) == method)
        .map(|rpc| rpc.payload["input"].clone())
        .collect()
}

/// The first `method` call the page made, once it has reached the MC.
fn wait_asked(world: &mut World, method: &str) -> Outcome<Json> {
    world.wait_for_with(
        |w| !asked(&w.mc, method).is_empty(),
        |_| format!("the page to call {method}"),
    )?;
    Ok(asked(&world.mc, method).swap_remove(0))
}

fn text_of(w: &World, brick: Brick, object_name: &str) -> String {
    named(w, brick, object_name)
        .map(|found| brick.text_of(w, found, "text"))
        .unwrap_or_default()
}

/// Waits until `object_name`'s text holds `part`.
fn wait_says(world: &mut World, object_name: &str, part: &str) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| text_of(w, brick, object_name).contains(part),
        |w| {
            format!(
                "{object_name} to say {part}, not {}",
                text_of(w, brick, object_name)
            )
        },
    )
}

/// Waits until the shown `object_name`, or a visible item under it, draws
/// `wanted`.
fn wait_draws(world: &mut World, object_name: &str, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| {
            named(w, brick, object_name)
                .is_some_and(|found| brick.shows_under(w, found, wanted).unwrap_or(false))
        },
        |_| format!("{object_name} to draw {wanted}"),
    )
}

fn click(world: &mut World, object_name: &str) -> Outcome {
    let brick = shell(world)?;
    let target: ObjectId = shown_named(world, object_name)?;
    world.wait_for_with(
        |w| brick.flag(w, target, "enabled"),
        |_| format!("{object_name} to be enabled"),
    )?;
    click_item(world, target)
}

fn open_page(world: &mut World) -> Outcome {
    let package = package(ID);
    let read = manifest(&package)?;
    let mut settings = Map::new();
    for each in read["settings"].as_array().into_iter().flatten() {
        settings.insert(text(&each["key"]), each["default"].clone());
    }
    let part = FakePluginPart {
        package,
        call: Some(Rc::new(answer)),
        ..FakePluginPart::default()
    };
    run_fake_plugin(world, entry_of(ID, &read, &Json::Object(settings)), part)?;
    publish(&mut world.mc)?;
    switch_to_tab(world, "CLIProxyAPI")?;
    shown_named(world, "cliproxyapiPage").map(|_| ())
}

pub fn register(steps: &mut Steps) {
    // The MC scenarios' fake proxy; here the MC part is faked whole.
    steps.step("a fake CLIProxyAPI", |_, _, _| Ok(()));

    steps.step(
        &format!("the CLIProxyAPI page with the proxy running(?: and the \"claude\" account {Q})?"),
        |world, c, _| {
            state(&mut world.mc).email = c[0].clone();
            open_page(world)
        },
    );
    steps.step(
        &format!("the CLIProxyAPI page with the proxy refusing the management key saying {Q}"),
        |world, c, _| {
            let fake = state(&mut world.mc);
            fake.state = "blocked".into();
            fake.message = c[0].clone();
            open_page(world)
        },
    );
    steps.step(
        &format!("the CLIProxyAPI page connected to the proxy at {Q}"),
        |world, c, _| {
            let fake = state(&mut world.mc);
            fake.mode = "connect".into();
            fake.state = "connected".into();
            fake.address = c[0].clone();
            open_page(world)
        },
    );
    steps.step(
        &format!("the CLIProxyAPI page with the proxy giving no usage, saying {Q}"),
        |world, c, _| {
            state(&mut world.mc).usage_note = c[0].clone();
            open_page(world)
        },
    );
    steps.step(
        &format!("the CLIProxyAPI page with \"Codex via CLIProxyAPI\" not added, saying {Q}"),
        |world, c, _| {
            state(&mut world.mc).codex_taken = c[0].clone();
            open_page(world)
        },
    );

    steps.step(
        &format!("the page says it is connected to the proxy at {Q}"),
        |world, c, _| {
            wait_says(
                world,
                "cliproxyapiState",
                &format!("Connected to CLIProxyAPI at {}", c[0]),
            )
        },
    );
    steps.step(
        &format!("the page says the proxy gives no usage, saying {Q}"),
        |world, c, _| {
            wait_says(
                world,
                "cliproxyapiUsageNote",
                &format!("The proxy gives no usage: {}", c[0]),
            )
        },
    );
    steps.step(
        &format!("the page shows {Q} as not added, saying {Q}"),
        |world, c, _| {
            let name = if c[0].starts_with("Claude") {
                "claude"
            } else {
                "codex"
            };
            let object_name = format!("cliproxyapiInstanceText:{name}");
            wait_says(world, &object_name, &format!("{} · not added: ", c[0]))?;
            wait_says(world, &object_name, &c[1])
        },
    );

    steps.step(
        "the page shows the proxy running CLIProxyAPI 8.0.79",
        |world, _, _| {
            wait_says(
                world,
                "cliproxyapiState",
                "Running CLIProxyAPI 8.0.79 at http://127.0.0.1:8317",
            )
        },
    );
    steps.step(&format!("the page lists the account {Q}"), |world, c, _| {
        wait_draws(
            world,
            &format!("cliproxyapiAccount:{}", account_name(&c[0])),
            &format!("Claude · {}", c[0]),
        )
    });
    steps.step(&format!("the page shows usage for {Q}"), |world, c, _| {
        wait_says(
            world,
            &format!("cliproxyapiUsage:{}", c[0]),
            &format!(
                "2026-11-19 · {} · claude-sonnet-4 · 2 request(s) · 175 tokens · 1 failed",
                c[0]
            ),
        )
    });
    steps.step(&format!("the page shows the {Q} key {Q}"), |world, c, _| {
        expect!(c[0] == "claude", "only a claude key is faked");
        wait_draws(
            world,
            "cliproxyapiKey:claude:0",
            &format!("Claude · {}", c[1]),
        )
    });
    steps.step(
        &format!("the page shows the log line {Q}"),
        |world, c, _| wait_says(world, "cliproxyapiLog", &c[0]),
    );

    steps.step("the user signs in to Claude on the page", |world, _, _| {
        click(world, "cliproxyapiSignIn:claude")?;
        let asking = wait_asked(world, "signIn")?;
        expect!(
            asking == json!({"provider": "claude"}),
            "the MC was asked {}",
            show(&asking)
        );
        Ok(())
    });
    steps.step(
        "the page shows the sign-in address and asks for the address the browser ended on",
        |world, _, _| {
            wait_says(world, "cliproxyapiSignInUrl", SIGN_IN_URL)?;
            wait_says(
                world,
                "cliproxyapiSignInHelp",
                "copy that page's whole address and paste it below",
            )?;
            shown_named(world, "cliproxyapiSignInAddress").map(|_| ())
        },
    );
    steps.step(
        &format!("the user pastes {Q} on the page"),
        |world, c, _| {
            state(&mut world.mc).pasted = c[0].clone();
            let brick = shell(world)?;
            let address = shown_named(world, "cliproxyapiSignInAddress")?;
            brick.write(world, address, "text", Value::from(c[0].as_str()))?;
            click(world, "cliproxyapiFinishSignIn")
        },
    );
    steps.step(
        "the page asked the MC to finish the sign-in with that address",
        |world, _, _| {
            let finishing = wait_asked(world, "finishSignIn")?;
            let pasted = state(&mut world.mc).pasted.clone();
            expect!(
                finishing == json!({"address": pasted}),
                "the MC was asked {}",
                show(&finishing)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the page says the proxy refused the management key {Q}"),
        |world, c, _| {
            wait_says(
                world,
                "cliproxyapiState",
                "CLIProxyAPI refused the management key",
            )?;
            wait_says(world, "cliproxyapiMessage", &c[0])
        },
    );
    steps.step("the user retries on the page", |world, _, _| {
        click(world, "cliproxyapiRetry")
    });
    steps.step("the page asked the MC to retry", |world, _, _| {
        wait_asked(world, "retry")?;
        wait_says(world, "cliproxyapiState", "Running CLIProxyAPI 8.0.79")
    });
}
