//! The page against a simulated MC: the view reports, the MC answers in
//! any way, agents move the tab and sizes are picked, answered or timed out.

use proptest::prelude::*;
use serde_json::json;

use super::{Json, PageCore, PageEffect, PageNote, Unheard};

#[derive(Clone, Debug)]
enum Act {
    /// The view went to page `n` (loading or loaded).
    View(u8, bool),
    /// The MC answers the report in flight.
    Answer(Unheard),
    /// No call could be made for the report in flight.
    NoCall,
    /// An agent moves the tab somewhere new.
    Agent,
    /// The connection came back and the MC listed the tabs.
    Listed,
    Pick(u8),
    Resized(bool),
    TimedOut,
    /// Another window sizes the tab.
    OtherSize(u8),
}

fn act() -> impl Strategy<Value = Act> {
    prop_oneof![
        3 => (0u8..4, any::<bool>()).prop_map(|(n, done)| Act::View(n, done)),
        3 => prop_oneof![
            Just(Unheard::Heard),
            Just(Unheard::Refused),
            Just(Unheard::Dropped),
            Just(Unheard::Unsent),
        ]
        .prop_map(Act::Answer),
        1 => Just(Act::NoCall),
        1 => Just(Act::Agent),
        1 => Just(Act::Listed),
        1 => (1u8..4).prop_map(Act::Pick),
        1 => any::<bool>().prop_map(Act::Resized),
        1 => Just(Act::TimedOut),
        1 => (1u8..4).prop_map(Act::OtherSize),
    ]
}

fn size(n: u8) -> Json {
    json!({"_tag": "device", "width": 100 * u64::from(n), "height": 200})
}

/// The MC's tab.
struct Mc {
    nav: Json,
    back: bool,
    forward: bool,
    viewport: Json,
}

impl Mc {
    fn snapshot(&self) -> Json {
        json!({
            "id": "tab-1",
            "navStatus": self.nav,
            "canGoBack": self.back,
            "canGoForward": self.forward,
            "viewport": self.viewport,
        })
    }
}

proptest! {
    #[test]
    fn the_page_follows_its_tab(acts in prop::collection::vec(act(), 1..60)) {
        let mut mc = Mc {
            nav: json!({"url": "http://localhost:5173/", "title": "", "_tag": "Success"}),
            back: false,
            forward: false,
            viewport: json!({"_tag": "fill"}),
        };
        let mut page = PageCore::default();
        page.set_tab("tab-1", mc.snapshot());
        page.take_notes();
        let mut in_flight: Option<(Json, bool, bool, u64)> = None;
        let mut pick: Option<(Json, u64)> = None;
        let mut agents = 0;
        for act in acts {
            let mut expect_load = None;
            match act {
                Act::View(n, done) => {
                    let url = format!("http://localhost:5173/page-{n}");
                    let phase = if done { "loaded" } else { "loading" };
                    page.report(phase, &url, "", 0, "", n > 0, false);
                }
                Act::Answer(unheard) => {
                    if let Some((nav, back, forward, owner)) = in_flight.take() {
                        // Heard, or dropped after the MC took it.
                        if matches!(unheard, Unheard::Heard | Unheard::Dropped) {
                            mc.nav = nav;
                            mc.back = back;
                            mc.forward = forward;
                            page.refresh(mc.snapshot(), "navigated");
                            // The MC saying back what the page said is no
                            // news.
                            prop_assert!(!page
                                .take_notes()
                                .iter()
                                .any(|note| matches!(note, PageNote::LoadRequested(_))));
                        }
                        page.heard("tab-1", owner, unheard);
                    }
                }
                Act::NoCall => {
                    if let Some((_, _, _, owner)) = in_flight.take() {
                        page.unreported(owner);
                    }
                }
                Act::Agent => {
                    agents += 1;
                    let url = format!("http://localhost:5173/agent-{agents}");
                    mc.nav = json!({"url": url, "title": "", "_tag": "Loading"});
                    page.refresh(mc.snapshot(), "navigated");
                    expect_load = Some(url);
                }
                Act::Listed => page.listed(),
                Act::Pick(n) => {
                    let resizing = page.resizing();
                    page.set_viewport(size(n));
                    if resizing {
                        prop_assert!(page.take_effects().is_empty(), "one size at a time");
                    }
                }
                Act::Resized(ok) => {
                    if let Some((viewport, n)) = pick.take() {
                        if ok {
                            mc.viewport = viewport;
                            page.refresh(mc.snapshot(), "resized");
                        }
                        page.resized("tab-1", n, (!ok).then_some("refused"));
                        if !ok {
                            prop_assert_eq!(page.viewport(), mc.viewport.clone());
                        }
                    }
                }
                Act::TimedOut => {
                    if let Some((_, n)) = pick.take() {
                        page.timed_out("tab-1", n);
                        prop_assert_eq!(page.viewport(), mc.viewport.clone());
                    }
                }
                Act::OtherSize(n) => {
                    mc.viewport = size(n);
                    page.refresh(mc.snapshot(), "resized");
                }
            }
            let notes = page.take_notes();
            if let Some(url) = expect_load {
                prop_assert!(
                    notes.contains(&PageNote::LoadRequested(url.clone())),
                    "an agent's {} is loaded",
                    url
                );
            }
            for effect in page.take_effects() {
                match effect {
                    PageEffect::Report { tab, nav, back, forward, owner } => {
                        prop_assert_eq!(tab, "tab-1");
                        prop_assert!(in_flight.is_none(), "one report in flight");
                        in_flight = Some((nav, back, forward, owner));
                    }
                    PageEffect::Resize { tab, viewport, pick: n } => {
                        prop_assert_eq!(tab, "tab-1");
                        prop_assert!(pick.is_none(), "one size at a time");
                        pick = Some((viewport, n));
                    }
                    PageEffect::Navigate { .. } => {}
                }
            }
            prop_assert_eq!(page.resizing(), pick.is_some());
            prop_assert!(page.viewport().is_object());
            if pick.is_none() {
                prop_assert_eq!(page.viewport(), mc.viewport.clone());
            }
        }
    }
}
