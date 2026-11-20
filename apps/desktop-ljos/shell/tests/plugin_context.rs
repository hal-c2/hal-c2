//! PluginContext.qml over the native `McPlugins`: what a plugin's MC part
//! publishes reaches the part that watches it, and only that part. Each script
//! handler of a signal is given its own copy of a value, so a handler per part
//! (a row mark per sidebar row) made a large value (code-review's `reviews`)
//! once per part on every publish, and could run the JS heap out.

mod common;

use std::path::Path;
use std::rc::Rc;

use common::{FakeMc, call, number, shell_with, text};
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::json;

fn brick(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../desktop-qt/qml/HalC2/Bricks")
        .join(format!("{name}.qml"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

const MAIN: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    id: root

    property int heard: 0
    property int rows: -1
    property var contexts: []
    property string answeredBy: ""

    Component {
        id: factory

        PluginContext {
            pluginId: "code-review"
            environments: ["env-1"]
        }
    }

    // `count` parts, each watching `topic` as a row mark watches `threads`.
    function open(count, topic) {
        const made = root.contexts.slice();
        for (let i = 0; i < count; i++) {
            const context = factory.createObject(root);
            context.watch(topic, value => {
                root.heard += 1;
                root.rows = value.reviews.length;
            });
            made.push(context);
        }
        root.contexts = made;
    }

    // Part `index` calls its MC part; whose `done` runs is kept in `answeredBy`.
    function ask(index) {
        root.contexts[index].call("refresh", {}, (result, error) => {
            root.answeredBy += String(index);
        });
    }

    function drop(index) {
        root.contexts[index].destroy();
    }

    function waiting() {
        return Object.keys(PluginChannel.answers).length;
    }

    function close() {
        for (const context of root.contexts)
            context.destroy();
        root.contexts = [];
    }
}
"#;

fn shell() -> (Engine, ObjectId, Rc<FakeMc>) {
    let mc = Rc::new(FakeMc::default());
    let context = brick("PluginContext");
    let channel = brick("PluginChannel");
    let (engine, root) = shell_with(
        &[
            ("HalC2/Bricks/PluginContext", &context),
            ("HalC2/Bricks/PluginChannel", &channel),
            ("Main", MAIN),
        ],
        &[(
            "HalC2/Bricks",
            "module HalC2.Bricks\nPluginContext 1.0 PluginContext.qml\nsingleton PluginChannel 1.0 PluginChannel.qml\n",
        )],
        mc.clone(),
    );
    (engine, root, mc)
}

fn publish(engine: &Engine, mc: &FakeMc, topic: &str, reviews: usize) {
    let reviews: Vec<_> = (0..reviews)
        .map(|i| json!({"key": format!("acme/api#{i}"), "summary": "x".repeat(200)}))
        .collect();
    mc.frame_where(
        engine,
        |shape| shape["type"] == "plugin" && shape["topic"] == topic,
        json!({"t": "plugin", "value": {"reviews": reviews}}),
    );
}

#[test]
fn a_published_value_reaches_only_the_parts_that_watch_its_topic() {
    let (engine, root, mc) = shell();
    call(
        &engine,
        root,
        "open",
        &[Value::from(1), Value::from("reviews")],
    );
    call(
        &engine,
        root,
        "open",
        &[Value::from(3), Value::from("threads")],
    );
    publish(&engine, &mc, "reviews", 5);
    assert_eq!(number(&engine, root, "heard"), 1.0);
    assert_eq!(number(&engine, root, "rows"), 5.0);
    publish(&engine, &mc, "threads", 2);
    assert_eq!(number(&engine, root, "heard"), 4.0);
}

#[test]
fn more_plugin_parts_do_not_add_script_handlers_to_every_publish() {
    let (engine, root, mc) = shell();
    call(
        &engine,
        root,
        "open",
        &[Value::from(1), Value::from("reviews")],
    );
    let one = engine.connection_count();
    call(
        &engine,
        root,
        "open",
        &[Value::from(40), Value::from("threads")],
    );
    let many = engine.connection_count();
    // A part's watch and answers go through the one listener to McPlugins
    // (PluginChannel), not a Connections of each part's own: a part keeps only
    // the binding of its `environment`.
    assert!(
        many - one <= 40,
        "40 parts added {} connections",
        many - one
    );
    publish(&engine, &mc, "reviews", 2000);
    assert_eq!(number(&engine, root, "heard"), 1.0);
    call(&engine, root, "close", &[]);
    // `destroy()` takes effect when the event loop next gets to it.
    engine.process_deferred_deletes();
    assert!(
        mc.subscriptions()
            .iter()
            .all(|(_, shape)| shape["type"] != "plugin"),
        "closing the parts ends their watches"
    );
}

#[test]
fn an_answer_reaches_only_the_part_that_asked_and_none_once_it_is_gone() {
    let (engine, root, mc) = shell();
    call(
        &engine,
        root,
        "open",
        &[Value::from(2), Value::from("threads")],
    );
    call(&engine, root, "ask", &[Value::from(1)]);
    mc.answer(&engine, "plugins.call", Ok(json!(null)));
    assert_eq!(text(&engine, root, "answeredBy"), "1");

    // A part gone before its answer comes leaves nothing behind to call.
    call(&engine, root, "ask", &[Value::from(0)]);
    call(&engine, root, "drop", &[Value::from(0)]);
    engine.process_deferred_deletes();
    assert_eq!(call(&engine, root, "waiting", &[]), Value::from(0));
    mc.answer(&engine, "plugins.call", Ok(json!(null)));
    assert_eq!(text(&engine, root, "answeredBy"), "1");
}
