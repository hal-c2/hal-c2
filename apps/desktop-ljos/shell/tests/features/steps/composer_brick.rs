//! The composer brick on screen (desktop-qt's ComposerBrick.h and
//! ComposerBrickSteps.cpp): what the user's keys and clicks do in the editor
//! and its toolbar, against the scenario's shell
//! (features/composer/drafting-and-sending.feature, editors-and-keys.feature,
//! qt-scenarios.feature).

use hal_c2_shell::controller;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use ljos::item::{KeyEvent, Modifiers, key};
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::stream::{self, PROJECT, THREAD};
use crate::steps::settings_composer::drawn_bold;
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};

/// The composer under the window's shortcuts (ShellWindow's Instantiator),
/// so a key a shortcut takes never reaches the editor here either.
const COMPOSER_QML: &str = r#"import QtQuick
import HalC2.Bricks
import HalC2.Shell
Item {
    id: root
    objectName: "composerBrick"
    anchors.fill: parent
    property int windowShortcuts: 0

    Composer {
        objectName: "composer"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }

    Instantiator {
        model: Keybindings.shortcuts

        delegate: Shortcut {
            required property var modelData

            sequence: modelData.sequence
            context: Qt.WindowShortcut
            enabled: modelData.chrome
            onActivated: {
                root.windowShortcuts += 1;
                Keybindings.press(modelData.sequence, { terminal: false, editable: true });
            }
        }
    }
}
"#;

/// What the last key press in the composer found there.
#[derive(Default)]
struct Pressed {
    text: String,
    commands: usize,
    cursor: i64,
}

fn target(world: &World) -> String {
    let route = controller::with::<Navigation, _>(world.engine(), |n, _| n.route().clone())
        .unwrap_or_default();
    match route {
        Route::Draft(id) => id,
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn shown(world: &World) -> Json {
    world.state("composer")
}

fn draft(world: &World, target: &str) -> String {
    composer::draft(world.engine(), target)
}

fn invoke(world: &World, item: ObjectId, function: &str, args: &[QmlValue]) -> Outcome<QmlValue> {
    world
        .engine()
        .invoke_by_name(item, function, args)
        .map_err(|e| Failure(format!("{function}: {e:?}")))
}

fn editor_text(world: &mut World) -> Outcome<String> {
    let (brick, editor) = editor(world)?;
    Ok(brick.text_of(world, editor, "text"))
}

fn number(brick: &Brick, world: &World, item: ObjectId, name: &str) -> i64 {
    brick
        .text_of(world, item, name)
        .parse::<f64>()
        .unwrap_or(-1.0) as i64
}

fn cursor(world: &mut World) -> Outcome<i64> {
    let (brick, editor) = editor(world)?;
    Ok(number(&brick, world, editor, "cursorPosition"))
}

fn set_cursor(world: &mut World, at: i64) -> Outcome {
    let (brick, editor) = editor(world)?;
    brick.write(world, editor, "cursorPosition", QmlValue::from(at as f64))
}

/// The editor's text, read without a brick in hand (for wait closures).
fn shown_editor_text(world: &World) -> String {
    let Some(brick) = composer_shown(world) else {
        return String::new();
    };
    match brick.find(world, "input") {
        Ok(Some(editor)) => brick.text_of(world, editor, "text"),
        _ => String::new(),
    }
}

fn messages(world: &mut World) -> Outcome<Vec<Value>> {
    world.sync()?;
    Ok(world
        .mc
        .commands
        .iter()
        .filter(|command| text(&command["type"]) == "message.dispatch")
        .cloned()
        .collect())
}

fn expect_nothing_sent(world: &mut World) -> Outcome {
    settle_composer(world)?;
    let sent = messages(world)?;
    expect!(sent.is_empty(), "the MC has {}", world.describe_commands());
    Ok(())
}

/// The editor holds `text` with the caret at `at`, as typed.
fn write(world: &mut World, typed: &str, at: i64) -> Outcome {
    composer_brick(world)?;
    let target = target(world);
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": typed, "cursor": at}),
    )?;
    let (want, shown) = (typed.to_owned(), typed.to_owned());
    world.wait_for_with(
        move |w| shown_editor_text(w) == want,
        move |w| {
            format!(
                "the editor to read \"{shown}\"; it reads \"{}\"",
                shown_editor_text(w)
            )
        },
    )?;
    set_cursor(world, at)?;
    settle_composer(world)
}

fn vim(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    let Some(keys) = brick.find(world, "vimKeys")? else {
        fail!("the composer has no Vim keys");
    };
    Ok((brick, keys))
}

fn set_setting(world: &mut World, key: &str, value: Json) -> Outcome {
    let engine = world.engine().clone();
    Settings::of(&engine).set(&engine, key, value);
    world.pump()
}

fn turn_on_vim(world: &mut World, normal: bool) -> Outcome {
    set_setting(world, "composerVimKeys", json!(true))?;
    let (brick, keys) = vim(world)?;
    expect!(
        brick.flag(world, keys, "vimEnabled"),
        "the composer's Vim keys are off"
    );
    if !normal {
        return Ok(());
    }
    expect!(
        press_in_composer(world, "Escape")?,
        "the composer did not take Escape"
    );
    expect!(
        !brick.flag(world, keys, "insertMode"),
        "Escape left the editor in insert mode"
    );
    Ok(())
}

fn other_thread(world: &mut World) -> Outcome<String> {
    let id = "thread-2";
    if !world.mc.threads.contains_key(id) {
        let row = json!({"id": id, "title": "Other", "projectId": PROJECT,
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
        world.mc.threads.insert(id.into(), row.clone());
        world.mc.send_row(id, &row);
        world.sync()?;
    }
    Ok(format!("{}:{id}", world.mc.environment_id))
}

fn look(world: &mut World, key: &str) -> Outcome {
    stream::look(world, key, true)
}

/// Prompts sent in the turn thread, one completed run each.
fn sent(world: &mut World, prompts: &[&str]) -> Outcome {
    open_turn_thread(world)?;
    for prompt in prompts {
        let run = stream::start_run(world, 60, "completed")?;
        stream::set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": prompt}),
        )?;
    }
    Ok(())
}

fn insert(world: &mut World, typed: &str, into: &str) -> Outcome<bool> {
    let item = composer_item(world)?;
    let inserted = invoke(
        world,
        item,
        "insertText",
        &[QmlValue::from(typed), QmlValue::from(into)],
    )?;
    world.pump()?;
    Ok(matches!(inserted, QmlValue::Bool(true)))
}

fn toasts(world: &World) -> Vec<Json> {
    at(&world.state("toasts"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    // Sending with Enter (drafting-and-sending.feature).
    steps.step(
        &format!("the message {Q} is sent to the agent"),
        |world, c, _| {
            let sent = messages(world)?;
            expect!(
                sent.len() == 1
                    && text(&sent[0]["text"]) == c[0]
                    && text(&sent[0]["threadId"]) == THREAD,
                "the MC has {}",
                world.describe_commands()
            );
            world.wait_for_with(
                |w| shown_editor_text(w).is_empty(),
                |w| format!("the editor to empty; it reads \"{}\"", shown_editor_text(w)),
            )
        },
    );
    steps.step(
        &format!("the user presses Shift\\+Enter and types {Q}"),
        |world, c, _| {
            composer_brick(world)?;
            expect!(
                press_in_composer(world, "Shift+Enter")?,
                "the composer did not take the key"
            );
            type_in_composer(world, &c[0])
        },
    );
    steps.step("the draft holds two lines", |world, _, _| {
        settle_composer(world)?;
        let draft = draft(world, &target(world));
        let editor = editor_text(world)?;
        expect!(
            draft == "first line\nsecond line" && editor == draft,
            "the draft reads \"{draft}\""
        );
        Ok(())
    });
    steps.step("nothing (?:has been|is) sent", |world, _, _| {
        expect_nothing_sent(world)
    });
    steps.step(
        &format!("the send shortcut setting is {Q}"),
        |world, c, _| {
            let value = match c[0].as_str() {
                "Enter" => "enter",
                "Mod+Enter for multiline prompts" => "mod-enter-multiline",
                "Mod+Enter" => "mod-enter",
                other => fail!("no send shortcut setting is called {other}"),
            };
            set_setting(world, "sendShortcut", json!(value))?;
            composer_brick(world)?;
            Ok(())
        },
    );
    steps.step("the user has typed two lines", |world, _, _| {
        let typed = "line one\nline two";
        write(world, typed, typed.chars().count() as i64)
    });
    steps.step("the message is sent", |world, _, _| {
        let pressed = world.part::<Pressed>().text.clone();
        let sent = messages(world)?;
        expect!(
            sent.len() == 1 && !pressed.is_empty() && text(&sent[0]["text"]) == pressed,
            "the draft read \"{pressed}\" and the MC has {}",
            world.describe_commands()
        );
        world.wait_for_with(
            |w| shown_editor_text(w).is_empty(),
            |w| format!("the editor to empty; it reads \"{}\"", shown_editor_text(w)),
        )
    });
    steps.step("a new line is added to the draft", |world, _, _| {
        let pressed = world.part::<Pressed>().text.clone();
        settle_composer(world)?;
        let draft = draft(world, &target(world));
        let editor = editor_text(world)?;
        expect!(
            draft == format!("{pressed}\n") && editor == draft,
            "the draft reads \"{draft}\""
        );
        let sent = messages(world)?;
        expect!(sent.is_empty(), "the MC has {}", world.describe_commands());
        Ok(())
    });
    steps.step(
        "a new thread starts with that message in the background",
        |world, _, _| {
            let prompt = world.part::<Pressed>().text.clone();
            expect!(!prompt.is_empty(), "the draft was empty");
            let (want, shown_prompt) = (prompt.clone(), prompt.clone());
            world.wait_for_with(
                move |w| w.mc.threads.values().any(|row| text(&row["title"]) == want),
                move |_| format!("the MC to launch \"{shown_prompt}\""),
            )?;
            world.sync()?;
            // In the background: the window stays on the draft, emptied for
            // the next prompt.
            let route = world.state("route");
            let composer = shown(world);
            expect!(
                text(&route["kind"]) == "draft" && text(&composer["text"]).is_empty(),
                "the route is {} and the composer shows {}",
                show(&route),
                show(&composer)
            );
            Ok(())
        },
    );
    steps.step("no window shortcut takes the key instead", |world, _, _| {
        let brick = composer_brick(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the composer brick has no root");
        };
        let taken = number(&brick, world, root, "windowShortcuts");
        expect!(taken == 0, "a window shortcut ran {taken} times");
        Ok(())
    });

    // Drafts and threads.
    steps.step(
        &format!("the user has just typed {Q} in thread A"),
        |world, c, _| {
            composer_brick(world)?;
            type_in_composer(world, &c[0])?;
            let editor = editor_text(world)?;
            expect!(editor == c[0], "the editor reads \"{editor}\"");
            Ok(())
        },
    );
    steps.step(
        "the user switches to thread B before the draft is saved",
        |world, _, _| {
            // The editor's text has not reached the shell yet.
            let thread_a = target(world);
            expect!(
                draft(world, &thread_a).is_empty(),
                "the draft was saved already"
            );
            let thread_b = other_thread(world)?;
            look(world, &thread_b)
        },
    );
    steps.step(
        &format!("thread B's draft does not contain {Q}"),
        |world, c, _| {
            settle_composer(world)?;
            let thread_b = other_thread(world)?;
            let draft = draft(world, &thread_b);
            let editor = editor_text(world)?;
            expect!(
                target(world) == thread_b && !draft.contains(&c[0]) && !editor.contains(&c[0]),
                "thread B's draft reads \"{draft}\" and its editor \"{editor}\""
            );
            Ok(())
        },
    );

    // Vim keys (editors-and-keys.feature).
    steps.step("Vim keys are on", |world, _, _| turn_on_vim(world, false));
    steps.step(
        "Vim keys are on and the editor is in normal mode",
        |world, _, _| turn_on_vim(world, true),
    );
    steps.step("the user turns on Vim keys in settings", |world, _, _| {
        let (brick, keys) = vim(world)?;
        expect!(
            !brick.flag(world, keys, "vimEnabled"),
            "Vim keys were on already"
        );
        // What the General page's switch does (SettingsRow).
        set_setting(world, "composerVimKeys", json!(true))
    });
    steps.step("the composer edits with Vim keys", |world, _, _| {
        write(world, "hello world", 0)?;
        press_in_composer(world, "Escape")?;
        press_in_composer(world, "w")?;
        let (editor, at) = (editor_text(world)?, cursor(world)?);
        expect!(
            editor == "hello world" && at == 6,
            "the draft reads \"{editor}\" with the cursor at {at}"
        );
        Ok(())
    });
    steps.step(
        "typed letters move the cursor instead of inserting text",
        |world, _, _| {
            let before = editor_text(world)?;
            set_cursor(world, 0)?;
            press_in_composer(world, "l")?;
            press_in_composer(world, "l")?;
            let (editor, at) = (editor_text(world)?, cursor(world)?);
            expect!(
                editor == before && at == 2,
                "the draft reads \"{editor}\" with the cursor at {at}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the draft reads {Q} with the cursor at the start"),
        |world, c, _| write(world, &c[0], 0),
    );
    steps.step(&format!("the cursor moves to {Q}"), |world, c, _| {
        let (editor, at) = (editor_text(world)?, cursor(world)?);
        let found = editor
            .find(c[0].as_str())
            .map(|byte| editor[..byte].chars().count() as i64);
        expect!(found == Some(at) && at > 0, "the cursor is at {at}");
        Ok(())
    });
    steps.step("the cursor moves to the end of the line", |world, _, _| {
        let (editor, at) = (editor_text(world)?, cursor(world)?);
        expect!(at == editor.chars().count() as i64, "the cursor is at {at}");
        Ok(())
    });
    steps.step("the user inserts at the end of the line", |world, _, _| {
        let (brick, keys) = vim(world)?;
        let insert_mode = brick.flag(world, keys, "insertMode");
        let (editor, at) = (editor_text(world)?, cursor(world)?);
        expect!(
            insert_mode && at == editor.chars().count() as i64,
            "insert mode {insert_mode}, the cursor at {at}"
        );
        type_in_composer(world, "!")?;
        let editor = editor_text(world)?;
        expect!(editor == "hello world!", "the draft reads \"{editor}\"");
        Ok(())
    });
    steps.step("the user switches to another thread", |world, _, _| {
        let thread_b = other_thread(world)?;
        look(world, &thread_b)?;
        settle_composer(world)
    });
    steps.step("typed letters insert text", |world, _, _| {
        type_in_composer(world, "hi")?;
        let editor = editor_text(world)?;
        expect!(editor == "hi", "the draft reads \"{editor}\"");
        Ok(())
    });

    // Rich text: the draft's Markdown drawn as it reads.
    steps.step(
        &format!("rich text editing is on and the draft shows {Q} in bold"),
        |world, c, _| {
            let on = Settings::of(world.engine())
                .setting(world.engine(), "composerRichTextEnabled")
                .unwrap_or(Json::Null);
            expect!(on == json!(true), "rich text is off");
            composer_brick(world)?;
            type_in_composer(world, &format!("**{}**", c[0]))?;
            settle_composer(world)?;
            let (brick, input) = editor(world)?;
            let word = c[0].clone();
            world.wait_for_with(
                |w| drawn_bold(w, brick, input, &word),
                |_| format!("\"{word}\" to be drawn bold"),
            )?;
            world.part::<Pressed>().text = c[0].clone();
            Ok(())
        },
    );
    steps.step("the user turns rich text editing off", |world, _, _| {
        set_setting(world, "composerRichTextEnabled", json!(false))?;
        let word = world.part::<Pressed>().text.clone();
        let (brick, input) = editor(world)?;
        world.wait_for_with(
            |w| !drawn_bold(w, brick, input, &word),
            |_| format!("\"{word}\" to be drawn plain"),
        )?;
        let editor = editor_text(world)?;
        expect!(
            editor == format!("**{word}**"),
            "the editor reads \"{editor}\""
        );
        Ok(())
    });

    // Text put into the composer by something else (voice input, a plugin).
    steps.step(
        &format!("the draft reads {Q} with {Q} selected"),
        |world, c, _| {
            write(world, &c[0], c[0].chars().count() as i64)?;
            let start = c[0]
                .find(c[1].as_str())
                .map_or(-1, |byte| c[0][..byte].chars().count() as i64);
            let end = start + c[1].chars().count() as i64;
            let (brick, editor) = editor(world)?;
            invoke(
                world,
                editor,
                "select",
                &[QmlValue::from(start as f64), QmlValue::from(end as f64)],
            )?;
            world.pump()?;
            let selected = brick.text_of(world, editor, "selectedText");
            expect!(selected == c[1], "the selection is \"{selected}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("text {Q} is inserted into the composer"),
        |world, c, _| {
            let target = target(world);
            expect!(
                insert(world, &c[0], &target)?,
                "the composer refused the text"
            );
            world.sync()
        },
    );
    steps.step("the user is writing in thread B", |world, _, _| {
        // Thread A.
        world.part::<Pressed>().text = target(world);
        let thread_b = other_thread(world)?;
        look(world, &thread_b)?;
        write(world, "for thread B", 12)
    });
    steps.step("text meant for thread A arrives late", |world, _, _| {
        let thread_a = world.part::<Pressed>().text.clone();
        expect!(
            !insert(world, "late transcript", &thread_a)?,
            "the composer took the text"
        );
        Ok(())
    });
    steps.step("thread B's draft is unchanged", |world, _, _| {
        settle_composer(world)?;
        let thread_b = other_thread(world)?;
        let draft = draft(world, &thread_b);
        let editor = editor_text(world)?;
        expect!(
            draft == "for thread B" && editor == draft,
            "thread B's draft reads \"{draft}\""
        );
        Ok(())
    });

    // Recalling sent prompts.
    steps.step(
        &format!("the user sent {Q} and then {Q} in this thread"),
        |world, c, _| sent(world, &[&c[0], &c[1]]),
    );
    steps.step(
        "the user recalls the previous prompt twice",
        |world, _, _| {
            composer_brick(world)?;
            press_in_composer(world, "Up")?;
            press_in_composer(world, "Up")?;
            Ok(())
        },
    );
    steps.step("the user moves forward again", |world, _, _| {
        press_in_composer(world, "Down")?;
        Ok(())
    });
    steps.step(
        "the composer is empty with keyboard focus",
        |world, _, _| {
            // In a thread whose last prompt was "Run the tests".
            sent(world, &["Run the tests"])?;
            let (brick, editor) = editor(world)?;
            let typed = brick.text_of(world, editor, "text");
            expect!(
                typed.is_empty() && brick.flag(world, editor, "activeFocus"),
                "the editor reads \"{typed}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the shell is asked for the previous prompt",
        |world, _, _| {
            // It answers with the thread's last prompt as the draft.
            let draft = draft(world, &target(world));
            expect!(
                draft == "Run the tests",
                "the shell's draft reads \"{draft}\""
            );
            Ok(())
        },
    );
    steps.step(&format!("the shell recalls {Q}"), |world, c, _| {
        let (want, recalled) = (c[0].clone(), c[0].clone());
        world.wait_for_with(
            move |w| text(&shown(w)["text"]) == want,
            move |w| {
                format!(
                    "the shell to publish {recalled}; it shows {}",
                    show(&shown(w))
                )
            },
        )
    });
    steps.step(&format!("the composer contains {Q}"), |world, c, _| {
        let (want, shown_want) = (c[0].clone(), c[0].clone());
        world.wait_for_with(
            move |w| shown_editor_text(w) == want,
            move |w| {
                format!(
                    "the editor to read {shown_want}; it reads \"{}\"",
                    shown_editor_text(w)
                )
            },
        )
    });
    steps.step(
        "the composer holds two lines with the caret on the second",
        |world, _, _| {
            sent(world, &["Run the tests"])?;
            let typed = "line one\nline two";
            write(world, typed, typed.chars().count() as i64)
        },
    );
    steps.step(
        "the shell is not asked for the previous prompt",
        |world, _, _| {
            settle_composer(world)?;
            // Up moved the caret onto the first line and left the draft
            // alone.
            let (editor, at) = (editor_text(world)?, cursor(world)?);
            expect!(
                editor == "line one\nline two" && at <= 8,
                "the draft reads \"{editor}\" with the caret at {at}"
            );
            Ok(())
        },
    );

    // The message limit.
    steps.step(
        "the user has typed a prompt (\\d+) characters over the 120,000-character limit",
        |world, c, _| {
            let over: usize = c[0].parse().unwrap_or(0);
            let typed = "x".repeat(120_000 + over);
            let target = target(world);
            world.dispatch(
                "composer.text.set",
                json!({"target": target, "text": typed, "cursor": typed.len()}),
            )
        },
    );
    steps.step("the message is not sent", |world, _, _| {
        let sent = messages(world)?;
        expect!(
            sent.is_empty(),
            "the MC has {} commands",
            world.mc.commands.len()
        );
        expect!(
            !draft(world, &target(world)).is_empty(),
            "the draft was cleared"
        );
        Ok(())
    });
    steps.step(
        "the user is told the prompt is (\\d+) characters over the limit and to shorten or split it",
        |world, c, _| {
            let expected = format!(
                "Prompt is {} characters over the 120,000-character limit. Shorten or split it before sending.",
                c[0]
            );
            let all = toasts(world);
            expect!(
                all.iter().any(|toast| text(&toast["description"]) == expected),
                "the toasts are {}",
                show(&json!(all))
            );
            Ok(())
        },
    );

    // The shell's own scenarios (qt-scenarios.feature).
    steps.step(&format!("the composer has the draft {Q}"), |world, c, _| {
        open_turn_thread(world)?;
        write(world, &c[0], c[0].chars().count() as i64)
    });
    steps.step(&format!("{Q} is sent in the foreground"), |world, c, _| {
        let sent = messages(world)?;
        expect!(
            sent.len() == 1
                && text(&sent[0]["text"]) == c[0]
                && text(at(&sent[0], "dispatchMode.type")) == "start_immediately",
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
}

/// The composer brick, when a step put it on screen.
fn composer_shown(world: &World) -> Option<Brick> {
    let brick = world.peek_part::<Shown>()?.0?;
    let root = brick.root(world)?;
    (brick.text_of(world, root, "objectName") == "composerBrick").then_some(brick)
}

/// Whether a step already put the composer on screen.
pub fn composer_brick_shown(world: &World) -> bool {
    composer_shown(world).is_some()
}

/// The composer on screen with the keyboard in its editor; loaded on first
/// use.
pub fn composer_brick(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = composer_shown(world) {
        return Ok(brick);
    }
    let composer = shown(world);
    expect!(
        composer.as_object().is_some_and(|c| !c.is_empty()),
        "no thread or draft is open for the composer"
    );
    Brick::show(world, COMPOSER_QML, 900.0, 700.0)?;
    let Some(brick) = composer_shown(world) else {
        fail!("the composer did not come up");
    };
    let editor = brick.item(world, "input")?;
    // A request that takes no typed text (an approval, fixed choices) has
    // the editor off.
    let editable = composer["editorDisabled"] != json!(true);
    world.wait_for("the composer to show the draft", move |w| {
        brick.flag(w, editor, "enabled") == editable
            && brick.text_of(w, editor, "text") == text(&shown(w)["text"])
    })?;
    let item = brick.item(world, "composer")?;
    invoke(world, item, "focusInput", &[])?;
    world.pump()?;
    expect!(
        brick.flag(world, editor, "activeFocus") == editable,
        "the composer's editor did not take the keyboard"
    );
    Ok(brick)
}

/// The Composer item.
pub fn composer_item(world: &mut World) -> Outcome<ObjectId> {
    let brick = composer_brick(world)?;
    brick.item(world, "composer")
}

/// The composer's editor (its TextArea), with the brick.
pub fn editor(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    let editor = brick.item(world, "input")?;
    Ok((brick, editor))
}

/// The item named `object_name` anywhere in the composer's window, popups
/// included; none when there is none.
pub fn composer_part(world: &mut World, object_name: &str) -> Outcome<Option<ObjectId>> {
    let brick = composer_brick(world)?;
    brick.find(world, object_name)
}

/// The editor has what the shell last published and the shell has what
/// the editor holds (its debounced text reached the controller).
pub fn settle_composer(world: &mut World) -> Outcome {
    if !composer_brick_shown(world) {
        return world.sync();
    }
    let item = composer_item(world)?;
    invoke(world, item, "flushText", &[])?;
    world.sync()?;
    world.wait_for_with(
        |w| shown_editor_text(w) == text(&shown(w)["text"]),
        |w| {
            format!(
                "the editor and the shell to agree; the editor reads \"{}\", the shell \"{}\"",
                shown_editor_text(w),
                text(&shown(w)["text"])
            )
        },
    )
}

/// Presses and releases `event`'s key in the composer's window.
fn click(world: &mut World, event: KeyEvent) -> Outcome<bool> {
    let release = KeyEvent::release(event.key).with_modifiers(event.modifiers);
    let taken = world.key(&event)?;
    world.key(&release)?;
    Ok(taken)
}

/// Types `typed` into the editor, a key at a time.
pub fn type_in_composer(world: &mut World, typed: &str) -> Outcome {
    composer_brick(world)?;
    for ch in typed.chars() {
        let upper = ch.to_ascii_uppercase();
        let mut event = KeyEvent::press(upper as i32).with_text(ch.to_string());
        if ch.is_ascii_uppercase() {
            event = event.with_modifiers(Modifiers::SHIFT);
        }
        click(world, event)?;
    }
    Ok(())
}

/// Presses `spelt` ("Enter", "Shift+Tab", "mod+alt+Enter", "w") in the
/// composer. False when the key is not the composer's to take: no composer
/// is on screen and nothing says the keyboard is in one.
pub fn press_in_composer(world: &mut World, spelt: &str) -> Outcome<bool> {
    let mut parts: Vec<&str> = spelt.split('+').collect();
    if spelt == "+" || parts.last().is_some_and(|p| p.is_empty()) {
        parts = vec![spelt];
    }
    let name = parts.pop().unwrap_or_default();
    let lower = name.to_lowercase();
    let enter = lower == "enter" || lower == "return";
    if !composer_brick_shown(world) {
        // The keyboard is in the composer of a thread or draft with a
        // prompt written: Enter is the composer's to take.
        let palette_open =
            controller::with::<Palette, _>(world.engine(), |p, _| p.is_open()).unwrap_or(false);
        if !enter || palette_open || text(&shown(world)["text"]).is_empty() {
            return Ok(false);
        }
    }
    composer_brick(world)?;
    let mut modifiers = Modifiers::empty();
    for part in &parts {
        match part.to_lowercase().as_str() {
            "mod" | "ctrl" | "cmd" => modifiers |= Modifiers::CONTROL,
            "shift" => modifiers |= Modifiers::SHIFT,
            "alt" => modifiers |= Modifiers::ALT,
            "meta" => modifiers |= Modifiers::META,
            _ => fail!("{part} is not a modifier"),
        }
    }
    let (editor_now, cursor_now) = (editor_text(world)?, cursor(world)?);
    let commands = world.mc.commands.len();
    *world.part::<Pressed>() = Pressed {
        text: editor_now,
        commands,
        cursor: cursor_now,
    };
    let named = match lower.as_str() {
        "enter" | "return" => Some(key::RETURN),
        "escape" | "esc" => Some(key::ESCAPE),
        "up" => Some(key::UP),
        "down" => Some(key::DOWN),
        "left" => Some(key::LEFT),
        "right" => Some(key::RIGHT),
        "backspace" => Some(key::BACKSPACE),
        "tab" => Some(key::TAB),
        "insert" => Some(key::INSERT),
        _ => None,
    };
    let plain = modifiers.is_empty() || modifiers == Modifiers::SHIFT;
    let event = if lower == "tab" && modifiers.contains(Modifiers::SHIFT) {
        KeyEvent::press(key::BACKTAB).with_modifiers(modifiers)
    } else if let Some(code) = named {
        let event = KeyEvent::press(code).with_modifiers(modifiers);
        match code {
            c if c == key::RETURN && plain => event.with_text("\r"),
            c if c == key::TAB && plain => event.with_text("\t"),
            _ => event,
        }
    } else if name.chars().count() == 1 {
        let ch = name.chars().next().unwrap_or(' ');
        let event = KeyEvent::press(ch.to_ascii_uppercase() as i32).with_modifiers(modifiers);
        if plain {
            event.with_text(ch.to_string())
        } else {
            event
        }
    } else {
        fail!("{spelt} is not a key the composer steps know");
    };
    click(world, event)?;
    world.sync()?;
    Ok(true)
}
