//! The desktop's Connections settings page (the Connections controller): who
//! may reach this machine (features/settings/connections.feature and the
//! desktop scenarios of connections/pairing.feature): desktop-qt's
//! ConnectionsSteps.cpp.

use std::collections::{HashMap, HashSet};

use hal_c2_shell::qr;
use serde_json::{Value, json};

use crate::brick::{Brick, Shown, shown};
use crate::expect;
use crate::fail;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

/// Who may reach the MC, as apps/server-ex lib/hal_c2/rpc.ex answers `hal-c2.*`
/// access calls and the `authAccess` shape.
struct FakeAccess {
    admin: bool,
    refuse_create: bool,
    pairing_links: Vec<Value>,
    clients: Vec<Value>,
    /// Unused pairing links' credentials, by link id, and the machine each
    /// link is on (its environment, "" for the MC's own): only that one
    /// revokes it.
    credentials: HashMap<String, String>,
    link_machine: HashMap<String, String>,
    /// Where Tailscale Serve publishes each machine, by environment ("" for
    /// the MC's own); one without a name cannot be reached over Tailscale.
    /// Asked without Tailscale, a machine names the loopback address it
    /// listens on.
    tailnet: HashMap<String, String>,
    /// Machines from before a pairing link named its address.
    silent: HashSet<String>,
    calls: Vec<(String, Value)>,
    next: u32,
    revision: u32,
}

impl Default for FakeAccess {
    fn default() -> Self {
        FakeAccess {
            admin: true,
            refuse_create: false,
            pairing_links: Vec::new(),
            clients: vec![json!({
                "sessionId": "session-desktop",
                "subject": "owner",
                "client": {"deviceType": "desktop", "label": "This desktop"},
                "connected": true,
                "current": true,
            })],
            credentials: HashMap::new(),
            link_machine: HashMap::new(),
            tailnet: HashMap::new(),
            silent: HashSet::new(),
            calls: Vec::new(),
            next: 1,
            revision: 0,
        }
    }
}

/// The width the Connections page is shown at.
#[derive(Default)]
struct PageWidth(f64);

fn fake(world: &mut World) -> &mut FakeAccess {
    world.mc.part::<FakeAccess>()
}

/// An `authAccess` event to the subscribers (to `only` when it is set).
fn send_access(mc: &mut FakeMc, kind: &str, payload: Value, only: Option<i64>) {
    let access = mc.part::<FakeAccess>();
    access.revision += 1;
    let event = json!({
        "version": 1,
        "revision": access.revision,
        "type": kind,
        "payload": payload,
    });
    for id in mc.subscribers("authAccess") {
        if only.is_some_and(|only| only != id) {
            continue;
        }
        mc.send(&json!({"t": "authAccess", "id": id, "event": event}));
    }
}

fn remove_where(list: &mut Vec<Value>, key: &str, value: &str) {
    list.retain(|item| text(&item[key]) != value);
}

fn answer_access(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let method = rpc.method.as_str();
    // A link asked for while the MC holds its answers is made once it answers, late.
    if method == "hal-c2.createPairingLink" && mc.holding("answers") {
        let rpc = rpc.clone();
        mc.defer(move |mc| {
            let _ = answer_access(mc, &rpc);
        });
        return Ok(());
    }
    let environment_id = mc.environment_id.clone();
    let origin = mc.origin();
    let access = mc.part::<FakeAccess>();
    access.calls.push((rpc.method.clone(), rpc.payload.clone()));
    let reads = method == "hal-c2.pairingLinks" || method == "hal-c2.clients";
    if !access.admin {
        let message = if reads {
            "access:read is required"
        } else {
            "access:write is required"
        };
        mc.refuse(rpc, message);
        return Ok(());
    }
    // The machine the call is for: "" for the MC's own.
    let machine = if rpc.environment == environment_id {
        String::new()
    } else {
        rpc.environment.clone()
    };
    match method {
        "hal-c2.createPairingLink" => {
            if access.refuse_create {
                mc.refuse(rpc, "the MC could not store the pairing link");
                return Ok(());
            }
            let tailscale = rpc.payload["tailscale"] == json!(true);
            if tailscale && !access.tailnet.contains_key(&machine) {
                mc.refuse(
                    rpc,
                    "Could not talk to Tailscale. Is tailscaled running? Try `tailscale status`.",
                );
                return Ok(());
            }
            let id = format!("link-{}", access.next);
            let credential = format!("secret-{}", access.next);
            access.next += 1;
            let mut link = json!({
                "id": id,
                "scopes": rpc.payload["scopes"],
                "subject": "owner",
                "createdAt": "2026-09-29T10:00:00Z",
                "expiresAt": "2026-09-29T10:05:00Z",
            });
            if rpc.payload.get("label").is_some() {
                link["label"] = rpc.payload["label"].clone();
            }
            access.credentials.insert(id.clone(), credential.clone());
            access.link_machine.insert(id, machine.clone());
            let mut result = link.clone();
            result["credential"] = json!(credential);
            if !access.silent.contains(&machine) {
                let loopback = if machine.is_empty() {
                    origin
                } else {
                    "http://127.0.0.1:3780".to_owned()
                };
                result["address"] = if tailscale {
                    json!(access.tailnet[&machine])
                } else {
                    json!(loopback)
                };
                result["localOnly"] = json!(!tailscale);
            }
            // The access list is of the MC's own links.
            if machine.is_empty() {
                access.pairing_links.push(link.clone());
                send_access(mc, "pairingLinkUpserted", link, None);
            }
            mc.reply(rpc, result);
        }
        "hal-c2.revokePairingLink" => {
            let id = text(&rpc.payload["id"]);
            let revoked = access.credentials.contains_key(&id)
                && access.link_machine.get(&id) == Some(&machine);
            if revoked {
                access.credentials.remove(&id);
                access.link_machine.remove(&id);
            }
            if revoked && machine.is_empty() {
                remove_where(&mut access.pairing_links, "id", &id);
                send_access(mc, "pairingLinkRemoved", json!({"id": id}), None);
            }
            mc.reply(rpc, json!({"revoked": revoked}));
        }
        "hal-c2.revokeClient" => {
            let id = text(&rpc.payload["sessionId"]);
            remove_where(&mut access.clients, "sessionId", &id);
            send_access(mc, "clientRemoved", json!({"sessionId": id}), None);
            mc.reply(rpc, json!({"revoked": true}));
        }
        "hal-c2.revokeOtherClients" => {
            let (current, others): (Vec<Value>, Vec<Value>) = access
                .clients
                .drain(..)
                .partition(|client| client["current"] == json!(true));
            access.clients = current;
            let count = others.len();
            for client in others {
                send_access(
                    mc,
                    "clientRemoved",
                    json!({"sessionId": client["sessionId"]}),
                    None,
                );
            }
            mc.reply(rpc, json!({"revokedCount": count}));
        }
        _ => mc.reply(rpc, Value::Null),
    }
    Ok(())
}

/// "Build box" is the machine at build-box.
fn host_of(label: &str) -> String {
    label.to_lowercase().replace(' ', "-")
}

fn connections(world: &mut World) -> Outcome<Value> {
    world.sync()?;
    Ok(world.state("connections"))
}

fn describe(world: &mut World) -> String {
    format!(
        "the Connections page is {}",
        show(&connections(world).unwrap_or(Value::Null))
    )
}

fn listed(world: &mut World, list: &str) -> Outcome<Vec<Value>> {
    let page = connections(world)?;
    Ok(at(&page, &format!("access.{list}"))
        .as_array()
        .cloned()
        .unwrap_or_default())
}

fn expect_notice(world: &mut World, kind: &str, says: impl Fn(&str) -> bool) -> Outcome {
    let page = connections(world)?;
    let notice = &page["notice"];
    expect!(
        notice["kind"] == kind && says(&text(&notice["text"])),
        "the Connections page is {}",
        show(&page)
    );
    Ok(())
}

fn called(world: &mut World, method: &str) -> Outcome<bool> {
    world.sync()?;
    Ok(fake(world).calls.iter().any(|(name, _)| name == method))
}

fn open_connections(world: &mut World) -> Outcome {
    if !world.active() {
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())?;
    }
    world.dispatch("connections.open", Value::Null)?;
    world.sync()?;
    let route = world.state("route");
    expect!(
        at(&route, "section") == "/settings/connections",
        "the route is {}",
        show(&route)
    );
    Ok(())
}

fn create_link(world: &mut World, label: Option<&str>, scopes: &[&str]) -> Outcome {
    let mut payload = json!({"scopes": scopes});
    if let Some(label) = label {
        payload["label"] = json!(label);
    }
    world.dispatch("connections.pairingLink.create", payload)
}

fn add_client(world: &mut World, label: &str) {
    let client = json!({
        "sessionId": format!("session-{}", host_of(label)),
        "subject": "owner",
        "client": {"deviceType": "mobile", "label": label},
        "connected": true,
        "current": false,
    });
    fake(world).clients.push(client.clone());
    send_access(&mut world.mc, "clientUpserted", client, None);
}

fn client_listed(world: &mut World, label: &str) -> Outcome<bool> {
    Ok(listed(world, "clients")?
        .iter()
        .any(|client| at(client, "client.label") == label))
}

/// The Connections page on screen, `width` wide (its last width when 0):
/// what the user chooses and is shown there.
fn page(world: &mut World, width: f64) -> Outcome<Brick> {
    let wanted = if width > 0.0 {
        width
    } else {
        match world.part::<PageWidth>().0 {
            0.0 => 900.0,
            last => last,
        }
    };
    if world.part::<Shown>().0.is_none() || world.part::<PageWidth>().0 != wanted {
        world.part::<PageWidth>().0 = wanted;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nConnectionsSettings {}\n",
            wanted,
            1400.0,
        )?;
        // The page fills the window, as desktop-qt's Brick sizes it.
        let brick = shown(world)?;
        if let Some(root) = brick.root(world) {
            brick.write(world, root, "width", ljos::prelude::Value::Real(wanted))?;
            brick.write(world, root, "height", ljos::prelude::Value::Real(1400.0))?;
        }
    }
    world.sync()?;
    shown(world)
}

/// The machines the page offers a pairing link for, by label; none while
/// there is no choice.
fn machines_of(brick: &Brick, world: &World) -> Vec<String> {
    let Ok(Some(choice)) = brick.find(world, "connectionsMachine") else {
        return Vec::new();
    };
    if !brick.flag(world, choice, "visible") {
        return Vec::new();
    }
    match brick.read(world, choice, "model") {
        ljos::prelude::Value::List(labels) => labels
            .iter()
            .map(|label| world.engine().to_js_string(label).to_string())
            .collect(),
        other => world
            .engine()
            .to_js_string(&other)
            .split(',')
            .filter(|label| !label.is_empty())
            .map(str::to_owned)
            .collect(),
    }
}

fn offered_machines(world: &mut World) -> Outcome<Vec<String>> {
    let brick = page(world, 0.0)?;
    Ok(machines_of(&brick, world))
}

fn leave_connections(world: &mut World) -> Outcome {
    world.dispatch("connections.close", Value::Null)?;
    world.sync()
}

/// Asks for a link from the page, over Tailscale or not, and waits for the
/// MC to hear of it.
fn ask_from_page(world: &mut World, tailscale: bool) -> Outcome {
    let brick = page(world, 0.0)?;
    let asked = world.mc.calls.len();
    brick.click(
        world,
        if tailscale {
            "connectionsCreateLinkTailscale"
        } else {
            "connectionsCreateLink"
        },
    )?;
    world.wait_for_with(
        |w| w.mc.calls.len() > asked,
        |w| format!("the MC to be asked; {}", describe_now(w)),
    )
}

/// `describe` for a failure message built while the world is borrowed.
fn describe_now(world: &World) -> String {
    format!(
        "the Connections page is {}",
        show(&world.state("connections"))
    )
}

/// Creates a link from the page, and waits for the MC's answer.
fn create_from_page(world: &mut World, tailscale: bool) -> Outcome {
    ask_from_page(world, tailscale)?;
    world.wait_for_with(
        |w| w.state("connections")["busy"] != json!(true),
        |w| format!("the MC to answer; {}", describe_now(w)),
    )
}

/// Picks `label` where the page offers the machines, with the keyboard.
fn choose_machine(world: &mut World, label: &str) -> Outcome {
    let brick = page(world, 0.0)?;
    let offered = offered_machines(world)?;
    let Some(wanted) = offered.iter().position(|offer| offer == label) else {
        fail!("{label} is not offered: {}", offered.join(", "));
    };
    let choice = brick.item(world, "connectionsMachine")?;
    brick.write(world, choice, "focus", ljos::prelude::Value::Bool(true))?;
    let mut index = brick
        .text_of(world, choice, "currentIndex")
        .parse::<usize>()
        .unwrap_or(0);
    while index != wanted {
        let up = index > wanted;
        expect!(
            brick.press(world, if up { "arrowup" } else { "arrowdown" })?,
            "the machine choice took no key"
        );
        index = if up { index - 1 } else { index + 1 };
    }
    let shown_label = brick.text_of(world, choice, "displayText");
    expect!(shown_label == label, "{shown_label} is chosen");
    Ok(())
}

/// The last call of `method`, and the machine it was for.
fn last_call(world: &mut World, method: &str) -> Outcome<Rpc> {
    world.sync()?;
    match world
        .mc
        .calls
        .iter()
        .rev()
        .find(|call| call.method == method)
    {
        Some(call) => Ok(call.clone()),
        None => fail!("the MC was not asked for {method}"),
    }
}

/// The link the page shows, in its field.
fn shown_link(world: &mut World) -> Outcome<String> {
    let brick = page(world, 0.0)?;
    let field = brick.item(world, "connectionsCreatedLink")?;
    expect!(
        brick.flag(world, field, "visible"),
        "no link is shown; {}",
        describe(world)
    );
    Ok(brick.text_of(world, field, "text"))
}

fn number(brick: &Brick, world: &World, item: ljos::prelude::ObjectId, name: &str) -> f64 {
    brick.text_of(world, item, name).parse().unwrap_or(f64::NAN)
}

/// The page's QR code as it is laid out: the code of `link`, its modules
/// and quiet zone, white under the dark path.
///
/// desktop-ljos's test window has no pixel grab, so the modules are held
/// against the code as the path the page draws (`qr::path`) and the item
/// that draws it, not as pixels read off the window.
fn expect_qr_code_of(world: &mut World, link: &str) -> Outcome {
    let brick = page(world, 0.0)?;
    let drawn = brick.item(world, "connectionsQr")?;
    expect!(
        brick.flag(world, drawn, "visible"),
        "no QR code is shown; {}",
        describe(world)
    );
    let code = qr::encode(link);
    let size = code.size as f64;
    let module = number(&brick, world, drawn, "moduleSize");
    let quiet = number(&brick, world, drawn, "quietZone");
    let width = number(&brick, world, drawn, "width");
    let height = number(&brick, world, drawn, "height");
    expect!(
        !code.is_null()
            && number(&brick, world, drawn, "modules") == size
            && quiet >= 4.0
            && module >= 1.0
            && (width - (size + 2.0 * quiet) * module).abs() < 0.5
            && (height - width).abs() < 0.5,
        "the code of {link} has {size} modules; {} are drawn, {module} px each, in {width}x{height} with a quiet zone of {quiet}",
        number(&brick, world, drawn, "modules")
    );
    let page_state = connections(world)?;
    expect!(
        at(&page_state, "created.qr.path") == qr::path(&code).as_str()
            && brick.text_of(world, drawn, "path") == qr::path(&code),
        "the QR code does not draw the code of {link}"
    );
    // Black modules on white, whatever the theme.
    let colour = brick.read(world, drawn, "color");
    let white = world.engine().to_js_string(&colour).to_string();
    expect!(
        white.eq_ignore_ascii_case("#ffffff") || white.eq_ignore_ascii_case("white"),
        "the code is drawn on {white}"
    );
    expect!(world.painted(drawn) > 0, "the QR code was not painted");
    Ok(())
}

const STANDARD_SCOPES: [&str; 5] = [
    "orchestration:read",
    "orchestration:operate",
    "terminal:operate",
    "review:write",
    "relay:read",
];

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        for method in [
            "createPairingLink",
            "revokePairingLink",
            "pairingLinks",
            "clients",
            "revokeClient",
            "revokeOtherClients",
        ] {
            mc.on_rpc(&format!("hal-c2.{method}"), answer_access);
        }
        mc.on_shape("authAccess", |mc, id, _| {
            let access = mc.part::<FakeAccess>();
            if !access.admin {
                mc.send(&json!({"t": "error", "id": id, "reason": "access:read is required"}));
                mc.forget(id);
                return Ok(());
            }
            let snapshot = json!({
                "pairingLinks": access.pairing_links,
                "clientSessions": access.clients,
            });
            send_access(mc, "snapshot", snapshot, Some(id));
            Ok(())
        });
    });

    // The MC and the session.
    steps.step("a running MC", |world, _, _| {
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())
    });
    steps.step(
        "the user has opened the Connections settings",
        |world, _, _| open_connections(world),
    );
    steps.step(
        "the user's session may manage this machine's access",
        |world, _, _| {
            fake(world).admin = true;
            let page = connections(world)?;
            expect!(
                !page["access"].is_null(),
                "the Connections page is {}",
                show(&page)
            );
            Ok(())
        },
    );
    steps.step(
        "the user's session may not manage this machine's access",
        |world, _, _| {
            fake(world).admin = false;
            world.dispatch("connections.refresh", Value::Null)
        },
    );
    steps.step(
        "the user is told administrative access is required",
        |world, _, _| {
            let page = connections(world)?;
            let needs = |t: &str| t.contains("needs an administrator session");
            expect!(
                needs(&text(&page["accessError"])) || needs(&text(at(&page, "notice.text"))),
                "the Connections page is {}",
                show(&page)
            );
            Ok(())
        },
    );
    steps.step("no pairing links or clients are listed", |world, _, _| {
        let page = connections(world)?;
        expect!(
            page["access"].is_null(),
            "the Connections page is {}",
            show(&page)
        );
        Ok(())
    });

    // Pairing links.
    steps.step(
        &format!(
            "the user creates a pairing link labelled {Q} allowed to view the environment and operate tasks"
        ),
        |world, c, _| {
            create_link(
                world,
                Some(&c[0]),
                &["orchestration:read", "orchestration:operate"],
            )
        },
    );
    steps.step(
        &format!("a pairing link labelled {Q} is listed with those permissions and its expiry"),
        |world, c, _| {
            let found = listed(world, "pairingLinks")?.iter().any(|link| {
                link["label"] == json!(c[0])
                    && link["scopes"] == json!(["orchestration:read", "orchestration:operate"])
                    && !text(&link["expiresAt"]).is_empty()
            });
            expect!(found, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "the user tries to create a pairing link with no permissions",
        |world, _, _| create_link(world, Some("Phone"), &[]),
    );
    steps.step(
        "the user is told to select at least one permission",
        |world, _, _| expect_notice(world, "error", |t| t == "Select at least one permission."),
    );
    steps.step("no link is created", |world, _, _| {
        expect!(
            !called(world, "hal-c2.createPairingLink")?,
            "the MC was asked for a pairing link"
        );
        expect!(
            listed(world, "pairingLinks")?.is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the server refuses to create pairing links",
        |world, _, _| {
            fake(world).refuse_create = true;
            Ok(())
        },
    );
    steps.step("the user creates a pairing link", |world, _, _| {
        create_link(world, None, &STANDARD_SCOPES)
    });
    steps.step(
        "the user is told the pairing URL could not be created",
        |world, _, _| {
            expect_notice(world, "error", |t| {
                t.starts_with("Could not create the pairing URL")
            })
        },
    );
    steps.step(
        "(a pairing link is listed|the user created a pairing link)",
        |world, _, _| {
            if at(&world.state("route"), "section") != "/settings/connections" {
                open_connections(world)?;
            }
            create_link(world, Some("Phone"), &STANDARD_SCOPES)?;
            let page = connections(world)?;
            expect!(
                listed(world, "pairingLinks")?.len() == 1 && !page["created"].is_null(),
                "the Connections page is {}",
                show(&page)
            );
            Ok(())
        },
    );
    steps.step("the user copies the link", |world, _, _| {
        world.set_clipboard("");
        world.dispatch("connections.pairingLink.copy", Value::Null)
    });
    steps.step("the link is on the clipboard", |world, _, _| {
        let page = connections(world)?;
        let url = text(at(&page, "created.url"));
        let copied = world.clipboard();
        expect!(
            !url.is_empty()
                && copied == url
                && copied.ends_with("/pair#token=secret-1")
                && copied.starts_with(&world.mc.origin()),
            "copied \"{copied}\", the page is {}",
            show(&page)
        );
        Ok(())
    });
    steps.step("the user is told it was copied", |world, _, _| {
        expect_notice(world, "success", |t| t == "Pairing link copied.")
    });
    steps.step("the user revokes it", |world, _, _| {
        let links = listed(world, "pairingLinks")?;
        expect!(!links.is_empty(), "no pairing link is listed");
        world.dispatch(
            "connections.pairingLink.revoke",
            json!({"id": links[0]["id"]}),
        )
    });
    steps.step("the link is no longer listed", |world, _, _| {
        expect!(
            listed(world, "pairingLinks")?.is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("a device can no longer pair with it", |world, _, _| {
        let left: Vec<String> = fake(world).credentials.values().cloned().collect();
        expect!(
            left.is_empty(),
            "the MC still pairs with {}",
            left.join(", ")
        );
        expect!(
            connections(world)?["created"].is_null(),
            "the revoked link can still be copied"
        );
        Ok(())
    });
    steps.step(
        "the user leaves the Connections page and comes back",
        |world, _, _| {
            leave_connections(world)?;
            open_connections(world)
        },
    );
    steps.step("the user leaves the Connections page", |world, _, _| {
        leave_connections(world)
    });
    steps.step(
        "the user comes back to the Connections page",
        |world, _, _| open_connections(world),
    );
    steps.step("the link is listed without its secret", |world, _, _| {
        let page = connections(world)?;
        expect!(
            listed(world, "pairingLinks")?.len() == 1
                && page["created"].is_null()
                && !show(&page).contains("secret-"),
            "the Connections page is {}",
            show(&page)
        );
        Ok(())
    });
    steps.step(
        "the user must create another link to share",
        |world, _, _| {
            world.set_clipboard("");
            world.dispatch("connections.pairingLink.copy", Value::Null)?;
            world.dispatch("connections.pairingLink.copy", json!({"what": "code"}))?;
            let copied = world.clipboard();
            expect!(copied.is_empty(), "copied \"{copied}\"");
            Ok(())
        },
    );

    // Where a link's machine is reached, the machine it is for, and its QR code.
    steps.step(
        &format!("this machine is reached over Tailscale at {Q}"),
        |world, c, _| {
            fake(world).tailnet.insert(String::new(), c[0].clone());
            Ok(())
        },
    );
    steps.step("Tailscale is not running on this machine", |world, _, _| {
        fake(world).tailnet.remove("");
        Ok(())
    });
    steps.step(
        &format!("the cluster also has the machine {Q}(?:, reached over Tailscale at {Q})?"),
        |world, c, _| {
            world.mc.join_named(&c[0]);
            if !c[1].is_empty() {
                fake(world).tailnet.insert(c[0].clone(), c[1].clone());
            }
            let machine = c[0].clone();
            let brick = page(world, 0.0)?;
            world.wait_for_with(
                |w| machines_of(&brick, w).contains(&machine),
                |w| format!("{} to be offered; {}", machine, describe_now(w)),
            )
        },
    );
    steps.step(
        &format!("the cluster also has the machines {Q} and {Q}"),
        |world, c, _| {
            world.mc.join_named(&c[0]);
            world.mc.join_named(&c[1]);
            let brick = page(world, 0.0)?;
            world.wait_for_with(
                |w| machines_of(&brick, w).len() == 3,
                |w| format!("both to be offered; {}", describe_now(w)),
            )
        },
    );
    steps.step(
        &format!("(this machine|{Q}) runs a HAL-C2 from before pairing links named their address"),
        |world, c, _| {
            // The quoted alternative captures the name again, without its quotes.
            fake(world).silent.insert(c[1].clone());
            Ok(())
        },
    );
    steps.step(
        "the Connections settings are shown in (a wide window|a narrow window|a window narrower than a code can be read)",
        |world, c, _| {
            let width = match c[0].as_str() {
                "a wide window" => 900.0,
                "a narrow window" => 300.0,
                _ => 200.0,
            };
            page(world, width).map(|_| ())
        },
    );
    steps.step(
        "the user creates a pairing link over Tailscale",
        |world, _, _| create_from_page(world, true),
    );
    steps.step(
        "the user creates a pairing link at the address this machine listens on",
        |world, _, _| create_from_page(world, false),
    );
    steps.step(
        &format!("the user (?:creates|created) a pairing link for {Q}( over Tailscale)?"),
        |world, c, _| {
            choose_machine(world, &c[0])?;
            create_from_page(world, !c[1].is_empty())
        },
    );
    // Its answer is the scenario's to wait for ("the MC holds its answers").
    steps.step(
        &format!("the user asks for a pairing link for {Q}"),
        |world, c, _| {
            choose_machine(world, &c[0])?;
            ask_from_page(world, false)
        },
    );
    steps.step(
        &format!("(this machine|{Q}) is asked for the pairing link over Tailscale"),
        |world, c, _| {
            let asked = last_call(world, "hal-c2.createPairingLink")?;
            let machine = if c[1].is_empty() {
                world.mc.environment_id.clone()
            } else {
                c[1].clone()
            };
            expect!(
                asked.environment == machine && asked.payload["tailscale"] == json!(true),
                "{} was asked with {}",
                asked.environment,
                show(&asked.payload)
            );
            Ok(())
        },
    );
    steps.step(&format!("the link shown starts with {Q}"), |world, c, _| {
        let link = shown_link(world)?;
        let code = text(at(&connections(world)?, "created.code"));
        expect!(
            !code.is_empty() && link == format!("{}{code}", c[0]),
            "the link shown is {link}"
        );
        Ok(())
    });
    steps.step(
        "the link shown starts with the address this desktop reached the machine at",
        |world, _, _| {
            let link = shown_link(world)?;
            let prefix = format!("{}/pair#token=secret-", world.mc.origin());
            expect!(link.starts_with(&prefix), "the link shown is {link}");
            Ok(())
        },
    );
    steps.step(
        "a QR code of the link shown is offered, dark on light",
        |world, _, _| {
            let link = shown_link(world)?;
            expect_qr_code_of(world, &link)
        },
    );
    steps.step(
        "the QR code of the link shown is (whole, at its full size|whole, smaller|no smaller than a phone can scan)",
        |world, c, _| {
            let link = shown_link(world)?;
            expect_qr_code_of(world, &link)?;
            let brick = page(world, 0.0)?;
            let drawn = brick.item(world, "connectionsQr")?;
            let module = number(&brick, world, drawn, "moduleSize");
            let full = (number(&brick, world, drawn, "preferredSide")
                / number(&brick, world, drawn, "side"))
            .ceil();
            // The page's content ends its margin short of the window's edge.
            let root = brick.root(world);
            let room = root.map_or(f64::NAN, |root| number(&brick, world, root, "contentWidth"));
            let width = number(&brick, world, drawn, "width");
            let is = format!(
                "each module is {module} px ({full} at full size), the code is {width} wide where the page has {room}"
            );
            let ok = match c[0].as_str() {
                "whole, at its full size" => module == full && width <= room,
                "whole, smaller" => module < full && module >= 4.0 && width <= room,
                // Four pixels a module is as small as it gets, though the page has less room than that.
                _ => module == 4.0 && width > room,
            };
            expect!(ok, "{is}");
            Ok(())
        },
    );
    steps.step("no QR code is offered", |world, _, _| {
        let created = connections(world)?["created"].clone();
        let brick = page(world, 0.0)?;
        let drawn = brick.item(world, "connectionsQr")?;
        expect!(
            created.is_object() && created["qr"].is_null() && !brick.flag(world, drawn, "visible"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told to create the link over Tailscale or start the machine on a network address",
        |world, _, _| {
            let brick = page(world, 0.0)?;
            let told = brick.item(world, "connectionsLocalOnly")?;
            let said = brick.text_of(world, told, "text");
            let visible = brick.flag(world, told, "visible");
            expect!(
                visible
                    && said.contains("No QR code")
                    && said.contains("over Tailscale")
                    && said.contains("HAL_C2_MC_HOST"),
                "the page says \"{said}\" (shown: {visible})"
            );
            Ok(())
        },
    );
    steps.step("no pairing link is shown", |world, _, _| {
        let created_gone = connections(world)?["created"].is_null();
        let brick = page(world, 0.0)?;
        let field = brick.item(world, "connectionsCreatedLink")?;
        let qr = brick.item(world, "connectionsQr")?;
        expect!(
            created_gone
                && !brick.flag(world, field, "visible")
                && !brick.flag(world, qr, "visible"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("a pairing link can be for this machine(?:, {Q})? or {Q}"),
        |world, c, _| {
            let mut wanted = vec!["This machine".to_owned()];
            wanted.extend(c.iter().filter(|label| !label.is_empty()).cloned());
            let expected = wanted.clone();
            let brick = page(world, 0.0)?;
            world.wait_for_with(
                move |w| machines_of(&brick, w) == expected,
                |w| {
                    let offered = machines_of(&brick, w);
                    format!(
                        "{} to be offered; offered are {}",
                        wanted.join(", "),
                        offered.join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "no choice of machine is offered for a pairing link",
        |world, _, _| {
            let offered = offered_machines(world)?;
            let brick = page(world, 0.0)?;
            let create = brick.item(world, "connectionsCreateLink")?;
            expect!(
                offered.is_empty() && brick.flag(world, create, "visible"),
                "offered are {}",
                offered.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the user revokes that link", |world, _, _| {
        let brick = page(world, 0.0)?;
        brick.click(world, "connectionsRevokeCreated")
    });
    steps.step(&format!("{Q} is asked to revoke it"), |world, c, _| {
        let asked = last_call(world, "hal-c2.revokePairingLink")?;
        expect!(asked.environment == c[0], "{} was asked", asked.environment);
        Ok(())
    });

    // Clients.
    steps.step(&format!("the client {Q} is connected"), |world, c, _| {
        add_client(world, &c[0]);
        expect!(client_listed(world, &c[0])?, "{}", describe(world));
        Ok(())
    });
    steps.step(&format!("the user revokes {Q}"), |world, c, _| {
        world.dispatch(
            "connections.client.revoke",
            json!({"sessionId": format!("session-{}", host_of(&c[0]))}),
        )
    });
    steps.step(
        &format!("{Q} is signed out and no longer listed"),
        |world, c, _| {
            expect!(
                called(world, "hal-c2.revokeClient")?,
                "the MC was not asked to revoke it"
            );
            expect!(!client_listed(world, &c[0])?, "{}", describe(world));
            let expected = format!("{} was signed out.", c[0]);
            expect_notice(world, "success", |t| t == expected)
        },
    );
    steps.step(
        "three clients are listed including this one",
        |world, _, _| {
            add_client(world, "Phone");
            add_client(world, "Laptop");
            expect!(listed(world, "clients")?.len() == 3, "{}", describe(world));
            Ok(())
        },
    );
    steps.step("the user revokes the others", |world, _, _| {
        world.dispatch("connections.clients.revokeOthers", Value::Null)
    });
    steps.step("only this client is listed", |world, _, _| {
        let clients = listed(world, "clients")?;
        expect!(
            clients.len() == 1 && clients[0]["current"] == json!(true),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told (\\d+) clients were revoked",
        |world, c, _| {
            let expected = format!("{} clients were revoked.", c[0]);
            expect_notice(world, "success", |t| t == expected)
        },
    );
    steps.step(
        "there are no pairing links or client sessions",
        |world, _, _| {
            fake(world).pairing_links = Vec::new();
            fake(world).clients = Vec::new();
            world.dispatch("connections.refresh", Value::Null)
        },
    );
    steps.step(
        "the user is told there are no pairing links or client sessions",
        |world, _, _| {
            let page = connections(world)?;
            // ConnectionsSettings.qml says so when both lists are empty.
            expect!(
                !page["access"].is_null()
                    && listed(world, "pairingLinks")?.is_empty()
                    && listed(world, "clients")?.is_empty(),
                "the Connections page is {}",
                show(&page)
            );
            Ok(())
        },
    );

    // Other machines.
    steps.step(
        "the user goes on to this machine's cluster",
        |world, _, _| world.dispatch("cluster.open", Value::Null),
    );
}
