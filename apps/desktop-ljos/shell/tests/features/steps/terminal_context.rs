//! Terminal excerpts on the composer's draft: a terminal selection added to
//! the chat (composer.terminalContext.add, as the terminal's menu dispatches
//! it), the chips the composer shows and removes, and the context records a
//! send carries (features/terminal/composer-context.feature,
//! composer/context-references.feature). A quoted reply is held the same way
//! (composer.citation.add, as the timeline's Cite dispatches it).
//! desktop-qt's TerminalContextSteps.cpp.

use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::Navigation;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};

const FAILURE: &str = "FAIL cart.test.ts\n  expected 3, got 2\n  at cart.test.ts:12";

/// The reply the quote scenarios cite from.
const PARAGRAPH: &str =
    "Cache keys include the tenant, so <one> tenant's entries never serve another.";

/// The selection the scenario's terminal shows, and the draft's text before
/// the last removal.
#[derive(Default)]
struct ContextState {
    selection: Value,
    text_before: String,
}

fn target(world: &World) -> Outcome<String> {
    world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
}

fn composer_state(world: &World) -> Value {
    world.state("composer")
}

fn chips(world: &World) -> Vec<Value> {
    composer_state(world)["terminalContexts"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The chip's words, as the composer brick writes them.
fn label(chip: &Value) -> String {
    let start = chip["lineStart"].as_i64().unwrap_or(0);
    let end = chip["lineEnd"].as_i64().unwrap_or(0);
    let name = text(&chip["label"]);
    if start == end {
        format!("{name} line {start}")
    } else {
        format!("{name} lines {start}-{end}")
    }
}

fn labels(world: &World) -> Vec<String> {
    chips(world).iter().map(label).collect()
}

fn selection(terminal: &str, start: i64, end: i64, body: &str) -> Value {
    let number = terminal.rsplit(' ').next().unwrap_or_default();
    json!({"terminalId": format!("term-{number}"), "terminalLabel": terminal,
           "lineStart": start, "lineEnd": end, "text": body})
}

fn add(world: &mut World, selection: Value) -> Outcome {
    open_turn_thread(world)?;
    world.part::<ContextState>().selection = selection.clone();
    world.dispatch("composer.terminalContext.add", selection)
}

/// The newest message the MC was sent.
fn last_message(world: &World) -> Option<Value> {
    world
        .mc
        .commands
        .iter()
        .rev()
        .find(|command| text(&command["type"]) == "message.dispatch")
        .cloned()
}

fn wait_for_message(world: &mut World) -> Outcome<Value> {
    world.wait_for_with(
        |w| last_message(w).is_some(),
        |w| format!("a message; the MC has {}", w.describe_commands()),
    )?;
    Ok(last_message(world).unwrap_or(Value::Null))
}

fn quotes(world: &World) -> Vec<Value> {
    composer_state(world)["citations"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// Cites the paragraph, as selecting it in the reply and choosing Cite does.
fn cite(world: &mut World) -> Outcome {
    open_turn_thread(world)?;
    world.dispatch(
        "composer.citation.add",
        json!({"messageId": "msg-caching", "text": PARAGRAPH, "start": 12,
               "end": 12 + PARAGRAPH.chars().count(), "prefix": "On caching: ", "suffix": ""}),
    )?;
    world.wait_for_with(
        |w| quotes(w).len() == 1,
        |w| {
            format!(
                "one quote; the composer shows {}",
                show(&Value::Array(quotes(w)))
            )
        },
    )
}

fn comment(world: &mut World, body: &str) -> Outcome {
    let id = quotes(world)
        .first()
        .map_or(Value::Null, |quote| quote["id"].clone());
    world.dispatch(
        "composer.citation.comment",
        json!({"id": id, "comment": body}),
    )?;
    world.wait_for_with(
        |w| quotes(w).first().is_some_and(|q| text(&q["comment"]) == body),
        |w| {
            format!(
                "the comment {}; the composer shows {}",
                show(&json!(body)),
                show(&Value::Array(quotes(w)))
            )
        },
    )
}

fn terminal_record(message: &Value) -> Option<Value> {
    message["context"]["records"]
        .as_array()?
        .iter()
        .find(|record| text(&record["kind"]) == "terminal")
        .cloned()
}

fn no_context_link(message: &Value) -> bool {
    !text(&message["text"]).contains("hal-c2-context:")
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("{Q} shows a failing test on lines (\\d+) to (\\d+)"),
        |world, c, _| {
            open_turn_thread(world)?;
            world.part::<ContextState>().selection = selection(
                &c[0],
                c[1].parse().unwrap_or(0),
                c[2].parse().unwrap_or(0),
                FAILURE,
            );
            Ok(())
        },
    );
    steps.step("the user selects those lines and adds them to the chat", |world, _, _| {
        let selection = world.part::<ContextState>().selection.clone();
        add(world, selection)
    });
    steps.step(
        &format!("the user adds line (\\d+) of {Q} to the chat"),
        |world, c, _| {
            let line = c[0].parse().unwrap_or(0);
            add(world, selection(&c[1], line, line, "$ npm test"))
        },
    );
    steps.step(
        "the user selects blank lines in the terminal and adds them to the chat",
        |world, _, _| add(world, selection("Terminal 1", 4, 6, "\n\n\n")),
    );
    steps.step(
        &format!("the draft holds an excerpt from {Q} lines (\\d+) to (\\d+)"),
        |world, c, _| {
            add(
                world,
                selection(
                    &c[0],
                    c[1].parse().unwrap_or(0),
                    c[2].parse().unwrap_or(0),
                    FAILURE,
                ),
            )
        },
    );

    steps.step(
        &format!("the draft gains an excerpt labelled {Q}"),
        |world, c, _| {
            let expected = vec![c[0].clone()];
            world.wait_for_with(
                |w| labels(w) == expected,
                |w| format!("the excerpt; the composer shows {}", show(&json!(labels(w)))),
            )
        },
    );
    steps.step("the excerpt holds the selected text", |world, _, _| {
        let held = composer::terminal_contexts(world.engine(), &target(world)?);
        let wanted = world.part::<ContextState>().selection["text"].clone();
        expect!(
            held.len() == 1 && held[0]["text"] == wanted,
            "the draft holds {}",
            show(&Value::Array(held))
        );
        Ok(())
    });
    steps.step("the draft gains no excerpt", |world, _, _| {
        world.sync()?;
        expect!(
            chips(world).is_empty(),
            "the composer shows {}",
            show(&json!(labels(world)))
        );
        Ok(())
    });
    steps.step(
        "the composer shows that excerpt with its terminal and lines",
        |world, _, _| {
            let selection = world.part::<ContextState>().selection.clone();
            let chip = json!({"label": selection["terminalLabel"],
                              "lineStart": selection["lineStart"], "lineEnd": selection["lineEnd"]});
            let expected = vec![label(&chip)];
            world.wait_for_with(
                |w| labels(w) == expected,
                |w| {
                    format!(
                        "{}; the composer shows {}",
                        expected[0],
                        show(&json!(labels(w)))
                    )
                },
            )
        },
    );
    steps.step("the user removes that excerpt", |world, _, _| {
        let shown = chips(world);
        expect!(!shown.is_empty(), "the composer shows no excerpt");
        let before = composer::draft(world.engine(), &target(world)?);
        world.part::<ContextState>().text_before = before;
        world.dispatch(
            "composer.terminalContext.remove",
            json!({"id": shown[0]["id"]}),
        )
    });
    steps.step("the draft no longer holds it", |world, _, _| {
        let key = target(world)?;
        world.wait_for_with(
            |w| chips(w).is_empty() && composer::terminal_contexts(w.engine(), &key).is_empty(),
            |w| format!("no excerpt; the composer shows {}", show(&json!(labels(w)))),
        )
    });
    steps.step("the rest of the draft is unchanged", |world, _, _| {
        let now = composer::draft(world.engine(), &target(world)?);
        let before = world.part::<ContextState>().text_before.clone();
        expect!(
            now == before,
            "the draft's text went from {} to {}",
            show(&json!(before)),
            show(&json!(now))
        );
        Ok(())
    });

    // An excerpt the store kept without its text.
    steps.step(
        "a restored draft holds a terminal excerpt with no text left",
        |world, _, _| {
            let excerpt = json!({"id": "c1", "terminalId": "term-1", "terminalLabel": "Terminal 1",
                                 "lineStart": 3, "lineEnd": 5, "text": ""});
            let stashed = json!({"id": "s1", "createdAt": "2026-09-23T09:00:00.000Z",
                                 "text": "why does this fail?", "attachments": [],
                                 "terminalContexts": [excerpt]});
            let data = world.home_dir().join("data");
            std::fs::create_dir_all(&data).map_err(|e| crate::harness::Failure(e.to_string()))?;
            let file = data.join("shell-composer.json");
            std::fs::write(
                &file,
                json!({"targets": {}, "stash": [stashed]}).to_string(),
            )
            .map_err(|e| crate::harness::Failure(format!("cannot write {}: {e}", file.display())))?;
            world.restart()?;
            open_turn_thread(world)?;
            world.dispatch("composer.stash.restore", json!({"id": "s1"}))?;
            world.wait_for_with(
                |w| {
                    chips(w).len() == 1
                        && at(&composer_state(w), "text") == "why does this fail?"
                },
                |w| {
                    format!(
                        "the restored draft; the composer shows {}",
                        show(&composer_state(w))
                    )
                },
            )?;
            let chips = chips(world);
            expect!(text(&chips[0]["text"]).is_empty(), "{}", show(&Value::Array(chips)));
            Ok(())
        },
    );
    steps.step("the user sends the message", |world, _, _| {
        let revision = world.next_edit;
        world.next_edit += 1;
        let body = composer_state(world)["text"].clone();
        world.dispatch(
            "composer.submit",
            json!({"edit": {"clientId": "qml", "revision": revision}, "text": body,
                   "intent": "foreground"}),
        )?;
        world.sync()
    });
    steps.step("the empty excerpt is not sent", |world, _, _| {
        let message = wait_for_message(world)?;
        expect!(
            message["text"] == "why does this fail?"
                && terminal_record(&message).is_none()
                && no_context_link(&message),
            "the message carries {}",
            show(&message)
        );
        // And the draft is left without it.
        world.wait_for_with(
            |w| chips(w).is_empty(),
            |w| show(&Value::Array(chips(w))),
        )
    });

    // What a send carries.
    steps.step(
        &format!("the message references the excerpt {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| last_message(w).and_then(|m| terminal_record(&m)).is_some(),
                |w| format!("a message with an excerpt; the MC has {}", w.describe_commands()),
            )?;
            let message = last_message(world).unwrap_or(Value::Null);
            let record = terminal_record(&message).unwrap_or(Value::Null);
            let link = format!(
                "[{}](hal-c2-context://v1/terminal/{})",
                c[0],
                text(&record["contextId"])
            );
            expect!(
                text(&record["label"]) == c[0],
                "the excerpt is labelled {}",
                show(&record)
            );
            expect!(
                text(&message["text"]).contains(&link),
                "the message text {} has no {link}",
                show(&message["text"])
            );
            Ok(())
        },
    );
    steps.step("the message carries the excerpt's text", |world, _, _| {
        let record = last_message(world)
            .and_then(|m| terminal_record(&m))
            .unwrap_or(Value::Null);
        let wanted = text(&world.part::<ContextState>().selection["text"]);
        expect!(
            text(&record["text"]) == wanted,
            "the excerpt carries {}",
            show(&record)
        );
        Ok(())
    });
    steps.step("the message carries no excerpt", |world, _, _| {
        let message = wait_for_message(world)?;
        expect!(
            terminal_record(&message).is_none() && no_context_link(&message),
            "the message carries {}",
            show(&message)
        );
        Ok(())
    });

    // Quoted replies.
    steps.step(
        "the assistant replied with a paragraph about caching",
        |world, _, _| open_turn_thread(world),
    );
    steps.step("the user cites that paragraph in the composer", |world, _, _| {
        cite(world)
    });
    steps.step("the draft carries the quoted paragraph", |world, _, _| {
        let quotes = quotes(world);
        expect!(
            quotes.first().is_some_and(|q| text(&q["text"]) == PARAGRAPH),
            "the composer shows {}",
            show(&Value::Array(quotes))
        );
        Ok(())
    });
    for step in [
        "the user can add a comment to it",
        "the user can add a comment to the citation",
    ] {
        steps.step(step, |world, _, _| comment(world, "Too slow?"));
    }
    steps.step(
        &format!("the draft quotes the assistant's paragraph about caching with the comment {Q}"),
        |world, c, _| {
            cite(world)?;
            comment(world, &c[0])
        },
    );
    steps.step(
        &format!("the message cites the paragraph with the comment {Q}"),
        |world, c, _| {
            let message = wait_for_message(world)?;
            let body = text(&message["text"]);
            let marker = "[Assistant quote](";
            let Some(start) = body.find(marker).filter(|_| body.ends_with(')')) else {
                fail!("the message reads {}", show(&json!(body)))
            };
            let link = &body[start + marker.len()..body.len() - 1];
            let parsed = url::Url::parse(link).ok();
            let query = |key: &str| {
                parsed
                    .as_ref()
                    .and_then(|u| u.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned()))
                    .unwrap_or_default()
            };
            expect!(
                parsed.as_ref().is_some_and(|u| u.path().ends_with("/msg-caching"))
                    && query("text") == PARAGRAPH
                    && query("comment") == c[0],
                "the message cites {}",
                show(&json!(link))
            );
            Ok(())
        },
    );
    steps.step(
        "the stash lists the prompt by the quoted paragraph and its comment",
        |world, _, _| {
            let entries = world.state("composerStash")["entries"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let full = format!("{PARAGRAPH} Comment: Too slow?");
            let expected = format!("{}…", full.chars().take(90).collect::<String>());
            expect!(
                entries.len() == 1 && text(&entries[0]["snippet"]) == expected,
                "the stash holds {}",
                show(&Value::Array(entries))
            );
            Ok(())
        },
    );
    steps.step("the draft no longer quotes it", |world, _, _| {
        world.wait_for_with(
            |w| quotes(w).is_empty(),
            |w| {
                format!(
                    "no quote; the composer shows {}",
                    show(&Value::Array(quotes(w)))
                )
            },
        )
    });

    steps.step(&format!("the message starts with {Q}"), |world, c, _| {
        let message = wait_for_message(world)?;
        let body = text(&message["text"]);
        expect!(
            body.starts_with(&c[0]),
            "the message reads {}",
            show(&json!(body))
        );
        Ok(())
    });
}
