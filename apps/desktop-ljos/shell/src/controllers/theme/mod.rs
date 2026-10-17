//! `theme`, desktop-qt's ThemeController: the look the shell draws in
//! (`Shell.state.theme`, which `Theme` draws from) and the `Themes`
//! singleton the Appearance page, the theme editor and the importer use.
//!
//! The look resolves from this device's preferences (`appearance`, `theme`
//! and `themeHalves`, which [`Settings`] keeps), the themes on offer (the
//! built-in ones, this device's `customThemes`, then the ones the MC
//! publishes), the Appearance rows (diff colours, glass, fonts), and the
//! system's colour scheme, followed as it changes. A theme of one appearance
//! takes that half of the look only.
//!
//! The state QML and the commands reach lives in a [`View`] apart from the
//! controller, so `Themes.draft()` read in a binding while this controller
//! runs still answers.
//!
//! Where desktop-qt reads `#rrggbbaa` it reads it as Qt does `#aarrggbb`;
//! here it is CSS's order, which is what the files mean.

pub mod color;
pub mod import;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::Path;
use std::rc::{Rc, Weak};
use std::sync::OnceLock;

use ljos::prelude::{
    Atom, Cx, Engine, ObjectId, QmlObject, QmlValue, StyleHints, Value, qml_impl, qml_singleton,
};
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::commands::{Choice, Commands};
use crate::controller::{self, Controller, Init};
use crate::controllers::keybindings::APPEARANCE_CYCLE;
use crate::controllers::menus::{Answer, Menus};
use crate::controllers::settings::{Settings, same_map};
use crate::controllers::toasts::Toasts;
use crate::json::{self, Json};

pub use color::{canonical_color, canonical_colors, derive, families, oklch_to_hex};
pub use import::{MAX_THEME_FILE_BYTES, id_from_name, oversized};

/// What the standard look is published as.
pub const STANDARD_ID: &str = "hal-c2";

const LIGHT: &str = "light";
const DARK: &str = "dark";
const SYSTEM: &str = "system";
const CUSTOM_THEMES: &str = "customThemes";
const HALVES: &str = "themeHalves";
// The wording of the theme failures.
const SAVE_FAILED: &str = "Couldn't save theme selection";
const REMOVE_FAILED: &str = "Couldn’t remove theme";

// --- What a theme is --------------------------------------------------------

/// themes.json (scripts/gen-themes.mjs) as desktop-qt builds it in, its
/// colours made drawable once.
pub(crate) struct BuiltIns {
    pub roles: Vec<String>,
    pub standard: Map<String, Json>,
    pub defaults: Map<String, Json>,
    pub fixed: Map<String, Json>,
    pub radius: f64,
    pub font_ui: String,
    pub font_mono: String,
    pub reserved: Vec<String>,
    pub themes: Vec<Json>,
}

pub(crate) fn built_ins() -> &'static BuiltIns {
    static DATA: OnceLock<BuiltIns> = OnceLock::new();
    DATA.get_or_init(|| {
        let root: Json = serde_json::from_str(include_str!(
            "../../../../../desktop-qt/src/native/themes.json"
        ))
        .unwrap_or_default();
        let per_appearance = |key: &str| {
            let pair = &root[key];
            let mut both = Map::new();
            for appearance in [LIGHT, DARK] {
                let colors = canonical_colors(&object_of(pair.get(appearance)));
                both.insert(appearance.to_owned(), Json::Object(colors));
            }
            both
        };
        let strings = |key: &str| -> Vec<String> {
            root[key]
                .as_array()
                .map(|items| items.iter().map(|v| string_of(v).to_owned()).collect())
                .unwrap_or_default()
        };
        let themes = root["builtIn"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(|theme| {
                let mut theme = object_of(Some(&theme));
                let colors = canonical_colors(&object_of(theme.get("colors")));
                let variants: Map<String, Json> = object_of(theme.get("variants"))
                    .into_iter()
                    .map(|(key, colors)| {
                        (
                            key,
                            Json::Object(canonical_colors(&object_of(Some(&colors)))),
                        )
                    })
                    .collect();
                theme.insert("colors".into(), Json::Object(colors));
                theme.insert("variants".into(), Json::Object(variants));
                Json::Object(theme)
            })
            .collect();
        BuiltIns {
            roles: strings("roles"),
            standard: per_appearance("standard"),
            defaults: per_appearance("defaults"),
            fixed: per_appearance("fixed"),
            radius: root["radius"].as_f64().unwrap_or(10.0),
            font_ui: string_of(&root["fonts"]["ui"]).to_owned(),
            font_mono: string_of(&root["fonts"]["mono"]).to_owned(),
            reserved: strings("reserved"),
            themes,
        }
    })
}

/// `QJsonValue::toString`: a string's text, "" for anything else.
pub(crate) fn string_of(value: &Json) -> &str {
    value.as_str().unwrap_or_default()
}

/// `QJsonValue::toObject`: an object's fields, none for anything else.
pub(crate) fn object_of(value: Option<&Json>) -> Map<String, Json> {
    value.and_then(Json::as_object).cloned().unwrap_or_default()
}

/// `QJsonValue::toInt`: a whole number in `int`'s range, else 0.
pub(crate) fn int_of(value: Option<&Json>) -> i64 {
    value
        .and_then(Json::as_f64)
        .filter(|n| n.fract() == 0.0 && *n >= f64::from(i32::MIN) && *n <= f64::from(i32::MAX))
        .map_or(0, |n| n as i64)
}

/// `QVariant::toInt` on a setting: a number rounded, a string's whole
/// number, else 0.
fn variant_int(value: Option<&Json>) -> i64 {
    match value {
        Some(Json::Number(n)) => n
            .as_i64()
            .unwrap_or_else(|| n.as_f64().unwrap_or(0.0).round() as i64),
        Some(Json::String(s)) => s.trim().parse().unwrap_or(0),
        Some(Json::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

/// A QString's length.
pub(crate) fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// `QString::left`: at most `n` UTF-16 units (a pair is not split).
pub(crate) fn left_utf16(text: &str, n: usize) -> &str {
    let mut units = 0;
    for (at, c) in text.char_indices() {
        units += c.len_utf16();
        if units > n {
            return &text[..at];
        }
    }
    text
}

fn appearance_of(value: Option<&Json>) -> &'static str {
    if value.and_then(Json::as_str) == Some(DARK) {
        DARK
    } else {
        LIGHT
    }
}

/// A theme on offer: its own colours (`appearance`) and the other
/// appearance's (`variants`).
#[derive(Clone, Debug)]
struct Definition {
    id: String,
    label: String,
    appearance: &'static str,
    colors: Map<String, Json>,
    variants: Map<String, Json>,
    /// builtIn, custom (this device's) or environment (the MC's).
    source: &'static str,
    collection: String,
}

impl Definition {
    fn colors_for(&self, appearance: &str) -> Map<String, Json> {
        if appearance == self.appearance {
            self.colors.clone()
        } else {
            object_of(self.variants.get(appearance))
        }
    }

    fn has(&self, appearance: &str) -> bool {
        !self.colors_for(appearance).is_empty()
    }
}

/// Saved and published themes fill the roles they leave out from the
/// defaults.
fn from_file(theme: &Map<String, Json>, source: &'static str) -> Option<Definition> {
    let data = built_ins();
    let id = string_of(theme.get("id").unwrap_or(&Json::Null));
    if id.is_empty() || data.reserved.iter().any(|r| r == id) {
        return None;
    }
    let appearance = appearance_of(theme.get("appearance"));
    let mut base = object_of(data.defaults.get(appearance));
    // The seeded short form: a canvas and an accent, painted over the defaults.
    let seed = |key: &str| canonical_color(string_of(theme.get(key).unwrap_or(&Json::Null)));
    let seeded = seed("canvas").zip(seed("accent"));
    if let Some((canvas, accent)) = &seeded {
        for role in ["canvas", "chrome", "toolbar", "sidebar"] {
            base.insert(role.into(), json!(canvas));
        }
        for role in ["accent", "focus"] {
            base.insert(role.into(), json!(accent));
        }
    }
    let colors = object_of(theme.get("colors"));
    let mut variants = Map::new();
    for (key, variant) in object_of(theme.get("variants")) {
        if key == appearance || (key != LIGHT && key != DARK) {
            continue;
        }
        let variant = object_of(Some(&variant));
        if import::overlay(Map::new(), &variant).is_empty() {
            continue;
        }
        let over = import::overlay(object_of(data.defaults.get(&key)), &variant);
        variants.insert(key, Json::Object(over));
    }
    if seeded.is_none() && import::overlay(Map::new(), &colors).is_empty() && variants.is_empty() {
        return None;
    }
    let label = match theme.get("label").and_then(Json::as_str) {
        Some(label) if !label.is_empty() => label.to_owned(),
        _ => theme
            .get("name")
            .and_then(Json::as_str)
            .unwrap_or(id)
            .to_owned(),
    };
    Some(Definition {
        id: id.to_owned(),
        label,
        appearance,
        colors: import::overlay(base, &colors),
        variants,
        source,
        collection: string_of(
            &theme
                .get("collection")
                .map_or(Json::Null, |c| c["label"].clone()),
        )
        .to_owned(),
    })
}

/// The three colours a picker previews a palette with.
fn swatch_of(colors: &Map<String, Json>) -> Json {
    ["canvas", "accent", "text"]
        .iter()
        .map(|role| json!(string_of(colors.get(*role).unwrap_or(&Json::Null))))
        .collect()
}

/// The appearance mode: the system's, or always light or dark.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    System,
    Light,
    Dark,
}

impl Mode {
    pub fn parse(mode: &str) -> Option<Mode> {
        match mode {
            SYSTEM => Some(Mode::System),
            LIGHT => Some(Mode::Light),
            DARK => Some(Mode::Dark),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::System => SYSTEM,
            Mode::Light => LIGHT,
            Mode::Dark => DARK,
        }
    }
}

// --- QML's `Themes` -----------------------------------------------------------

/// `Themes` in QML: desktop-qt's ThemeController as the bricks read it.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Themes", uncreatable)]
#[qml_singleton]
pub struct ThemesObject {
    /// system, light or dark.
    #[qml(notify, readonly)]
    mode: Atom,
    /// The theme chosen for both appearances; "" for the standard look.
    #[qml(notify, readonly)]
    theme_id: Atom,
    /// {light, dark}: the theme chosen for one appearance.
    #[qml(notify, readonly)]
    halves: Value,
    /// The appearance drawn now.
    #[qml(notify, readonly)]
    appearance: Atom,
    /// The theme drawn now; `hal-c2` for the standard look.
    #[qml(notify, readonly)]
    resolved_id: Atom,
    /// [{id, label, appearance, appearances, source, collection, swatch}]
    #[qml(notify, readonly)]
    available: Value,
    #[qml(notify, readonly)]
    standard_swatch: Value,
    #[qml(readonly)]
    roles: Value,
    /// [{title, roles}]: the editor's groups.
    #[qml(readonly)]
    families: Value,
    #[qml(notify)]
    editor_open: bool,
    /// The editor's draft: {id, label, appearance, colors}.
    #[qml(notify, readonly)]
    editing: Value,
    /// Picking a colour off the window.
    #[qml(notify)]
    inspecting: bool,
    /// {color, role, roles, count}: what the pick found.
    #[qml(notify, readonly)]
    picked: Value,
    #[qml(notify, readonly)]
    import_error: Atom,
    /// The labels of the themes an import would replace.
    #[qml(notify, readonly)]
    import_conflicts: Value,
}

impl Default for ThemesObject {
    fn default() -> Self {
        ThemesObject {
            mode: Atom::from(SYSTEM),
            theme_id: Atom::from(""),
            halves: Value::Undefined,
            appearance: Atom::from(DARK),
            resolved_id: Atom::from(STANDARD_ID),
            available: Value::Undefined,
            standard_swatch: Value::Undefined,
            roles: Value::Undefined,
            families: Value::Undefined,
            editor_open: false,
            editing: Value::Undefined,
            inspecting: false,
            picked: Value::Undefined,
            import_error: Atom::from(""),
            import_conflicts: Value::Undefined,
        }
    }
}

/// Each window's `Themes` object and the view behind it.
#[derive(Default)]
struct Views(RefCell<HashMap<ObjectId, Weak<View>>>);

/// Runs `f` on the view behind `cx`'s object, as its window.
fn on_view<R: Default>(cx: &Cx, f: impl FnOnce(&Engine, &View) -> R) -> R {
    let view = cx
        .engine
        .extension::<Views>()
        .0
        .borrow()
        .get(&cx.this)
        .and_then(Weak::upgrade);
    match view {
        Some(view) => view.bridge.act(cx.engine, || f(cx.engine, &view)),
        None => R::default(),
    }
}

fn text_of(engine: &Engine, value: &Value) -> String {
    string_of(&json::from_value(engine, value)).to_owned()
}

#[qml_impl]
impl ThemesObject {
    #[qml(invokable)]
    fn set_mode(cx: &Cx, mode: Atom) -> bool {
        on_view(cx, |engine, view| view.set_mode(engine, &mode))
    }

    #[qml(invokable)]
    fn choose(cx: &Cx, id: Atom) -> bool {
        on_view(cx, |engine, view| view.choose(engine, &id))
    }

    #[qml(invokable)]
    fn choose_half(cx: &Cx, appearance: Atom, id: Atom) -> bool {
        on_view(cx, |engine, view| {
            view.choose_half(engine, &appearance, &id)
        })
    }

    #[qml(invokable)]
    fn cycle_appearance(cx: &Cx) -> bool {
        on_view(cx, |engine, view| view.cycle_appearance(engine))
    }

    #[qml(invokable)]
    fn restore_defaults(cx: &Cx) -> bool {
        on_view(cx, |engine, view| view.restore_defaults(engine))
    }

    /// The editor's draft of `id` (the theme drawn now when none).
    #[qml(invokable)]
    fn draft(cx: &Cx, id: Value) -> Value {
        let id = text_of(cx.engine, &id);
        on_view(cx, |engine, view| {
            Json::Object(view.draft(engine, &id)).to_value()
        })
    }

    #[qml(invokable)]
    fn save_custom(cx: &Cx, theme: Json) -> String {
        on_view(cx, |engine, view| {
            view.save_custom(engine, &object_of(Some(&theme)))
        })
    }

    #[qml(invokable)]
    fn duplicate(cx: &Cx, id: Atom) -> String {
        on_view(cx, |engine, view| view.duplicate(engine, &id))
    }

    #[qml(invokable)]
    fn remove_custom(cx: &Cx, id: Atom) -> bool {
        on_view(cx, |engine, view| {
            view.remove_custom_many(engine, &[id.to_string()])
        })
    }

    #[qml(invokable)]
    fn request_remove(cx: &Cx, id: Atom) {
        on_view(cx, |engine, view| view.request_remove(engine, &id));
    }

    #[qml(invokable)]
    fn request_remove_many(cx: &Cx, ids: Vec<String>) {
        on_view(cx, |engine, view| view.request_remove_many(engine, &ids));
    }

    #[qml(invokable)]
    fn edit(cx: &Cx, draft: Json) {
        on_view(cx, |engine, view| {
            view.edit(engine, object_of(Some(&draft)))
        });
    }

    #[qml(invokable)]
    fn set_editing(cx: &Cx, draft: Json) {
        on_view(cx, |engine, view| {
            view.set_editing(engine, object_of(Some(&draft)))
        });
    }

    #[qml(invokable)]
    fn pick(cx: &Cx, color: Atom) {
        on_view(cx, |engine, view| view.pick(engine, &color));
    }

    /// A whole palette from a canvas and an accent; {} when either is not
    /// a colour.
    #[qml(invokable)]
    fn derive(_cx: &Cx, canvas: Atom, accent: Atom) -> Value {
        Json::Object(derive_palette(&canvas, &accent)).to_value()
    }

    #[qml(invokable)]
    fn import_text(cx: &Cx, text: Atom) -> bool {
        on_view(cx, |engine, view| view.import_text(engine, &text))
    }

    #[qml(invokable)]
    fn import_files(cx: &Cx, paths: Vec<String>) {
        on_view(cx, |engine, view| view.import_files(engine, &paths));
    }

    /// cancel, copy or update.
    #[qml(invokable)]
    fn resolve_import(cx: &Cx, choice: Atom) {
        on_view(cx, |engine, view| view.resolve_import(engine, &choice));
    }

    #[qml(invokable)]
    fn clear_import(cx: &Cx) {
        on_view(cx, |engine, view| view.clear_import(engine));
    }

    #[qml(invokable)]
    fn export_theme(cx: &Cx, id: Atom, path: Atom) -> bool {
        on_view(cx, |engine, view| {
            view.export_theme(engine, &id, Path::new(&*path))
        })
    }
}

/// [`derive`] over the defaults of the canvas's appearance; {} when either
/// is not a colour.
pub fn derive_palette(canvas: &str, accent: &str) -> Map<String, Json> {
    derive(canvas, accent, |dark| {
        object_of(built_ins().defaults.get(if dark { DARK } else { LIGHT }))
    })
    .unwrap_or_default()
}

// --- The view -----------------------------------------------------------------

/// One window's themes: what its `Themes` shows and its commands reach.
struct View {
    bridge: Bridge,
    settings: Settings,
    object: Option<ObjectId>,
    system_dark: Cell<bool>,
    appearance: RefCell<&'static str>,
    resolved_id: RefCell<String>,
    /// The cycle's toast, replaced however fast the shortcut is pressed.
    cycle_toast: RefCell<String>,
    editor_open: Cell<bool>,
    editing: RefCell<Map<String, Json>>,
    inspecting: Cell<bool>,
    picked: RefCell<Map<String, Json>>,
    import_error: RefCell<String>,
    import_conflicts: RefCell<Vec<Json>>,
}

impl View {
    fn cx<'e>(&self, engine: &'e Engine) -> Option<Cx<'e>> {
        self.object.map(|obj| Cx::new(engine, obj))
    }

    fn mode(&self) -> &'static str {
        match self
            .settings
            .device_value("appearance")
            .as_ref()
            .and_then(Json::as_str)
        {
            Some(LIGHT) => LIGHT,
            Some(DARK) => DARK,
            _ => SYSTEM,
        }
    }

    fn theme_id(&self) -> String {
        self.settings
            .device_value("theme")
            .as_ref()
            .map(string_of)
            .unwrap_or_default()
            .to_owned()
    }

    fn halves(&self) -> Map<String, Json> {
        object_of(self.settings.device_value(HALVES).as_ref())
    }

    fn definitions(&self) -> Vec<Definition> {
        let mut result: Vec<Definition> = built_ins()
            .themes
            .iter()
            .map(|theme| Definition {
                id: string_of(&theme["id"]).to_owned(),
                label: string_of(&theme["label"]).to_owned(),
                appearance: appearance_of(theme.get("appearance")),
                colors: object_of(theme.get("colors")),
                variants: object_of(theme.get("variants")),
                source: "builtIn",
                collection: String::new(),
            })
            .collect();
        let saved = self
            .settings
            .device_value(CUSTOM_THEMES)
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default();
        let custom = saved.iter().map(|theme| (theme, "custom"));
        let published = self.settings.themes();
        let environment = published.iter().map(|theme| (theme, "environment"));
        for (theme, source) in custom.chain(environment) {
            result.extend(from_file(&object_of(Some(theme)), source));
        }
        result
    }

    /// The first with the id: built-in, then this device's, then published,
    /// so a theme the user saved wins over one the MC publishes under its id.
    fn find(&self, id: &str) -> Option<Definition> {
        if id.is_empty() {
            return None;
        }
        self.definitions().into_iter().find(|d| d.id == id)
    }

    fn available(&self) -> Vec<Json> {
        let appearance = *self.appearance.borrow();
        let mut seen: Vec<String> = Vec::new();
        let mut result = Vec::new();
        for definition in self.definitions() {
            if seen.contains(&definition.id) {
                continue;
            }
            seen.push(definition.id.clone());
            let appearances: Vec<&str> = [LIGHT, DARK]
                .into_iter()
                .filter(|a| definition.has(a))
                .collect();
            let shown = if appearances.contains(&appearance) {
                appearance
            } else {
                definition.appearance
            };
            result.push(json!({
                "id": definition.id,
                "label": definition.label,
                "appearance": definition.appearance,
                "appearances": appearances,
                "source": definition.source,
                "collection": definition.collection,
                "swatch": swatch_of(&definition.colors_for(shown)),
            }));
        }
        result
    }

    fn standard_swatch(&self) -> Json {
        swatch_of(&object_of(
            built_ins().standard.get(*self.appearance.borrow()),
        ))
    }

    // -- Showing -------------------------------------------------------------

    /// `changed`: the choice, the look, and what is on offer.
    fn show_changed(&self, engine: &Engine) {
        let Some(cx) = self.cx(engine) else {
            return;
        };
        let appearance = *self.appearance.borrow();
        let resolved = self.resolved_id.borrow().clone();
        let _ = cx.set(ThemesObject::MODE, Atom::from(self.mode()));
        let _ = cx.set(ThemesObject::THEME_ID, Atom::from(self.theme_id().as_str()));
        let _ = cx.set(ThemesObject::HALVES, Json::Object(self.halves()).to_value());
        let _ = cx.set(ThemesObject::APPEARANCE, Atom::from(appearance));
        let _ = cx.set(ThemesObject::RESOLVED_ID, Atom::from(resolved.as_str()));
        let _ = cx.set(
            ThemesObject::AVAILABLE,
            Json::Array(self.available()).to_value(),
        );
        let _ = cx.set(
            ThemesObject::STANDARD_SWATCH,
            self.standard_swatch().to_value(),
        );
    }

    fn show_editing(&self, engine: &Engine) {
        let Some(cx) = self.cx(engine) else {
            return;
        };
        let editing = Json::Object(self.editing.borrow().clone());
        let _ = cx.set(ThemesObject::EDITING, editing.to_value());
        let _ = cx.set(ThemesObject::EDITOR_OPEN, self.editor_open.get());
    }

    fn show_inspect(&self, engine: &Engine) {
        let Some(cx) = self.cx(engine) else {
            return;
        };
        let picked = Json::Object(self.picked.borrow().clone());
        let _ = cx.set(ThemesObject::INSPECTING, self.inspecting.get());
        let _ = cx.set(ThemesObject::PICKED, picked.to_value());
    }

    fn show_import(&self, engine: &Engine) {
        let Some(cx) = self.cx(engine) else {
            return;
        };
        let error = self.import_error.borrow().clone();
        let labels: Vec<Json> = self
            .import_conflicts
            .borrow()
            .iter()
            .map(|theme| json!(string_of(&theme["label"])))
            .collect();
        let _ = cx.set(ThemesObject::IMPORT_ERROR, Atom::from(error.as_str()));
        let _ = cx.set(
            ThemesObject::IMPORT_CONFLICTS,
            Json::Array(labels).to_value(),
        );
    }

    // -- The look ------------------------------------------------------------

    fn resolve(&self, engine: &Engine) {
        let data = built_ins();
        let target = match self.mode() {
            SYSTEM if self.system_dark.get() => DARK,
            SYSTEM => LIGHT,
            chosen => chosen,
        };
        let halves = self.halves();
        let half =
            |appearance: &str| string_of(halves.get(appearance).unwrap_or(&Json::Null)).to_owned();
        // A theme without the appearance asked for keeps its own, unless a
        // half gives one.
        let mut appearance = target;
        if half(target).is_empty()
            && let Some(base) = self.find(&self.theme_id())
            && !base.has(target)
        {
            appearance = base.appearance;
        }
        let mut id = half(appearance);
        if id.is_empty() {
            id = self.theme_id();
        }
        let mut colors = self
            .find(&id)
            .map(|d| d.colors_for(appearance))
            .unwrap_or_default();
        if colors.is_empty() {
            // No theme, or one no longer anywhere: the standard look.
            id = STANDARD_ID.to_owned();
            colors = object_of(data.standard.get(appearance));
        }
        for (role, color) in object_of(data.fixed.get(appearance)) {
            colors.entry(role).or_insert(color);
        }
        // The interface rows of Settings → Appearance that are colours:
        // what diffs draw additions and deletions in, and how solid menus,
        // dialogs and the composer are.
        let setting = |key: &str| self.settings.setting(engine, key);
        let blue_orange = setting("diffColorScheme").as_ref().map(string_of) == Some("blue-orange");
        let (added, removed) = if blue_orange {
            ("#3b82f6", "#f97316")
        } else {
            ("#22c55e", "#ef4444")
        };
        colors.insert("diffAdded".into(), json!(added));
        colors.insert("diffRemoved".into(), json!(removed));
        let glass = variant_int(setting("glassOpacity").as_ref()).clamp(40, 100);
        if glass < 100
            && let Some(overlay) = colors
                .get("surfaceOverlay")
                .and_then(Json::as_str)
                .and_then(with_glass(glass))
        {
            colors.insert("surfaceOverlay".into(), json!(overlay));
        }
        // The font rows of Settings → Appearance: a family the user named
        // wins over the theme's, and each part of the app has its size.
        let family = |key: &str, fallback: &str| {
            let chosen = setting(key);
            let chosen = chosen.as_ref().map(string_of).unwrap_or_default().trim();
            if chosen.is_empty() {
                fallback.to_owned()
            } else {
                chosen.to_owned()
            }
        };
        let size = |key: &str, fallback: i64| {
            let chosen = variant_int(setting(key).as_ref());
            if chosen > 0 { chosen } else { fallback }
        };
        let theme = json!({
            "id": id,
            "appearance": appearance,
            "colors": colors,
            "radius": data.radius,
            "fontUi": family("fontFamilySans", &data.font_ui),
            "fontMono": family("fontFamilyCode", &data.font_mono),
            // Empty: the composer writes in the interface font, the
            // terminal in the code font.
            "fontPrompt": family("fontFamilyComposer", ""),
            "fontTerminal": family("fontFamilyTerminal", ""),
            "fontSizes": {
                "interface": size("fontSizeInterface", 16),
                "prompt": size("fontSizePrompt", 14),
                "code": size("fontSizeCode", 13),
                "terminal": size("fontSizeTerminal", 12),
            },
        });
        *self.appearance.borrow_mut() = appearance;
        *self.resolved_id.borrow_mut() = id;
        self.bridge.publish(engine, "theme", theme);
        // The choice and `available` move with the device and the MC as well.
        self.show_changed(engine);
    }

    // -- Choosing ------------------------------------------------------------

    fn save(&self, engine: &Engine, device: Map<String, Json>, failure: &str) -> bool {
        if self.settings.set_device_settings(engine, device) {
            return true;
        }
        let title = if failure.is_empty() {
            SAVE_FAILED
        } else {
            failure
        };
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.error(engine, title, "Try again.");
        });
        false
    }

    fn set_mode(&self, engine: &Engine, mode: &str) -> bool {
        if Mode::parse(mode).is_none() {
            return false;
        }
        let mut device = self.settings.device();
        device.insert("appearance".into(), json!(mode));
        self.save(engine, device, "")
    }

    fn restore_defaults(&self, engine: &Engine) -> bool {
        let mut device = self.settings.device();
        for key in ["appearance", "theme", HALVES] {
            device.remove(key);
        }
        self.save(engine, device, "Couldn’t restore theme settings")
    }

    /// system, then light, then dark, then system again, told in a toast.
    fn cycle_appearance(&self, engine: &Engine) -> bool {
        let next = match self.mode() {
            SYSTEM => LIGHT,
            LIGHT => DARK,
            _ => SYSTEM,
        };
        if !self.set_mode(engine, next) {
            return false;
        }
        let previous = self.cycle_toast.borrow().clone();
        let label = format!("Appearance: {}{}", next[..1].to_uppercase(), &next[1..]);
        let shown = controller::with::<Toasts, _>(engine, |toasts, engine| {
            // One toast however fast the shortcut is pressed.
            if !previous.is_empty() {
                toasts.dismiss(engine, &previous);
            }
            toasts.show(engine, "info", &label, "", None, 1500)
        });
        if let Some(id) = shown {
            *self.cycle_toast.borrow_mut() = id;
        }
        true
    }

    fn choose(&self, engine: &Engine, id: &str) -> bool {
        if let Some(definition) = self.find(id) {
            let (light, dark) = (definition.has(LIGHT), definition.has(DARK));
            if light != dark {
                return self.choose_half(engine, if light { LIGHT } else { DARK }, id);
            }
        }
        let mut device = self.settings.device();
        if id.is_empty() {
            device.remove("theme");
        } else {
            device.insert("theme".into(), json!(id));
        }
        device.remove(HALVES);
        self.save(engine, device, "")
    }

    fn choose_half(&self, engine: &Engine, appearance: &str, id: &str) -> bool {
        if appearance != LIGHT && appearance != DARK {
            return false;
        }
        let mut device = self.settings.device();
        let mut halves = object_of(device.get(HALVES));
        if id.is_empty() {
            halves.remove(appearance);
        } else {
            halves.insert(appearance.into(), json!(id));
        }
        set_or_remove(&mut device, HALVES, halves);
        self.save(engine, device, "")
    }

    // -- Saved themes --------------------------------------------------------

    /// The editor's draft of `id`, or of the theme drawn now: its colours
    /// over the standard look's, in the appearance drawn now when it has
    /// one. `id` is kept only for this device's themes, which save over
    /// themselves.
    fn draft(&self, _engine: &Engine, id: &str) -> Map<String, Json> {
        let shown = *self.appearance.borrow();
        let resolved = self.resolved_id.borrow().clone();
        let definition = self.find(if id.is_empty() { &resolved } else { id });
        let appearance = match &definition {
            Some(d) if d.has(shown) => shown,
            Some(d) => d.appearance,
            None => shown,
        };
        let mut colors = object_of(built_ins().standard.get(appearance));
        if let Some(definition) = &definition {
            colors.extend(definition.colors_for(appearance));
        }
        let mut draft = Map::new();
        let editable = definition.as_ref().filter(|d| d.source == "custom");
        draft.insert(
            "id".into(),
            json!(editable.map(|d| d.id.as_str()).unwrap_or_default()),
        );
        draft.insert(
            "label".into(),
            json!(definition.as_ref().map_or("HAL-C2", |d| d.label.as_str())),
        );
        draft.insert("appearance".into(), json!(appearance));
        draft.insert("colors".into(), Json::Object(colors));
        draft
    }

    /// Saves `theme` ({id, label, appearance, colors}) on this device and
    /// draws it: over the saved theme of its id, else as a new one with an
    /// id from its label. Its id, or "" when it is not saved.
    fn save_custom(&self, engine: &Engine, theme: &Map<String, Json>) -> String {
        let label = string_of(theme.get("label").unwrap_or(&Json::Null))
            .trim()
            .to_owned();
        if label.is_empty() {
            return String::new();
        }
        let mut device = self.settings.device();
        let mut saved = device
            .get(CUSTOM_THEMES)
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let index_of =
            |saved: &[Json], id: &str| saved.iter().position(|t| string_of(&t["id"]) == id);
        let mut id = string_of(theme.get("id").unwrap_or(&Json::Null)).to_owned();
        if index_of(&saved, &id).is_none() {
            // A new theme: an id from its name no other theme or the
            // standard look has.
            let base = id_from_name(&label);
            id = base.clone();
            let mut n = 2;
            while built_ins().reserved.contains(&id) || self.find(&id).is_some() {
                id = format!("{base}-{n}");
                n += 1;
            }
        }
        let entry = json!({
            "id": id,
            "label": label,
            "appearance": appearance_of(theme.get("appearance")),
            "colors": canonical_colors(&object_of(theme.get("colors"))),
        });
        match index_of(&saved, &id) {
            Some(at) => saved[at] = entry,
            None => saved.push(entry),
        }
        device.insert(CUSTOM_THEMES.into(), Json::Array(saved));
        // Saved and applied at once.
        device.insert("theme".into(), json!(id));
        device.remove(HALVES);
        if self.save(engine, device, "") {
            id
        } else {
            String::new()
        }
    }

    fn duplicate(&self, engine: &Engine, id: &str) -> String {
        let Some(definition) = self.find(id) else {
            return String::new();
        };
        let mut copy = self.draft(engine, id);
        copy.insert("id".into(), json!(""));
        copy.insert("label".into(), json!(format!("{} copy", definition.label)));
        self.save_custom(engine, &copy)
    }

    fn own(&self, id: &str) -> Option<Definition> {
        self.find(id).filter(|d| d.source == "custom")
    }

    /// Asks before removing one of this device's themes.
    fn request_remove(&self, engine: &Engine, id: &str) {
        let Some(definition) = self.own(id) else {
            return;
        };
        let ids = vec![id.to_owned()];
        self.confirm_removal(
            engine,
            &format!("Remove “{}”?", definition.label),
            "This device will no longer offer it.",
            ids,
        );
    }

    fn request_remove_many(&self, engine: &Engine, ids: &[String]) {
        let own: Vec<String> = ids
            .iter()
            .filter(|id| self.own(id).is_some())
            .cloned()
            .collect();
        match own.len() {
            0 => {}
            1 => self.request_remove(engine, &own[0]),
            count => self.confirm_removal(
                engine,
                &format!("Remove {count} themes?"),
                "This device will no longer offer them.",
                own,
            ),
        }
    }

    fn confirm_removal(&self, engine: &Engine, title: &str, description: &str, ids: Vec<String>) {
        let me = self.me(engine);
        let accepted: Answer = Rc::new(move |engine: &Engine| {
            if let Some(view) = me.upgrade() {
                view.bridge
                    .if_open(engine, || view.remove_custom_many(engine, &ids));
            }
        });
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                title,
                description,
                "Remove",
                true,
                Some(accepted),
                None,
            );
        });
    }

    /// This view, for a callback that outlives the call.
    fn me(&self, engine: &Engine) -> Weak<View> {
        self.object
            .and_then(|obj| engine.extension::<Views>().0.borrow().get(&obj).cloned())
            .unwrap_or_default()
    }

    /// Removes this device's themes of `ids`, and the choices of them.
    fn remove_custom_many(&self, engine: &Engine, ids: &[String]) -> bool {
        let mut device = self.settings.device();
        let saved = device
            .get(CUSTOM_THEMES)
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let named = |value: &Json| ids.iter().any(|id| id == string_of(value));
        let kept: Vec<Json> = saved.iter().filter(|t| !named(&t["id"])).cloned().collect();
        if kept.len() == saved.len() {
            return false;
        }
        if kept.is_empty() {
            device.remove(CUSTOM_THEMES);
        } else {
            device.insert(CUSTOM_THEMES.into(), Json::Array(kept));
        }
        if device.get("theme").is_some_and(named) {
            device.remove("theme");
        }
        let mut halves = object_of(device.get(HALVES));
        for appearance in [LIGHT, DARK] {
            if halves.get(appearance).is_some_and(named) {
                halves.remove(appearance);
            }
        }
        set_or_remove(&mut device, HALVES, halves);
        self.save(engine, device, REMOVE_FAILED)
    }

    // -- The editor ----------------------------------------------------------

    fn set_editor_open(&self, engine: &Engine, open: bool) {
        if open == self.editor_open.get() {
            return;
        }
        // Opened by its toggle: on the theme drawn now. Closed: the draft goes.
        if open && self.editing.borrow().is_empty() {
            let draft = self.draft(engine, "");
            *self.editing.borrow_mut() = draft;
        }
        if !open {
            self.editing.borrow_mut().clear();
            if self.inspecting.get() || !self.picked.borrow().is_empty() {
                self.inspecting.set(false);
                self.picked.borrow_mut().clear();
                self.show_inspect(engine);
            }
        }
        self.editor_open.set(open);
        self.show_editing(engine);
    }

    fn set_inspecting(&self, engine: &Engine, inspecting: bool) {
        if inspecting == self.inspecting.get() {
            return;
        }
        self.inspecting.set(inspecting);
        if inspecting {
            self.picked.borrow_mut().clear();
        }
        self.show_inspect(engine);
    }

    /// While inspecting: the roles the window draws in `color` now.
    fn pick(&self, engine: &Engine, color: &str) {
        if !self.inspecting.get() {
            return;
        }
        let wanted = canonical_color(color).and_then(|c| color::Rgb::parse(&c));
        let mut roles: Vec<String> = Vec::new();
        if let Some(wanted) = wanted {
            let drawn = self
                .bridge
                .published(engine, "theme")
                .map(|theme| object_of(theme.get("colors")))
                .unwrap_or_default();
            for role in &built_ins().roles {
                let shown = drawn
                    .get(role)
                    .and_then(Json::as_str)
                    .and_then(color::Rgb::parse);
                if shown == Some(wanted) {
                    roles.push(role.clone());
                }
            }
        }
        self.inspecting.set(false);
        *self.picked.borrow_mut() = json!({
            "color": wanted.map(color::Rgb::name).unwrap_or_default(),
            "role": roles.first().cloned().unwrap_or_default(),
            "count": roles.len(),
            "roles": roles,
        })
        .as_object()
        .cloned()
        .unwrap_or_default();
        self.show_inspect(engine);
    }

    /// Opens the editor on `draft`.
    fn edit(&self, engine: &Engine, draft: Map<String, Json>) {
        *self.editing.borrow_mut() = draft;
        self.show_editing(engine);
        self.set_editor_open(engine, true);
    }

    fn set_editing(&self, engine: &Engine, draft: Map<String, Json>) {
        if !self.editor_open.get() || same_map(&draft, &self.editing.borrow()) {
            return;
        }
        *self.editing.borrow_mut() = draft;
        self.show_editing(engine);
    }

    /// Follows what QML wrote to `editorOpen` and `inspecting`.
    fn follow_writes(engine: &Engine, obj: ObjectId) {
        let _ = engine.connect_by_name(obj, "editorOpenChanged", move |engine, _| {
            let open = engine.read_by_name(obj, "editorOpen").to_boolean();
            with_object_view(engine, obj, |view| view.set_editor_open(engine, open));
        });
        let _ = engine.connect_by_name(obj, "inspectingChanged", move |engine, _| {
            let inspecting = engine.read_by_name(obj, "inspecting").to_boolean();
            with_object_view(engine, obj, |view| view.set_inspecting(engine, inspecting));
        });
    }

    // -- Importing and exporting ---------------------------------------------

    fn installed(&self, id: &str) -> bool {
        self.settings
            .device_value(CUSTOM_THEMES)
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .any(|t| string_of(&t["id"]) == id)
    }

    /// Adds `themes` to this device's (over those of their ids), and draws
    /// the one of `activate` as choosing it would.
    fn install(&self, engine: &Engine, themes: &[Json], activate: &str) -> bool {
        let mut device = self.settings.device();
        let mut saved = device
            .get(CUSTOM_THEMES)
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        for theme in themes {
            let id = string_of(&theme["id"]);
            match saved.iter().position(|t| string_of(&t["id"]) == id) {
                Some(at) => saved[at] = theme.clone(),
                None => saved.push(theme.clone()),
            }
        }
        device.insert(CUSTOM_THEMES.into(), Json::Array(saved));
        if !activate.is_empty()
            && let Some(theme) = themes.first()
        {
            // As choosing it: a theme of one appearance takes that side only.
            if object_of(theme.get("variants")).is_empty() {
                let mut halves = object_of(device.get(HALVES));
                halves.insert(string_of(&theme["appearance"]).to_owned(), json!(activate));
                device.insert(HALVES.into(), Json::Object(halves));
            } else {
                device.insert("theme".into(), json!(activate));
                device.remove(HALVES);
            }
        }
        self.save(engine, device, "Couldn’t add theme")
    }

    fn fail_import(&self, engine: &Engine, error: &str) {
        *self.import_error.borrow_mut() = error.to_owned();
        self.show_import(engine);
    }

    fn told(&self, engine: &Engine, themes: &[Json], verb: &str, description: &str) {
        if themes.is_empty() {
            return;
        }
        let labels: Vec<&str> = themes.iter().map(|t| string_of(&t["label"])).collect();
        let title = if labels.len() == 1 {
            format!("{} {verb}", labels[0])
        } else {
            format!("{} themes {verb}", labels.len())
        };
        let description = if description.is_empty() {
            labels.join(", ")
        } else {
            description.to_owned()
        };
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show(
                engine,
                "success",
                &title,
                &description,
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    }

    fn clear_import(&self, engine: &Engine) {
        if self.import_error.borrow().is_empty() && self.import_conflicts.borrow().is_empty() {
            return;
        }
        self.import_error.borrow_mut().clear();
        self.import_conflicts.borrow_mut().clear();
        self.show_import(engine);
    }

    /// Adds the theme file `text` and draws it; false with `importError`
    /// or `importConflicts` set when it is not added.
    fn import_text(&self, engine: &Engine, text: &str) -> bool {
        self.clear_import(engine);
        // Pasted text gets the file's limit too.
        if let Some(too_big) = oversized(text.len() as u64) {
            self.fail_import(engine, &too_big);
            return false;
        }
        let theme = match import::parse_file(text.as_bytes()) {
            Ok(theme) => Json::Object(theme),
            Err(error) => {
                self.fail_import(engine, &error);
                return false;
            }
        };
        let id = string_of(&theme["id"]).to_owned();
        if self.installed(&id) {
            *self.import_conflicts.borrow_mut() = vec![theme];
            self.show_import(engine);
            return false;
        }
        if !self.install(engine, std::slice::from_ref(&theme), &id) {
            self.fail_import(
                engine,
                "Theme added, but it could not be selected. Try again.",
            );
            return false;
        }
        let description = if object_of(theme.get("variants")).is_empty() {
            format!("It’s now your {} theme.", string_of(&theme["appearance"]))
        } else {
            "It’s now active.".to_owned()
        };
        self.told(engine, &[theme], "added", &description);
        true
    }

    /// Adds the theme files at `paths`: one as [`View::import_text`], more
    /// without drawing any.
    fn import_files(&self, engine: &Engine, paths: &[String]) {
        self.clear_import(engine);
        if paths.is_empty() {
            return;
        }
        let read = |path: &str| -> Result<Vec<u8>, String> {
            // The size first: a large file is never read at all.
            if let Ok(meta) = std::fs::metadata(path)
                && let Some(too_big) = oversized(meta.len())
            {
                return Err(too_big);
            }
            std::fs::read(path)
                .map_err(|_| "Could not read that file. Paste the JSON below instead.".to_owned())
        };
        if let [path] = paths {
            match read(path) {
                Ok(bytes) => {
                    self.import_text(engine, &String::from_utf8_lossy(&bytes));
                }
                Err(error) => self.fail_import(engine, &error),
            }
            return;
        }
        // Several at once install without activating.
        let mut failures: Vec<String> = Vec::new();
        let mut fresh: Vec<Json> = Vec::new();
        let mut conflicting: Vec<Json> = Vec::new();
        for path in paths {
            let name = Path::new(path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let bytes = match read(path) {
                Ok(bytes) => bytes,
                Err(error) => {
                    let why = if error.starts_with("That file is") {
                        "too large".to_owned()
                    } else {
                        error
                    };
                    failures.push(format!("{name}: {why}"));
                    continue;
                }
            };
            match import::parse_file(&bytes) {
                Err(error) => failures.push(format!("{name}: {error}")),
                Ok(theme) if self.installed(string_of(theme.get("id").unwrap_or(&Json::Null))) => {
                    conflicting.push(Json::Object(theme));
                }
                Ok(theme) => fresh.push(Json::Object(theme)),
            }
        }
        if !fresh.is_empty() {
            if self.install(engine, &fresh, "") {
                self.told(engine, &fresh, "added", "");
            } else {
                failures.push("the themes could not be saved".to_owned());
            }
        }
        *self.import_conflicts.borrow_mut() = conflicting;
        *self.import_error.borrow_mut() = failures.join(" — ");
        self.show_import(engine);
    }

    /// What to do with the themes an import would replace: cancel, copy
    /// (added beside them as "<name> (2)") or update.
    fn resolve_import(&self, engine: &Engine, choice: &str) {
        let conflicts = self.import_conflicts.borrow().clone();
        self.clear_import(engine);
        if conflicts.is_empty() || choice == "cancel" {
            return;
        }
        let mut resolved = Vec::new();
        for theme in conflicts {
            let mut theme = object_of(Some(&theme));
            if choice == "copy" {
                // The next free "<name> (2)".
                let label = string_of(theme.get("label").unwrap_or(&Json::Null)).to_owned();
                for copy in 2..100 {
                    let suffix = format!(" ({copy})");
                    let name = format!("{}{suffix}", left_utf16(&label, 48 - suffix.len()));
                    let id = id_from_name(&name);
                    if self.installed(&id) || self.find(&id).is_some() {
                        continue;
                    }
                    theme.insert("id".into(), json!(id));
                    theme.insert("label".into(), json!(name));
                    break;
                }
            }
            resolved.push(Json::Object(theme));
        }
        if !self.install(engine, &resolved, "") {
            return self.fail_import(engine, "The themes could not be saved.");
        }
        let verb = if choice == "copy" { "added" } else { "updated" };
        self.told(engine, &resolved, verb, "");
    }

    /// Writes theme `id` as a theme file (version 1) at `path`.
    fn export_theme(&self, engine: &Engine, id: &str, path: &Path) -> bool {
        let Some(definition) = self.find(id) else {
            return false;
        };
        let mut file = json!({
            "version": 1,
            "id": definition.id,
            "name": definition.label,
            "appearance": definition.appearance,
            "colors": definition.colors,
        });
        if !definition.variants.is_empty() {
            file["variants"] = Json::Object(definition.variants.clone());
        }
        let saved = self
            .settings
            .device_value(CUSTOM_THEMES)
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default();
        for theme in saved {
            if string_of(&theme["id"]) == id
                && let Some(collection) = theme.get("collection")
            {
                file["collection"] = collection.clone();
            }
        }
        let text = serde_json::to_vec_pretty(&file).unwrap_or_default();
        if let Err(error) = save_file(path, &text) {
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.error(engine, "Couldn’t export theme", &error.to_string());
            });
            return false;
        }
        let path = path.display().to_string();
        let title = format!("{} exported", definition.label);
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show(
                engine,
                "success",
                &title,
                &path,
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
        true
    }
}

fn with_object_view(engine: &Engine, obj: ObjectId, f: impl FnOnce(&View)) {
    let view = engine
        .extension::<Views>()
        .0
        .borrow()
        .get(&obj)
        .and_then(Weak::upgrade);
    if let Some(view) = view {
        view.bridge.act(engine, || f(&view));
    }
}

/// Writes `bytes` to `path` whole or not at all, as `QSaveFile`: into a
/// folder that is there.
fn save_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut partial = path.as_os_str().to_owned();
    partial.push(".partial");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&partial);
    })
}

/// What a palette choice does with the view, while the window is open.
type OnView = Box<dyn Fn(&Engine, &View)>;

/// `device[key] = map`, or no `key` when the map is empty.
fn set_or_remove(device: &mut Map<String, Json>, key: &str, map: Map<String, Json>) {
    if map.is_empty() {
        device.remove(key);
    } else {
        device.insert(key.into(), Json::Object(map));
    }
}

/// A colour made `glass`% as solid as it is, as `#rrggbbaa`; `None` when it
/// is not a colour.
fn with_glass(glass: i64) -> impl Fn(&str) -> Option<String> {
    move |css: &str| {
        let hex = canonical_color(css)?;
        let rgb = color::Rgb::parse(&hex)?;
        // QColor keeps alpha in 16 bits too.
        let alpha = match hex.len() {
            9 => u16::from_str_radix(&hex[7..9], 16).ok()? * 257,
            _ => u16::MAX,
        };
        let alpha = f64::from(alpha) / 65535.0 * glass as f64 / 100.0;
        Some(format!("{}{:02x}", rgb.name(), color::qt_byte_f(alpha)))
    }
}

// --- The controller -----------------------------------------------------------

pub struct Themes {
    view: Rc<View>,
}

impl Controller for Themes {
    // The look needs no MC: it shows before the first snapshot.
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let object = init.bridge.singleton::<ThemesObject>(engine).ok();
        let view = Rc::new(View {
            bridge: init.bridge,
            settings: Settings::of(engine),
            object,
            system_dark: Cell::new(ljos::color_scheme(engine) == ljos::prelude::ColorScheme::Dark),
            appearance: RefCell::new(LIGHT),
            resolved_id: RefCell::new(STANDARD_ID.to_owned()),
            cycle_toast: RefCell::new(String::new()),
            editor_open: Cell::new(false),
            editing: RefCell::new(Map::new()),
            inspecting: Cell::new(false),
            picked: RefCell::new(Map::new()),
            import_error: RefCell::new(String::new()),
            import_conflicts: RefCell::new(Vec::new()),
        });
        if let Some(obj) = object {
            engine
                .extension::<Views>()
                .0
                .borrow_mut()
                .insert(obj, Rc::downgrade(&view));
            let cx = Cx::new(engine, obj);
            let roles: Vec<Json> = built_ins().roles.iter().map(|r| json!(r)).collect();
            let _ = cx.set(ThemesObject::ROLES, Json::Array(roles).to_value());
            let _ = cx.set(
                ThemesObject::FAMILIES,
                families(&built_ins().roles).to_value(),
            );
            View::follow_writes(engine, obj);
        }
        // The device's choices and the MC's themes move the look.
        let resolve = |view: Weak<View>| {
            move |engine: &Engine| {
                if let Some(view) = view.upgrade() {
                    view.bridge.if_open(engine, || view.resolve(engine));
                }
            }
        };
        view.settings
            .on_device_changed(resolve(Rc::downgrade(&view)));
        view.settings
            .on_themes_changed(resolve(Rc::downgrade(&view)));
        // So does the system's scheme, while the look follows it.
        if let Some(hints) = ljos::style_hints(engine) {
            let weak = Rc::downgrade(&view);
            let _ = engine.watch(
                hints,
                StyleHints::COLOR_SCHEME.index,
                move |engine, value| {
                    let Some(view) = weak.upgrade() else {
                        return;
                    };
                    // Qt::ColorScheme: Unknown, Light, Dark.
                    let dark = value.to_number() as i32 == 2;
                    if view.system_dark.replace(dark) == dark {
                        return;
                    }
                    let resolve_later = view.clone();
                    view.bridge.defer(engine, move |engine| {
                        resolve_later
                            .bridge
                            .if_open(engine, || resolve_later.resolve(engine));
                    });
                },
            );
        }
        view.resolve(engine);
        view.show_editing(engine);
        view.show_inspect(engine);
        view.show_import(engine);
        Themes { view }
    }

    fn activate(&mut self, engine: &Engine) {
        let commands = Commands::of(engine);
        let weak = Rc::downgrade(&self.view);
        let on = move |f: fn(&Engine, &View)| {
            let weak = weak.clone();
            move |engine: &Engine| {
                if let Some(view) = weak.upgrade() {
                    view.bridge.if_open(engine, || f(engine, &view));
                }
            }
        };
        if !commands.contains(engine, APPEARANCE_CYCLE) {
            commands.add(
                engine,
                APPEARANCE_CYCLE,
                &crate::keybindings::command_label(APPEARANCE_CYCLE),
                on(|engine, view| {
                    view.cycle_appearance(engine);
                }),
            );
        }

        // The standard look first, then every theme offered; a theme drawn
        // in one appearance takes that half. "Current" is the one drawn now.
        let select = "theme.select";
        let weak = Rc::downgrade(&self.view);
        commands.add_menu(engine, select, "Change theme", move |_engine| {
            let Some(view) = weak.upgrade() else {
                return Vec::new();
            };
            let shown = *view.appearance.borrow();
            let half = view
                .halves()
                .get(shown)
                .map(string_of)
                .unwrap_or_default()
                .to_owned();
            let drawn = if half.is_empty() {
                view.theme_id()
            } else {
                half
            };
            let terms = vec!["theme".to_owned(), "appearance".to_owned()];
            let run = |f: OnView| {
                let weak = Rc::downgrade(&view);
                move |engine: &Engine| {
                    if let Some(view) = weak.upgrade() {
                        view.bridge.if_open(engine, || f(engine, &view));
                    }
                }
            };
            let mut standard = Choice::new(
                "theme:standard",
                "HAL-C2",
                run(Box::new(|engine, view| {
                    view.choose(engine, "");
                })),
            );
            standard.current = drawn.is_empty();
            standard.terms = terms.clone();
            let mut choices = vec![standard];
            for theme in view.available() {
                let id = string_of(&theme["id"]).to_owned();
                let appearances: Vec<String> = theme["appearances"]
                    .as_array()
                    .map(|a| a.iter().map(|v| string_of(v).to_owned()).collect())
                    .unwrap_or_default();
                let only = (appearances.len() == 1).then(|| appearances[0].clone());
                let chosen = id.clone();
                let only_run = only.clone();
                let mut choice = Choice::new(
                    &format!("theme:palette:{id}"),
                    string_of(&theme["label"]),
                    run(Box::new(move |engine, view| {
                        match &only_run {
                            Some(appearance) => view.choose_half(engine, appearance, &chosen),
                            None => view.choose(engine, &chosen),
                        };
                    })),
                );
                if let Some(appearance) = only {
                    choice.description = format!("For {appearance} mode");
                }
                choice.current = id == drawn;
                choice.terms = terms.clone();
                choices.push(choice);
            }
            choices
        });
        commands.set_terms(select, &["change theme", "appearance", "colors", "palette"]);

        let appearance = "appearance.select";
        let weak = Rc::downgrade(&self.view);
        commands.add_menu(engine, appearance, "Change appearance", move |_engine| {
            let Some(view) = weak.upgrade() else {
                return Vec::new();
            };
            let mode = view.mode();
            [(SYSTEM, "System"), (LIGHT, "Light"), (DARK, "Dark")]
                .into_iter()
                .map(|(choice_mode, label)| {
                    let weak = Rc::downgrade(&view);
                    let mut choice =
                        Choice::new(&format!("appearance:{choice_mode}"), label, move |engine| {
                            if let Some(view) = weak.upgrade() {
                                view.bridge
                                    .if_open(engine, || view.set_mode(engine, choice_mode));
                            }
                        });
                    choice.current = mode == choice_mode;
                    choice.terms = vec!["appearance".to_owned(), "mode".to_owned()];
                    choice
                })
                .collect()
        });
        commands.set_terms(
            appearance,
            &[
                "change appearance",
                "light",
                "dark",
                "system",
                "mode",
                "toggle",
            ],
        );

        let editor = "themeEditor.toggle";
        commands.add(
            engine,
            editor,
            "Toggle theme editor",
            on(|engine, view| view.set_editor_open(engine, !view.editor_open.get())),
        );
        commands.set_terms(
            editor,
            &["theme", "appearance", "colors", "palette", "customize"],
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let field = |key: &str| string_of(payload.get(key).unwrap_or(&Json::Null)).to_owned();
        let view = &self.view;
        match action {
            "appearance.cycle" => {
                view.cycle_appearance(engine);
            }
            "theme.mode" => {
                view.set_mode(engine, &field("mode"));
            }
            "theme.choose" => {
                view.choose(engine, &field("id"));
            }
            "theme.chooseHalf" => {
                view.choose_half(engine, &field("appearance"), &field("id"));
            }
            _ => return false,
        }
        true
    }
}

/// What the other controllers and the tests reach: `Themes` in QML.
impl Themes {
    pub fn mode(&self) -> Mode {
        Mode::parse(self.view.mode()).unwrap_or(Mode::System)
    }

    /// The appearance drawn now.
    pub fn appearance(&self) -> &'static str {
        *self.view.appearance.borrow()
    }

    /// The theme drawn now; [`STANDARD_ID`] for the standard look.
    pub fn resolved_id(&self) -> String {
        self.view.resolved_id.borrow().clone()
    }

    pub fn theme_id(&self) -> String {
        self.view.theme_id()
    }

    pub fn halves(&self) -> Map<String, Json> {
        self.view.halves()
    }

    /// [{id, label, appearance, appearances, source, collection, swatch}]
    pub fn available(&self) -> Vec<Json> {
        self.view.available()
    }

    /// system, then light, then dark, then system again, told in a toast.
    pub fn cycle(&mut self, engine: &Engine) -> bool {
        self.view.cycle_appearance(engine)
    }

    pub fn set_mode(&mut self, engine: &Engine, mode: Mode) -> bool {
        self.view.set_mode(engine, mode.name())
    }

    pub fn choose(&mut self, engine: &Engine, id: &str) -> bool {
        self.view.choose(engine, id)
    }

    pub fn choose_half(&mut self, engine: &Engine, appearance: &str, id: &str) -> bool {
        self.view.choose_half(engine, appearance, id)
    }

    pub fn restore_defaults(&mut self, engine: &Engine) -> bool {
        self.view.restore_defaults(engine)
    }

    pub fn draft(&self, engine: &Engine, id: &str) -> Map<String, Json> {
        self.view.draft(engine, id)
    }

    pub fn save_custom(&mut self, engine: &Engine, theme: &Map<String, Json>) -> String {
        self.view.save_custom(engine, theme)
    }

    pub fn duplicate(&mut self, engine: &Engine, id: &str) -> String {
        self.view.duplicate(engine, id)
    }

    pub fn remove_custom(&mut self, engine: &Engine, id: &str) -> bool {
        self.view.remove_custom_many(engine, &[id.to_owned()])
    }

    pub fn request_remove(&mut self, engine: &Engine, id: &str) {
        self.view.request_remove(engine, id);
    }

    pub fn request_remove_many(&mut self, engine: &Engine, ids: &[String]) {
        self.view.request_remove_many(engine, ids);
    }

    pub fn editor_open(&self) -> bool {
        self.view.editor_open.get()
    }

    pub fn set_editor_open(&mut self, engine: &Engine, open: bool) {
        self.view.set_editor_open(engine, open);
    }

    pub fn editing(&self) -> Map<String, Json> {
        self.view.editing.borrow().clone()
    }

    pub fn edit(&mut self, engine: &Engine, draft: Map<String, Json>) {
        self.view.edit(engine, draft);
    }

    pub fn set_editing(&mut self, engine: &Engine, draft: Map<String, Json>) {
        self.view.set_editing(engine, draft);
    }

    pub fn inspecting(&self) -> bool {
        self.view.inspecting.get()
    }

    pub fn set_inspecting(&mut self, engine: &Engine, inspecting: bool) {
        self.view.set_inspecting(engine, inspecting);
    }

    pub fn picked(&self) -> Map<String, Json> {
        self.view.picked.borrow().clone()
    }

    pub fn pick(&mut self, engine: &Engine, color: &str) {
        self.view.pick(engine, color);
    }

    pub fn import_text(&mut self, engine: &Engine, text: &str) -> bool {
        self.view.import_text(engine, text)
    }

    pub fn import_files(&mut self, engine: &Engine, paths: &[String]) {
        self.view.import_files(engine, paths);
    }

    pub fn resolve_import(&mut self, engine: &Engine, choice: &str) {
        self.view.resolve_import(engine, choice);
    }

    pub fn clear_import(&mut self, engine: &Engine) {
        self.view.clear_import(engine);
    }

    pub fn import_error(&self) -> String {
        self.view.import_error.borrow().clone()
    }

    /// The labels of the themes an import would replace.
    pub fn import_conflicts(&self) -> Vec<String> {
        self.view
            .import_conflicts
            .borrow()
            .iter()
            .map(|t| string_of(&t["label"]).to_owned())
            .collect()
    }

    pub fn export_theme(&mut self, engine: &Engine, id: &str, path: &Path) -> bool {
        self.view.export_theme(engine, id, path)
    }
}
