//! The Open source licenses page (the licenses controller, the
//! OpenSourceLicenses brick): the @desktop scenarios of
//! features/settings/licenses.feature, desktop-qt's LicensesSteps.cpp. The
//! manifest is a fixture written to the scenario's home, shaped as
//! scripts/lib/third-party-licenses.ts writes it.

use hal_c2_shell::controllers::licenses::{self, SECTION};
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

struct Notice {
    name: &'static str,
    version: &'static str,
    license: &'static str,
    bundles: &'static [&'static str],
}

// Enough to tell the fields apart: no name, version or license holds another
// field's query.
const NOTICES: &[Notice] = &[
    Notice {
        name: "react",
        version: "19.1.0",
        license: "MIT",
        bundles: &["web"],
    },
    Notice {
        name: "effect",
        version: "4.0.0-beta.1",
        license: "MIT",
        bundles: &["web", "server"],
    },
    Notice {
        name: "@effect/platform-node",
        version: "4.0.0-beta.1",
        license: "MIT",
        bundles: &["server"],
    },
    Notice {
        name: "yaml",
        version: "2.8.1",
        license: "ISC",
        bundles: &["web"],
    },
    Notice {
        name: "Qt",
        version: "",
        license: "LGPL-3.0-only",
        bundles: &["desktop-qt"],
    },
    Notice {
        name: "MesloLGS NF",
        version: "",
        license: "Apache-2.0",
        bundles: &["android", "assets", "mobile"],
    },
    Notice {
        name: "agent-device",
        version: "0.21.7",
        license: "MIT",
        bundles: &["device-tools"],
    },
    Notice {
        name: "expo-device-hub",
        version: "0.10.1",
        license: "MIT AND Apache-2.0 AND BSD-3-Clause",
        bundles: &["device-tools"],
    },
];

fn notice_text(notice: &Notice) -> String {
    format!("{} license text for {}.", notice.license, notice.name)
}

fn manifest_path(world: &World) -> std::path::PathBuf {
    world.home_dir().join("third-party-licenses.json")
}

fn write_manifest(world: &World) -> Outcome {
    let entries: Vec<Json> = NOTICES
        .iter()
        .map(|notice| {
            let custom = notice.bundles.contains(&"device-tools") || notice.version.is_empty();
            let mut entry = json!({
                "kind": if custom { "custom" } else { "package" },
                "name": notice.name,
                "license": notice.license,
                "bundles": notice.bundles,
                "noticeText": notice_text(notice),
            });
            if !notice.version.is_empty() {
                entry["version"] = json!(notice.version);
            }
            entry
        })
        .collect();
    let path = manifest_path(world);
    std::fs::write(
        &path,
        json!({"schemaVersion": 1, "entries": entries}).to_string(),
    )
    .map_err(|e| Failure(format!("cannot write {}: {e}", path.display())))
}

/// Whether the scenario's manifest is missing ("the license list cannot be
/// loaded"), kept on the scenario's MC.
#[derive(Default)]
struct Fixture {
    broken: bool,
    written: bool,
}

fn licenses_state(world: &World) -> Json {
    world.state("licenses")
}

fn listed(world: &World) -> Vec<Json> {
    at(&licenses_state(world), "entries")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The page as the desktop draws it. Its root also has `inside`, finding an
/// item by name among another's descendants.
fn page(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nOpenSourceLicenses {\n\
         anchors.fill: parent\n\
         function inside(item, name) {\n\
           var kids = item.children || []\n\
           for (var i = 0; i < kids.length; i++) {\n\
             if (kids[i].objectName === name) return kids[i]\n\
             var found = inside(kids[i], name)\n\
             if (found) return found\n\
           }\n\
           return null\n\
         }\n}\n",
        760.0,
        4000.0,
    )?;
    crate::brick::shown(world)
}

fn text_of(world: &mut World, object_name: &str) -> Outcome<String> {
    let brick = page(world)?;
    let item = brick.item(world, object_name)?;
    Ok(brick.text_of(world, item, "text"))
}

fn open(world: &mut World) -> Outcome {
    licenses::set_manifest_path(world.engine(), &manifest_path(world));
    let fixture = world.mc.part::<Fixture>();
    if !fixture.broken && !fixture.written {
        fixture.written = true;
        write_manifest(world)?;
    }
    if world.shell_subscriptions() == 0 {
        // The shell starts once an MC has answered, even one since gone.
        world.connect()?;
        world.sync()?;
    }
    world.dispatch("settings.open", Json::Null)?;
    world.dispatch("settings.navigate", json!({"to": SECTION}))?;
    world.wait_for_with(
        |w| at(&w.state("route"), "section") == SECTION,
        |w| {
            format!(
                "the licenses page to open; the route is {}",
                show(&w.state("route"))
            )
        },
    )?;
    page(world)?;
    Ok(())
}

fn shown(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| at(&licenses_state(w), "status") == "ready",
        |w| format!("the notices to load; they are {}", show(&licenses_state(w))),
    )?;
    expect!(
        listed(world).len() == NOTICES.len(),
        "{} notices are listed",
        listed(world).len()
    );
    let brick = page(world)?;
    let react = brick.item(world, "license:react")?;
    expect!(brick.flag(world, react, "visible"), "react is not drawn");
    Ok(())
}

/// The item named `name` inside `item`.
fn inside(world: &mut World, item: ObjectId, name: &str) -> Outcome<ObjectId> {
    let brick = page(world)?;
    let root = brick.root(world).ok_or_else(|| Failure("no page".into()))?;
    let found = world
        .engine()
        .invoke_by_name(root, "inside", &[Value::Object(item), Value::from(name)])
        .map_err(|e| Failure(format!("inside: {e:?}")))?;
    match found {
        Value::Object(found) => Ok(found),
        _ => {
            let owner = brick.text_of(world, item, "objectName");
            fail!("{owner} has no {name}")
        }
    }
}

/// A row's `modelData`, as JSON.
fn model_data(world: &mut World, name: &str) -> Outcome<Json> {
    let brick = page(world)?;
    let row = brick.item(world, &format!("license:{name}"))?;
    Ok(hal_c2_shell::json::from_value(
        world.engine(),
        &brick.read(world, row, "modelData"),
    ))
}

fn search(world: &mut World, query: &str) -> Outcome {
    world.dispatch("licenses.search", json!({"query": query}))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user (?:has opened|opens|views) the open source licenses",
        |world, _, _| open(world),
    );
    steps.step("the license list cannot be loaded", |world, _, _| {
        world.mc.part::<Fixture>().broken = true;
        Ok(())
    });
    steps.step("the list of third-party notices is shown", |world, _, _| {
        shown(world)
    });
    steps.step("\"General\" stays marked as the current section", |world, _, _| {
        // What the settings navigation marks for the route (SettingsNav.currentSection).
        let marked = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Shell\nimport \"qrc:/hal-c2/settings/settingsPages.js\" as Pages\n\
             Item { property string current: Pages.current(Shell.state.route.section) }\n",
            10.0,
            10.0,
        )?;
        let root = marked
            .root(world)
            .ok_or_else(|| Failure("no root".into()))?;
        let current = marked.text_of(world, root, "current");
        expect!(
            current == "/settings/general",
            "the navigation marks {current}"
        );
        Ok(())
    });

    steps.step(
        "each entry shows its version when known, its license identifier and the parts of HAL-C2 that use it",
        |world, _, _| {
            shown(world)?;
            for notice in NOTICES {
                let entry = model_data(world, notice.name)?;
                let version_ok = if notice.version.is_empty() {
                    entry["version"].is_null()
                } else {
                    entry["version"] == notice.version
                };
                expect!(
                    version_ok,
                    "{}'s version is {}",
                    notice.name,
                    show(&entry)
                );
                expect!(entry["license"] == notice.license, "{}", show(&entry));
            }
            let meslo = model_data(world, "MesloLGS NF")?;
            expect!(meslo["where"] == "Android, Assets, Mobile", "{}", show(&meslo));
            let qt = model_data(world, "Qt")?;
            expect!(qt["where"] == "Qt desktop", "{}", show(&qt));
            Ok(())
        },
    );

    steps.step(&format!("the user opens the entry {Q}"), |world, c, _| {
        shown(world)?;
        let brick = page(world)?;
        let row = brick.item(world, &format!("license:{}", c[0]))?;
        let toggle = inside(world, row, "toggle")?;
        let (x, y) = brick.at(world, toggle, 0.5, 0.5)?;
        world.click_at(x, y)?;
        world.sync()
    });
    steps.step(
        &format!("the complete notice text for {Q} is shown"),
        |world, c, _| {
            let Some(notice) = NOTICES.iter().find(|n| n.name == c[0]) else {
                fail!("{} is not a notice of the fixture", c[0]);
            };
            let wanted = notice_text(notice);
            let want = wanted.clone();
            world.wait_for_with(
                move |w| text(at(&licenses_state(w), "noticeText")) == want,
                |w| {
                    format!(
                        "the notice to open; the page is {}",
                        show(&licenses_state(w))
                    )
                },
            )?;
            let brick = page(world)?;
            let row = brick.item(world, &format!("license:{}", c[0]))?;
            let shown_text = inside(world, row, "noticeText")?;
            expect!(
                brick.flag(world, shown_text, "visible")
                    && brick.text_of(world, shown_text, "text") == wanted,
                "the notice text is not drawn"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the user searches the licenses for {Q}"),
        |world, c, _| {
            shown(world)?;
            search(world, &c[0])
        },
    );
    steps.step(
        &format!("only entries whose (package name|license|app component) matches {Q} are listed"),
        |world, c, _| {
            let query = c[1].to_lowercase();
            let want = c[1].clone();
            world.wait_for("the search to apply", move |w| {
                at(&licenses_state(w), "query") == want.as_str()
            })?;
            let entries = listed(world);
            expect!(
                !entries.is_empty() && entries.len() < NOTICES.len(),
                "{} entries are listed",
                entries.len()
            );
            for entry in entries {
                let field = match c[0].as_str() {
                    "package name" => text(&entry["name"]),
                    "license" => text(&entry["license"]),
                    _ => text(&entry["where"]),
                };
                expect!(
                    field.to_lowercase().contains(&query),
                    "{} is listed",
                    show(&entry)
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the page shows how many of the notices match",
        |world, _, _| {
            let count = text_of(world, "licenseCount")?;
            let wanted = format!("{} of {}", listed(world).len(), NOTICES.len());
            expect!(count == wanted, "the count reads {count}");
            Ok(())
        },
    );
    steps.step(
        "the user is told no licenses match that search",
        |world, _, _| {
            world.wait_for_with(|w| listed(w).is_empty(), |w| show(&licenses_state(w)))?;
            let brick = page(world)?;
            let none = brick.item(world, "noLicenseMatch")?;
            expect!(
                brick.flag(world, none, "visible")
                    && brick.text_of(world, none, "text") == "No licenses match that search.",
                "no match is not said"
            );
            Ok(())
        },
    );

    steps.step(
        "the device tools HAL-C2 installs on demand are listed",
        |world, _, _| {
            shown(world)?;
            for name in ["agent-device", "expo-device-hub"] {
                let entry = model_data(world, name)?;
                expect!(entry["where"] == "Device tools", "{}", show(&entry));
            }
            Ok(())
        },
    );

    steps.step(
        "the user is told the open source notices are unavailable",
        |world, _, _| {
            world.wait_for_with(
                |w| at(&licenses_state(w), "status") == "error",
                |w| show(&licenses_state(w)),
            )?;
            let brick = page(world)?;
            let error = brick.item(world, "licensesError")?;
            expect!(
                brick.flag(world, error, "visible"),
                "the failure is not drawn"
            );
            Ok(())
        },
    );
    steps.step("the user tries again and the list loads", |world, _, _| {
        let fixture = world.mc.part::<Fixture>();
        fixture.broken = false;
        fixture.written = true;
        write_manifest(world)?;
        let brick = page(world)?;
        brick.click(world, "licensesRetry")?;
        world.sync()
    });
}
