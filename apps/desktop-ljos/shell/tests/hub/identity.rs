//! `identity`: projects' and environments' icons, and the project icon
//! picker (IdentityController.cpp, features/files/project-identity.feature).

use hal_c2_shell::controllers::sidebar;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const AT: &str = "2026-03-01T00:00:00Z";
const CREATE_URL: &str = "assets.createUrl";
const READ: &str = "hal-c2.readSettings";
const WRITE: &str = "hal-c2.writeSettings";
const SESSION: &str = "GET /api/auth/session";
const SEARCH: &str = "projects.searchEntries";

/// What the laptop (`env-1`) serves of the project "shop".
#[derive(Clone)]
struct Shop {
    title: &'static str,
    favicon_path: Option<&'static str>,
    icon: Option<Json>,
    online: bool,
}

impl Default for Shop {
    fn default() -> Shop {
        Shop {
            title: "Shop",
            favicon_path: None,
            icon: None,
            online: true,
        }
    }
}

fn shell(hub: &Hub, shop: &Shop) {
    let mut row = json!({"id": "p1", "title": shop.title, "workspaceRoot": "/w/shop",
        "createdAt": AT, "updatedAt": AT});
    if let Some(path) = shop.favicon_path {
        row["faviconPath"] = path.into();
    }
    if let Some(icon) = &shop.icon {
        row["projectIcon"] = icon.clone();
    }
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": shop.online, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop",
                    "capabilities": {"projectSettingsOverrides": true}}}],
            "rows": [["a", "p1", "project", row]]}),
    );
}

fn served(shop: &Shop) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, shop);
    hub
}

/// The laptop's config: its descriptor (`environment`) and settings, the
/// reads it sets off answered with them.
fn config(hub: &Hub, environment: Json, settings: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config", "config": {"settings": settings, "environment": environment}}),
    );
    while let Some(index) = hub.mc.pending_on("env-1", READ) {
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": settings, "version": 1})),
        );
    }
}

fn shop_icon(hub: &Hub) -> Json {
    hub.published("projectIcons")["env-1:p1"].clone()
}

fn picker(hub: &Hub) -> Json {
    hub.published("projectIconPicker")
}

fn machine(hub: &Hub) -> Json {
    hub.published("environmentIcons")["env-1"].clone()
}

fn calls(hub: &Hub, method: &str) -> Vec<(usize, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .filter(|(_, (_, m, _))| m == method)
        .map(|(i, (_, _, p))| (i, p.clone()))
        .collect()
}

fn toast_descriptions(hub: &Hub) -> Vec<(String, String)> {
    hub.published("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|t| {
            (
                t["title"].as_str().unwrap_or_default().to_owned(),
                t["description"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

// --- Project icons ---------------------------------------------------------------------

#[test]
fn a_project_without_an_icon_shows_a_two_character_monogram() {
    for (title, monogram) in [
        ("Nebula", "NA"),
        ("Silver Orchard", "SO"),
        ("M7 Forge", "M7"),
    ] {
        let hub = served(&Shop {
            title,
            ..Shop::default()
        });
        let icon = shop_icon(&hub);
        assert_eq!(icon["kind"], "monogram", "{title}");
        assert_eq!(icon["text"], monogram, "{title}");
        assert_eq!(icon["automatic"], true);
        assert!(!icon["tint"].as_str().unwrap().is_empty());
    }
}

#[test]
fn the_mcs_favicon_replaces_the_monogram_and_a_missing_one_leaves_it() {
    let hub = served(&Shop::default());
    let asked = calls(&hub, CREATE_URL);
    assert_eq!(asked.len(), 1, "asked once");
    assert_eq!(
        asked[0].1,
        json!({"resource": {"_tag": "project-favicon", "cwd": "/w/shop"}})
    );
    hub.mc.reply(
        &hub.engine,
        asked[0].0,
        Ok(json!({"relativeUrl": "/assets/x/project-favicon-missing"})),
    );
    assert_eq!(shop_icon(&hub)["kind"], "monogram");

    // A picked file is asked for again, by its path.
    shell(
        &hub,
        &Shop {
            favicon_path: Some("assets/logo.png"),
            ..Shop::default()
        },
    );
    let asked = calls(&hub, CREATE_URL);
    assert_eq!(asked.len(), 2);
    assert_eq!(asked[1].1["resource"]["path"], "assets/logo.png");
    hub.mc.reply(
        &hub.engine,
        asked[1].0,
        Ok(json!({"relativeUrl": "/assets/signed/logo.png"})),
    );
    let icon = shop_icon(&hub);
    assert_eq!(icon["kind"], "image");
    assert_eq!(icon["url"], "/assets/signed/logo.png");
    assert_eq!(icon["path"], "assets/logo.png");
    assert_eq!(icon["automatic"], false);
}

#[test]
fn an_answer_for_a_favicon_no_longer_asked_for_is_dropped() {
    let hub = served(&Shop::default());
    let first = calls(&hub, CREATE_URL)[0].0;
    shell(
        &hub,
        &Shop {
            favicon_path: Some("logo.svg"),
            ..Shop::default()
        },
    );
    hub.mc
        .reply(&hub.engine, first, Ok(json!({"relativeUrl": "/old.ico"})));
    assert_eq!(shop_icon(&hub)["kind"], "monogram");
}

#[test]
fn an_own_icon_wins_and_an_offline_environment_is_not_asked() {
    let hub = served(&Shop {
        icon: Some(json!({"kind": "emoji", "emoji": "🛒"})),
        online: false,
        ..Shop::default()
    });
    assert_eq!(shop_icon(&hub)["kind"], "emoji");
    assert!(calls(&hub, CREATE_URL).is_empty());
    shell(
        &hub,
        &Shop {
            online: false,
            ..Shop::default()
        },
    );
    assert_eq!(shop_icon(&hub)["kind"], "monogram");
    assert!(calls(&hub, CREATE_URL).is_empty(), "nobody to ask");
    shell(&hub, &Shop::default());
    assert_eq!(calls(&hub, CREATE_URL).len(), 1, "asked once it is back");
}

// --- The picker ------------------------------------------------------------------------

fn open(hub: &Hub) {
    hub.dispatch(
        "projectIcon.open",
        json!({"projectKey": "env-1:p1", "name": ""}),
    );
}

#[test]
fn the_picker_opens_on_the_icon_the_project_has() {
    let hub = served(&Shop::default());
    assert_eq!(picker(&hub), Json::Null);
    open(&hub);
    let shown = picker(&hub);
    assert_eq!(shown["name"], "Shop");
    assert_eq!(shown["mode"], "lucide");
    assert_eq!(shown["symbol"], "folder-code");
    assert_eq!(shown["letters"], "SP");
    assert_eq!(shown["colors"].as_array().unwrap().len(), 18);
    assert!(
        shown["symbols"]
            .as_array()
            .unwrap()
            .contains(&json!("rocket"))
    );

    let hub = served(&Shop {
        icon: Some(json!({"kind": "lucide", "name": "rocket", "color": "teal"})),
        ..Shop::default()
    });
    open(&hub);
    assert_eq!(picker(&hub)["symbol"], "rocket");
    assert_eq!(picker(&hub)["color"], "teal");

    let hub = served(&Shop {
        favicon_path: Some("logo.png"),
        ..Shop::default()
    });
    open(&hub);
    assert_eq!(picker(&hub)["mode"], "image");

    hub.dispatch("projectIcon.cancel", Json::Null);
    assert_eq!(picker(&hub), Json::Null);
}

#[test]
fn the_picker_takes_only_what_it_offers() {
    let hub = served(&Shop::default());
    open(&hub);
    hub.dispatch(
        "projectIcon.set",
        json!({"mode": "tiles", "symbol": "nope", "color": "plaid"}),
    );
    let shown = picker(&hub);
    assert_eq!(shown["mode"], "lucide");
    assert_eq!(shown["symbol"], "folder-code");
    hub.dispatch(
        "projectIcon.set",
        json!({"mode": "monogram", "color": "rose", "letters": "ab"}),
    );
    let shown = picker(&hub);
    assert_eq!(shown["mode"], "monogram");
    assert_eq!(shown["color"], "rose");
    assert_eq!(shown["letters"], "ab");
}

#[test]
fn monograms_take_one_or_two_letters_or_numbers() {
    for (typed, saved) in [
        ("abc", None),
        ("#!", None),
        ("sh", Some("SH")),
        ("7", Some("7")),
    ] {
        let hub = settings_hub();
        open(&hub);
        hub.dispatch(
            "projectIcon.set",
            json!({"mode": "monogram", "letters": typed, "color": "rose"}),
        );
        hub.dispatch("projectIcon.save", Json::Null);
        match saved {
            None => {
                assert_eq!(
                    picker(&hub)["error"],
                    "Use one or two letters or numbers.",
                    "{typed}"
                );
                assert!(hub.mc.pending("projects.mutate").is_none());
                // Typing again clears the error.
                hub.dispatch("projectIcon.set", json!({"letters": "s"}));
                assert_eq!(picker(&hub)["error"], "");
            }
            Some(saved) => {
                assert_eq!(picker(&hub), Json::Null, "{typed}");
                // A monogram travels as a folder symbol carrying its letters.
                assert_eq!(
                    mutated(&hub)["projectIcon"],
                    json!({"kind": "lucide", "name": "folder-code", "color": "rose",
                        "monogramText": saved})
                );
            }
        }
    }
}

#[test]
fn an_emoji_or_a_symbol_is_saved_and_an_empty_emoji_is_not() {
    let hub = settings_hub();
    open(&hub);
    hub.dispatch("projectIcon.set", json!({"mode": "emoji", "emoji": "  "}));
    hub.dispatch("projectIcon.save", Json::Null);
    assert_eq!(picker(&hub)["error"], "Choose an emoji.");
    hub.dispatch("projectIcon.set", json!({"emoji": "🛒"}));
    hub.dispatch("projectIcon.save", Json::Null);
    assert_eq!(
        mutated(&hub)["projectIcon"],
        json!({"kind": "emoji", "emoji": "🛒"})
    );

    open(&hub);
    hub.dispatch(
        "projectIcon.set",
        json!({"mode": "lucide", "symbol": "rocket", "color": "teal"}),
    );
    hub.dispatch("projectIcon.save", Json::Null);
    assert_eq!(
        mutated(&hub)["projectIcon"],
        json!({"kind": "lucide", "name": "rocket", "color": "teal"})
    );
}

#[test]
fn choosing_an_image_searches_only_image_files_in_the_project() {
    let hub = settings_hub();
    open(&hub);
    hub.dispatch("projectIcon.set", json!({"mode": "image"}));
    hub.dispatch("projectIcon.save", Json::Null);
    assert_eq!(picker(&hub)["error"], "Choose an image file.");

    hub.dispatch("projectIcon.search", json!({"query": "lo"}));
    let stale = hub.mc.pending(SEARCH).expect("a search");
    hub.dispatch("projectIcon.search", json!({"query": " logo "}));
    assert_eq!(picker(&hub)["searching"], true);
    let (index, asked) = calls(&hub, SEARCH).pop().unwrap();
    assert_eq!(asked["cwd"], "/w/shop");
    assert_eq!(asked["query"], "logo");
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"entries": [
            {"path": "src/logo.ts", "kind": "file"},
            {"path": "assets/logo.png", "kind": "file"},
            {"path": "assets/logo.svg", "kind": "directory"},
            {"path": "Logo.ICO", "kind": "file"}]})),
    );
    let shown = picker(&hub);
    assert_eq!(shown["searching"], false);
    assert_eq!(shown["images"], json!(["Logo.ICO", "assets/logo.png"]));
    // The older search's answer comes late and changes nothing.
    hub.mc.reply(
        &hub.engine,
        stale,
        Ok(json!({"entries": [{"path": "lo.png", "kind": "file"}]})),
    );
    assert_eq!(
        picker(&hub)["images"],
        json!(["Logo.ICO", "assets/logo.png"])
    );

    hub.dispatch("projectIcon.image", json!({"path": "src/logo.ts"}));
    assert_ne!(picker(&hub), Json::Null, "not an image");
    hub.dispatch("projectIcon.image", json!({"path": "assets/logo.png"}));
    assert_eq!(picker(&hub), Json::Null);
    let sent = mutated(&hub);
    assert_eq!(sent["faviconPath"], "assets/logo.png");
    assert_eq!(sent["projectIcon"], Json::Null);

    // An empty query lists nothing and asks nothing.
    open(&hub);
    let searches = calls(&hub, SEARCH).len();
    hub.dispatch("projectIcon.search", json!({"query": "  "}));
    assert_eq!(calls(&hub, SEARCH).len(), searches);
    assert_eq!(picker(&hub)["images"], json!([]));
}

/// A hub on Settings → Project with "shop" picked, where the picker's save
/// lands (`projectSettings.icon`).
fn settings_hub() -> Hub {
    let hub = served(&Shop::default());
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config", "config": {"settings": {},
            "environment": {"capabilities": {"projectSettingsOverrides": true}}}}),
    );
    while let Some(index) = hub.mc.pending_on("env-1", READ) {
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": {}, "version": 1})),
        );
    }
    hub.dispatch("settings.navigate", json!({"to": "/settings/projects"}));
    let key = sidebar::groups(&hub.engine)
        .into_iter()
        .find(|g| g.members.iter().any(|m| m.id == "p1"))
        .expect("shop's group")
        .key;
    hub.dispatch("settingsScope.project", json!({"key": key}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    hub
}

/// What the save wrote to the project, answered.
fn mutated(hub: &Hub) -> Json {
    let index = hub.mc.pending("projects.mutate").expect("an update");
    let sent = hub.mc.calls.borrow()[index].2.clone();
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    sent
}

// --- Environment icons -------------------------------------------------------------------

const KEEPS_ICONS: &str = "environmentIcon";

fn laptop(keeps_icons: bool) -> Json {
    json!({"platform": {"machine": "laptop"}, "capabilities": {KEEPS_ICONS: keeps_icons}})
}

/// Answers the session check with `scopes` (none: an MC that says nothing).
fn session(hub: &Hub, scopes: Option<&[&str]>) {
    let answer = match scopes {
        Some(scopes) => json!({"authenticated": true, "scopes": scopes}),
        None => json!({"authenticated": true}),
    };
    hub.mc.answer(&hub.engine, SESSION, Ok(answer));
}

/// Answers the read a write starts with and returns what is written.
fn written(hub: &Hub, settings: Json) -> Json {
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": settings, "version": 1})),
    );
    let index = hub.mc.pending(WRITE).expect("the settings are written");
    let sent = hub.mc.calls.borrow()[index].2["settings"].clone();
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"settings": sent, "version": 2})),
    );
    sent
}

#[test]
fn the_user_chooses_the_kind_of_machine_and_the_detected_kind_clears_it() {
    let hub = served(&Shop::default());
    config(&hub, laptop(true), json!({}));
    let shown = machine(&hub);
    assert_eq!(shown["kind"], "laptop");
    assert_eq!(shown["detected"], "laptop");
    assert_eq!(shown["icon"], "laptop");
    assert_eq!(shown["chosen"], false);
    assert_eq!(shown["lock"], "");
    assert_eq!(shown["kinds"].as_array().unwrap().len(), 7);

    hub.dispatch(
        "environmentIcon.set",
        json!({"environmentId": "env-1", "kind": "server"}),
    );
    session(&hub, Some(&["orchestration:operate"]));
    assert_eq!(written(&hub, json!({}))["environmentIcon"], "server");
    config(&hub, laptop(true), json!({"environmentIcon": "server"}));
    let shown = machine(&hub);
    assert_eq!(shown["kind"], "server");
    assert_eq!(shown["chosen"], true);

    // The session is known now: no second check.
    hub.dispatch(
        "environmentIcon.set",
        json!({"environmentId": "env-1", "kind": "laptop"}),
    );
    assert_eq!(calls(&hub, SESSION).len(), 1);
    let sent = written(&hub, json!({"environmentIcon": "server"}));
    assert!(sent.get("environmentIcon").is_none(), "{sent}");
}

#[test]
fn an_environment_icon_cannot_always_be_changed() {
    let tried = |hub: &Hub| {
        hub.dispatch(
            "environmentIcon.set",
            json!({"environmentId": "env-1", "kind": "server"}),
        );
    };
    let told = |hub: &Hub, message: &str| {
        assert_eq!(machine(hub)["lock"], message);
        assert!(
            toast_descriptions(hub).contains(&("Icon not changed".into(), message.into())),
            "{:?}",
            toast_descriptions(hub)
        );
        assert!(hub.mc.pending(WRITE).is_none() && hub.mc.pending(READ).is_none());
    };

    let hub = served(&Shop {
        online: false,
        ..Shop::default()
    });
    config(&hub, laptop(true), json!({}));
    tried(&hub);
    session(&hub, None);
    told(&hub, "Connect to this environment to change its icon.");

    let hub = served(&Shop::default());
    config(&hub, laptop(false), json!({}));
    tried(&hub);
    session(&hub, None);
    told(
        &hub,
        "This environment's server is too old to keep an icon. Update it to choose one.",
    );

    let hub = served(&Shop::default());
    config(&hub, laptop(true), json!({}));
    tried(&hub);
    session(&hub, Some(&["orchestration:read"]));
    told(
        &hub,
        "Your session on this environment cannot change its settings.",
    );
    // Another connection is another session: asked again.
    hub.mc.set_ready(&hub.engine, false);
    hub.mc.set_ready(&hub.engine, true);
    tried(&hub);
    assert_eq!(calls(&hub, SESSION).len(), 2);
}

#[test]
fn a_session_check_that_fails_lets_the_mc_decide() {
    let hub = served(&Shop::default());
    config(&hub, laptop(true), json!({}));
    hub.dispatch(
        "environmentIcon.set",
        json!({"environmentId": "env-1", "kind": "desktop"}),
    );
    hub.mc
        .answer(&hub.engine, SESSION, Err(McError::new("404 Not Found")));
    assert_eq!(written(&hub, json!({}))["environmentIcon"], "desktop");
}

// --- Answers in any order ----------------------------------------------------------------

#[derive(Clone, Debug)]
enum Op {
    /// The row's picked favicon file: none, or one of two.
    Pick(Option<u8>),
    /// The row has its own icon, or not.
    Own(bool),
    Online(bool),
    /// Answers the n-th favicon request still waiting: found or missing.
    Answer(usize, bool),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        prop::option::of(0u8..2).prop_map(Op::Pick),
        any::<bool>().prop_map(Op::Own),
        any::<bool>().prop_map(Op::Online),
        (0usize..4, any::<bool>()).prop_map(|(n, found)| Op::Answer(n, found)),
    ]
}

const PATHS: [&str; 2] = ["a.png", "b.svg"];

/// IdentityController's rule for one project: the favicon asked for is the
/// one its row names, asked once while its environment is online, and an
/// answer counts only while it is still what was asked.
#[derive(Default)]
struct Model {
    asked: Option<String>,
    url: String,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn a_project_shows_the_favicon_last_asked_for_whatever_order_answers_come(
        ops in prop::collection::vec(op(), 1..24),
    ) {
        let mut shop = Shop::default();
        let hub = served(&shop);
        let mut model = Model { asked: Some("/w/shop\n".into()), url: String::new() };
        let mut waiting: Vec<(usize, String)> = vec![(calls(&hub, CREATE_URL)[0].0, "/w/shop\n".into())];
        for op in ops {
            match op {
                Op::Pick(path) => shop.favicon_path = path.map(|p| PATHS[p as usize]),
                Op::Own(own) => shop.icon = own.then(|| json!({"kind": "emoji", "emoji": "🛒"})),
                Op::Online(online) => shop.online = online,
                Op::Answer(n, found) => {
                    if waiting.is_empty() {
                        continue;
                    }
                    let (index, asked) = waiting.remove(n % waiting.len());
                    let relative = if found {
                        format!("/assets/{}", asked.replace('\n', "/"))
                    } else {
                        "/assets/project-favicon-missing".to_owned()
                    };
                    hub.mc.reply(&hub.engine, index, Ok(json!({"relativeUrl": relative})));
                    if found && model.asked.as_deref() == Some(asked.as_str()) {
                        model.url = relative;
                    }
                }
            }
            if !matches!(op, Op::Answer(..)) {
                let before = calls(&hub, CREATE_URL).len();
                shell(&hub, &shop);
                let asked = format!("/w/shop\n{}", shop.favicon_path.unwrap_or_default());
                let mut asks = false;
                if shop.icon.is_some() {
                    model.asked = None;
                    model.url.clear();
                } else if model.asked.as_deref() != Some(asked.as_str()) && shop.online {
                    model.asked = Some(asked.clone());
                    model.url.clear();
                    asks = true;
                }
                prop_assert_eq!(calls(&hub, CREATE_URL).len() - before, usize::from(asks));
                if asks {
                    let (index, _) = calls(&hub, CREATE_URL).pop().unwrap();
                    waiting.push((index, asked));
                }
            }
            let icon = shop_icon(&hub);
            if shop.icon.is_some() {
                prop_assert_eq!(&icon["kind"], "emoji");
            } else if model.url.is_empty() {
                prop_assert_eq!(&icon["kind"], "monogram");
            } else {
                prop_assert_eq!(&icon["kind"], "image");
                prop_assert_eq!(icon["url"].as_str(), Some(model.url.as_str()));
                prop_assert_eq!(icon["automatic"].as_bool(), Some(shop.favicon_path.is_none()));
            }
        }
    }
}
