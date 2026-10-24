//! The theme choice as a state machine: the mode chosen and the system's,
//! themes saved on this device, saved over and removed, the MC publishing
//! and withdrawing its own, whole themes and halves chosen, the defaults
//! restored, and the editor opened, drafted in, inspected and closed. What
//! is drawn is always what the device's choice resolves to over the themes
//! there are, and the editor keeps a draft while it is open, and after a
//! press outside only when it was changed.

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::{Mode, Themes};
use hal_c2_shell::json::Json;
use ljos::prelude::{ColorScheme, Engine};
use proptest::prelude::*;
use serde_json::{Map, json};
use tempfile::TempDir;

use crate::Hub;

const COLORS: [&str; 4] = ["#102030", "#203040", "#304050", "#405060"];
/// "Grove" is a built-in's name: saved, it is `grove-2`. "HAL-C2" makes the
/// standard look's id, which a saved theme does not take: it is `hal-c2-2`.
const LABELS: [&str; 4] = ["Dusk", "Dawn", "Grove", "HAL-C2"];
/// `ember` is a built-in's id, which the MC's theme does not get.
const PUBLISHED: [(&str, bool); 3] = [("dusk", false), ("aurora", true), ("ember", true)];
/// Built-ins, saved and published ones, and one that is nowhere.
const CHOICES: [&str; 9] = [
    "", "grove", "iris", "dusk", "dawn", "aurora", "ember", "dusk-2", "gone",
];
const MODES: [Mode; 3] = [Mode::System, Mode::Light, Mode::Dark];

#[derive(Clone, Debug)]
enum Op {
    System(bool),
    SetMode(Mode),
    Cycle,
    Restore,
    Choose(&'static str),
    ChooseHalf(bool, &'static str),
    /// A new theme of this label, dark or light, in a colour.
    Save(&'static str, bool, usize),
    /// A saved one (picked from those there are) in another colour.
    SaveOver(usize, usize),
    Remove(usize),
    /// A copy of the standard look as drawn now.
    DuplicateStandard,
    /// The MC's themes: which of [`PUBLISHED`], in which colour.
    Publish(Vec<bool>, usize),
    Open(bool),
    /// The editor closed by a press outside it.
    Hide,
    Edit(usize),
    SetEditing(usize),
    Inspect(bool),
    Pick,
}

fn op() -> impl Strategy<Value = Op> {
    let color = 0..COLORS.len();
    prop_oneof![
        2 => any::<bool>().prop_map(Op::System),
        2 => proptest::sample::select(&MODES[..]).prop_map(Op::SetMode),
        1 => Just(Op::Cycle),
        1 => Just(Op::Restore),
        3 => proptest::sample::select(&CHOICES[..]).prop_map(Op::Choose),
        2 => (any::<bool>(), proptest::sample::select(&CHOICES[..]))
            .prop_map(|(dark, id)| Op::ChooseHalf(dark, id)),
        3 => (proptest::sample::select(&LABELS[..]), any::<bool>(), color.clone())
            .prop_map(|(label, dark, c)| Op::Save(label, dark, c)),
        2 => (any::<usize>(), color.clone()).prop_map(|(i, c)| Op::SaveOver(i, c)),
        2 => any::<usize>().prop_map(Op::Remove),
        1 => Just(Op::DuplicateStandard),
        2 => (proptest::collection::vec(any::<bool>(), PUBLISHED.len()), color.clone())
            .prop_map(|(which, c)| Op::Publish(which, c)),
        2 => any::<bool>().prop_map(Op::Open),
        1 => Just(Op::Hide),
        1 => color.clone().prop_map(Op::Edit),
        1 => color.prop_map(Op::SetEditing),
        1 => any::<bool>().prop_map(Op::Inspect),
        1 => Just(Op::Pick),
    ]
}

fn side(dark: bool) -> &'static str {
    if dark { "dark" } else { "light" }
}

/// A saved or published theme of one appearance.
#[derive(Clone, Debug)]
struct Theme {
    id: String,
    label: String,
    dark: bool,
    canvas: &'static str,
}

impl Theme {
    fn file(&self) -> Json {
        json!({"id": self.id, "label": self.label, "appearance": side(self.dark),
               "colors": {"canvas": self.canvas}})
    }
}

fn themes<R>(hub: &Hub, f: impl FnOnce(&mut Themes, &Engine) -> R) -> R {
    hub.with_controller::<Themes, R>(f)
}

/// An editor's draft in `COLORS[color]`.
fn edited(color: usize) -> Map<String, Json> {
    let draft = json!({"id": "", "label": "Edited", "appearance": "light",
                       "colors": {"canvas": COLORS[color]}});
    draft.as_object().cloned().unwrap_or_default()
}

/// What the editor holds.
#[derive(Clone, Debug, PartialEq)]
enum Editing {
    /// The draft of the theme drawn when it opened.
    Draft,
    /// A draft in this canvas.
    Canvas(&'static str),
}

#[derive(Default)]
struct Model {
    system_dark: bool,
    mode: Option<Mode>,
    theme: Option<String>,
    halves: Map<String, Json>,
    saved: Vec<Theme>,
    published: Vec<Theme>,
    editor_open: bool,
    editing: Option<Editing>,
    /// What the editor opened on, to tell whether anything changed since.
    opened: Option<Editing>,
    inspecting: bool,
    picked: bool,
}

/// A definition: built-ins have both appearances and colours the model does
/// not check.
struct Found {
    dark_only: Option<bool>,
    canvas: Option<&'static str>,
}

impl Found {
    fn has(&self, dark: bool) -> bool {
        self.dark_only.is_none_or(|d| d == dark)
    }
}

impl Model {
    fn mode(&self) -> Mode {
        self.mode.unwrap_or(Mode::System)
    }

    /// Built-in, then saved, then published.
    fn find(&self, builtins: &[String], id: &str) -> Option<Found> {
        if id.is_empty() {
            return None;
        }
        if builtins.iter().any(|b| b == id) {
            return Some(Found {
                dark_only: None,
                canvas: None,
            });
        }
        self.saved
            .iter()
            .chain(&self.published)
            .find(|t| t.id == id)
            .map(|t| Found {
                dark_only: Some(t.dark),
                canvas: Some(t.canvas),
            })
    }

    fn half(&self, dark: bool) -> Option<String> {
        self.halves
            .get(side(dark))
            .and_then(Json::as_str)
            .map(str::to_owned)
    }

    /// The id drawn, whether dark, and the canvas when not a built-in's.
    fn resolved(&self, builtins: &[String]) -> (String, bool, Option<&'static str>) {
        let target = match self.mode() {
            Mode::System => self.system_dark,
            Mode::Light => false,
            Mode::Dark => true,
        };
        let theme = self.theme.clone().unwrap_or_default();
        let mut dark = target;
        if self.half(target).is_none()
            && let Some(base) = self.find(builtins, &theme)
            && !base.has(target)
        {
            dark = !target;
        }
        let id = self.half(dark).unwrap_or(theme);
        match self.find(builtins, &id) {
            Some(found) if found.has(dark) => (id, dark, found.canvas),
            _ => ("hal-c2".to_owned(), dark, None),
        }
    }

    fn set_choice(&mut self, theme: Option<String>) {
        self.theme = theme;
        self.halves.clear();
    }

    fn choose_half(&mut self, dark: bool, id: &str) {
        if id.is_empty() {
            self.halves.remove(side(dark));
        } else {
            self.halves.insert(side(dark).into(), json!(id));
        }
    }
}

struct World {
    hub: Hub,
    _dir: TempDir,
    model: Model,
    builtins: Vec<String>,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
        let hub = Hub::with(Launch {
            config_dir: Some(dir.path().to_owned()),
            ..Launch::default()
        });
        let builtins = hub
            .with_controller::<Themes, _>(|t, _| t.available())
            .into_iter()
            .filter(|t| t["source"] == "builtIn")
            .map(|t| t["id"].as_str().unwrap_or_default().to_owned())
            .collect();
        World {
            hub,
            _dir: dir,
            model: Model::default(),
            builtins,
        }
    }

    fn step(&mut self, op: Op) {
        let (hub, builtins) = (&self.hub, &self.builtins);
        let m = &mut self.model;
        match op {
            Op::System(dark) => {
                ljos::testing::update_system_prefs(&hub.engine, |p| {
                    p.color_scheme = if dark {
                        ColorScheme::Dark
                    } else {
                        ColorScheme::Light
                    }
                });
                m.system_dark = dark;
            }
            Op::SetMode(mode) => {
                assert!(themes(hub, |t, e| t.set_mode(e, mode)));
                m.mode = Some(mode);
            }
            Op::Cycle => {
                hub.dispatch("appearance.cycle", json!({}));
                m.mode = Some(match m.mode() {
                    Mode::System => Mode::Light,
                    Mode::Light => Mode::Dark,
                    Mode::Dark => Mode::System,
                });
            }
            Op::Restore => {
                assert!(themes(hub, |t, e| t.restore_defaults(e)));
                m.mode = None;
                m.set_choice(None);
            }
            Op::Choose(id) => {
                assert!(themes(hub, |t, e| t.choose(e, id)));
                match m.find(builtins, id) {
                    Some(Found {
                        dark_only: Some(dark),
                        ..
                    }) => m.choose_half(dark, id),
                    _ => m.set_choice((!id.is_empty()).then(|| id.to_owned())),
                }
            }
            Op::ChooseHalf(dark, id) => {
                assert!(themes(hub, |t, e| t.choose_half(e, side(dark), id)));
                m.choose_half(dark, id);
            }
            Op::Save(label, dark, color) => {
                let draft = json!({"id": "", "label": label, "appearance": side(dark),
                                   "colors": {"canvas": COLORS[color]}});
                let draft = draft.as_object().cloned().unwrap();
                let saved = themes(hub, |t, e| t.save_custom(e, &draft));
                let base = label.to_lowercase();
                let mut id = base.clone();
                let mut n = 2;
                while m.find(builtins, &id).is_some() || id == "hal-c2" {
                    id = format!("{base}-{n}");
                    n += 1;
                }
                assert_eq!(saved, id);
                m.saved.push(Theme {
                    id: id.clone(),
                    label: label.to_owned(),
                    dark,
                    canvas: COLORS[color],
                });
                m.set_choice(Some(id));
            }
            Op::SaveOver(pick, color) => {
                if m.saved.is_empty() {
                    return;
                }
                let at = pick % m.saved.len();
                let mut theme = m.saved[at].clone();
                theme.canvas = COLORS[color];
                let draft = theme.file().as_object().cloned().unwrap();
                assert_eq!(themes(hub, |t, e| t.save_custom(e, &draft)), theme.id);
                m.set_choice(Some(theme.id.clone()));
                m.saved[at] = theme;
            }
            Op::Remove(pick) => {
                let id = match m.saved.len() {
                    0 => "grove".to_owned(),
                    len => m.saved[pick % len].id.clone(),
                };
                let removed = themes(hub, |t, e| t.remove_custom(e, &id));
                assert_eq!(removed, !m.saved.is_empty(), "{id} removed");
                if removed {
                    m.saved.retain(|t| t.id != id);
                    if m.theme.as_deref() == Some(&id) {
                        m.theme = None;
                    }
                    m.halves.retain(|_, v| v.as_str() != Some(&id));
                }
            }
            Op::DuplicateStandard => {
                let (_, dark, _) = m.resolved(builtins);
                let saved = themes(hub, |t, e| t.duplicate_standard(e));
                let mut id = "hal-c2-copy".to_owned();
                let mut n = 2;
                while m.find(builtins, &id).is_some() {
                    id = format!("hal-c2-copy-{n}");
                    n += 1;
                }
                assert_eq!(saved, id);
                m.saved.push(Theme {
                    id: id.clone(),
                    label: "HAL-C2 copy".to_owned(),
                    dark,
                    canvas: if dark { "#0a0a0a" } else { "#fcfcfc" },
                });
                m.set_choice(Some(id));
            }
            Op::Publish(which, color) => {
                m.published = PUBLISHED
                    .iter()
                    .zip(which)
                    .filter(|(_, on)| *on)
                    .map(|((id, dark), _)| Theme {
                        id: (*id).to_owned(),
                        label: (*id).to_owned(),
                        dark: *dark,
                        canvas: COLORS[color],
                    })
                    .collect();
                let files = m.published.iter().map(Theme::file).collect();
                Settings::of(&hub.engine).set_themes(&hub.engine, files);
            }
            Op::Open(open) => {
                themes(hub, |t, e| t.set_editor_open(e, open));
                if open && !m.editor_open && m.editing.is_none() {
                    m.editing = Some(Editing::Draft);
                    m.opened = Some(Editing::Draft);
                }
                if !open && m.editor_open {
                    m.editing = None;
                    m.opened = None;
                    m.inspecting = false;
                    m.picked = false;
                }
                m.editor_open = open;
            }
            Op::Hide => {
                themes(hub, |t, e| t.hide_editor(e));
                if m.editor_open {
                    if m.editing == m.opened {
                        m.editing = None;
                    }
                    m.editor_open = false;
                    m.inspecting = false;
                    m.picked = false;
                }
            }
            Op::Edit(color) => {
                let draft = edited(color);
                themes(hub, |t, e| t.edit(e, draft));
                m.editing = Some(Editing::Canvas(COLORS[color]));
                m.opened = m.editing.clone();
                m.editor_open = true;
            }
            Op::SetEditing(color) => {
                let draft = edited(color);
                themes(hub, |t, e| t.set_editing(e, draft));
                if m.editor_open {
                    m.editing = Some(Editing::Canvas(COLORS[color]));
                }
            }
            Op::Inspect(inspecting) => {
                themes(hub, |t, e| t.set_inspecting(e, inspecting));
                if inspecting && !m.inspecting {
                    m.picked = false;
                }
                m.inspecting = inspecting;
            }
            Op::Pick => {
                themes(hub, |t, e| t.pick(e, "#fcfcfc"));
                if m.inspecting {
                    m.inspecting = false;
                    m.picked = true;
                }
            }
        }
    }

    fn check(&self) {
        let m = &self.model;
        let hub = &self.hub;
        assert_eq!(themes(hub, |t, _| t.mode()), m.mode());
        let theme_id = m.theme.clone().unwrap_or_default();
        assert_eq!(themes(hub, |t, _| t.theme_id()), theme_id);
        assert_eq!(themes(hub, |t, _| t.halves()), m.halves);

        // What is saved is the choice.
        let device = Settings::of(&hub.engine).device();
        assert_eq!(
            device.get("appearance").and_then(Json::as_str),
            m.mode.map(Mode::name)
        );
        assert_eq!(
            device.get("theme").and_then(Json::as_str),
            m.theme.as_deref()
        );
        assert_eq!(
            device.get("themeHalves").and_then(Json::as_object),
            (!m.halves.is_empty()).then_some(&m.halves)
        );

        // What is drawn.
        let (id, dark, canvas) = m.resolved(&self.builtins);
        let drawn = hub.published("theme");
        assert_eq!(themes(hub, |t, _| t.resolved_id()), id);
        assert_eq!(drawn["id"], id);
        assert_eq!(drawn["appearance"], side(dark));
        assert_eq!(themes(hub, |t, _| t.appearance()), side(dark));
        if let Some(canvas) = canvas {
            assert_eq!(drawn["colors"]["canvas"], canvas, "{id}");
        }

        // What is offered: each id once, a saved one over a published one.
        let offered = themes(hub, |t, _| t.available());
        let of = |source: &str| -> Vec<String> {
            offered
                .iter()
                .filter(|t| t["source"] == source)
                .map(|t| t["id"].as_str().unwrap_or_default().to_owned())
                .collect()
        };
        let saved: Vec<String> = m.saved.iter().map(|t| t.id.clone()).collect();
        let published: Vec<String> = m
            .published
            .iter()
            .filter(|t| !saved.contains(&t.id) && !self.builtins.contains(&t.id))
            .map(|t| t.id.clone())
            .collect();
        assert_eq!(of("builtIn"), self.builtins);
        assert_eq!(of("custom"), saved);
        assert_eq!(of("environment"), published);

        // The editor.
        assert_eq!(themes(hub, |t, _| t.editor_open()), m.editor_open);
        let editing = themes(hub, |t, _| t.editing());
        match &m.editing {
            None => assert!(editing.is_empty(), "{editing:?}"),
            Some(Editing::Draft) => assert!(editing.contains_key("colors"), "{editing:?}"),
            Some(Editing::Canvas(canvas)) => {
                assert_eq!(editing["colors"]["canvas"], *canvas)
            }
        }
        // Open, there is a draft; closed by a press outside, one is kept.
        assert!(m.editing.is_some() || !m.editor_open);
        assert_eq!(themes(hub, |t, _| t.inspecting()), m.inspecting);
        assert_eq!(!themes(hub, |t, _| t.picked()).is_empty(), m.picked);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn the_theme_drawn_follows_the_choice_and_the_themes_there_are(
        ops in proptest::collection::vec(op(), 1..40),
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
