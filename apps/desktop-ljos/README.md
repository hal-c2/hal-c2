# desktop-ljos

An experiment: the desktop shell of `apps/desktop-qt` (DefaultShell → ShellWindow → DefaultLayout) run on
[Ljós](https://github.com/olafura/ljos-ui), a Rust QML runtime. QML only, no Rust crate yet. It reuses
`apps/desktop-qt/qml/HalC2/Bricks` as is and stands a pure-QML `HalC2.Shell` in for the native module, so
the shell draws with an empty state (no MC connection).

## Build the ljos CLI

Ljós needs rustc 1.98; its `mise.toml` pins it. Build with a target directory under this checkout so
nothing is written in the Ljós tree:

```sh
cd ~/dev/ljos-ui
CARGO_TARGET_DIR=<checkout>/.hal-c2/ljos-target mise exec -- cargo build --release -p ljos_cli
```

The tasks use `.hal-c2/ljos-target/release/ljos`; set `LJOS_BIN` to use another binary.

## Check and render

```sh
mise-tasks/desktop-ljos/check            # ljos check over the staged project
mise-tasks/desktop-ljos/render           # headless PNG at .hal-c2/desktop-ljos.png (--out, --size, --settle)
```

(or `mise run desktop-ljos:check` / `desktop-ljos:render` once the repo's mise.toml is trusted.) Neither
opens a window or needs an MC.

`ljos` does not follow symlinks, so `scripts/ljos.sh` stages the Bricks and `qml/` into the gitignored
`.hal-c2/desktop-ljos-stage/` first. The stage also drops `default` from five `default property alias`
lines to get around a Ljós bug; see the comment in the script (`LJOS_KEEP_DEFAULT_ALIAS=1` turns that off).
`check` exits 1 for the Bricks that need native types Ljós has not got (`Terminal`, `DeviceScreen`,
`LocalFolderModel`, `TreeView`); `render` is not blocked by them.

## Stubs in `qml/HalC2/Shell`

Each file names the C++ class it stands in for: `Shell` (ShellBridge), `Theme` (ThemeStore), `Runtime`
(ShellRuntime), `Keybindings`, `Terminals`, `PaletteModel`, `Themes`, `Settings`, `Panel`, `Threads`,
`Onboarding` (their controllers), and the `ComposerHighlighter` type. They hold only the members the bricks
read, with the empty values the app shows before anything is published.
