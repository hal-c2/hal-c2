//! The files the shell's QML loads besides QML and JavaScript: the
//! terminal's symbol font, the provider icons, the device bodies' models.
//! The pack names the QML by key (`file:///HalC2/Bricks/TerminalSplits.qml`),
//! where a release has no file, so a path a brick gives relative to itself
//! names none either. build.rs builds these in, and [`install`] gives each
//! the address the pack's QML resolves it to.

use ljos::ComponentSource;
use ljos::prelude::{Engine, Platform};

/// (key, bytes), the key as the pack's: the path under the QML directory.
const FILES: &[(&str, &[u8])] = include!(concat!(env!("OUT_DIR"), "/assets.rs"));

/// The file extensions an `Image` shows.
const PICTURES: [&str; 7] = ["png", "jpg", "jpeg", "gif", "bmp", "svg", "webp"];

/// Makes each built-in file what its address loads: for a `FontLoader` and
/// a model, Ljós's platform; for an `Image`, its picture store. A file of
/// the user's that replaces a brick resolves from the user's directory, so
/// these stand only for the bricks as built.
pub fn install(engine: &Engine) {
    let pack = crate::pack();
    let platform = Platform::of(engine);
    let images = ljos_quick::ImageStore::of(engine);
    for (key, bytes) in FILES {
        let url = url(&pack, key);
        platform.register_resource(&url, *bytes);
        let picture = key
            .rsplit_once('.')
            .is_some_and(|(_, e)| PICTURES.iter().any(|p| e.eq_ignore_ascii_case(p)));
        if picture {
            images.register_resource(url, *bytes);
        }
    }
}

/// The address a file `key` has beside the pack's QML: the pack's address
/// of a QML file named as it is, with its own extension.
fn url(pack: &impl ComponentSource, key: &str) -> String {
    let (stem, ext) = key.rsplit_once('.').unwrap_or((key, ""));
    let qml = pack.url(stem);
    let base = qml.strip_suffix(".qml").unwrap_or(&qml);
    format!("{base}.{ext}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bricks_files_are_built_in() {
        let keys: Vec<&str> = FILES.iter().map(|(k, _)| *k).collect();
        for key in [
            "HalC2/Bricks/fonts/SymbolsNerdFontMono-Regular.woff2",
            "HalC2/Bricks/icons/antigravity.png",
            "HalC2/Bricks/models/phone.glb",
        ] {
            assert!(keys.contains(&key), "{key} is not among {keys:?}");
        }
    }

    #[test]
    fn a_file_has_the_address_its_brick_resolves_it_to() {
        let pack = crate::pack();
        assert_eq!(
            url(
                &pack,
                "HalC2/Bricks/fonts/SymbolsNerdFontMono-Regular.woff2"
            ),
            "file:///HalC2/Bricks/fonts/SymbolsNerdFontMono-Regular.woff2"
        );
    }
}
