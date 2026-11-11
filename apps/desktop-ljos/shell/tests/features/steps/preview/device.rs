//! A browser tab's zoom and device sizes: the zoom steps, the device toolbar
//! above the page (BrowserDeviceToolbar), the edges a device-sized page is
//! resized from (BrowserResizeHandles) and the Devices view, against the
//! loopback dev server, as desktop-qt's BrowserSteps.cpp and
//! BrowserDeviceToolbarSteps.cpp. features/preview/surfaces.feature.

use hal_c2_shell::browser::{self, BrowserPage};
use hal_c2_shell::controllers::panel::RightPanel;
use ljos::item::{MouseButtons, PointerEvent};
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::browser::{
    active_tab, browsing, dev_server, find, panel, read_flag, read_text, server_url, show_tab,
    state, view, view_url, wait_for_engine, wait_for_title,
};
use super::navigation::{browser_panel, call, choose, run};
use super::update;
use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps, show};
use crate::world::World;
use crate::{expect, fail};

/// The contract's named device sizes, as the toolbar labels them, and
/// their ids.
const PRESETS: &[(&str, &str)] = &[
    ("iPhone SE", "iphone-se"),
    ("iPhone XR", "iphone-xr"),
    ("iPhone 12 Pro", "iphone-12-pro"),
    ("iPhone 14 Pro Max", "iphone-14-pro-max"),
    ("Pixel 7", "pixel-7"),
    ("Samsung Galaxy S8+", "samsung-galaxy-s8-plus"),
    ("Samsung Galaxy S20 Ultra", "samsung-galaxy-s20-ultra"),
    ("iPad Mini", "ipad-mini"),
    ("iPad Air", "ipad-air"),
    ("iPad Pro", "ipad-pro"),
    ("Surface Pro 7", "surface-pro-7"),
    ("Surface Duo", "surface-duo"),
    ("Galaxy Z Fold 5", "galaxy-z-fold-5"),
    ("Asus Zenbook Fold", "asus-zenbook-fold"),
    ("Samsung Galaxy A51/71", "samsung-galaxy-a51-71"),
    ("Nest Hub", "nest-hub"),
    ("Nest Hub Max", "nest-hub-max"),
];

/// The Devices view's frames a scenario looks at.
const DEVICES: &[&str] = &["iphone-12-pro", "ipad-air", "desktop"];

const SIZE_CONTROLS: &[&str] = &[
    "browserToolbarPreset",
    "browserToolbarWidth",
    "browserToolbarHeight",
    "browserToolbarAspect",
    "browserToolbarRotate",
    "browserToolbarClose",
];

/// A preset's id, from the label the scenario names.
fn preset_id(label: &str) -> String {
    PRESETS.iter().find(|(name, _)| *name == label).map_or_else(
        || label.to_lowercase().replace(' ', "-"),
        |(_, id)| (*id).to_owned(),
    )
}

/// What a toolbar scenario keeps: the tabs it is about, and what was there
/// before the user acted.
#[derive(Default)]
struct Toolbar {
    first: String,
    second: String,
    before: Json,
    resizes: usize,
    /// What the width field showed after each key the user typed.
    shown_while_typing: Vec<String>,
}

fn toolbar(world: &mut World) -> &mut Toolbar {
    world.mc.part::<Toolbar>()
}

/// The id of the browser tab showing in the panel.
fn tab(world: &World) -> String {
    active_tab(world)
        .strip_prefix("browser:")
        .unwrap_or_default()
        .to_owned()
}

fn page_of(world: &World) -> Outcome<ObjectId> {
    let tab = tab(world);
    match browser::page(world.engine(), &tab) {
        Some(page) => Ok(page),
        None => fail!("no page shows {tab:?}"),
    }
}

fn viewport(world: &World) -> Json {
    page_of(world)
        .ok()
        .and_then(|p| BrowserPage::read(world.engine(), p, |core| core.viewport()))
        .unwrap_or(Json::Null)
}

fn viewport_of(world: &World, tab: &str) -> Json {
    browser::page(world.engine(), tab)
        .and_then(|p| BrowserPage::read(world.engine(), p, |core| core.viewport()))
        .unwrap_or(Json::Null)
}

fn resizing(world: &World) -> bool {
    page_of(world)
        .ok()
        .and_then(|p| BrowserPage::read(world.engine(), p, |core| core.resizing()))
        .unwrap_or(false)
}

/// The tab's size as the MC has it.
fn mc_viewport(world: &World, tab: &str) -> Json {
    world
        .mc
        .peek::<super::FakePreviews>()
        .and_then(|f| f.tabs.iter().find(|t| t["tabId"] == tab).cloned())
        .map_or(Json::Null, |t| t["viewport"].clone())
}

fn resizes(world: &World) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "preview.resize")
        .count()
}

fn is_fill(viewport: &Json) -> bool {
    viewport.is_null()
        || viewport.as_object().is_some_and(serde_json::Map::is_empty)
        || viewport["_tag"] == "fill"
}

fn number(value: &Value) -> f64 {
    match value {
        Value::Int(n) => f64::from(*n),
        Value::Real(r) => *r,
        _ => 0.0,
    }
}

fn real(world: &World, item: ObjectId, name: &str) -> f64 {
    number(&world.engine().read_by_name(item, name))
}

fn parent(world: &World, item: ObjectId) -> Option<ObjectId> {
    match world.engine().read_by_name(item, "parent") {
        Value::Object(p) => Some(p),
        _ => None,
    }
}

/// The scale `item` is drawn at: its own and every parent's.
fn inherited_scale(world: &World, item: ObjectId) -> f64 {
    let mut scale = 1.0;
    let mut at = Some(item);
    while let Some(each) = at {
        let own = real(world, each, "scale");
        scale *= if own == 0.0 { 1.0 } else { own };
        at = parent(world, each);
    }
    scale
}

/// The named item the user can see.
fn item(world: &mut World, name: &str) -> Outcome<ObjectId> {
    let brick = panel(world)?;
    match find(world, brick, name) {
        Some(found) => Ok(found),
        None => fail!("no {name} shows"),
    }
}

fn text(world: &mut World, name: &str) -> Outcome<String> {
    let field = item(world, name)?;
    Ok(read_text(world, field, "text"))
}

fn describe(world: &World) -> String {
    let brick = panel_of(world);
    let shown = brick.and_then(|b| view(world, b));
    let (w, h, s) = shown.map_or((0.0, 0.0, 0.0), |v| {
        (
            real(world, v, "width"),
            real(world, v, "height"),
            real(world, v, "scale"),
        )
    });
    format!(
        "the page is {} ({}), drawn {w}x{h} at {s}; the MC has {}",
        show(&viewport(world)),
        if resizing(world) {
            "resizing"
        } else {
            "settled"
        },
        show(&mc_viewport(world, &tab(world)))
    )
}

fn panel_of(world: &World) -> Option<Brick> {
    world.peek_part::<crate::brick::Shown>().and_then(|s| s.0)
}

fn inner_size(world: &mut World) -> Outcome<String> {
    super::browser::evaluated(world, "window.innerWidth + 'x' + window.innerHeight")
}

/// Waits for the MC to have the size the page shows.
fn settle(world: &mut World) -> Outcome {
    wait_for_engine(
        world,
        |w| !resizing(w),
        |w| format!("the size to be confirmed; {}", describe(w)),
    )
}

/// The page renders at `width` by `height`, and the MC keeps that size.
fn renders_at(world: &mut World, width: i64, height: i64) -> Outcome {
    wait_for_engine(
        world,
        |w| {
            let kept = mc_viewport(w, &tab(w));
            !resizing(w) && kept["width"] == width && kept["height"] == height
        },
        |w| format!("the MC to keep {width} by {height}; {}", describe(w)),
    )?;
    let want = format!("{width}x{height}");
    for _ in 0..40 {
        if inner_size(world)? == want {
            return Ok(());
        }
        let _ = world.wait_for_with(|_| false, |_| String::new());
    }
    fail!("the page to render at {want}; it is {}", inner_size(world)?)
}

/// The panel at `width` by `height`, as the user sees it.
fn resize_window(world: &mut World, width: f64, height: f64) -> Outcome {
    let brick = panel(world)?;
    if let Some(root) = brick.root(world) {
        brick.write(world, root, "width", Value::from(width))?;
        brick.write(world, root, "height", Value::from(height))?;
    }
    world.resize(width, height)?;
    world.sync()
}

/// The tab's menu shows the device toolbar, at the room the page has.
fn show_toolbar(world: &mut World) -> Outcome {
    choose(world, "browserMore", "browserDeviceToolbarItem")?;
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| find(w, brick, "browserDeviceToolbar").is_some(),
        |w| format!("the device toolbar to show; {}", describe(w)),
    )?;
    settle(world)
}

/// A browser tab with the device toolbar shown, at `size` when given.
fn tab_with_toolbar(world: &mut World, size: Option<(i64, i64)>) -> Outcome {
    show_tab(world, "/")?;
    if size.is_some() {
        // Tall enough for a phone's height unscaled.
        resize_window(world, 900.0, 1100.0)?;
    }
    show_toolbar(world)?;
    let Some((width, height)) = size else {
        return Ok(());
    };
    let page = page_of(world)?;
    let viewport = json!({"_tag": "freeform", "width": width, "height": height});
    BrowserPage::update(world.engine(), page, |core| core.set_viewport(viewport));
    world.sync()?;
    renders_at(world, width, height)
}

/// The user replaces what `field` holds with `value`, without leaving it.
fn type_into(world: &mut World, field: &str, value: &str) -> Outcome {
    let brick = panel(world)?;
    brick.click(world, field)?;
    let input = item(world, field)?;
    wait_for_engine(
        world,
        |w| read_flag(w, input, "activeFocus"),
        |_| format!("{field} to take the keyboard"),
    )?;
    call(world, input, "selectAll", &[])?;
    world.type_text(value)?;
    world.sync()
}

/// What the user is about to change, kept to compare with.
fn remember(world: &mut World) -> Outcome {
    settle(world)?;
    let before = viewport(world);
    let count = resizes(world);
    let kept = toolbar(world);
    kept.before = before;
    kept.resizes = count;
    Ok(())
}

fn type_size(world: &mut World, width: &str, height: &str) -> Outcome {
    remember(world)?;
    type_into(world, "browserToolbarWidth", width)?;
    type_into(world, "browserToolbarHeight", height)?;
    panel(world)?.press(world, "enter")?;
    world.sync()
}

fn checked(world: &mut World, name: &str) -> Outcome<bool> {
    let control = item(world, name)?;
    Ok(read_flag(world, control, "checked"))
}

fn lock_aspect(world: &mut World, locked: bool) -> Outcome {
    panel(world)?.click(world, "browserToolbarAspect")?;
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| {
            find(w, brick, "browserToolbarAspect")
                .is_some_and(|a| read_flag(w, a, "checked") == locked)
        },
        |_| format!("the ratio to {}", if locked { "lock" } else { "unlock" }),
    )
}

/// Presses on the page's right edge and moves `by` window pixels right.
fn drag_right_edge(world: &mut World, by: f64, release: bool) -> Outcome {
    let edge = item(world, "browserEdge-right")?;
    let brick = panel(world)?;
    let (x, y) = brick.at(world, edge, 0.5, 0.5)?;
    let (x, y) = (x.round(), y.round());
    world.pointer(|now| PointerEvent::press(x, y, now))?;
    let half = (x + by / 2.0).round();
    world.pointer(|now| PointerEvent::moved(half, y, MouseButtons::LEFT, now))?;
    let to = (x + by).round();
    world.pointer(|now| PointerEvent::moved(to, y, MouseButtons::LEFT, now))?;
    if release {
        world.pointer(|now| PointerEvent::release(to, y, now))?;
    }
    world.sync()
}

fn devices_frame(world: &World, id: &str) -> Option<ObjectId> {
    panel_of(world).and_then(|b| find(world, b, &format!("browserDevicesFrame-{id}")))
}

fn open_devices_view(world: &mut World) -> Outcome {
    let brick = panel(world)?;
    if find(world, brick, "browserDevicesView").is_none() {
        brick.click(world, "browserDevices")?;
    }
    wait_for_engine(
        world,
        |w| find(w, brick, "browserDevicesView").is_some(),
        |w| format!("the Devices view to show; {}", state(w, brick)),
    )
}

/// The picker's entry for `id`, ticked or unticked.
fn toggle_devices_preset(world: &mut World, id: &str) -> Outcome {
    let brick = panel(world)?;
    let name = format!("browserDevicesPreset-{id}");
    if find(world, brick, &name).is_none() {
        brick.click(world, "browserDevicesPick")?;
        wait_for_engine(
            world,
            |w| find(w, brick, &name).is_some(),
            |_| format!("the devices picker to offer {id}"),
        )?;
    }
    // The list has more entries than the picker shows at once; bring the
    // one the click targets into its scrolled viewport first.
    let entry = item(world, &name)?;
    if let Some(scroll) = find(world, brick, "browserDevicesScroll") {
        let (_, top) = brick.at_px(world, entry, 0.0, 0.0)?;
        let (_, scroll_top) = brick.at_px(world, scroll, 0.0, 0.0)?;
        let top = top - scroll_top;
        let height = real(world, entry, "height");
        let view_height = real(world, scroll, "height");
        if top < 0.0 || top + height > view_height {
            let max = (real(world, scroll, "contentHeight") - view_height).max(0.0);
            let y = real(world, scroll, "contentY") + top + height / 2.0 - view_height / 2.0;
            brick.write(world, scroll, "contentY", Value::from(y.clamp(0.0, max)))?;
            world.sync()?;
        }
    }
    brick.click(world, &name)?;
    world.sync()
}

/// Width and height of `item` as drawn in the window.
fn drawn_size(world: &World, brick: Brick, item: ObjectId) -> Outcome<(f64, f64)> {
    let (x0, y0) = brick.at(world, item, 0.0, 0.0)?;
    let (x1, y1) = brick.at(world, item, 1.0, 1.0)?;
    Ok((x1 - x0, y1 - y0))
}

pub fn register(steps: &mut Steps) {
    register_zoom(steps);
    register_devices(steps);
    register_toolbar(steps);
    register_edges(steps);
}

fn register_zoom(steps: &mut Steps) {
    steps.step("a browser tab at (\\d+)% zoom", |world, c, _| {
        show_tab(world, "/")?;
        let percent: f64 = c[0].parse().unwrap_or(100.0);
        let page = page_of(world)?;
        let brick = panel(world)?;
        brick.write(world, page, "zoom", Value::from(percent / 100.0))?;
        world.sync()
    });
    steps.step("the user zooms (in|out|reset)", |world, c, _| {
        let command = match c[0].as_str() {
            "in" => "preview.zoomIn",
            "out" => "preview.zoomOut",
            _ => "preview.resetZoom",
        };
        run(world, command)
    });
    steps.step(
        "the (?:tab|page in the tab) (?:is|stays) at (\\d+)% zoom",
        |world, c, _| {
            let percent = c[0].clone();
            let zoom = percent.parse::<f64>().unwrap_or(100.0) / 100.0;
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| view(w, brick).is_some_and(|v| (real(w, v, "zoomFactor") - zoom).abs() < 1e-6),
                |w| state(w, brick),
            )?;
            let page = page_of(world)?;
            let kept = real(world, page, "zoom");
            expect!((kept - zoom).abs() < 1e-6, "the page keeps zoom {kept}");
            // The zoom shows in the chrome unless it is 100%.
            let reset = find(world, brick, "browserZoomReset").is_some();
            expect!(
                reset == (percent != "100"),
                "the zoom button is {}",
                if reset { "shown" } else { "hidden" }
            );
            Ok(())
        },
    );
    steps.step("the user zooms the whole app in", |world, _, _| {
        run(world, "view.zoomIn")?;
        let panel_item = browser_panel(world)?;
        wait_for_engine(
            world,
            |w| real(w, panel_item, "appZoom") > 1.0,
            |_| "the app to zoom in".into(),
        )?;
        // The page is drawn at the screen's pixels: the app's zoom is undone
        // around it.
        let stage = item(world, "browserPage")?;
        let app_zoom = real(world, panel_item, "appZoom");
        let scale = real(world, stage, "scale");
        expect!(
            (scale * app_zoom - 1.0).abs() < 1e-6,
            "the page is drawn at {scale} of the app's {app_zoom}"
        );
        Ok(())
    });
}

fn register_devices(steps: &mut Steps) {
    steps.step(
        &format!("the user picks the {Q} device size"),
        |world, c, _| {
            let id = preset_id(&c[0]);
            choose(world, "browserDevice", &format!("browserPreset-{id}"))?;
            browsing(world).typed = id;
            Ok(())
        },
    );
    steps.step("the page renders at that device's size", |world, _, _| {
        let id = browsing(world).typed.clone();
        let kept = viewport(world);
        expect!(kept["presetId"] == id.as_str(), "{}", show(&kept));
        let width = kept["width"].as_i64().unwrap_or(0);
        let height = kept["height"].as_i64().unwrap_or(0);
        renders_at(world, width, height)?;
        // The MC keeps the size picked.
        let tab = tab(world);
        wait_for_engine(
            world,
            |w| mc_viewport(w, &tab)["presetId"] == id.as_str(),
            |w| super::describe(w),
        )
    });
    steps.step(
        "the page is scaled down to fit the tab and centred in it",
        |world, _, _| {
            let shown = item(world, "browserView")?;
            let Some(area) = parent(world, shown) else {
                fail!("the page has no area");
            };
            let scale = real(world, shown, "scale");
            let width = real(world, shown, "width") * scale;
            let (area_w, area_h) = (real(world, area, "width"), real(world, area, "height"));
            expect!(
                scale < 1.0 && real(world, shown, "height") * scale <= area_h,
                "the page is drawn at {scale} in {area_w}x{area_h}"
            );
            let x = real(world, shown, "x");
            expect!(
                (x + width / 2.0 - area_w / 2.0).abs() <= 1.0,
                "the page is at x {x}, {width} wide, in {area_w}"
            );
            Ok(())
        },
    );
    steps.step(
        "the tab names the device, its size and the scale",
        |world, _, _| {
            let label = text(world, "browserDeviceLabel")?;
            let shown = item(world, "browserView")?;
            let percent = (real(world, shown, "scale") * 100.0).round();
            let want = format!("iPad Air · 820 × 1180 · {percent}%");
            expect!(label == want, "the tab says {label:?}, not {want:?}");
            Ok(())
        },
    );

    // The Devices view.
    steps.step("the user opens the Devices view", |world, _, _| {
        open_devices_view(world)
    });
    steps.step("a browser tab showing the Devices view", |world, _, _| {
        show_tab(world, "/")?;
        open_devices_view(world)
    });
    steps.step(
        "the page shows side by side at a phone, a tablet, and a desktop size",
        |world, _, _| {
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| DEVICES.iter().all(|id| devices_frame(w, id).is_some()),
                |_| "a phone, a tablet, and a desktop frame to show".into(),
            )?;
            let mut lefts = Vec::new();
            for id in DEVICES {
                let frame = devices_frame(world, id).expect("waited for above");
                lefts.push(brick.at(world, frame, 0.0, 0.0)?.0);
            }
            expect!(
                lefts[0] < lefts[1] && lefts[1] < lefts[2],
                "the frames are not left to right: phone {}, tablet {}, desktop {}",
                lefts[0],
                lefts[1],
                lefts[2]
            );
            let url = view_url(world, brick);
            wait_for_engine(
                world,
                |w| {
                    DEVICES.iter().all(|id| {
                        devices_frame(w, id).is_some_and(|f| read_text(w, f, "url") == url)
                    })
                },
                |w| format!("every frame to load {url}; {}", state(w, brick)),
            )?;
            // TODO(ljos#357): desktop-qt also grabs each frame to see the page
            // drawn; Ljós's test window has no grab yet, so the painted list
            // stands in.
            wait_for_engine(
                world,
                |w| {
                    DEVICES
                        .iter()
                        .all(|id| devices_frame(w, id).is_some_and(|f| w.painted(f) > 0))
                },
                |w| format!("every frame to draw the page; {}", state(w, brick)),
            )
        },
    );
    steps.step(
        "every device in the view draws its page at the screen's pixels, filling its frame",
        |world, _, _| {
            let brick = panel(world)?;
            let tab_view = item(world, "browserView")?;
            for id in DEVICES {
                let Some(frame) = devices_frame(world, id) else {
                    fail!("no {id} frame");
                };
                let (frame_scale, tab_scale) =
                    (inherited_scale(world, frame), inherited_scale(world, tab_view));
                expect!(
                    (frame_scale - tab_scale).abs() < 1e-6,
                    "the {id} page is drawn in a parent at {frame_scale}, the tab's page at {tab_scale}"
                );
                let Some(device) = parent(world, frame).and_then(|p| parent(world, p)) else {
                    fail!("the {id} frame has no device");
                };
                let page = drawn_size(world, brick, frame)?;
                let body = drawn_size(world, brick, device)?;
                expect!(
                    (page.0 - body.0).abs() < 1.0 && (page.1 - body.1).abs() < 1.0,
                    "the {id} page is {}x{} in a {}x{} frame",
                    page.0,
                    page.1,
                    body.0,
                    body.1
                );
            }
            Ok(())
        },
    );
    steps.step("the user navigates to another page", |world, _, _| {
        dev_server(world)?.page("/other", "Other", "");
        super::browser::evaluate(world, "location.href = '/other'; true")?;
        wait_for_title(world, "Other")
    });
    steps.step("every device in the view shows that page", |world, _, _| {
        let url = server_url(world, "/other")?;
        for id in DEVICES {
            wait_for_engine(
                world,
                |w| devices_frame(w, id).is_some_and(|f| read_text(w, f, "url") == url),
                |_| format!("the {id:?} frame to show {url}"),
            )?;
        }
        Ok(())
    });
    steps.step(
        &format!("the user (?:adds|removes) the {Q} device (?:to|from) the view"),
        |world, c, _| toggle_devices_preset(world, &preset_id(&c[0])),
    );
    steps.step(
        &format!("the view also shows a {Q} frame"),
        |world, c, _| {
            let id = preset_id(&c[0]);
            wait_for_engine(
                world,
                |w| devices_frame(w, &id).is_some(),
                |_| format!("a {:?} frame to show", id),
            )
        },
    );
    steps.step(
        &format!("the view no longer shows a {Q} frame"),
        |world, c, _| {
            let id = preset_id(&c[0]);
            wait_for_engine(
                world,
                |w| devices_frame(w, &id).is_none(),
                |_| format!("the {:?} frame to go away", id),
            )
        },
    );
}

fn register_toolbar(steps: &mut Steps) {
    steps.step(
        "the user shows the device toolbar from the tab's menu",
        |world, _, _| show_toolbar(world),
    );
    steps.step(
        &format!("the toolbar offers {Q} and the named device sizes"),
        |world, c, _| {
            let brick = panel(world)?;
            brick.click(world, "browserToolbarPreset")?;
            wait_for_engine(
                world,
                |w| find(w, brick, "browserToolbarPreset-responsive").is_some(),
                |_| "the toolbar's sizes to show".into(),
            )?;
            let responsive = item(world, "browserToolbarPreset-responsive")?;
            let label = read_text(world, responsive, "text");
            expect!(label == c[0], "the first size is {label:?}");
            let missing: Vec<&str> = PRESETS
                .iter()
                .filter(|(name, id)| {
                    find(world, brick, &format!("browserToolbarPreset-{id}"))
                        .is_none_or(|entry| read_text(world, entry, "text") != *name)
                })
                .map(|(name, _)| *name)
                .collect();
            expect!(
                missing.is_empty(),
                "the toolbar does not offer {}",
                missing.join(", ")
            );
            brick.press(world, "escape")?;
            wait_for_engine(
                world,
                |w| find(w, brick, "browserToolbarPreset-responsive").is_none(),
                |_| "the sizes to close".into(),
            )
        },
    );
    steps.step(
        "the page keeps the room it has, less the toolbar's",
        |world, _, _| {
            let kept = viewport(world);
            expect!(kept["_tag"] == "freeform", "{}", describe(world));
            // Drawn as it is, not scaled down to fit.
            let shown = item(world, "browserView")?;
            expect!(real(world, shown, "scale") == 1.0, "{}", describe(world));
            renders_at(
                world,
                kept["width"].as_i64().unwrap_or(0),
                kept["height"].as_i64().unwrap_or(0),
            )
        },
    );
    steps.step("the user hides the device toolbar", |world, _, _| {
        settle(world)?;
        choose(world, "browserMore", "browserDeviceToolbarItem")
    });
    steps.step("the user closes the device toolbar", |world, _, _| {
        settle(world)?;
        panel(world)?.click(world, "browserToolbarClose")
    });
    steps.step("the page fills the tab again", |world, _, _| {
        wait_for_engine(
            world,
            |w| !resizing(w) && is_fill(&mc_viewport(w, &tab(w))) && is_fill(&viewport(w)),
            |w| format!("the page to fill the tab; {}", describe(w)),
        )?;
        let brick = panel(world)?;
        expect!(
            find(world, brick, "browserDeviceToolbar").is_none(),
            "the device toolbar still shows"
        );
        let shown = item(world, "browserView")?;
        wait_for_engine(
            world,
            |w| {
                let area = parent(w, shown).map_or(0.0, |a| real(w, a, "width"));
                real(w, shown, "scale") == 1.0
                    && real(w, shown, "x") == 0.0
                    && real(w, shown, "width") == area
            },
            |w| format!("the page to fill its space; {}", describe(w)),
        )
    });

    // Each tab its own size.
    steps.step("the thread has two browser tabs", |world, _, _| {
        show_tab(world, "/")?;
        let first = tab(world);
        toolbar(world).first = first.clone();
        dev_server(world)?.page("/second", "Second", "");
        let url = server_url(world, "/second")?;
        update(world, |p| p.open_address(&url))?;
        world.sync()?;
        wait_for_engine(
            world,
            |w| {
                let now = tab(w);
                !now.is_empty() && now != first && browser::page(w.engine(), &now).is_some()
            },
            |w| {
                format!(
                    "a second tab to show; the panel is {}",
                    show(&w.state("panel"))
                )
            },
        )?;
        let second = tab(world);
        toolbar(world).second = second;
        Ok(())
    });
    steps.step(
        &format!("the user picks the {Q} size in the first tab"),
        |world, c, _| {
            let first = toolbar(world).first.clone();
            world.with::<RightPanel, _>(|p, engine| {
                p.show_tab(engine, &format!("browser:{first}"))
            })?;
            world.sync()?;
            wait_for_engine(
                world,
                |w| tab(w) == first,
                |_| "the first tab to show".into(),
            )?;
            let id = preset_id(&c[0]);
            choose(world, "browserDevice", &format!("browserPreset-{id}"))?;
            wait_for_engine(
                world,
                |w| mc_viewport(w, &first)["presetId"] == id.as_str(),
                |w| describe(w),
            )
        },
    );
    steps.step("the second tab still fills its space", |world, _, _| {
        let second = toolbar(world).second.clone();
        let kept = mc_viewport(world, &second);
        expect!(is_fill(&kept), "{}", show(&kept));
        let page = viewport_of(world, &second);
        expect!(is_fill(&page), "the second tab's page is {}", show(&page));
        Ok(())
    });

    // Sizes of the user's own.
    steps.step(
        "a browser tab with the device toolbar shown",
        |world, _, _| tab_with_toolbar(world, None),
    );
    steps.step(
        "a browser tab at (\\d+) by (\\d+) with the device toolbar shown",
        |world, c, _| {
            let (w, h) = (c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0));
            tab_with_toolbar(world, Some((w, h)))
        },
    );
    steps.step(
        "the user (?:types a width of (\\d+) and a height of|previews the page at (\\d+) by) (\\d+)",
        |world, c, _| {
            let width = if c[0].is_empty() { c[1].clone() } else { c[0].clone() };
            type_size(world, &width, &c[2])
        },
    );
    steps.step(
        "the page (?:renders|still renders) at (\\d+) by (\\d+)(?: once the user pauses)?",
        |world, c, _| renders_at(world, c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0)),
    );
    steps.step("the page keeps its previous size", |world, _, _| {
        let before = toolbar(world).before.clone();
        let width = before["width"].as_i64().unwrap_or(0).to_string();
        let height = before["height"].as_i64().unwrap_or(0).to_string();
        let brick = panel(world)?;
        // The fields show the size the page has again.
        wait_for_engine(
            world,
            |w| {
                let field = |name| find(w, brick, name).map(|f| read_text(w, f, "text"));
                field("browserToolbarWidth").as_deref() == Some(width.as_str())
                    && field("browserToolbarHeight").as_deref() == Some(height.as_str())
            },
            |w| format!("the toolbar to show {width} by {height}; {}", describe(w)),
        )?;
        expect!(
            resizes(world) == toolbar(world).resizes,
            "the desktop asked the MC to resize the page"
        );
        expect!(viewport(world) == before, "{}", describe(world));
        Ok(())
    });

    // The aspect ratio.
    steps.step(
        "the user locks the aspect ratio and changes the width to (\\d+)",
        |world, c, _| {
            settle(world)?;
            lock_aspect(world, true)?;
            type_into(world, "browserToolbarWidth", &c[0])
        },
    );
    steps.step("the height becomes (\\d+)", |world, c, _| {
        let height = text(world, "browserToolbarHeight")?;
        expect!(height == c[0], "the height is {height}");
        panel(world)?.press(world, "enter")?;
        let width: i64 = text(world, "browserToolbarWidth")?.parse().unwrap_or(0);
        renders_at(world, width, c[0].parse().unwrap_or(0))
    });
    steps.step("the user unlocks the aspect ratio", |world, _, _| {
        settle(world)?;
        lock_aspect(world, false)
    });
    steps.step(
        "changing the width leaves the height alone",
        |world, _, _| {
            let height = text(world, "browserToolbarHeight")?;
            type_into(world, "browserToolbarWidth", "320")?;
            let now = text(world, "browserToolbarHeight")?;
            expect!(now == height, "the height became {now}");
            Ok(())
        },
    );
    steps.step("the user has typed a width of (\\d+)", |world, c, _| {
        type_into(world, "browserToolbarWidth", &c[0])
    });
    steps.step("locking the aspect ratio is unavailable", |world, _, _| {
        let brick = panel(world)?;
        let aspect = brick.item(world, "browserToolbarAspect")?;
        expect!(
            !read_flag(world, aspect, "enabled"),
            "the aspect ratio can be locked"
        );
        Ok(())
    });
    steps.step(
        "the preview is set to a device size of (\\d+) by (\\d+) with the aspect ratio locked",
        |world, c, _| {
            let (w, h) = (c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0));
            tab_with_toolbar(world, Some((w, h)))?;
            lock_aspect(world, true)
        },
    );
    steps.step("the user types the width (\\d+)", |world, c, _| {
        let brick = panel(world)?;
        brick.click(world, "browserToolbarWidth")?;
        let input = item(world, "browserToolbarWidth")?;
        wait_for_engine(
            world,
            |w| read_flag(w, input, "activeFocus"),
            |_| "the width to take the keyboard".into(),
        )?;
        call(world, input, "selectAll", &[])?;
        toolbar(world).shown_while_typing.clear();
        for ch in c[0].chars() {
            world.type_text(&ch.to_string())?;
            world.sync()?;
            let shown = read_text(world, input, "text");
            toolbar(world).shown_while_typing.push(shown);
        }
        Ok(())
    });
    steps.step(
        "the width field shows (\\d+) while the user types",
        |world, c, _| {
            let typed: Vec<String> = (1..=c[0].len()).map(|i| c[0][..i].to_owned()).collect();
            let shown = toolbar(world).shown_while_typing.clone();
            expect!(
                shown == typed,
                "the width field showed {}",
                shown.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the preview is set to (\\d+) by (\\d+)", |world, c, _| {
        panel(world)?.press(world, "enter")?;
        renders_at(world, c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0))
    });
    steps.step("the user rotates the viewport", |world, _, _| {
        settle(world)?;
        panel(world)?.click(world, "browserToolbarRotate")
    });

    // While a size is applied, and when it cannot be.
    steps.step(
        "the user has just picked a device size for a tab",
        |world, _, _| {
            tab_with_toolbar(world, None)?;
            toolbar(world).resizes = resizes(world);
            world.mc.hold("preview.resize");
            choose(
                world,
                "browserToolbarPreset",
                "browserToolbarPreset-iphone-se",
            )
        },
    );
    steps.step("the MC has not confirmed the size yet", |world, _, _| {
        let before = toolbar(world).resizes;
        wait_for_engine(
            world,
            |w| resizes(w) > before,
            |_| "the desktop to ask the MC for the size".into(),
        )?;
        expect!(resizing(world), "{}", describe(world));
        Ok(())
    });
    steps.step(
        "the toolbar's size controls cannot be used until it does",
        |world, _, _| {
            let brick = panel(world)?;
            for control in SIZE_CONTROLS {
                let found = brick.item(world, control)?;
                expect!(!read_flag(world, found, "enabled"), "{control} can be used");
            }
            world.mc.answer_held();
            wait_for_engine(
                world,
                |w| {
                    SIZE_CONTROLS.iter().all(|control| {
                        brick
                            .item(w, control)
                            .is_ok_and(|found| read_flag(w, found, "enabled"))
                    })
                },
                |w| format!("the controls to be usable; {}", describe(w)),
            )
        },
    );
    steps.step(
        "the user picks another size from the tab's Device size menu",
        |world, _, _| {
            let before = toolbar(world).resizes;
            wait_for_engine(
                world,
                |w| resizes(w) > before,
                |_| "the desktop to ask the MC for the size".into(),
            )?;
            toolbar(world).resizes = resizes(world);
            let picker = item(world, "browserDeviceToolbar")?;
            call(world, picker, "pick", &[Value::from("ipad-mini")])?;
            Ok(())
        },
    );
    steps.step(
        "the desktop asks the MC for no other size and the tab keeps the first",
        |world, _, _| {
            world.mc.answer_held();
            settle(world)?;
            let more = resizes(world) - toolbar(world).resizes;
            expect!(more == 0, "the desktop asked the MC for {more} more sizes");
            expect!(
                viewport(world)["presetId"] == "iphone-se",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the desktop cannot resize the page to the size the user picked",
        |world, _, _| {
            remember(world)?;
            world.mc.refusals.insert(
                "preview.resize".into(),
                "The page could not be resized".into(),
            );
            choose(
                world,
                "browserToolbarPreset",
                "browserToolbarPreset-iphone-se",
            )
        },
    );
    steps.step("the tab returns to its previous size", |world, _, _| {
        let before = toolbar(world).before.clone();
        wait_for_engine(
            world,
            |w| !resizing(w) && viewport(w) == before,
            |w| format!("the page to be {} again; {}", show(&before), describe(w)),
        )?;
        let width = text(world, "browserToolbarWidth")?;
        let want = before["width"].as_i64().unwrap_or(0).to_string();
        expect!(width == want, "the width shows {width}");
        Ok(())
    });
}

fn register_edges(steps: &mut Steps) {
    steps.step(
        "the user drags the page's right edge (\\d+) pixels wider",
        |world, c, _| {
            settle(world)?;
            // The page stays centred, so its edge moves half as far as it
            // grows.
            let shown = item(world, "browserView")?;
            let by = c[0].parse::<f64>().unwrap_or(0.0) / 2.0 * real(world, shown, "scale");
            drag_right_edge(world, by, true)
        },
    );
    steps.step(
        "the page renders at (\\d+) by (\\d+) and the toolbar shows the new size",
        |world, c, _| {
            renders_at(world, c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0))?;
            let (w, h) = (
                text(world, "browserToolbarWidth")?,
                text(world, "browserToolbarHeight")?,
            );
            expect!(w == c[0] && h == c[1], "the toolbar shows {w} by {h}");
            Ok(())
        },
    );
    steps.step(
        "the keyboard focus is on the page's right edge",
        |world, _, _| {
            let edge = item(world, "browserEdge-right")?;
            call(world, edge, "forceActiveFocus", &[])?;
            wait_for_engine(
                world,
                |w| read_flag(w, edge, "activeFocus"),
                |_| "the right edge to take the keyboard".into(),
            )
        },
    );
    steps.step(
        "the user presses (Right arrow|Shift and Right arrow|Left arrow)",
        |world, c, _| {
            let key = if c[0].ends_with("Left arrow") {
                "left"
            } else {
                "right"
            };
            let spelt = if c[0].starts_with("Shift") {
                format!("shift+{key}")
            } else {
                key.to_owned()
            };
            panel(world)?.press(world, &spelt)?;
            Ok(())
        },
    );
    steps.step(
        "a browser tab (\\d+) pixels wide and (\\d+) pixels tall with the device toolbar shown",
        |world, c, _| {
            show_tab(world, "/")?;
            resize_window(
                world,
                c[0].parse().unwrap_or(900.0),
                c[1].parse().unwrap_or(760.0),
            )?;
            show_toolbar(world)
        },
    );
    steps.step(
        "the page is shown smaller, centred and in proportion, so all of it fits in the tab",
        |world, _, _| {
            let shown = item(world, "browserView")?;
            let Some(area) = parent(world, shown) else {
                fail!("the page has no area");
            };
            let scale = real(world, shown, "scale");
            let (x, y) = (real(world, shown, "x"), real(world, shown, "y"));
            let (w, h) = (
                real(world, shown, "width") * scale,
                real(world, shown, "height") * scale,
            );
            let (area_w, area_h) = (real(world, area, "width"), real(world, area, "height"));
            // One scale for both sides: in proportion.
            expect!(
                scale < 1.0 && x >= 0.0 && y >= 0.0 && x + w <= area_w && y + h <= area_h,
                "the page is drawn at {scale} in {area_w}x{area_h}; {}",
                describe(world)
            );
            expect!(
                (x + w / 2.0 - area_w / 2.0).abs() <= 1.0,
                "the page is not centred: {w} wide at x {x} in {area_w}"
            );
            Ok(())
        },
    );
    steps.step(
        "the page has no edges to drag or to move with the keyboard",
        |world, _, _| {
            let brick = panel(world)?;
            for edge in [
                "browserEdge-right",
                "browserEdge-bottom",
                "browserEdge-corner",
            ] {
                expect!(find(world, brick, edge).is_none(), "{edge} shows");
            }
            Ok(())
        },
    );
    steps.step(
        "the user is dragging the edge of a device-sized page",
        |world, _, _| {
            tab_with_toolbar(world, Some((400, 800)))?;
            drag_right_edge(world, 20.0, false)?;
            let edges = item(world, "browserEdges")?;
            wait_for_engine(
                world,
                |w| {
                    !matches!(
                        w.engine().read_by_name(edges, "size"),
                        Value::Null | Value::Undefined
                    )
                },
                |_| "the drag to show a size".into(),
            )
        },
    );
    steps.step(
        "the page's size is changed from the device toolbar",
        |world, _, _| {
            toolbar(world).resizes = resizes(world);
            let picker = item(world, "browserDeviceToolbar")?;
            call(world, picker, "pick", &[Value::from("iphone-se")])?;
            world.sync()
        },
    );
    steps.step("the drag is dropped", |world, _, _| {
        let edges = item(world, "browserEdges")?;
        let unset = |w: &World, name| {
            matches!(
                w.engine().read_by_name(edges, name),
                Value::Null | Value::Undefined
            )
        };
        expect!(
            unset(world, "size") && unset(world, "start"),
            "the drag goes on"
        );
        // The pointer moves on and lets go: nothing changes.
        let edge = item(world, "browserEdge-right")?;
        let brick = panel(world)?;
        let (x, y) = brick.at(world, edge, 0.5, 0.5)?;
        let (x, y) = ((x + 60.0).round(), y.round());
        world.pointer(|now| PointerEvent::moved(x, y, MouseButtons::LEFT, now))?;
        world.pointer(|now| PointerEvent::release(x, y, now))?;
        world.sync()
    });
    steps.step("the page keeps the size that was chosen", |world, _, _| {
        renders_at(world, 375, 667)?;
        expect!(
            viewport(world)["presetId"] == "iphone-se",
            "{}",
            describe(world)
        );
        let asked = resizes(world) - toolbar(world).resizes;
        expect!(asked == 1, "the desktop asked the MC for {asked} sizes");
        Ok(())
    });
}
