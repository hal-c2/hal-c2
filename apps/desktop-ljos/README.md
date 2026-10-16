# desktop-ljos

An experiment: the desktop shell of `apps/desktop-qt` (DefaultShell → ShellWindow → DefaultLayout) on
[Ljós](https://github.com/hal-c2/ljos-ui), a Rust QML runtime. It reuses `apps/desktop-qt/qml/HalC2/Bricks`
as they are and puts a Rust `HalC2.Shell` under them.

- `shell/` is the app (`hal-c2-ljos`): the native `Shell`, `Theme` and `Runtime` singletons, the
  controllers behind `Shell.state` (desktop-qt's NativeController and NativeShell), and the seam to the MC.
- `mc/` is the MC client, desktop-qt's McClient in Rust.
- `qml/` is the entry (`Main.qml`) and the QML half of `HalC2.Shell`: stubs for what is not ported yet, each
  naming the C++ class it stands in for, holding only what the bricks read.

Both QML trees are compiled when the app starts (`shell/src/qml.rs` says why not ahead of time). A file that
does not compile fails only where it is made, as in Qt.

## Run, check and render

Ljós needs rustc 1.98; `mise.toml` here pins it.

```sh
mise run desktop-ljos                                   # the window; --mc-origin URL --mc-token TOKEN
mise run desktop-ljos:check                             # compile the QML; fails when a file does not
mise run desktop-ljos:render                            # .hal-c2/desktop-ljos.png without a window
mise run desktop-ljos:render -- --action settings.open --action 'theme.mode {"mode":"dark"}'
```

There is no pairing yet: the window takes the MC's origin and a session token (also
`HAL_C2_MC_ORIGIN`/`HAL_C2_MC_TOKEN`), and runs disconnected without them. The render is always
disconnected; `--action` dispatches shell actions first to show a given place (`usage.open` by default).

`check` compiles every file. The native item types the bricks use are `LocalFolderModel`, `ComposerHighlighter`,
`DeviceScreen` (a frame the decoder hands it; no decoder here) and `Terminal` (`import Ghostty`, on the `vt100`
crate rather than libghostty-vt: no Zig or C build, and what it lacks is listed in `shell/src/terminal/mod.rs`).

## Tests

```sh
cd apps/desktop-ljos && mise exec -- cargo test -p hal_c2_shell
```

They build the app headlessly through `ljos::App`, compile QML written in the test, and drive time with a
virtual clock.
