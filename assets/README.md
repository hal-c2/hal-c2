# Brand

`brand/hal-c2-avatar.svg` is the HAL-C2 mark and `brand/hal-c2-logotype.svg` the "HAL-C2" logotype: "HAL-" in `#fba919` and "C2" in `#768efb`, set in the [HAL C2 font](https://github.com/hal-c2/hal-c2-font) and outlined so nothing needs the font installed. The desktop's `HalC2Wordmark.qml` and the marketing site carry copies of these outlines; update them together.

## App icons

The three Icon Composer projects are the source of truth for full application icons:

- `dev/app-icon.icon`
- `nightly/app-icon.icon`
- `prod/app-icon.icon`

Each project uses `text.svg` for the avatar (the mark centred in the 128pt layer box) and `background.svg` when the background is a vector layer. Additional layers use semantic names that describe their role and placement.

Run `vp run icons:export` from the repository root to regenerate the tracked `*-universal-1024.png` beside each project: the Qt desktop's window icon (`prod`, via `apps/desktop-qt/CMakeLists.txt`) and its Linux desktop entry. Run `vp run icons:check` to verify that they match their sources without changing files.

Exporting requires Icon Composer 2 or newer on macOS. The script selects the newest compatible exporter from Xcode or a standalone Icon Composer installation and pins design generation 26. Set `ICON_COMPOSER_TOOL` to the full path of `Icon Composer.app/Contents/Executables/ictool` to override automatic discovery.

Do not edit the generated PNG files directly.

## Android launcher icon

Android masks the central 72dp of a 108dp adaptive canvas, so the Icon Composer exports cannot be
used directly: their rounded-square silhouette gets framed again and the avatar is cropped.
`vp run icons:export:android` instead renders the launcher's foreground from the production
project's `text.svg`: a transparent avatar sized to stay inside the safe zone, written to
`apps/mobile-qt/android/res/mipmap-xxxhdpi/ic_launcher_foreground.png`. The background is the
colour in `apps/mobile-qt/android/res/values/colors.xml`.

Rerun the export after changing the layer SVG. `ic_launcher_monochrome.png` beside it is not
rendered: it remains a flat silhouette for Android's monochrome themed icon.
