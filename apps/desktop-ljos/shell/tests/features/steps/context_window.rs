//! How full the open thread's context window is
//! (features/timeline/runs-and-queue.feature): the provider thread on
//! the thread's stream carries the provider's latest report
//! (contextUsage), which the composer's ContextWindowMeter reads
//! behind its setting: desktop-qt's ContextWindowSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::stream::{THREAD, iso, now, read, set};
use crate::brick::{self, Brick};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

const PROVIDER_THREAD: &str = "provider-thread-1";

/// Whether the scenario said where the meter's setting stands; otherwise
/// the meter is on, as the scenarios that read it take for granted.
#[derive(Default)]
struct MeterSetting {
    said: bool,
}

fn composer(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem {\n\
               Composer { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom }\n}\n",
            720.0,
            360.0,
        )?;
    }
    brick::shown(world)
}

fn set_meter(world: &mut World, on: bool) {
    world.mc.part::<MeterSetting>().said = true;
    Settings::of(world.engine()).set(world.engine(), "contextWindowMeterEnabled", json!(on));
}

fn count(digits: &str) -> f64 {
    digits.replace(',', "").parse().unwrap_or(0.0)
}

fn usage(world: &World) -> Json {
    world
        .mc
        .peek::<super::stream::FakeStreams>()
        .and_then(|fake| fake.threads.get(THREAD))
        .and_then(|entities| entities.get(&format!("provider-thread\n{PROVIDER_THREAD}")))
        .map(|thread| thread["contextUsage"].clone())
        .unwrap_or(Json::Null)
}

/// The provider's report on the thread, as its adapter writes it.
fn report(world: &mut World, context_usage: Json) -> Outcome {
    set(
        world,
        "provider-thread",
        PROVIDER_THREAD,
        json!({"id": PROVIDER_THREAD, "appThreadId": THREAD,
               "contextUsage": context_usage, "updatedAt": iso(now())}),
    )
}

fn reading(world: &World) -> Json {
    read(world, |t| Json::Object(t.context_window())).unwrap_or(Json::Null)
}

fn meter(world: &mut World) -> Outcome<Option<ObjectId>> {
    let view = composer(world)?;
    view.find(world, "contextWindowMeter")
}

fn meter_shown(world: &World) -> bool {
    let Some(view) = world.peek_part::<brick::Shown>().and_then(|shown| shown.0) else {
        return false;
    };
    view.find(world, "contextWindowMeter")
        .ok()
        .flatten()
        .is_some_and(|item| view.flag(world, item, "visible"))
}

fn seen(world: &World) -> String {
    format!(
        "the meter is {}; the thread's context window is {}",
        if meter_shown(world) {
            "shown"
        } else {
            "hidden"
        },
        show(&reading(world))
    )
}

fn open_details(world: &mut World) -> Outcome {
    let view = composer(world)?;
    world.wait_for("the meter to show", |w| {
        view.find_visible(w, "contextWindowMeter")
            .is_ok_and(|found| found.is_some())
    })?;
    view.click(world, "contextWindowMeter")?;
    world.wait_for_with(
        move |w| {
            // Shown, and done fading in.
            let Some(details) = view
                .find(w, "contextWindowDetails")
                .ok()
                .flatten()
                .filter(|&item| view.flag(w, item, "visible"))
            else {
                return false;
            };
            let mut item = Some(details);
            while let Some(current) = item {
                let engine = w.engine();
                let opacity = engine.read_by_name(current, "opacity");
                if matches!(opacity, Value::Real(r) if r < 1.0) {
                    return false;
                }
                item = match engine.read_by_name(current, "parent") {
                    Value::Object(parent) => Some(parent),
                    _ => None,
                };
            }
            true
        },
        |w| format!("the context window's details to open; {}", seen(w)),
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the agent has used ([\\d,]+) tokens of (?:a ([\\d,]+) token window|an unknown window)",
        |world, c, _| {
            composer(world)?;
            if !world.mc.part::<MeterSetting>().said {
                Settings::of(world.engine()).set(
                    world.engine(),
                    "contextWindowMeterEnabled",
                    json!(true),
                );
            }
            let mut context_usage = json!({"usedTokens": count(&c[0])});
            if !c[1].is_empty() {
                context_usage["maxTokens"] = json!(count(&c[1]));
            }
            report(world, context_usage)?;
            let used = count(&c[0]);
            world.wait_for_with(
                move |w| reading(w)["usedTokens"].as_f64() == Some(used),
                |w| seen(w),
            )
        },
    );
    steps.step(&format!("the context window reads {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| meter_shown(w) && text(&reading(w)["reading"]) == wanted,
            {
                let wanted = c[0].clone();
                move |w| format!("the context window to read \"{wanted}\"; {}", seen(w))
            },
        )?;
        open_details(world)?;
        let view = composer(world)?;
        let label = view
            .find(world, "contextWindowReading")?
            .map_or_else(String::new, |item| view.text_of(world, item, "text"));
        expect!(label == c[0], "{}", seen(world));
        Ok(())
    });
    steps.step("the context window meter setting is off", |world, _, _| {
        composer(world)?;
        set_meter(world, false);
        Ok(())
    });
    steps.step(
        "the user turns the context window meter setting on",
        |world, _, _| {
            set_meter(world, true);
            Ok(())
        },
    );
    steps.step(
        "the thread shows no context window reading",
        |world, _, _| {
            world.sync()?;
            let read_back = reading(world);
            expect!(
                read_back.as_object().is_some_and(|map| !map.is_empty()) && !meter_shown(world),
                "{}",
                seen(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the context window is {Q} full"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| meter_shown(w) && text(&reading(w)["percentLabel"]) == wanted,
            {
                let wanted = c[0].clone();
                move |w| format!("the context window to be {wanted} full; {}", seen(w))
            },
        )
    });
    steps.step(
        "the context window reading is marked as nearly full",
        |world, _, _| {
            world.wait_for_with(
                |w| meter_shown(w) && reading(w)["nearlyFull"] == json!(true),
                |w| seen(w),
            )?;
            open_details(world)?;
            let view = composer(world)?;
            let Some(label) = view.find(world, "contextWindowReading")? else {
                crate::fail!("no reading is drawn; {}", seen(world));
            };
            let Some(shown_meter) = meter(world)? else {
                crate::fail!("no meter is drawn; {}", seen(world));
            };
            let marked = world.engine().read_by_name(shown_meter, "usedColor");
            let colour = world.engine().read_by_name(label, "color");
            // The reading takes the ring's colour only when it is marked;
            // it is the text's otherwise.
            expect!(colour == marked, "{}", seen(world));
            Ok(())
        },
    );
    steps.step(
        "the thread has processed ([\\d,]+) tokens in all at a cost of ([\\d.]+) US dollars",
        |world, c, _| {
            let mut context_usage = usage(world);
            if !context_usage.is_object() {
                context_usage = json!({});
            }
            context_usage["totalProcessedTokens"] = json!(count(&c[0]));
            context_usage["cost"] =
                json!({"amount": c[1].parse::<f64>().unwrap_or(0.0), "currency": "USD"});
            report(world, context_usage)?;
            world.wait_for_with(|w| !text(&reading(w)["cost"]).is_empty(), |w| seen(w))
        },
    );
    steps.step(
        "the user opens the context window's details",
        |world, _, _| open_details(world),
    );
    steps.step(
        &format!("the details show {Q} as ([^ ]+) and {Q} as {Q}"),
        |world, c, _| {
            let view = composer(world)?;
            let first = format!("contextWindowFact:{}", c[0]);
            let second = format!("contextWindowFact:{}", c[2]);
            let (first_wanted, second_wanted) = (c[1].clone(), c[3].clone());
            world.wait_for_with(
                move |w| {
                    let said = |w: &World, name: &str| {
                        view.find(w, name)
                            .ok()
                            .flatten()
                            .map_or_else(String::new, |item| view.text_of(w, item, "text"))
                    };
                    said(w, &first) == first_wanted && said(w, &second) == second_wanted
                },
                {
                    let (c0, c1, c2, c3) =
                        (c[0].clone(), c[1].clone(), c[2].clone(), c[3].clone());
                    move |w| {
                        let said = |w: &World, name: &str| {
                            view.find(w, name)
                                .ok()
                                .flatten()
                                .map_or_else(String::new, |item| view.text_of(w, item, "text"))
                        };
                        format!(
                            "the details to show {c0} as {c1} and {c2} as {c3}; they show {} and {}",
                            said(w, &format!("contextWindowFact:{c0}")),
                            said(w, &format!("contextWindowFact:{c2}"))
                        )
                    }
                },
            )
        },
    );
    steps.step(
        "a thread whose provider reports no cost shows no cost",
        |world, _, _| {
            let mut context_usage = usage(world);
            if let Some(object) = context_usage.as_object_mut() {
                object.remove("cost");
            }
            report(world, context_usage)?;
            let view = composer(world)?;
            world.wait_for_with(
                move |w| {
                    let cost = view.find(w, "contextWindowFact:Cost").ok().flatten();
                    let shown_cost = cost.is_some_and(|item| {
                        view.flag(w, item, "visible")
                            && match w.engine().read_by_name(item, "parent") {
                                Value::Object(parent) => view.flag(w, parent, "visible"),
                                _ => false,
                            }
                    });
                    text(&reading(w)["cost"]).is_empty() && !shown_cost
                },
                |w| seen(w),
            )
        },
    );
}
