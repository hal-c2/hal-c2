# Brand

`brand/hal-c2-avatar.svg` is the HAL-C2 mark and `brand/hal-c2-logotype.svg` the "HAL-C2" logotype: "HAL-" in `#fba919` and "C2" in `#768efb`, set in the [HAL C2 font](https://github.com/hal-c2/hal-c2-font) and outlined so nothing needs the font installed. The desktop's `HalC2Wordmark.qml` and the marketing site carry copies of these outlines; update them together.

## App icons

The three Icon Composer projects are the source of truth for full application icons:

- `dev/app-icon.icon`
- `nightly/app-icon.icon`
- `prod/app-icon.icon`

Each project uses `text.svg` for the avatar (the mark centred in the 128pt layer box) and `background.svg` when the background is a vector layer. Additional layers use semantic names that describe their role and placement.

Run `vp run icons:export` from the repository root to regenerate the tracked iOS, Linux, Windows, and web assets. The development web exports are also copied to `apps/web/public` for the browser favicon and splash screen. Run `vp run icons:check` to verify that the generated assets and public copies match their sources without changing files.

Exporting requires Icon Composer 2 or newer on macOS. The script selects the newest compatible exporter from Xcode or a standalone Icon Composer installation and pins design generation 26. Set `ICON_COMPOSER_TOOL` to the full path of `Icon Composer.app/Contents/Executables/ictool` to override automatic discovery.

## macOS exports

Icon Composer's command-line exporter does not expose the `macOS pre-Tahoe` preset. A plain command-line `macOS` export is full bleed and is not suitable for the desktop app, so the export script intentionally leaves the tracked macOS PNGs unchanged and prints a reminder after every run.

After changing an Icon Composer project, open it in Icon Composer and export the macOS PNG with exactly these settings:

- Platform: `macOS pre-Tahoe`
- Appearance: `Default`
- Size: `1024pt`
- Scale: `1×`

Save the three exports to:

- `dev/app-icon.icon` -> `dev/blueprint-macos-1024.png`
- `nightly/app-icon.icon` -> `nightly/nightly-macos-1024.png`
- `prod/app-icon.icon` -> `prod/black-macos-1024.png`

The result must be a 1024×1024 PNG with the classic macOS safe area: the opaque icon body is 824×824, inset 100 pixels on every side, with only the native Icon Composer shadow extending into the surrounding transparent canvas.

To have Codex perform the native exports, paste this prompt into a task opened at the repository root:

```text
Use [@Computer](plugin://computer-use@openai-bundled) and the Icon Composer app to export the three macOS app icons in this repository.

For each project below, use Platform: macOS pre-Tahoe, Appearance: Default, Size: 1024pt, and Scale: 1×, then save the PNG to the exact destination:

- assets/dev/app-icon.icon -> assets/dev/blueprint-macos-1024.png
- assets/nightly/app-icon.icon -> assets/nightly/nightly-macos-1024.png
- assets/prod/app-icon.icon -> assets/prod/black-macos-1024.png

Do not resize, composite, or otherwise post-process the exported PNGs.

Verify every result is 1024×1024 and has the classic macOS safe area: an 824×824 opaque body inset 100px on every side, with only Icon Composer's native shadow extending beyond it.
```

Do not edit the generated PNG or ICO files directly.

## Android launcher icon

Android masks the central 72dp of a 108dp adaptive canvas, so the Icon Composer exports cannot be
used directly: their rounded-square silhouette gets framed again and the avatar is cropped.
`vp run icons:export:android` instead renders the launcher's foreground from the production
project's `text.svg`: a transparent avatar sized to stay inside the safe zone, written to
`apps/mobile-qt/android/res/mipmap-xxxhdpi/ic_launcher_foreground.png`. The background is the
colour in `apps/mobile-qt/android/res/values/colors.xml`.

Rerun the export after changing the layer SVG. `ic_launcher_monochrome.png` beside it is not
rendered: it remains a flat silhouette for Android's monochrome themed icon.
