//! Pairing a phone with an environment (features/mobile/
//! pairing-and-environments.feature): the pairing screen as the user
//! touches and types it, against an exchange the scenario sets in
//! place of an MC that sells sessions for pairing links. Ported from
//! mobile-qt's PairingSteps; the steps that want a paired environment's
//! rows wait for the fake pairable MC and are undefined here until it
//! lands.

use hal_c2_mc::pairing::Outcome as Exchanged;

use crate::expect;
use crate::harness::{Outcome, Steps, at, show, text};
use crate::world::{World, fake_exchange};

fn phase(world: &World) -> String {
    text(at(&world.state("pairing"), "phase"))
}

fn shown_text(world: &World, object_name: &str) -> Outcome<String> {
    let item = world.item(object_name)?;
    Ok(world.text_of(item, "text"))
}

/// The app's own link to a pairing link, as the MC's /pair page offers it.
fn app_link_to(link: &str) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(link.as_bytes()).collect();
    format!("hal-c2://pair?pairingUrl={encoded}")
}

/// Types `link` in the field, as a user does, opening the app first
/// if the scenario has not.
fn type_pairing_link(world: &mut World, link: &str) -> Outcome {
    if !world.is_open() {
        world.open()?;
    }
    world.touch("pairingLink")?;
    world.type_text(link)?;
    let field = world.item("pairingLink")?;
    expect!(
        world.text_of(field, "text") == link,
        "the field reads {}",
        world.text_of(field, "text")
    );
    Ok(())
}

/// Touches Pair and waits for the answer.
fn add_environment(world: &mut World) -> Outcome {
    // A phone on its side scrolls down to the button.
    let screen = world.item("pairingScreen")?;
    let (height, content) = (
        world.read(screen, "height").to_number(),
        world.read(screen, "contentHeight").to_number(),
    );
    let engine = world.engine().clone();
    engine
        .write_by_name(
            screen,
            "contentY",
            ljos::prelude::Value::Real((content - height).max(0.0)),
        )
        .map_err(|e| crate::harness::Failure(format!("contentY: {e:?}")))?;
    world.pump()?;
    world.touch("pairingPair")?;
    world.wait_for(
        |world| phase(world) != "pairing",
        |_| "an answer to the pairing link".into(),
    )
}

/// Types `link` in the field and touches Pair, as a user does, and
/// waits for the answer.
fn enter_pairing_link(world: &mut World, link: &str) -> Outcome {
    type_pairing_link(world, link)?;
    add_environment(world)
}

pub fn register(steps: &mut Steps) {
    steps.step("the app has never been paired", |world, _, _| {
        expect!(!world.is_open(), "the app is already open");
        expect!(
            !world.pairing_file().exists(),
            "the phone already keeps a pairing"
        );
        Ok(())
    });

    steps.step("the user opens the app", |world, _, _| world.open());

    steps.step(
        "the user is told no environments are connected",
        |world, _, _| {
            world.item("pairingScreen")?;
            expect!(
                shown_text(world, "pairingTitle")? == "No environment connected",
                "the screen says: {}",
                shown_text(world, "pairingTitle")?
            );
            Ok(())
        },
    );

    steps.step(
        "the user is offered to add an environment",
        |world, _, _| {
            let field = world.item("pairingLink")?;
            let pair = world.item("pairingPair")?;
            expect!(
                world.flag(field, "enabled"),
                "the pairing link cannot be entered"
            );
            expect!(
                world.text_of(pair, "text") == "Pair",
                "the button reads {}",
                world.text_of(pair, "text")
            );
            // Its help says where a link comes from.
            expect!(
                shown_text(world, "pairingHelp")?.contains("pairing link"),
                "the screen says: {}",
                shown_text(world, "pairingHelp")?
            );
            Ok(())
        },
    );

    steps.step(
        "the user enters a pairing link that carries a token",
        |world, _, _| {
            if world.link.is_empty() {
                world.link = "http://mc.example:3780/pair#token=abc".into();
            }
            let link = world.link.clone();
            type_pairing_link(world, &link)
        },
    );

    steps.step("the user adds the environment", |world, _, _| {
        add_environment(world)
    });

    steps.step("the pairing token has already been used", |world, _, _| {
        // Another device spent it: this one's exchange is refused.
        world.set_exchange(fake_exchange(Exchanged::Refused, None));
        world.link = "http://mc.example:3780/pair#token=spent".into();
        Ok(())
    });

    steps.step(
        "the environment at the pairing address is offline",
        |world, _, _| {
            world.set_exchange(fake_exchange(Exchanged::Unreachable, None));
            world.link = "http://127.0.0.1:9/pair#token=abc".into();
            Ok(())
        },
    );

    steps.step("the phone has no room to save a session", |world, _, _| {
        world.set_exchange(fake_exchange(Exchanged::Paired, None));
        world.fill_storage();
        Ok(())
    });

    steps.step("the user tries to pair with it", |world, _, _| {
        let link = world.link.clone();
        if !world.is_open() {
            world.open()?;
        }
        enter_pairing_link(world, &link)
    });

    steps.step("the user is told pairing failed", |world, _, _| {
        expect!(
            shown_text(world, "pairingError")?.starts_with("Pairing failed"),
            "the screen says: {}",
            shown_text(world, "pairingError")?
        );
        Ok(())
    });

    steps.step(
        "the user is told the environment could not be reached",
        |world, _, _| {
            expect!(
                shown_text(world, "pairingError")?.contains("could not be reached"),
                "the screen says: {}",
                shown_text(world, "pairingError")?
            );
            Ok(())
        },
    );

    steps.step(
        "the user is told the session could not be saved",
        |world, _, _| {
            let said = shown_text(world, "pairingError")?;
            expect!(
                said.contains("could not be saved on this device")
                    && said.contains("ask the environment for a fresh one"),
                "the screen says: {said}"
            );
            Ok(())
        },
    );

    steps.step(
        "the pairing form keeps what the user entered",
        |world, _, _| {
            let field = world.item("pairingLink")?;
            expect!(
                world.text_of(field, "text") == world.link,
                "the field reads {}",
                world.text_of(field, "text")
            );
            expect!(
                world.flag(field, "enabled"),
                "the field cannot be corrected"
            );
            Ok(())
        },
    );

    steps.step("no environment is added", |world, _, _| {
        expect!(phase(world) == "unpaired", "the phone is {}", phase(world));
        world.item("pairingScreen")?;
        expect!(
            world.find("homeScreen").is_none(),
            "the home screen is showing"
        );
        expect!(!world.pairing_file().exists(), "the phone keeps a pairing");
        Ok(())
    });

    steps.step(
        "the user follows a pairing link from outside the app",
        |world, _, _| {
            world.link = "http://mc.example:3780/pair#token=offered".into();
            if !world.is_open() {
                world.open()?;
            }
            let link = world.link.clone();
            world.follow_link(&app_link_to(&link))?;
            world.wait_for(
                |world| world.find("pairingOffer").is_some(),
                |world| {
                    format!(
                        "the pairing screen with the link; the phone is {}",
                        show(&world.state("pairing"))
                    )
                },
            )
        },
    );

    steps.step("the pairing form holds the link", |world, _, _| {
        expect!(
            shown_text(world, "pairingLink")? == world.link,
            "the field reads {}",
            shown_text(world, "pairingLink")?
        );
        Ok(())
    });

    steps.step(
        "the user is told which address the link would pair with",
        |world, _, _| {
            let offer = world.item("pairingOffer")?;
            expect!(
                world.flag(offer, "visible")
                    && world.text_of(offer, "text").contains("mc.example:3780"),
                "the offer reads {}",
                world.text_of(offer, "text")
            );
            Ok(())
        },
    );

    steps.step(
        "the user followed a pairing link from outside the app",
        |world, _, _| {
            world.link = "http://mc.example:3780/pair#token=offered".into();
            world.open()?;
            let link = world.link.clone();
            world.follow_link(&app_link_to(&link))
        },
    );

    steps.step(
        "the user follows a link from outside the app that carries no pairing link",
        |world, _, _| {
            if !world.is_open() {
                world.open()?;
            }
            world.follow_link("hal-c2://pair?pairingUrl=not-a-link")
        },
    );

    steps.step(
        "the user is told the link is not a pairing link",
        |world, _, _| {
            expect!(
                shown_text(world, "pairingError")?.contains("is not a pairing link"),
                "the screen says: {}",
                shown_text(world, "pairingError")?
            );
            Ok(())
        },
    );

    steps.step("the environment is added to the phone", |world, _, _| {
        // The environment's thread rows want a paired MC's snapshot
        // (the fake pairable MC); until the harness has one, what
        // proves the pairing is the phase, the kept session, and home
        // in the pairing screen's place.
        world.wait_for(
            |world| phase(world) == "paired",
            |world| format!("the phone to pair; it is {}", show(&world.state("pairing"))),
        )?;
        expect!(world.pairing_file().exists(), "the phone keeps no session");
        world.wait_for(
            |world| world.find("homeScreen").is_some(),
            |_| "the home screen".into(),
        )
    });
}
