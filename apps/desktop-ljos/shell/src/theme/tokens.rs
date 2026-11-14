//! The design tokens on `Theme` (desktop-qt's ThemeStore.h): the type ramp
//! (`Theme.type.body.size`), the spacing scale (`Theme.space.md`), and
//! control heights and icon sizes (`Theme.control.md`, `Theme.icon.md`).

use ljos::prelude::{Cx, Engine, ObjectId, QmlObject, QmlType, qml_impl};

/// One step of the type ramp: pixel size and line height, already scaled by
/// the interface size, and a weight for `font.weight`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThemeTypeStep", uncreatable)]
pub struct ThemeTypeStep {
    #[qml(notify, readonly)]
    size: i32,
    #[qml(notify, readonly)]
    line_height: i32,
    #[qml(notify, readonly)]
    weight: i32,
}

impl Default for ThemeTypeStep {
    fn default() -> Self {
        ThemeTypeStep {
            size: 13,
            line_height: 18,
            weight: 400,
        }
    }
}

/// The six text sizes, and nothing between them: caption (badges, counts,
/// keys), meta (secondary lines, times), body (controls, rows, menus), prose
/// (messages), title (dialog and section titles) and display (page titles).
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThemeTypeRamp", uncreatable)]
pub struct ThemeTypeRamp {
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    caption: Option<ObjectId>,
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    meta: Option<ObjectId>,
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    body: Option<ObjectId>,
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    prose: Option<ObjectId>,
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    title: Option<ObjectId>,
    #[qml(constant, readonly, object = "ThemeTypeStep")]
    display: Option<ObjectId>,
}

/// The spacing scale: 2 4 8 12 16 24 32, nothing between.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThemeSpace", uncreatable)]
pub struct ThemeSpace {
    #[qml(constant, readonly)]
    xxs: i32,
    #[qml(constant, readonly)]
    xs: i32,
    #[qml(constant, readonly)]
    sm: i32,
    #[qml(constant, readonly)]
    md: i32,
    #[qml(constant, readonly)]
    lg: i32,
    #[qml(constant, readonly)]
    xl: i32,
    #[qml(constant, readonly)]
    xxl: i32,
}

impl Default for ThemeSpace {
    fn default() -> Self {
        ThemeSpace {
            xxs: 2,
            xs: 4,
            sm: 8,
            md: 12,
            lg: 16,
            xl: 24,
            xxl: 32,
        }
    }
}

/// Control heights (`md` the default; a text field is md, xl a tab strip)
/// or icon sizes, with the stroke each size draws at.
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThemeSizes", uncreatable)]
pub struct ThemeSizes {
    #[qml(constant, readonly)]
    sm: i32,
    #[qml(constant, readonly)]
    md: i32,
    #[qml(constant, readonly)]
    lg: i32,
    #[qml(constant, readonly)]
    xl: i32,
}

#[qml_impl]
impl ThemeSizes {
    /// The lucide stroke (in its 24-unit box) for an icon `size` pixels
    /// wide: small icons draw heavier so every size reads at about the same
    /// weight.
    #[qml(invokable)]
    fn stroke(_cx: &Cx, size: f64) -> f64 {
        if size <= 12.0 {
            2.0
        } else if size <= 16.0 {
            1.75
        } else {
            1.5
        }
    }
}

/// Registers the token types, which only `Theme` makes.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [
        ThemeTypeStep,
        ThemeTypeRamp,
        ThemeSpace,
        ThemeSizes,
    ]));
}

/// The token objects `Theme` holds.
pub struct Tokens {
    pub ramp: Option<ObjectId>,
    pub space: Option<ObjectId>,
    pub control: Option<ObjectId>,
    pub icon: Option<ObjectId>,
    steps: [Option<ObjectId>; 6],
}

impl Tokens {
    /// Makes them, owned by `parent`.
    pub fn new(engine: &Engine, parent: ObjectId) -> Tokens {
        fn made<T: QmlType>(engine: &Engine, parent: ObjectId, object: T) -> Option<ObjectId> {
            engine.create_native(object, Some(parent)).ok()
        }
        let make = |object| made(engine, parent, object);
        let steps = std::array::from_fn(|_| make(ThemeTypeStep::default()));
        let ramp = made(engine, parent, ThemeTypeRamp::default());
        if let Some(ramp) = ramp {
            let cx = Cx::new(engine, ramp);
            let fields = [
                ThemeTypeRamp::CAPTION,
                ThemeTypeRamp::META,
                ThemeTypeRamp::BODY,
                ThemeTypeRamp::PROSE,
                ThemeTypeRamp::TITLE,
                ThemeTypeRamp::DISPLAY,
            ];
            for (field, step) in fields.into_iter().zip(steps) {
                let _ = cx.set(field, step);
            }
        }
        let sizes = |sm, md, lg, xl| made(engine, parent, ThemeSizes { sm, md, lg, xl });
        Tokens {
            ramp,
            space: made(engine, parent, ThemeSpace::default()),
            control: sizes(24, 28, 32, 36),
            icon: sizes(12, 16, 20, 24),
            steps,
        }
    }

    /// Scales the ramp by the interface size; a monospace face gets two more
    /// pixels of leading on every step and a smaller display, since its
    /// glyphs run wide.
    pub fn apply_type(&self, engine: &Engine, scale: f64, monospace: bool) {
        for (step, (size, line_height, weight)) in self.steps.iter().zip(ramp(scale, monospace)) {
            let Some(step) = *step else { continue };
            let cx = Cx::new(engine, step);
            let _ = cx.set(ThemeTypeStep::SIZE, size);
            let _ = cx.set(ThemeTypeStep::LINE_HEIGHT, line_height);
            let _ = cx.set(ThemeTypeStep::WEIGHT, weight);
        }
    }
}

/// Each step's size, line height and weight, caption to display.
fn ramp(scale: f64, monospace: bool) -> [(i32, i32, i32); 6] {
    let leading = if monospace { 2 } else { 0 };
    let px = |v: i32| (f64::from(v) * scale).round() as i32;
    let step = |size, line_height, weight| (px(size), px(line_height) + leading, weight);
    [
        step(11, 16, 500),
        step(12, 16, 400),
        step(13, 18, 400),
        step(14, 22, 400),
        step(16, 22, 600),
        if monospace {
            (px(22), px(28), 600)
        } else {
            step(24, 30, 600)
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::ramp;

    #[test]
    fn the_ramp_scales_and_a_monospace_face_reads_looser() {
        assert_eq!(ramp(1.0, false)[2], (13, 18, 400));
        assert_eq!(ramp(1.25, false)[3], (18, 28, 400));
        assert_eq!(ramp(1.0, true)[2], (13, 20, 400));
        assert_eq!(ramp(1.0, true)[5], (22, 28, 600));
    }
}
