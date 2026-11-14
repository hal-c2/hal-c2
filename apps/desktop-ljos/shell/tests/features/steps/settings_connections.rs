//! Settings → Connections beyond its environments and access lists: a session
//! that may only look, and a pairing link the clipboard refuses
//! (features/settings/connections.feature): desktop-qt's
//! SettingsConnectionsSteps.cpp.

use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Steps, at, show, text};
use crate::world::World;

fn page(world: &World) -> Value {
    world.state("connections")
}

fn describe(world: &World) -> String {
    format!("the Connections page is {}", show(&page(world)))
}

fn create_link(world: &mut World) -> crate::harness::Outcome {
    world.dispatch(
        "connections.pairingLink.create",
        json!({"label": "Phone", "scopes": ["orchestration:read", "orchestration:operate"]}),
    )
}

pub fn register(steps: &mut Steps) {
    // A session that may only look.
    steps.step("the user looks at this machine", |world, _, _| {
        world.wait_for_with(|w| !page(w)["accessError"].is_null(), describe)
    });
    steps.step("its controls cannot be changed", |world, _, _| {
        // Nothing is listed to change, and what is asked anyway is refused.
        expect!(
            page(world)["access"].is_null() && page(world)["created"].is_null(),
            "{}",
            describe(world)
        );
        create_link(world)?;
        world.sync()?;
        world.wait_for_with(|w| page(w)["busy"] != json!(true), describe)?;
        expect!(
            page(world)["created"].is_null() && page(world)["access"].is_null(),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // The clipboard.
    steps.step("the clipboard is unavailable", |world, _, _| {
        world.set_clipboard_fails(true);
        Ok(())
    });
    steps.step("the user copies a pairing link", |world, _, _| {
        create_link(world)?;
        world.wait_for_with(|w| !page(w)["created"].is_null(), describe)?;
        world.dispatch("connections.pairingLink.copy", Value::Null)
    });
    steps.step(
        "the link is shown so the user can copy it by hand",
        |world, _, _| {
            let shown = page(world);
            let url = text(at(&shown, "created.url"));
            expect!(
                shown["revealed"] == json!(true)
                    && url.contains("/pair#token=")
                    && at(&shown, "notice.kind") == "error"
                    && text(at(&shown, "notice.text")).contains("by hand"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
}
