//! desktop-qt's example shells (`apps/desktop-qt/examples`) installed as a
//! user installs one, their files copied into the config dir, and made on
//! the checkout's bricks, as desktop-qt's tst_ShellExamples makes them: each
//! compiles, loads in place of the built-in shell, and shows what it is for.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::runtime::{self, ShellRuntime};
use ljos::App;
use ljos::dev::Severity;
use ljos::prelude::{Engine, ObjectId, Value};
use ljos::testing::TestWindow;
use tempfile::TempDir;

use crate::common::{number, text};

/// 2026-10-25T12:00:00Z, the dashboard's today.
const NOW_MS: f64 = 1_792_929_600_000.0;

const HEIGHT: f64 = 880.0;

/// An example's shell in a window `width` wide.
struct Example {
    engine: Engine,
    window: TestWindow,
    root: ObjectId,
    _home: TempDir,
}

impl Example {
    /// `name`'s files copied into a new config dir, beside the preferences
    /// of a user past onboarding, then the shell compiled and opened.
    fn install(name: &str, width: f64) -> Example {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
        let config = home.path().join("config");
        std::fs::create_dir(&config).unwrap();
        for entry in std::fs::read_dir(examples().join(name)).unwrap() {
            let path = entry.unwrap().path();
            std::fs::copy(&path, config.join(path.file_name().unwrap())).unwrap();
        }
        std::fs::write(
            config.join("preferences.json"),
            r#"{"onboardingCompletedAt":"2026-01-01T00:00:00.000Z"}"#,
        )
        .unwrap();
        let roots = Roots::checkout().with_user(config.clone());
        let compiled = qml::compile(&roots).unwrap();
        let errors: Vec<String> = compiled
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
            // TODO(ljos-lottie): the cat compiles once Ljós has
            // Qt.labs.lottieqt; until then the dashboard shows its fallback.
            .filter(|d| !d.to_string().contains("CatPlaying"))
            .map(ToString::to_string)
            .collect();
        assert!(errors.is_empty(), "{name} compiles:\n{}", errors.join("\n"));

        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        engine.set_wall_clock_origin(Some(NOW_MS));
        // Before the shell starts, for its timers to start on the window's clock.
        let mut window = TestWindow::new(&engine, width, HEIGHT);
        let mc = Rc::new(Disconnected::default());
        hal_c2_shell::start(
            &engine,
            &Launch {
                config_dir: Some(config),
                qml: Some(roots),
                ..Launch::default()
            },
            mc.clone(),
        );
        engine.set_component_source(compiled.source);
        hal_c2_shell::theme::set_application_font(&engine);
        let root = runtime::open(&engine, false).unwrap();
        mc.deliver(&engine);
        window.show(root).unwrap();
        window.settle().unwrap();
        // Then resized to the test's size, as tst_ShellExamples resizes it.
        for (name, size) in [("width", width), ("height", HEIGHT)] {
            engine.write_by_name(root, name, Value::from(size)).unwrap();
        }
        window.settle().unwrap();
        let example = Example {
            engine,
            window,
            root,
            _home: home,
        };
        assert_eq!(
            example.runtime("lastError"),
            "",
            "{name} loads without an error"
        );
        assert_eq!(example.runtime("usingUserShell"), "true", "{name} is shown");
        example
    }

    fn runtime(&self, name: &str) -> String {
        let obj = self.engine.singleton::<ShellRuntime>().unwrap();
        self.engine
            .to_js_string(&self.engine.read_by_name(obj, name))
            .to_string()
    }

    /// The item named `name` in the window, shown or not.
    fn find(&self, name: &str) -> Option<ObjectId> {
        find_under(&self.engine, self.root, name)
    }

    /// The first CentreHost in the window: the brick that holds the route's
    /// page, found by what only it has, as tst_ShellExamples finds it by type.
    fn centre(&self) -> ObjectId {
        find_where(&self.engine, self.root, &|obj| {
            self.engine
                .find_property(obj, "conversationScrolled")
                .is_some()
        })
        .expect("the shell has a CentreHost")
    }

    fn item(&self, name: &str) -> ObjectId {
        self.find(name)
            .unwrap_or_else(|| panic!("the shell has no {name}"))
    }

    /// `item` in the window's tree of items, it and every item above it
    /// visible, as Qt's `isVisible`.
    fn visible(&self, item: ObjectId) -> bool {
        let content = match self.engine.read_by_name(self.root, "contentItem") {
            Value::Object(content) => Some(content),
            _ => None,
        };
        let mut at = item;
        loop {
            if self.engine.read_by_name(at, "visible") == Value::Bool(false) {
                return false;
            }
            if at == self.root || Some(at) == content {
                return true;
            }
            match parent(&self.engine, at) {
                Some(above) => at = above,
                None => return false,
            }
        }
    }

    /// The texts shown at or under `item`.
    fn texts(&self, item: ObjectId) -> Vec<String> {
        let mut found = Vec::new();
        if let Value::String(shown) = self.engine.read_by_name(item, "text")
            && self.visible(item)
        {
            found.push(shown.to_string());
        }
        for child in self.engine.children(item) {
            found.extend(self.texts(child));
        }
        found
    }

    /// Visible, with a size.
    fn shown(&self, item: ObjectId) -> bool {
        self.visible(item)
            && number(&self.engine, item, "width") > 0.0
            && number(&self.engine, item, "height") > 0.0
    }

    /// `item`'s top left in the window.
    fn at(&self, item: ObjectId) -> (f64, f64) {
        let (mut x, mut y) = (0.0, 0.0);
        let mut at = Some(item);
        while let Some(obj) = at {
            x += number(&self.engine, obj, "x");
            y += number(&self.engine, obj, "y");
            at = parent(&self.engine, obj);
        }
        (x, y)
    }

    fn width(&self, item: ObjectId) -> f64 {
        number(&self.engine, item, "width")
    }

    fn advance(&mut self, ms: u64) {
        self.window.advance(ms).unwrap();
    }
}

fn examples() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../desktop-qt/examples")
}

fn parent(engine: &Engine, item: ObjectId) -> Option<ObjectId> {
    match engine.read_by_name(item, "parent") {
        Value::Object(parent) => Some(parent),
        _ => None,
    }
}

fn find_under(engine: &Engine, root: ObjectId, name: &str) -> Option<ObjectId> {
    find_where(engine, root, &|obj| text(engine, obj, "objectName") == name)
}

fn find_where(
    engine: &Engine,
    root: ObjectId,
    test: &dyn Fn(ObjectId) -> bool,
) -> Option<ObjectId> {
    if test(root) {
        return Some(root);
    }
    engine
        .children(root)
        .into_iter()
        .find_map(|child| find_where(engine, child, test))
}

/// What every example has: the thread's title in the window.
fn fits(example: &Example, width: f64) {
    let title = example.item("threadLabel");
    let (x, _) = example.at(title);
    assert!(
        x + example.width(title) <= width,
        "the thread's title ends at {} in a window {width} wide",
        x + example.width(title)
    );
}

#[test]
fn the_minimal_glass_and_terminal_examples_load_at_every_width() {
    for name in ["minimal", "glass", "terminal"] {
        for width in [1400.0, 1000.0, 640.0] {
            let example = Example::install(name, width);
            fits(&example, width);
            let centre = example.centre();
            assert!(example.shown(centre), "{name} at {width} shows its centre");
        }
    }
}

#[test]
fn the_folders_example_puts_its_explorer_beside_or_under_the_threads() {
    for width in [1400.0, 1000.0, 640.0] {
        let mut example = Example::install("folders", width);
        fits(&example, width);
        let explorer = example.item("folderExplorer");
        let centre = example.item("centreHost");
        let threads = example.item("threadSidebar");
        // Under 768 the list and the explorer beside it are an overlay,
        // shown over the centre when called for.
        let overlay = width < 768.0;
        if overlay {
            assert!(!example.visible(threads));
            Bridge::of(&example.engine).dispatch(&example.engine, "sidebar.toggle", Json::Null);
            example.window.settle().unwrap();
        }
        assert!(example.visible(threads), "at {width}");
        assert!(example.shown(explorer), "at {width}");
        let (explorer_x, explorer_y) = example.at(explorer);
        let (threads_x, threads_y) = example.at(threads);
        if !overlay {
            assert!(example.at(centre).0 >= explorer_x + example.width(explorer));
        }
        assert!(example.width(centre) >= 300.0, "at {width}");
        if width >= 1100.0 {
            assert!(explorer_x >= threads_x + example.width(threads));
        } else {
            let threads_bottom = threads_y + number(&example.engine, threads, "height");
            assert!(explorer_y >= threads_bottom, "at {width}");
        }
    }
}

#[test]
fn the_dashboard_drawer_opens_on_its_cards_and_clock() {
    for width in [1400.0, 1000.0, 640.0] {
        let mut example = Example::install("dashboard", width);
        fits(&example, width);
        let engine = example.engine.clone();
        let drawer = example.item("drawer");
        assert!(!example.shown(drawer));
        engine
            .write_by_name(example.root, "drawerOpen", Value::Bool(true))
            .unwrap();
        // An OpacityAnimator writes its property once it is done, as Qt's.
        for _ in 0..30 {
            example.advance(16);
        }
        assert_eq!(number(&engine, drawer, "opacity"), 1.0);
        assert!(example.shown(drawer));

        let (drawer_x, _) = example.at(drawer);
        let drawer_width = example.width(drawer);
        for name in [
            "clockCard",
            "workspaceCard",
            "calendarCard",
            "metersCard",
            "agentCard",
        ] {
            let card = example.item(name);
            assert!(example.shown(card), "{name} shows at {width}");
            // A DashCard's children are what it shows (ljos#132 lost them).
            assert!(!example.texts(card).is_empty(), "{name} is empty");
            let left = example.at(card).0 - drawer_x;
            assert!(left >= 10.0, "{name} at {width} starts at {left}");
            assert!(
                left + example.width(card) <= drawer_width - 10.0,
                "{name} at {width} ends at {}",
                left + example.width(card)
            );
        }
        let branch = example.item("branchChip");
        let row = parent(&engine, branch).unwrap();
        assert!(example.width(branch) <= example.width(row));

        // Today's date and time, kept by the minute while the drawer is open.
        let clock = example.item("clockCard");
        let shown = example.texts(clock);
        assert!(shown.contains(&"25".to_owned()), "{shown:?}");
        assert!(shown.contains(&"10".to_owned()), "{shown:?}");
        let time = |shown: &[String]| {
            shown
                .iter()
                .find(|t| t.len() == 5 && t.as_bytes()[2] == b':')
                .cloned()
                .unwrap_or_else(|| panic!("a time in {shown:?}"))
        };
        let before = time(&shown);
        example.advance(60_000);
        assert_ne!(time(&example.texts(clock)), before, "the clock moves on");

        // TODO(ljos-lottie): with Qt.labs.lottieqt in Ljós the cat loads
        // (`mascotCat`'s status Ready) and the initial hides. Until then
        // the agent's initial stands in for it.
        let cat = example.item("mascotCat");
        assert_eq!(number(&engine, cat, "status"), 3.0, "the cat is an error");
        let initial = example.item("mascotInitial");
        assert!(example.shown(initial));
        assert_eq!(example.texts(initial), ["H"]);
    }
}

#[test]
#[cfg(not(target_os = "macos"))]
fn the_macos_glass_example_falls_back_to_the_built_in_shell_elsewhere() {
    // Its toolbar is QtQuick.Controls.macOS's, which only macOS has: the
    // built-in shell shows instead, saying why, as desktop-qt does there.
    let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let config = home.path().join("config");
    std::fs::create_dir(&config).unwrap();
    for entry in std::fs::read_dir(examples().join("glass-macos")).unwrap() {
        let path = entry.unwrap().path();
        std::fs::copy(&path, config.join(path.file_name().unwrap())).unwrap();
    }
    let roots = Roots::checkout().with_user(config.clone());
    let compiled = qml::compile(&roots).unwrap();
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .build_engine();
    hal_c2_shell::start(
        &engine,
        &Launch {
            config_dir: Some(config),
            qml: Some(roots),
            ..Launch::default()
        },
        Rc::new(Disconnected::default()),
    );
    engine.set_component_source(compiled.source);
    runtime::open(&engine, false).unwrap();
    let runtime = engine.singleton::<ShellRuntime>().unwrap();
    let read = |name| {
        engine
            .to_js_string(&engine.read_by_name(runtime, name))
            .to_string()
    };
    assert_eq!(read("usingUserShell"), "false");
    assert_ne!(read("lastError"), "");
}
