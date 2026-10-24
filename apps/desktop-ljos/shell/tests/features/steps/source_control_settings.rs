//! The Source Control settings section (desktop-qt's
//! SourceControlSettingsSteps.cpp): the discovery scenarios of
//! settings/source-control.feature. The fake answers
//! `server.discoverSourceControl` with the tools a scenario gives the
//! machine.
//!
//! TODO(port): the fetch interval and writing-style scenarios save through
//! FakeConfig (`settings.rs`, ported by another worker), so their steps wait
//! for it: the fetch interval, the writing style, change request templates
//! and the writer model.

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

fn some(value: &str) -> Value {
    json!({"_tag": "Some", "value": value})
}

fn none() -> Value {
    json!({"_tag": "None"})
}

fn tool(kind: &str, label: &str, executable: &str, available: bool) -> Value {
    json!({
        "kind": kind,
        "label": label,
        "executable": executable,
        "installHint": format!("Install {label} and make sure `{executable}` is on the PATH."),
        "status": if available { "available" } else { "missing" },
        "version": if available { some("2.45.0") } else { none() },
        "detail": none(),
    })
}

fn host_item(
    kind: &str,
    label: &str,
    executable: &str,
    available: bool,
    auth: &str,
    account: &str,
) -> Value {
    let mut item = tool(kind, label, executable, available);
    item.as_object_mut().map(|o| o.remove("detail"));
    item["auth"] = json!({
        "status": if available { auth } else { "unknown" },
        "account": if account.is_empty() { none() } else { some(account) },
        "host": none(),
        "detail": none(),
    });
    item
}

struct FakeSourceControl {
    version_control: Vec<Value>,
    hosts: Vec<Value>,
    refusal: String,
}

impl Default for FakeSourceControl {
    fn default() -> Self {
        let mut git = tool("git", "Git", "git", true);
        git["implemented"] = json!(true);
        let mut jj = tool("jj", "Jujutsu", "jj", true);
        jj["implemented"] = json!(false);
        FakeSourceControl {
            version_control: vec![git, jj],
            hosts: vec![
                host_item("github", "GitHub", "gh", true, "authenticated", "octocat"),
                host_item("gitlab", "GitLab", "glab", false, "unknown", ""),
                host_item("bitbucket", "Bitbucket", "", true, "unknown", ""),
            ],
            refusal: String::new(),
        }
    }
}

impl FakeSourceControl {
    fn set_host(&mut self, entry: Value) {
        let kind = entry["kind"].clone();
        match self.hosts.iter_mut().find(|h| h["kind"] == kind) {
            Some(host) => *host = entry,
            None => self.hosts.push(entry),
        }
    }
}

/// Makes the source control host `kind` ("gitlab") of the fake's
/// `server.discoverSourceControl` installed and signed in, or missing.
pub fn set_source_control_host(mc: &mut FakeMc, kind: &str, ready: bool) {
    let (label, executable) = match kind {
        "github" => ("GitHub", "gh"),
        "gitlab" => ("GitLab", "glab"),
        "bitbucket" => ("Bitbucket", ""),
        _ => ("", ""),
    };
    let entry = host_item(
        kind,
        label,
        executable,
        ready,
        if ready { "authenticated" } else { "unknown" },
        if ready { "sam" } else { "" },
    );
    mc.part::<FakeSourceControl>().set_host(entry);
}

fn extend(mc: &mut FakeMc) {
    mc.on_rpc("server.discoverSourceControl", |mc, rpc| {
        let fake = mc.part::<FakeSourceControl>();
        if !fake.refusal.is_empty() {
            let refusal = fake.refusal.clone();
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        let result = json!({
            "versionControlSystems": fake.version_control,
            "sourceControlProviders": fake.hosts,
        });
        mc.reply(rpc, result);
        Ok(())
    });
}

fn fake(world: &mut World) -> &mut FakeSourceControl {
    world.mc.part::<FakeSourceControl>()
}

fn section(world: &World) -> Value {
    world.state("sourceControlSettings")
}

fn found(world: &World) -> Value {
    at(&section(world), "discovery").clone()
}

fn send(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(&format!("sourceControlSettings.{action}"), payload)
}

/// The tool of `kind` the section lists, null while it does not.
fn listed(world: &World, kind: &str) -> Value {
    let discovery = found(world);
    ["versionControl", "providers"]
        .iter()
        .filter_map(|group| discovery[group].as_array())
        .flatten()
        .find(|entry| entry["kind"] == kind)
        .cloned()
        .unwrap_or(Value::Null)
}

/// A scan of the machine as the scenario now has it, once it answers.
fn scan(world: &mut World) -> Outcome {
    send(world, "scan", Value::Null)?;
    world.wait_for_with(
        |w| {
            let discovery = found(w);
            let status = discovery["status"].as_str().unwrap_or_default();
            discovery["scanning"].as_bool() != Some(true)
                && (status == "ready" || status == "error")
        },
        |w| format!("the scan to finish; the section is {}", show(&section(w))),
    )
}

fn open(world: &mut World) -> Outcome {
    // TODO(port): desktop-qt gives the MC's config two providers (FakeConfig)
    // and waits for the settings scope to be editable.
    world.connect()?;
    world.sync()?;
    world.with::<Navigation, _>(|n, engine| {
        n.open(engine, Route::Settings("/settings/source-control".into()))
    })?;
    world.wait_for_with(
        |w| {
            let section = section(w);
            section["open"].as_bool() == Some(true) && at(&section, "discovery.status") == "ready"
        },
        |w| {
            format!(
                "source control settings to show; they are {}",
                show(&section(w))
            )
        },
    )
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    steps.step(
        "the user is connected to an environment and opens Settings, Source Control",
        |world, _, _| open(world),
    );

    steps.step("the panel loads", |world, _, _| {
        // Settings, SnapShots loads on its own, as it opens (SnapShotSteps).
        if at(&world.state("route"), "section") == "/settings/snap-shot" {
            return Ok(());
        }
        scan(world)
    });
    steps.step(
        "each version control and hosting tool is listed as available, missing or status unknown",
        |world, _, _| {
            let found = found(world);
            expect!(
                listed(world, "git")["available"] == true,
                "Git to be available; {}",
                show(&found)
            );
            expect!(
                !listed(world, "gitlab").is_null() && listed(world, "gitlab")["available"] != true,
                "GitLab to be missing; {}",
                show(&found)
            );
            expect!(
                listed(world, "bitbucket")["authLabel"] == "Status unknown",
                "Bitbucket's status to be unknown; {}",
                show(&found)
            );
            expect!(
                listed(world, "github")["authLabel"] == "Authenticated",
                "GitHub to be authenticated; {}",
                show(&found)
            );
            Ok(())
        },
    );
    steps.step("each available tool shows its version", |world, _, _| {
        for kind in ["git", "github"] {
            expect!(
                listed(world, kind)["version"] == "2.45.0",
                "{kind} to show its version; {}",
                show(&found(world))
            );
        }
        let missing = listed(world, "gitlab");
        expect!(
            missing["version"].as_str().unwrap_or_default().is_empty(),
            "a missing tool to show none"
        );
        Ok(())
    });
    steps.step(
        &format!("the GitHub CLI is signed in as {Q}"),
        |world, c, _| {
            fake(world).set_host(host_item(
                "github",
                "GitHub",
                "gh",
                true,
                "authenticated",
                &c[0],
            ));
            scan(world)
        },
    );
    steps.step(
        &format!("GitHub reads {Q} without the account name"),
        |world, c, _| {
            let github = listed(world, "github");
            expect!(
                github["summary"] == c[0].as_str()
                    && github["hasAccount"] == true
                    && github["account"].as_str().unwrap_or_default().is_empty(),
                "GitHub to read {} and keep its account hidden; it is {}",
                c[0],
                show(&github)
            );
            Ok(())
        },
    );
    steps.step("the user reveals the account", |world, _, _| {
        send(world, "reveal", json!({"kind": "github", "revealed": true}))
    });
    steps.step(&format!("the account {Q} is shown"), |world, c, _| {
        let account = c[0].clone();
        world.wait_for_with(
            |w| listed(w, "github")["account"] == account.as_str(),
            |w| {
                format!(
                    "{account} to show; GitHub is {}",
                    show(&listed(w, "github"))
                )
            },
        )
    });
    steps.step("the user revealed the GitHub account", |world, _, _| {
        send(world, "reveal", json!({"kind": "github", "revealed": true}))?;
        world.wait_for_with(
            |w| listed(w, "github")["account"] == "octocat",
            |w| {
                format!(
                    "the account to show; GitHub is {}",
                    show(&listed(w, "github"))
                )
            },
        )
    });
    steps.step("the user hides it", |world, _, _| {
        send(
            world,
            "reveal",
            json!({"kind": "github", "revealed": false}),
        )
    });
    steps.step("the account name is hidden again", |world, _, _| {
        world.wait_for_with(
            |w| {
                let github = listed(w, "github");
                github["hasAccount"] == true
                    && github["account"].as_str().unwrap_or_default().is_empty()
            },
            |w| {
                format!(
                    "the account to hide; GitHub is {}",
                    show(&listed(w, "github"))
                )
            },
        )
    });
    steps.step(
        "the GitHub CLI is installed but not signed in",
        |world, _, _| {
            fake(world).set_host(host_item(
                "github",
                "GitHub",
                "gh",
                true,
                "unauthenticated",
                "",
            ));
            Ok(())
        },
    );
    steps.step(
        &format!("GitHub reads {Q} with how to sign in"),
        |world, c, _| {
            let github = listed(world, "github");
            let summary = github["summary"].as_str().unwrap_or_default();
            expect!(
                github["authLabel"] == c[0].as_str()
                    && github["authWarning"] == true
                    && summary.contains("Sign in")
                    && summary.contains("`gh`"),
                "GitHub to read {} with how to sign in; it is {}",
                c[0],
                show(&github)
            );
            Ok(())
        },
    );
    steps.step("the GitLab CLI is not installed", |world, _, _| {
        fake(world).set_host(host_item("gitlab", "GitLab", "glab", false, "unknown", ""));
        Ok(())
    });
    steps.step(
        "GitLab is shown as missing with its install instructions",
        |world, _, _| {
            let gitlab = listed(world, "gitlab");
            expect!(
                !gitlab.is_null()
                    && gitlab["available"] != true
                    && gitlab["summary"]
                        .as_str()
                        .unwrap_or_default()
                        .contains("Install GitLab"),
                "GitLab to be missing with how to install it; it is {}",
                show(&gitlab)
            );
            Ok(())
        },
    );
    steps.step(
        "the GitHub CLI was missing when the panel loaded",
        |world, _, _| {
            fake(world).set_host(host_item("github", "GitHub", "gh", false, "unknown", ""));
            scan(world)?;
            expect!(
                listed(world, "github")["available"] != true,
                "GitHub to be missing"
            );
            Ok(())
        },
    );
    steps.step(
        "the user has since installed and signed in to it",
        |world, _, _| {
            fake(world).set_host(host_item(
                "github",
                "GitHub",
                "gh",
                true,
                "authenticated",
                "octocat",
            ));
            Ok(())
        },
    );
    steps.step(
        "the user rescans Git and hosting integrations",
        |world, _, _| scan(world),
    );
    steps.step(&format!("GitHub reads {Q}"), |world, c, _| {
        let label = c[0].clone();
        world.wait_for_with(
            |w| listed(w, "github")["authLabel"] == label.as_str(),
            |w| {
                format!(
                    "GitHub to read {label}; it is {}",
                    show(&listed(w, "github"))
                )
            },
        )
    });
    steps.step(
        "the environment has no version control or hosting tools",
        |world, _, _| {
            let fake = fake(world);
            fake.version_control.clear();
            fake.hosts.clear();
            Ok(())
        },
    );
    steps.step(
        "the user is told nothing was detected yet and to install Git on the server and rescan",
        |world, _, _| {
            let discovery = found(world);
            let detail = discovery["detail"].as_str().unwrap_or_default();
            expect!(
                discovery["title"] == "Nothing detected yet"
                    && detail.starts_with("Install Git on the server")
                    && detail.ends_with("then rescan."),
                "to be told nothing was detected; the section shows {}",
                show(&discovery)
            );
            Ok(())
        },
    );
    steps.step("the scan fails", |world, _, _| {
        fake(world).refusal = "The MC could not run the scan.".into();
        Ok(())
    });
    steps.step(
        "hosts HAL-C2 cannot use yet are marked \"Coming Soon\"",
        |world, _, _| {
            let jj = listed(world, "jj");
            if !(jj["comingSoon"] == true && jj["summary"] == "Support for Jujutsu is coming soon.")
            {
                fail!("Jujutsu to be coming soon; {}", show(&found(world)));
            }
            expect!(
                listed(world, "git")["comingSoon"] != true,
                "Git to be usable"
            );
            Ok(())
        },
    );
}
