//! The Source Control settings section (desktop-qt's
//! SourceControlSettingsSteps.cpp): the discovery scenarios of
//! settings/source-control.feature. The fake answers
//! `server.discoverSourceControl` with the tools a scenario gives the
//! machine; the fetch interval and writing-style scenarios check what the
//! section saves through FakeConfig.
//!

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::steps::settings::{document_of, fake_config, publish_providers, save_elsewhere};
use crate::steps::settings_scoped_rows::held_all;
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
    /// The writing style the scenario picked.
    mode: String,
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
            mode: String::new(),
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

fn provider(instance: &str, name: &str, model: &str, enabled: bool) -> Value {
    json!({
        "instanceId": instance,
        "driver": instance,
        "displayName": name,
        "enabled": enabled,
        "installed": true,
        "status": "ready",
        "auth": {"status": "authenticated"},
        "models": [{"slug": model, "name": model}],
    })
}

/// What the MC has saved of the settings.
fn saved(world: &World) -> Value {
    held_all(world)
}

fn style(settings: &Value) -> &Value {
    &settings["sourceControlWritingStyle"]
}

fn wait_saved(world: &mut World, what: &str, done: impl Fn(&Value) -> bool) -> Outcome {
    world.wait_for_with(
        |w| done(&saved(w)),
        |w| format!("{what}; the settings are {}", show(&saved(w))),
    )
}

/// The background activity's fetch interval override in ms, -1 without one.
fn fetch_override(settings: &Value) -> i64 {
    settings["backgroundActivity"]["overrides"]["automaticGitFetchInterval"]
        .as_f64()
        .map_or(-1, |ms| ms as i64)
}

fn part_of(world: &World, key: &str) -> Value {
    section(world)[key].clone()
}

fn set_interval(world: &mut World, seconds: i64) -> Outcome {
    send(world, "fetchInterval", json!({"seconds": seconds}))?;
    wait_saved(
        world,
        &format!("a {seconds} second fetch interval to be saved"),
        move |settings| fetch_override(settings) == seconds * 1000,
    )?;
    world.wait_for_with(
        |w| part_of(w, "fetchInterval")["seconds"].as_i64() == Some(seconds),
        |w| {
            format!(
                "the interval to show {seconds} seconds; it is {}",
                show(&part_of(w, "fetchInterval"))
            )
        },
    )
}

fn mode_of(label: &str) -> String {
    match label {
        "Repository conventions" => "repo_conventions".into(),
        "Conventional Commits" => "conventional_commits".into(),
        "Custom instructions" => "custom".into(),
        other => other.into(),
    }
}

fn writer_key(settings: &Value) -> String {
    let selection = &settings["sourceControlWriterModelSelection"];
    if selection.as_object().is_none_or(|o| o.is_empty()) {
        return String::new();
    }
    format!(
        "{}:{}",
        selection["instanceId"].as_str().unwrap_or_default(),
        selection["model"].as_str().unwrap_or_default()
    )
}

const INSTRUCTIONS: &str = "Keep titles under 50 characters.";

fn open(world: &mut World) -> Outcome {
    fake_config(&mut world.mc).config.insert(
        "providers".into(),
        json!([
            provider("codex", "Codex", "codex-model", true),
            provider("claude", "Claude", "claude-model", true)
        ]),
    );
    world.connect()?;
    world.sync()?;
    world.with::<Navigation, _>(|n, engine| {
        n.open(engine, Route::Settings("/settings/source-control".into()))
    })?;
    world.wait_for_with(
        |w| {
            let section = section(w);
            section["open"].as_bool() == Some(true)
                && at(&section, "discovery.status") == "ready"
                && w.state("settingsScope")["editable"] == true
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

    steps.step(
        "the user sets the automatic Git fetch interval to (\\d+) seconds",
        |world, c, _| {
            send(
                world,
                "fetchInterval",
                json!({"seconds": c[0].parse::<i64>().unwrap_or(0)}),
            )
        },
    );
    steps.step(
        "Git fetches every (\\d+) seconds while a thread is on screen",
        |world, c, _| {
            let seconds: i64 = c[0].parse().unwrap_or(0);
            wait_saved(
                world,
                &format!("a {seconds} second fetch interval to be saved"),
                move |settings| fetch_override(settings) == seconds * 1000,
            )?;
            world.wait_for_with(
                |w| part_of(w, "fetchInterval")["seconds"].as_i64() == Some(seconds),
                |w| {
                    format!(
                        "the interval to show; it is {}",
                        show(&part_of(w, "fetchInterval"))
                    )
                },
            )
        },
    );
    steps.step(
        "the user set the automatic Git fetch interval to (\\d+) seconds",
        |world, c, _| set_interval(world, c[0].parse().unwrap_or(0)),
    );
    steps.step("the user resets the fetch interval", |world, _, _| {
        send(world, "resetFetchInterval", Value::Null)
    });
    steps.step(
        "the interval follows the background activity profile again",
        |world, _, _| {
            wait_saved(world, "the fetch override to go", |s| fetch_override(s) < 0)?;
            world.wait_for_with(
                |w| {
                    let interval = part_of(w, "fetchInterval");
                    interval["custom"] != true && interval["seconds"] == interval["preset"]
                },
                |w| {
                    format!(
                        "the interval to follow its preset; it is {}",
                        show(&part_of(w, "fetchInterval"))
                    )
                },
            )
        },
    );
    steps.step("Git never fetches in the background", |world, _, _| {
        wait_saved(world, "fetching to be turned off", |s| {
            fetch_override(s) == 0
        })
    });

    // source-control-writing.feature
    steps.step(
        &format!("the user picks the writing style {Q}"),
        |world, c, _| {
            let mode = mode_of(&c[0]);
            fake(world).mode = mode.clone();
            send(world, "writingMode", json!({"mode": mode}))
        },
    );
    steps.step(&format!("the panel explains {Q}"), |world, c, _| {
        let said = c[0].clone();
        world.wait_for_with(
            |w| part_of(w, "writingStyle")["description"] == said.as_str(),
            |w| {
                format!(
                    "the style to be explained; it is {}",
                    show(&part_of(w, "writingStyle"))
                )
            },
        )
    });
    steps.step(
        "generated commits and pull requests follow that style",
        |world, _, _| {
            let mode = fake(world).mode.clone();
            wait_saved(world, &format!("the {mode} style to be saved"), move |s| {
                style(s)["mode"] == mode.as_str()
            })
        },
    );
    steps.step("the writing style is Custom instructions", |world, _, _| {
        save_elsewhere(
            &mut world.mc,
            "sourceControlWritingStyle",
            json!({"mode": "custom"}),
            false,
        );
        world.wait_for_with(
            |w| part_of(w, "writingStyle")["mode"] == "custom",
            |w| {
                format!(
                    "the custom style to show; it is {}",
                    show(&part_of(w, "writingStyle"))
                )
            },
        )
    });
    steps.step(
        &format!("the user writes {Q} as the instructions"),
        |world, c, _| send(world, "instructions", json!({"text": c[0]})),
    );
    steps.step(
        "generated commits and pull requests follow those instructions",
        |world, _, _| {
            wait_saved(world, "the instructions to be saved", |s| {
                style(s)["mode"] == "custom" && style(s)["customInstructions"] == INSTRUCTIONS
            })
        },
    );
    steps.step(
        "the settings scope covers two environments",
        |world, _, _| {
            // A server whose style differs, so the instructions are one for both.
            document_of(&mut world.mc, "server").settings.insert(
                "sourceControlWritingStyle".into(),
                json!({"mode": "conventional_commits"}),
            );
            world.mc.join_named("server");
            world.wait_for_with(
                |w| {
                    w.state("settingsScope")["environments"]
                        .as_array()
                        .is_some_and(|e| e.len() == 2)
                },
                |w| {
                    format!(
                        "two environments; the scope is {}",
                        show(&w.state("settingsScope"))
                    )
                },
            )?;
            world.dispatch("settingsScope.environment", json!({"id": ""}))?;
            world.wait_for_with(
                |w| {
                    SettingsScope::of(w.engine()).targets().len() == 2
                        && part_of(w, "writingStyle")["mixed"] == true
                },
                |w| {
                    format!(
                        "both environments' styles, mixed; the section is {}",
                        show(&section(w))
                    )
                },
            )
        },
    );
    steps.step("the user writes custom instructions", |world, _, _| {
        send(world, "instructions", json!({"text": INSTRUCTIONS}))
    });
    steps.step("both environments use those instructions", |world, _, _| {
        let custom = |s: &Value| {
            style(s)["mode"] == "custom" && style(s)["customInstructions"] == INSTRUCTIONS
        };
        world.wait_for_with(
            |w| {
                let server =
                    w.mc.peek::<crate::steps::settings::FakeConfig>()
                        .and_then(|f| f.documents.get("server"))
                        .map_or(Value::Null, |d| Value::Object(d.settings.clone()));
                custom(&saved(w)) && custom(&server)
            },
            |w| format!("both to use the instructions; here {}", show(&saved(w))),
        )
    });
    steps.step(
        "following change request templates is shown on",
        |world, _, _| {
            world.wait_for_with(
                |w| part_of(w, "templates")["value"] == true,
                |w| {
                    format!(
                        "templates to be shown followed; the row is {}",
                        show(&part_of(w, "templates"))
                    )
                },
            )
        },
    );
    steps.step(
        "the environment's settings leave templates followed",
        |world, _, _| {
            // Absent means followed: the MC writes to a repository's template unless told not to.
            let saved = saved(world);
            expect!(
                style(&saved)["followChangeRequestTemplates"] != false,
                "the environment to follow templates; its settings are {}",
                show(&saved)
            );
            Ok(())
        },
    );
    steps.step(
        "the user turns off following change request templates",
        |world, _, _| send(world, "templates", json!({"enabled": false})),
    );
    steps.step(
        "pull request descriptions are written without the repository's template",
        |world, _, _| {
            wait_saved(world, "templates to be turned off", |s| {
                style(s)["followChangeRequestTemplates"] == false
            })?;
            world.wait_for_with(
                |w| part_of(w, "templates")["value"] != true,
                |w| {
                    format!(
                        "the row to be off; it is {}",
                        show(&part_of(w, "templates"))
                    )
                },
            )
        },
    );
    steps.step(
        "the user turns on a separate source control writer model and picks one",
        |world, _, _| {
            send(world, "writerModel", json!({"enabled": true}))?;
            wait_saved(world, "a writer model to be saved", |s| {
                !writer_key(s).is_empty()
            })?;
            send(
                world,
                "pickWriterModel",
                json!({"key": "claude:claude-model"}),
            )
        },
    );
    steps.step(
        "commits, pull requests and branch names are written by that model",
        |world, _, _| {
            wait_saved(world, "Claude to write source control text", |s| {
                writer_key(s) == "claude:claude-model"
            })
        },
    );
    steps.step(
        "a separate source control writer model is on",
        |world, _, _| {
            save_elsewhere(
                &mut world.mc,
                "sourceControlWriterModelSelection",
                json!({"instanceId": "codex", "model": "codex-model"}),
                false,
            );
            world.wait_for_with(
                |w| part_of(w, "writerModel")["on"] == true,
                |w| {
                    format!(
                        "the writer model to be on; it is {}",
                        show(&part_of(w, "writerModel"))
                    )
                },
            )
        },
    );
    steps.step("the user turns it off", |world, _, _| {
        send(world, "writerModel", json!({"enabled": false}))
    });
    steps.step(
        "the environment's text generation model writes source control text again",
        |world, _, _| {
            wait_saved(world, "the writer model to be off", |s| {
                s["sourceControlWriterModelSelection"].is_null()
            })
        },
    );
    steps.step("the provider of a model is turned off", |world, _, _| {
        publish_providers(
            &mut world.mc,
            vec![
                provider("codex", "Codex", "codex-model", true),
                provider("claude", "Claude", "claude-model", false),
            ],
        );
        Ok(())
    });
    steps.step(
        "the user looks at the writer model choices",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    part_of(w, "writerModel")["models"]
                        .as_array()
                        .is_some_and(|models| {
                            models
                                .iter()
                                .any(|m| !m["reason"].as_str().unwrap_or_default().is_empty())
                        })
                },
                |w| {
                    format!(
                        "a model to be unusable; the choices are {}",
                        show(&part_of(w, "writerModel"))
                    )
                },
            )
        },
    );
    steps.step(
        "that model cannot be picked and the reason is shown",
        |world, _, _| {
            let reason = part_of(world, "writerModel")["models"]
                .as_array()
                .and_then(|models| models.iter().find(|m| m["key"] == "claude:claude-model"))
                .and_then(|m| m["reason"].as_str().map(str::to_owned))
                .unwrap_or_default();
            expect!(
                reason == "Claude is turned off.",
                "Claude's model to say why; it says \"{reason}\""
            );
            let writes = fake_config(&mut world.mc).writes.len();
            send(
                world,
                "pickWriterModel",
                json!({"key": "claude:claude-model"}),
            )?;
            world.sync()?;
            expect!(
                fake_config(&mut world.mc).writes.len() == writes,
                "picking it to save nothing"
            );
            Ok(())
        },
    );
    steps.step("saving settings fails", |world, _, _| {
        fake_config(&mut world.mc).refuse_writes = "The settings file is read-only.".into();
        Ok(())
    });
    steps.step("the user picks a writer model", |world, _, _| {
        send(
            world,
            "pickWriterModel",
            json!({"key": "codex:codex-model"}),
        )
    });
}
