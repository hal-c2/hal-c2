//! This machine's cluster settings page on the desktop, and the MC's side of
//! it (the @desktop scenarios of features/connections/cluster.feature):
//! desktop-qt's ClusterSteps.cpp.

use std::collections::HashMap;

use fancy_regex::Regex;
use serde_json::{Value, json};

use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::expect;

/// This machine's cluster as apps/server-ex lib/hal_c2/rpc.ex answers
/// `cluster.*`: the other members, whether the MC listens only on loopback,
/// and why it refuses to read the cluster or join (when it does). Reads are
/// held while the MC holds `cluster.status`.
#[derive(Default)]
struct FakeCluster {
    members: Vec<Value>,
    loopback_only: bool,
    status_refusal: String,
    join_refusal: String,
    /// The version this machine runs, and why a member cannot take it, by label.
    version: String,
    update_refusals: HashMap<String, String>,
    calls: Vec<(String, Value)>,
}

fn cluster_status(mc: &mut FakeMc) -> Value {
    let (id, name) = (mc.environment_id.clone(), mc.name.clone());
    let fake = mc.part::<FakeCluster>();
    json!({
        "clustered": true,
        "id": id,
        "label": "desk",
        "mc": name,
        "addresses": ["desk:4369"],
        "version": fake.version,
        "members": fake.members,
    })
}

fn answer_cluster(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    mc.part::<FakeCluster>()
        .calls
        .push((rpc.method.clone(), rpc.payload.clone()));
    let refuse = |mc: &FakeMc, message: &str, reason: &str| {
        mc.refuse_with(
            rpc,
            message,
            json!({"_tag": "ClusterError", "reason": reason}),
        );
    };
    let mut result = cluster_status(mc);
    let status_refusal = mc.part::<FakeCluster>().status_refusal.clone();
    if rpc.method == "cluster.status" && !status_refusal.is_empty() {
        refuse(mc, &status_refusal, "request_failed");
        return Ok(());
    }
    // Answered with the cluster as it was when asked.
    if rpc.method == "cluster.status" && mc.holding("cluster.status") {
        let rpc = rpc.clone();
        mc.defer(move |mc| mc.reply(&rpc, result));
        return Ok(());
    }
    match rpc.method.as_str() {
        "cluster.invite" => {
            let loopback = mc.part::<FakeCluster>().loopback_only;
            let host = if loopback { "127.0.0.1" } else { "desk" };
            result = json!({
                "link": format!("http://{host}:3773/pair#token=invite-1"),
                "expiresAt": "2026-09-23T10:15:00Z",
                "localOnly": loopback,
            });
        }
        "cluster.join" => {
            let refusal = mc.part::<FakeCluster>().join_refusal.clone();
            if !refusal.is_empty() {
                refuse(mc, &refusal, "link_lacks_access");
                return Ok(());
            }
            let link = text(&rpc.payload["link"]);
            let host = link
                .split_once("://")
                .map_or(link.as_str(), |(_, rest)| rest)
                .split(['/', ':', '?', '#'])
                .next()
                .unwrap_or_default()
                .to_owned();
            mc.part::<FakeCluster>().members.push(json!({
                "id": format!("env-{host}"),
                "label": host,
                "addresses": [format!("{host}:4369")],
                "connected": true,
            }));
            result = cluster_status(mc);
        }
        "cluster.update" => {
            // Each connected member on another version takes this one, or says why not.
            let fake = mc.part::<FakeCluster>();
            let mut updates = Vec::new();
            let version = fake.version.clone();
            for index in 0..fake.members.len() {
                let mut member = fake.members[index].clone();
                let from = text(&member["version"]);
                if member["connected"] != json!(true) || from.is_empty() || from == version {
                    continue;
                }
                let label = text(&member["label"]);
                let outcome = fake
                    .update_refusals
                    .get(&label)
                    .cloned()
                    .unwrap_or_else(|| "updated".to_owned());
                updates.push(json!({
                    "id": member["id"],
                    "label": label,
                    "from": from,
                    "outcome": outcome,
                }));
                if outcome == "updated" {
                    member["version"] = json!(version);
                    fake.members[index] = member;
                }
            }
            result = json!({"version": version, "members": updates});
        }
        "cluster.remove" => {
            let removed = text(&rpc.payload["id"]);
            mc.part::<FakeCluster>()
                .members
                .retain(|member| text(&member["id"]) != removed);
            result = cluster_status(mc);
        }
        _ => {}
    }
    mc.reply(rpc, result);
    Ok(())
}

fn fake(world: &mut World) -> &mut FakeCluster {
    world.mc.part::<FakeCluster>()
}

fn cluster(world: &World) -> Value {
    world.state("cluster")
}

/// The payload of the first call of `method`, once the MC has heard what
/// was sent before.
fn cluster_call(world: &mut World, method: &str) -> Outcome<Option<Value>> {
    world.sync()?;
    Ok(fake(world)
        .calls
        .iter()
        .find(|(called, _)| called == method)
        .map(|(_, payload)| payload.clone()))
}

fn page_is(world: &World) -> String {
    format!("the cluster page is {}", show(&cluster(world)))
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        mc.on_rpc("cluster.", answer_cluster);
    });

    // The cluster settings page.
    steps.step("this machine is clustered with (.*)", |world, c, _| {
        let member = Regex::new("\"([^\"]*)\", which is (connected|offline)").expect("a pattern");
        for found in member.captures_iter(&c[0]).flatten() {
            let label = found.get(1).map_or("", |m| m.as_str()).to_owned();
            fake(world).members.push(json!({
                "id": format!("env-{label}"),
                "label": label,
                "addresses": [],
                "connected": found.get(2).map_or("", |m| m.as_str()) == "connected",
            }));
        }
        Ok(())
    });
    steps.step(
        &format!(
            "this machine runs {Q} and is clustered with {Q}, which is connected on {Q}(?: and cannot update saying {Q})?"
        ),
        |world, c, _| {
            let fake = fake(world);
            fake.version = c[0].clone();
            fake.members.push(json!({
                "id": format!("env-{}", c[1]),
                "label": c[1],
                "addresses": [],
                "version": c[2],
                "connected": true,
            }));
            if c.len() > 3 && !c[3].is_empty() {
                fake.update_refusals.insert(c[1].clone(), c[3].clone());
            }
            Ok(())
        },
    );
    steps.step("the MC listens only on loopback", |world, _, _| {
        fake(world).loopback_only = true;
        Ok(())
    });
    steps.step(&format!("the MC refuses joins saying {Q}"), |world, c, _| {
        fake(world).join_refusal = c[0].clone();
        Ok(())
    });
    steps.step("the user opens Cluster in the desktop's settings", |world, _, _| {
        world.dispatch("cluster.open", Value::Null)?;
        world.sync()?;
        let route = world.state("route");
        expect!(
            at(&route, "section") == "/settings/cluster",
            "the route is {}",
            show(&route)
        );
        Ok(())
    });
    steps.step(
        &format!("the MC can no longer read its cluster, saying {Q}"),
        |world, c, _| {
            fake(world).status_refusal = c[0].clone();
            Ok(())
        },
    );
    steps.step("the MC is slow to read its cluster", |world, _, _| {
        world.mc.hold("cluster.status");
        Ok(())
    });
    steps.step("the user makes a cluster invite", |world, _, _| {
        world.dispatch("cluster.invite", Value::Null)
    });
    steps.step(&format!("the user joins with {Q}"), |world, c, _| {
        world.dispatch("cluster.join", json!({"link": c[0]}))
    });
    steps.step(
        &format!("the user removes {Q} from the cluster"),
        |world, c, _| world.dispatch("cluster.remove", json!({"id": format!("env-{}", c[0])})),
    );
    steps.step(
        "the user sends this machine's version to the other machines",
        |world, _, _| world.dispatch("cluster.update", Value::Null),
    );
    steps.step("the user goes back from settings", |world, _, _| {
        world.dispatch("settings.back", Value::Null)
    });
    steps.step(
        &format!("the user picks the settings section {Q}"),
        |world, c, _| world.dispatch("settings.navigate", json!({"to": c[0]})),
    );
    for (text, method) in [
        ("the MC is asked for its cluster status", "cluster.status"),
        ("the MC is asked for a cluster invite", "cluster.invite"),
        (
            "the MC is asked to update the other machines",
            "cluster.update",
        ),
    ] {
        steps.step(text, move |world, _, _| {
            expect!(
                cluster_call(world, method)?.is_some(),
                "the MC was not asked"
            );
            Ok(())
        });
    }
    steps.step(
        &format!("the MC is asked to join with {Q}"),
        |world, c, _| {
            let payload = cluster_call(world, "cluster.join")?;
            expect!(
                payload.as_ref().is_some_and(|p| text(&p["link"]) == c[0]),
                "the MC was asked {}",
                payload.map_or("nothing".to_owned(), |p| show(&p))
            );
            Ok(())
        },
    );
    steps.step(&format!("the MC is asked to remove {Q}"), |world, c, _| {
        let payload = cluster_call(world, "cluster.remove")?;
        expect!(
            payload.as_ref().is_some_and(|p| text(&p["id"]) == c[0]),
            "the MC was asked {}",
            payload.map_or("nothing".to_owned(), |p| show(&p))
        );
        Ok(())
    });
    steps.step("the invite link is copied", |world, _, _| {
        world.sync()?;
        let link = text(at(&cluster(world), "invite.link"));
        let copied = world.clipboard();
        expect!(
            !link.is_empty() && copied == link,
            "copied \"{copied}\", the invite is {}",
            show(&cluster(world))
        );
        Ok(())
    });
    steps.step("the cluster page shows the invite link", |world, _, _| {
        world.sync()?;
        expect!(
            text(at(&cluster(world), "invite.link")).starts_with("http"),
            "{}",
            page_is(world)
        );
        Ok(())
    });
    steps.step(&format!("the cluster page says {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            text(at(&cluster(world), "notice.text")) == c[0],
            "{}",
            page_is(world)
        );
        Ok(())
    });
    steps.step(
        "the user is warned that only this machine can open the invite",
        |world, _, _| {
            world.sync()?;
            let notice = &cluster(world)["notice"];
            expect!(
                notice["kind"] == "error"
                    && text(&notice["text"]).contains("Only this machine can open it"),
                "{}",
                page_is(world)
            );
            Ok(())
        },
    );
    steps.step("the cluster page lists (.*)", |world, c, _| {
        world.sync()?;
        let member = Regex::new("\"([^\"]*)\" as (connected|offline)").expect("a pattern");
        let page = cluster(world);
        let listed = at(&page, "status.members")
            .as_array()
            .cloned()
            .unwrap_or_default();
        for found in member.captures_iter(&c[0]).flatten() {
            let connected = found.get(2).map_or("", |m| m.as_str()) == "connected";
            let there = listed.iter().any(|row| {
                text(&row["label"]) == found.get(1).map_or("", |m| m.as_str()) && (row["connected"] == json!(true)) == connected
            });
            expect!(there, "{}", page_is(world));
        }
        Ok(())
    });
    steps.step(
        &format!("the cluster page does not list {Q}"),
        |world, c, _| {
            world.sync()?;
            let page = cluster(world);
            for row in at(&page, "status.members")
                .as_array()
                .into_iter()
                .flatten()
            {
                expect!(text(&row["label"]) != c[0], "{}", page_is(world));
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the cluster page shows the error {Q} instead of the machines"),
        |world, c, _| {
            world.sync()?;
            let page = cluster(world);
            expect!(
                text(&page["error"]) == c[0] && page["status"].is_null(),
                "{}",
                page_is(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the cluster page says the session needs administrative access, with nothing to invite or join",
        |world, _, _| {
            world.sync()?;
            let page = cluster(world);
            expect!(
                page["needsAdmin"] == json!(true) && page["error"].is_null() && page["status"].is_null(),
                "{}",
                page_is(world)
            );
            Ok(())
        },
    );
    // A machine that left.
    steps.step(
        "a client lists a machine that has left the cluster",
        |world, _, _| {
            fake(world).members.push(json!({
                "id": "env-laptop",
                "label": "laptop",
                "addresses": [],
                "connected": false,
            }));
            world.connect()?;
            world.wait_for("the shell to start", |w| w.active())?;
            world.dispatch("cluster.open", Value::Null)?;
            world.wait_for("the cluster to be read", |w| {
                !at(&cluster(w), "status.members")
                    .as_array()
                    .is_none_or(Vec::is_empty)
            })
        },
    );
    steps.step("the machine stays listed", |world, _, _| {
        // Read again, it is still a member, shown as offline.
        let reads = fake(world).calls.len();
        world.dispatch("cluster.refresh", Value::Null)?;
        world.wait_for("the cluster to be read again", |w| {
            w.mc.peek::<FakeCluster>()
                .is_some_and(|f| f.calls.len() > reads)
        })?;
        world.sync()?;
        let page = cluster(world);
        let members = at(&page, "status.members")
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            members.len() == 1
                && members[0]["label"] == "laptop"
                && members[0]["connected"] != json!(true),
            "{}",
            page_is(world)
        );
        Ok(())
    });
    steps.step("the user can remove it like any environment", |world, _, _| {
        world.dispatch("cluster.remove", json!({"id": "env-laptop"}))?;
        world.wait_for_with(
            |w| {
                let page = cluster(w);
                at(&page, "status.members")
                    .as_array()
                    .is_none_or(Vec::is_empty)
                    && page["busy"] != json!(true)
            },
            |w| format!("the machine to go; {}", page_is(w)),
        )?;
        let payload = cluster_call(world, "cluster.remove")?;
        expect!(
            payload.is_some_and(|p| p["id"] == "env-laptop")
                && text(at(&cluster(world), "notice.text")) == "Removed laptop from the cluster.",
            "{}",
            page_is(world)
        );
        Ok(())
    });
    steps.step("the cluster page closes", |world, _, _| {
        world.sync()?;
        let route = world.state("route");
        expect!(
            at(&route, "section") != "/settings/cluster",
            "the route is {}",
            show(&route)
        );
        Ok(())
    });
}

