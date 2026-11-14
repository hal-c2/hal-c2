//! `menu` and `confirmation`: the shell's context menu and question.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::menus::{Item, Menus};
use ljos::prelude::Engine;
use serde_json::json;

use crate::Hub;

type Log = Rc<RefCell<Vec<String>>>;

fn items() -> Vec<Item> {
    let mut disabled = Item::new("off", "Off");
    disabled.enabled = false;
    let mut parent = Item::new("move", "Move to");
    parent.children = vec![Item::new("move:p2", "Project two")];
    let mut nested_off = Item::new("hidden", "Hidden");
    nested_off.enabled = false;
    nested_off.children = vec![Item::new("hidden:child", "Child")];
    vec![Item::new("pin", "Pin"), disabled, parent, nested_off]
}

fn open(hub: &Hub, log: &Log) -> String {
    let log = log.clone();
    hub.with_controller::<Menus, _>(|m, e| {
        m.open(e, 12.0, 30.5, items(), move |_, id| {
            log.borrow_mut().push(id.to_owned())
        })
    })
}

#[test]
fn a_menu_publishes_its_items_and_runs_the_one_picked() {
    let hub = Hub::new();
    let log = Log::default();
    let request = open(&hub, &log);
    let menu = hub.published("menu");
    assert_eq!(menu["requestId"], request);
    assert_eq!(menu["surfaceId"], "shell");
    assert_eq!(
        (menu["x"].as_f64(), menu["y"].as_f64()),
        (Some(12.0), Some(30.5))
    );
    assert_eq!(
        menu["items"][2],
        json!({"id": "move", "label": "Move to", "icon": "", "enabled": true, "checked": false,
               "destructive": false, "separatorBefore": false,
               "children": [{"id": "move:p2", "label": "Project two", "icon": "", "enabled": true,
                             "checked": false, "destructive": false, "separatorBefore": false}]})
    );
    assert!(menu["items"][0].get("children").is_none());
    hub.dispatch(
        "menu.select",
        json!({"requestId": request, "id": "move:p2"}),
    );
    assert_eq!(hub.published("menu"), json!(null));
    assert_eq!(*log.borrow(), ["move:p2"]);
}

#[test]
fn only_an_offered_leaf_runs() {
    let hub = Hub::new();
    let log = Log::default();
    for id in [
        json!("off"),
        json!("move"),
        json!("hidden:child"),
        json!("nope"),
        json!(null),
        json!(3),
    ] {
        let request = open(&hub, &log);
        hub.dispatch("menu.select", json!({"requestId": request, "id": id}));
        assert_eq!(hub.published("menu"), json!(null));
    }
    assert!(log.borrow().is_empty());
}

#[test]
fn a_newer_menu_replaces_the_open_one() {
    let hub = Hub::new();
    let log = Log::default();
    let first = open(&hub, &log);
    let second = open(&hub, &log);
    hub.dispatch("menu.select", json!({"requestId": first, "id": "pin"}));
    assert_eq!(hub.published("menu")["requestId"], second);
    assert!(log.borrow().is_empty());
    hub.with_controller::<Menus, _>(|m, e| m.close(e));
    assert_eq!(hub.published("menu"), json!(null));
    assert!(!hub.with_controller::<Menus, _>(|m, _| m.is_open()));
}

#[test]
fn a_choice_may_open_another_menu() {
    let hub = Hub::new();
    let log = Log::default();
    let inner = log.clone();
    let request = hub.with_controller::<Menus, _>(|m, e| {
        m.open(
            e,
            0.0,
            0.0,
            vec![Item::new("more", "More")],
            move |engine: &Engine, _| {
                let inner = inner.clone();
                hal_c2_shell::controller::with::<Menus, _>(engine, |m, e| {
                    m.open(
                        e,
                        1.0,
                        1.0,
                        vec![Item::new("deep", "Deep")],
                        move |_, id| inner.borrow_mut().push(id.to_owned()),
                    )
                })
                .expect("menus are free when a choice runs");
            },
        )
    });
    hub.dispatch("menu.select", json!({"requestId": request, "id": "more"}));
    let next = hub.published("menu")["requestId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(next, "menu:2");
    hub.dispatch("menu.select", json!({"requestId": next, "id": "deep"}));
    assert_eq!(*log.borrow(), ["deep"]);
}

#[test]
fn a_question_runs_yes_or_no_once() {
    let hub = Hub::new();
    let log = Log::default();
    let ask = |hub: &Hub| {
        let (yes, no) = (log.clone(), log.clone());
        hub.with_controller::<Menus, _>(|m, e| {
            m.confirm(
                e,
                "Delete thread?",
                "It cannot be undone.",
                "Delete",
                true,
                Some(Rc::new(move |_: &Engine| {
                    yes.borrow_mut().push("yes".into())
                })),
                Some(Rc::new(move |_: &Engine| no.borrow_mut().push("no".into()))),
            )
        })
    };
    let request = ask(&hub);
    assert_eq!(
        hub.published("confirmation"),
        json!({"requestId": request, "title": "Delete thread?", "description": "It cannot be undone.",
               "confirmLabel": "Delete", "destructive": true})
    );
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": "confirm:0", "accepted": true}),
    );
    assert!(log.borrow().is_empty());
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": true}),
    );
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": true}),
    );
    assert_eq!(hub.published("confirmation"), json!(null));
    let request = ask(&hub);
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": false}),
    );
    assert_eq!(*log.borrow(), ["yes", "no"]);
}
