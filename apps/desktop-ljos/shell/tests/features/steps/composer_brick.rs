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
use ljos::item::{KeyEvent, Modifiers, MouseButtons, key};
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::settings_composer::drawn_bold;
use crate::steps::stream::{self, PROJECT, THREAD};
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};

/// The composer under the window's shortcuts (ShellWindow's Instantiator),
/// so a key a shortcut takes never reaches the editor here either. The room
/// above it stands for the timeline, and the conversation's drop covers
/// both, as DefaultLayout lays them out.
const COMPOSER_QML: &str = r#"import QtQuick
import HalC2.Bricks
import HalC2.Shell
Item {
    id: root
    objectName: "composerBrick"
    anchors.fill: parent
    property int windowShortcuts: 0

    Composer {
        id: composerView
        objectName: "composer"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }

    ConversationDrop {
        objectName: "conversationDrop"
        anchors.fill: parent
        composer: composerView
    }

    // Selected text, which a step drags over the conversation.
    // TODO(ljos#115): a drag from another application carries only files,
    // so this one starts inside the window.
    Item {
        objectName: "textDrag"
        property bool dragging: false
        width: 1
        height: 1
        Drag.active: dragging
        Drag.dragType: Drag.Internal
        Drag.keys: ["text/plain"]
        Drag.mimeData: { "text/plain": "the cart totals add up" }
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

/// Whether the scenario turned rich text editing on, so what the user
/// types goes to the composer's editor rather than the palette.
#[derive(Default)]
struct RichTyping(bool);

/// Types `typed` into the composer's editor when the scenario turned rich
/// text editing on; false otherwise (palette.rs's "the user types").
pub fn rich_text_types(world: &mut World, typed: &str) -> Outcome<bool> {
    if !world.part::<RichTyping>().0 {
        return Ok(false);
    }
    type_in_composer(world, typed)?;
    settle_composer(world)?;
    Ok(true)
}

/// What the last key press in the composer found there.
#[derive(Default)]
struct Pressed {
    text: String,
    commands: usize,
    cursor: i64,
}

/// A draft a step set up and a later step measures against.
#[derive(Default)]
struct SetUp {
    text: String,
    start: i64,
    length: i64,
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
    // The prompt's wrap width against the composer's: typed a key at a
    // time, so its wrapping starts while the composer has one width, then
    // the window is resized under it.
    steps.step(
        "the user typed a prompt into the composer",
        |world, _, _| type_in_composer(world, "what are you talking about terminal color theme"),
    );
    steps.step("the composer gets (narrower|wider)", |world, c, _| {
        let brick = composer_brick(world)?;
        let (width, height) = brick.size(world);
        let width = if c[0] == "narrower" {
            width * 0.5
        } else {
            width * 2.0
        };
        world.resize(width, height)?;
        if let Some(root) = brick.root(world) {
            brick.write(world, root, "width", QmlValue::from(width))?;
        }
        Ok(())
    });
    steps.step("the prompt wraps at the composer's width", |world, _, _| {
        let (brick, input) = editor(world)?;
        let scroll = brick.item(world, "promptScroll")?;
        let real = move |w: &World, item: ObjectId, name: &str| {
            brick
                .text_of(w, item, name)
                .parse::<f64>()
                .unwrap_or(f64::NAN)
        };
        world.wait_for_with(
            move |w| (real(w, input, "width") - real(w, scroll, "availableWidth")).abs() < 1.0,
            move |w| {
                format!(
                    "the prompt is {} wide in a composer {} wide",
                    real(w, input, "width"),
                    real(w, scroll, "availableWidth")
                )
            },
        )
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
    // Pasting, and the draft's right-click menu (TextEditMenu).
    steps.step(&format!("the user copied {Q}"), |world, c, _| {
        world.set_clipboard(&c[0]);
        Ok(())
    });
    steps.step("the user presses (\\S+) in the composer", |world, c, _| {
        expect!(
            press_in_composer(world, &c[0])?,
            "the composer did not take {}",
            c[0]
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses {Q} from the draft's right-click menu"),
        |world, c, _| choose_in_draft_menu(world, &c[0]),
    );
    steps.step(
        &format!("{Q} is selected in the composer"),
        |world, c, _| {
            let (brick, editor) = editor(world)?;
            let selected = brick.text_of(world, editor, "selectedText");
            expect!(selected == c[0], "the selection is \"{selected}\"");
            Ok(())
        },
    );
    steps.step("the draft's right-click menu is open", |world, _, _| {
        let brick = composer_brick(world)?;
        let menu = brick.item(world, "editorMenu")?;
        world.wait_for("the draft's right-click menu to open", move |w| {
            brick.flag(w, menu, "visible")
        })
    });
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
    steps.step(&format!("{Q} is sent"), |world, c, _| {
        let list = messages(world)?;
        expect!(
            list.len() == 1 && text(&list[0]["text"]) == c[0],
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the whole prompt is sent to the MC", |world, _, _| {
        let sent = messages(world)?;
        let first = sent.first().map_or(0, |m| text(&m["text"]).chars().count());
        expect!(
            sent.len() == 1 && text(&sent[0]["text"]) == "x".repeat(120_010),
            "the MC has {} messages, the first {first} characters long",
            sent.len()
        );
        Ok(())
    });
    steps.step(
        "the window is narrowed to the width of a phone",
        |world, _, _| {
            let brick = composer_brick(world)?;
            world.resize(390.0, 700.0)?;
            if let Some(root) = brick.root(world) {
                brick.write(world, root, "width", QmlValue::from(390.0))?;
                brick.write(world, root, "height", QmlValue::from(700.0))?;
            }
            let item = composer_item(world)?;
            world.wait_for("the composer to narrow", |w| {
                number(&brick, w, item, "width") <= 390
            })
        },
    );

    // More of recalling sent prompts, and what is never recalled.
    steps.step(
        &format!("the user sent {Q} in this thread"),
        |world, c, _| {
            sent(world, &[&c[0]])?;
            composer_brick(world)?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user sent {Q}, then {Q} and then {Q} in this thread"),
        |world, c, _| sent(world, &[&c[0], &c[1], &c[2]]),
    );
    steps.step(&format!("the user then sent {Q}"), |world, c, _| {
        sent(world, &[&c[0]])
    });
    steps.step(&format!("a scheduled task then sent {Q}"), |world, c, _| {
        let run = stream::start_run(world, 60, "completed")?;
        stream::set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": c[0], "scheduledTaskId": "task-nightly"}),
        )
    });
    steps.step(
        &format!("the user sent {Q} with (Ultrathink turned on|a comment on a file|a terminal excerpt added at the end|a preview annotation)"),
        |world, c, _| {
            // How each extra reaches the MC: in the text after the words typed.
            let full = match c[1].as_str() {
                "Ultrathink turned on" => format!("Ultrathink:\n{}", c[0]),
                "a comment on a file" => format!(
                    "{}\n\n[cart.ts:12](hal-c2-context://v1/review-comment/comment-1)",
                    c[0]
                ),
                "a terminal excerpt added at the end" => format!(
                    "{}\n\n[Terminal 1 lines 3-9](hal-c2-context://v1/terminal/excerpt-1)",
                    c[0]
                ),
                _ => format!(
                    "{} [Preview: Checkout button](hal-c2-context://v1/preview-annotation/note-1)",
                    c[0]
                ),
            };
            sent(world, &[&full])
        },
    );
    steps.step(
        &format!("the user sent {Q} and then (an image with no text|the request to implement a proposed plan)"),
        |world, c, _| {
            let second = if c[1].starts_with("an image") {
                String::new()
            } else {
                "PLEASE IMPLEMENT THIS PLAN:\n# Tax line\n\nAdd it.".to_owned()
            };
            sent(world, &[&c[0], &second])
        },
    );
    // An older MC or a T3 import: the task is in the item's id and the
    // text's prefix, and the sender is "user".
    steps.step(
        &format!(
            "the user sent {Q} and then a scheduled task's message an older MC marked by its id"
        ),
        |world, c, _| {
            sent(world, &[&c[0]])?;
            let run = stream::start_run(world, 60, "completed")?;
            stream::set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"text": ""}),
            )?;
            stream::set(
                world,
                "turn-item",
                "scheduled-task-message:task-nightly:1:scheduled",
                json!({
                    "type": "user_message", "runId": run, "createdBy": "user",
                    "text": "[Triggered by schedule task: Nightly]\n\nRun the nightly check",
                }),
            )
        },
    );
    steps.step("the user recalls the previous prompt", |world, _, _| {
        composer_brick(world)?;
        press_in_composer(world, "Up")?;
        Ok(())
    });
    steps.step(
        &format!("the user recalled {Q}(?: in thread A)?"),
        |world, c, _| {
            composer_brick(world)?;
            for _ in 0..8 {
                if editor_text(world)? == c[0] {
                    break;
                }
                press_in_composer(world, "Up")?;
            }
            let editor = editor_text(world)?;
            expect!(editor == c[0], "Up recalled \"{editor}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("the user changes the draft to {Q}"),
        |world, c, _| write(world, &c[0], c[0].chars().count() as i64),
    );
    steps.step(
        "the user presses (Up|Down) on the (?:first|last) line of the composer",
        |world, c, _| {
            composer_brick(world)?;
            press_in_composer(world, &c[0])?;
            Ok(())
        },
    );
    steps.step(
        "the caret moves to the start of the draft",
        |world, _, _| {
            let at = cursor(world)?;
            expect!(at == 0, "the caret is at {at}");
            Ok(())
        },
    );
    steps.step(
        "the user recalled a prompt long enough to wrap onto three lines",
        |world, _, _| {
            let (brick, input) = editor(world)?;
            // Words until the editor wraps them onto a third line.
            let mut prompt = "totals".to_owned();
            for _ in 1..1000 {
                brick.write(world, input, "text", QmlValue::from(prompt.as_str()))?;
                world.sync()?;
                if number(&brick, world, input, "lineCount") >= 3 {
                    break;
                }
                prompt += " totals";
            }
            brick.write(world, input, "text", QmlValue::from(""))?;
            settle_composer(world)?;
            sent(world, &[&prompt])?;
            press_in_composer(world, "Up")?;
            let wanted = prompt.clone();
            world.wait_for_with(
                move |w| {
                    shown_editor_text(w) == wanted && number(&brick, w, input, "lineCount") == 3
                },
                move |w| {
                    format!(
                        "the editor reads \"{}\" on {} lines",
                        shown_editor_text(w),
                        number(&brick, w, input, "lineCount")
                    )
                },
            )?;
            world.part::<SetUp>().text = prompt;
            Ok(())
        },
    );
    steps.step("the caret is on the last line", |world, _, _| {
        let at = editor_text(world)?.chars().count() as i64;
        world.part::<Pressed>().cursor = at;
        set_cursor(world, at)
    });
    steps.step("the caret moves up one line", |world, _, _| {
        let (_brick, input) = editor(world)?;
        let caret_y = |world: &World, at: i64| -> Outcome<f64> {
            let rect = invoke(
                world,
                input,
                "positionToRectangle",
                &[QmlValue::Int(at as i32)],
            )?;
            Ok(match rect {
                QmlValue::Rect(r) => r.y,
                other => {
                    let _ = other;
                    f64::NAN
                }
            })
        };
        let pressed_at = world.part::<Pressed>().cursor;
        let was = caret_y(world, pressed_at)?;
        let now_at = cursor(world)?;
        let now = caret_y(world, now_at)?;
        let top = caret_y(world, 0)?;
        expect!(
            now < was && now > top,
            "the caret went from y {was} to {now}"
        );
        Ok(())
    });
    steps.step("the draft still reads that prompt", |world, _, _| {
        settle_composer(world)?;
        let prompt = world.part::<SetUp>().text.clone();
        let draft = draft(world, &target(world));
        expect!(
            draft == prompt,
            "the draft reads \"{}\"",
            editor_text(world)?
        );
        Ok(())
    });
    steps.step(
        &format!("the user sent {Q} in thread A and {Q} in thread B"),
        |world, c, _| {
            sent(world, &[&c[0]])?;
            other_thread(world)?;
            // Thread B's own stream, while the user is still in thread A.
            let was = std::mem::replace(
                &mut world.mc.part::<stream::FakeStreams>().thread,
                "thread-2".into(),
            );
            let at = stream::iso(world.now() - chrono::Duration::seconds(60));
            let done = (|| -> Outcome {
                stream::set(
                    world,
                    "run",
                    "run-b",
                    json!({"id": "run-b", "ordinal": 1, "status": "completed",
                           "requestedAt": at, "startedAt": at}),
                )?;
                stream::set(
                    world,
                    "turn-item",
                    "message:run-b",
                    json!({"id": "message:run-b", "type": "user_message", "runId": "run-b",
                           "ordinal": 2, "status": "completed", "text": c[1], "updatedAt": at}),
                )
            })();
            world.mc.part::<stream::FakeStreams>().thread = was;
            done
        },
    );
    steps.step(
        "the user opens thread B and recalls the previous prompt",
        |world, _, _| {
            let key = other_thread(world)?;
            look(world, &key)?;
            world.sync()?;
            settle_composer(world)?;
            press_in_composer(world, "Up")?;
            Ok(())
        },
    );

    // Keys the composer does not send with.
    steps.step(
        "the user presses Enter (to accept a word from their input method|and holds it so the key repeats)",
        |world, c, _| {
            composer_brick(world)?;
            if c[0].starts_with("to accept") {
                // The input method is still composing the word Enter accepts.
                world.preedit("ね")?;
                press_in_composer(world, "Enter")?;
            } else {
                // Only the repeats: the first press has been and gone.
                for _ in 0..3 {
                    let mut repeat = KeyEvent::press(key::RETURN).with_text("\r");
                    repeat.auto_repeat = true;
                    world.key(&repeat)?;
                }
                world.key(&KeyEvent::release(key::RETURN).with_text("\r"))?;
                world.sync()?;
            }
            Ok(())
        },
    );

    // Lists: a new line in an item starts the next one.
    steps.step(
        &format!("the draft's last line (?:reads|is) {Q}(?: with the caret at its end)?"),
        |world, c, _| write(world, &c[0], c[0].chars().count() as i64),
    );
    steps.step(
        "the draft's last line is a bullet indented by two spaces",
        |world, _, _| write(world, "- milk\n  - oat", 14),
    );
    steps.step(
        "the draft's last line is a bullet with nothing after it",
        |world, _, _| write(world, "- milk\n- ", 9),
    );
    steps.step("a list item holds a file reference", |world, _, _| {
        let typed = "- read [cart.ts](src/cart.ts) first";
        write(world, typed, typed.chars().count() as i64)
    });
    steps.step(
        &format!("the draft reads {Q} with the caret before {Q}"),
        |world, c, _| {
            let at = c[0]
                .find(c[1].as_str())
                .map_or(-1, |byte| c[0][..byte].chars().count() as i64);
            write(world, &c[0], at)
        },
    );
    steps.step("the user (?:adds|starts) a new line", |world, _, _| {
        expect!(
            press_in_composer(world, "Shift+Enter")?,
            "the composer did not take Shift+Enter"
        );
        Ok(())
    });
    steps.step(
        "the user adds a new line with the caret inside the reference label",
        |world, _, _| {
            // After "[cart", inside the label.
            let typed = editor_text(world)?;
            let at = typed
                .find("[cart")
                .map_or(-1, |byte| typed[..byte].chars().count() as i64 + 5);
            set_cursor(world, at)?;
            expect!(
                press_in_composer(world, "Shift+Enter")?,
                "the composer did not take Shift+Enter"
            );
            Ok(())
        },
    );
    let lines = |world: &mut World| -> Outcome<Vec<String>> {
        settle_composer(world)?;
        Ok(editor_text(world)?.split('\n').map(str::to_owned).collect())
    };
    steps.step(
        &format!("the new line starts with {Q}"),
        move |world, c, _| {
            let now = lines(world)?;
            let typed = editor_text(world)?;
            expect!(
                now.len() == 2
                    && now.last().map(String::as_str) == Some(&format!("{} ", c[0]))
                    && cursor(world)? == typed.chars().count() as i64,
                "the draft reads \"{typed}\" with the caret at {}",
                cursor(world)?
            );
            Ok(())
        },
    );
    steps.step(
        "the new line is a bullet indented by two spaces",
        move |world, _, _| {
            expect!(
                lines(world)?.last().map(String::as_str) == Some("  - "),
                "the draft reads \"{}\"",
                editor_text(world)?
            );
            Ok(())
        },
    );
    steps.step("that line is no longer a bullet", move |world, _, _| {
        expect!(
            lines(world)?.last().is_some_and(|line| line.is_empty()),
            "the draft reads \"{}\"",
            editor_text(world)?
        );
        Ok(())
    });
    steps.step("no new bullet is started", move |world, _, _| {
        expect!(
            lines(world)? == ["- milk", ""],
            "the draft reads \"{}\"",
            editor_text(world)?
        );
        Ok(())
    });
    steps.step(
        &format!("the draft reads {Q} and then {Q} on the next line"),
        move |world, c, _| {
            expect!(
                lines(world)? == [c[0].clone(), c[1].clone()],
                "the draft reads \"{}\"",
                editor_text(world)?
            );
            Ok(())
        },
    );
    steps.step(
        "the file reference is whole on one of the two lines",
        move |world, _, _| {
            let now = lines(world)?;
            expect!(
                now.len() == 2
                    && (now[0].contains("[cart.ts](src/cart.ts)")
                        || now[1].contains("[cart.ts](src/cart.ts)")),
                "the draft reads \"{}\"",
                editor_text(world)?
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the line {Q} is kept and a new line starts below it"),
        move |world, c, _| {
            expect!(
                lines(world)? == [c[0].clone(), String::new()],
                "the draft reads \"{}\"",
                editor_text(world)?
            );
            Ok(())
        },
    );
    steps.step("no suggestion list is open", |world, _, _| {
        let brick = composer_brick(world)?;
        let item = composer_item(world)?;
        expect!(
            !brick.flag(world, item, "suggesting"),
            "a suggestion list is open"
        );
        Ok(())
    });
    steps.step("that line is indented by two spaces", |world, _, _| {
        settle_composer(world)?;
        let was = world.part::<Pressed>().text.clone();
        let typed = editor_text(world)?;
        expect!(typed == format!("  {was}"), "the draft reads \"{typed}\"");
        Ok(())
    });

    // Typing over a selection, and with an input method.
    steps.step("the user types (\\S)", |world, c, _| {
        type_in_composer(world, &c[0])?;
        settle_composer(world)
    });
    // The wrapped word is unquoted: one of the marks is a quote.
    steps.step("the draft reads hello (\\S+)", |world, c, _| {
        settle_composer(world)?;
        let expected = format!("hello {}", c[0]);
        let typed = editor_text(world)?;
        expect!(typed == expected, "the draft reads \"{typed}\"");
        Ok(())
    });
    steps.step(&format!("{Q} is still selected"), |world, c, _| {
        let (brick, input) = editor(world)?;
        let selected = brick.text_of(world, input, "selectedText");
        expect!(selected == c[0], "the selection is \"{selected}\"");
        Ok(())
    });
    steps.step(
        "the draft's selection covers (a file reference|text shown in bold)",
        |world, c, _| {
            let reference = c[0] == "a file reference";
            let typed = if reference {
                "see [cart.ts](src/cart.ts) now"
            } else {
                "see **bold** now"
            };
            let selected = if reference {
                "[cart.ts](src/cart.ts)"
            } else {
                "bold"
            };
            write(world, typed, typed.chars().count() as i64)?;
            let start = typed
                .find(selected)
                .map_or(-1, |byte| typed[..byte].chars().count() as i64);
            let length = selected.chars().count() as i64;
            let (_brick, input) = editor(world)?;
            invoke(
                world,
                input,
                "select",
                &[
                    QmlValue::Int(start as i32),
                    QmlValue::Int((start + length) as i32),
                ],
            )?;
            world.pump()?;
            *world.part::<SetUp>() = SetUp {
                text: typed.to_owned(),
                start,
                length,
            };
            Ok(())
        },
    );
    steps.step(
        &format!("the selection is replaced by {Q}"),
        |world, c, _| {
            settle_composer(world)?;
            let (kept, start, length) = {
                let kept = world.part::<SetUp>();
                (kept.text.clone(), kept.start, kept.length)
            };
            let mut expected: Vec<char> = kept.chars().collect();
            expected.splice(start as usize..(start + length) as usize, c[0].chars());
            let expected: String = expected.into_iter().collect();
            let typed = editor_text(world)?;
            expect!(typed == expected, "the draft reads \"{typed}\"");
            Ok(())
        },
    );
    steps.step(
        "the user types Compose, then (\\S), then (\\S)",
        |world, c, _| {
            let composed = match format!("{}{}", c[0], c[1]).as_str() {
                "\"o" => "ö",
                "\"a" => "ä",
                "'e" => "é",
                _ => fail!("no Compose sequence for {}{}", c[0], c[1]),
            };
            let at = editor_text(world)?.chars().count() as i64;
            set_cursor(world, at)?;
            // Compose shows the mark it is composing, then commits the letter.
            world.preedit(&c[0])?;
            world.type_text(composed)?;
            settle_composer(world)
        },
    );

    // Rich text.
    steps.step("rich text editing is (on|off)", |world, c, _| {
        set_setting(world, "composerRichTextEnabled", json!(c[0] == "on"))?;
        world.part::<RichTyping>().0 = c[0] == "on";
        composer_brick(world)?;
        Ok(())
    });
    steps.step("nothing in it is italic", |world, _, _| {
        let (_brick, input) = editor(world)?;
        let spans = ljos::item::highlights(world.engine(), input).unwrap_or_default();
        let typed = editor_text(world)?;
        for span in spans.iter() {
            expect!(
                !span.italic,
                "\"{}\" is italic",
                typed.get(span.range.clone()).unwrap_or_default()
            );
        }
        Ok(())
    });
    steps.step(
        &format!("the draft reads {Q} with a file reference"),
        |world, c, _| {
            let typed = format!("{} [cart.ts](src/cart.ts) ", c[0]);
            write(world, &typed, typed.chars().count() as i64)?;
            world.part::<SetUp>().text = typed;
            Ok(())
        },
    );
    steps.step(
        "the user turns rich text editing on and then off again",
        |world, _, _| {
            for on in [true, false] {
                set_setting(world, "composerRichTextEnabled", json!(on))?;
                world.sync()?;
                settle_composer(world)?;
            }
            Ok(())
        },
    );
    steps.step(
        "the draft reads the same text with the same file reference",
        |world, _, _| {
            settle_composer(world)?;
            let kept = world.part::<SetUp>().text.clone();
            let draft = draft(world, &target(world));
            let typed = editor_text(world)?;
            expect!(
                typed == kept && draft == kept,
                "the editor reads \"{typed}\", the draft \"{draft}\""
            );
            Ok(())
        },
    );

    // Undo.
    steps.step("the user typed, pasted, then typed more", |world, _, _| {
        composer_brick(world)?;
        type_in_composer(world, "fix ")?;
        world.set_clipboard("the tax line");
        expect!(
            press_in_composer(world, "Ctrl+V")?,
            "the composer did not take Ctrl+V"
        );
        type_in_composer(world, " today")?;
        let typed = editor_text(world)?;
        expect!(
            typed == "fix the tax line today",
            "the editor reads \"{typed}\""
        );
        Ok(())
    });
    steps.step("the user undoes once", |world, _, _| {
        expect!(
            press_in_composer(world, "Ctrl+Z")?,
            "the composer did not take Ctrl+Z"
        );
        Ok(())
    });
    steps.step("only the last action is undone", |world, _, _| {
        settle_composer(world)?;
        let typed = editor_text(world)?;
        expect!(typed == "fix the tax line", "the editor reads \"{typed}\"");
        Ok(())
    });
}

/// The composer brick, when a step put it on screen.
fn composer_shown(world: &World) -> Option<Brick> {
    let brick = world.peek_part::<Shown>()?.0?;
    let root = brick.root(world)?;
    (brick.text_of(world, root, "objectName") == "composerBrick").then_some(brick)
}

/// The composer brick for a wait's condition: none until a step showed it.
pub fn composer_brick_now(world: &World) -> Option<Brick> {
    composer_shown(world)
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
/// `composer_part` for a wait's condition, which only reads the world: the
/// composer must already be on screen.
pub fn composer_part_now(world: &World, object_name: &str) -> Option<ObjectId> {
    composer_shown(world)?.find(world, object_name).ok()?
}

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

/// The object name of the item a text's right-click menu (TextEditMenu)
/// calls `said`.
pub fn text_menu_item(said: &str) -> Outcome<&'static str> {
    Ok(match said {
        "Cut" => "cutText",
        "Copy" => "copyText",
        "Paste" => "pasteText",
        "Select All" => "selectAllText",
        other => fail!("a text's menu has no {other}"),
    })
}

/// Right-clicks the middle of the composer's editor and chooses `said` from
/// the menu that opens.
pub fn choose_in_draft_menu(world: &mut World, said: &str) -> Outcome {
    let item = text_menu_item(said)?;
    let (brick, editor) = editor(world)?;
    let (x, y) = brick.at(world, editor, 0.5, 0.5)?;
    world.click_at_with(
        x.trunc(),
        y.trunc(),
        MouseButtons::RIGHT,
        Modifiers::empty(),
    )?;
    let menu = brick.item(world, "editorMenu")?;
    // An item takes clicks once the menu has finished opening.
    world.wait_for("the draft's right-click menu to open", move |w| {
        brick.flag(w, menu, "opened")
    })?;
    brick.click(world, item)?;
    // What it chose is done once the menu has gone.
    world.wait_for("the draft's right-click menu to close", move |w| {
        !brick.flag(w, menu, "visible")
    })
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
        "menu" => Some(key::MENU),
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
