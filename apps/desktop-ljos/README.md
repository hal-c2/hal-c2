# desktop-ljos

An experiment: the desktop shell of `apps/desktop-qt` (DefaultShell → ShellWindow → DefaultLayout) on
[Ljós](https://github.com/hal-c2/ljos-ui), a Rust QML runtime. It reuses `apps/desktop-qt/qml/HalC2/Bricks`
as they are and puts a Rust `HalC2.Shell` under them.

- `shell/` is the app (`hal-c2-ljos`): the native `Shell`, `Theme` and `Runtime` singletons, the
  controllers behind `Shell.state` (desktop-qt's NativeController and NativeShell), and the seam to the MC.
- `mc/` is the MC client, desktop-qt's McClient in Rust.
- `qml/` is the entry (`Main.qml`) and the QML half of `HalC2.Shell`: stubs for what is not ported yet, each
  naming the C++ class it stands in for, holding only what the bricks read.

Both QML trees are compiled when the app starts, against `HalC2.Shell`'s native types, as one import path
whose base URL is the bricks' root (so a brick's `Qt.resolvedUrl` finds its icons). A file that does not compile
fails only where it is made, as in Qt. It takes about a second in a debug build.

Not ahead of time. At the pinned Ljós it could be (hal-c2/ljos-ui#6): a test would write `ljostypes.json` from
the shell's types with `ljos::types::check_file`, and a build script would compile both trees against it with
`ljos::build::compile_dirs_with_types`, running none of the shell's code. It would catch nothing `--check` does
not, as the compiler checks a native type's members either way. Every QML edit would mean a rebuild where a
restart does now, a file that does not compile would fail the build, and `--qml-dir` would still need the
compiler. A second at start-up does not pay for that.

## Run, check and render

Ljós needs rustc 1.98; `mise.toml` here pins it.

```sh
mise run desktop-ljos                                   # the window; --mc-origin URL --mc-token TOKEN
mise run desktop-ljos:check                             # compile the QML; fails when a file does not
mise run desktop-ljos:render                            # .hal-c2/desktop-ljos.png without a window
mise run desktop-ljos:render -- --action settings.open --action 'theme.mode {"mode":"dark"}'
```

The window takes the MC's origin and a session token (also `HAL_C2_MC_ORIGIN`/`HAL_C2_MC_TOKEN`), or
`--pair LINK` (from `mise run mc:pair`), which keeps the session for the next start; without either it
reconnects to the MC it paired with last, or runs disconnected. `--home-dir DIR` keeps the session and the
client cache under `DIR` instead of the XDG directories. A render waits for the MC's first snapshot, or shows
what the cache kept; `--action` dispatches shell actions first to show a given place (`usage.open` by default).

A scripted run is `--action NAME[=JSON]` and `--key CHORD` steps, replayed in the order given 1.5 s apart once
the MC's first snapshot is in, and `--screenshot PNG` (no window; exit 0, or 2 when there is no picture) taken
1.5 s after the last: `hal-c2-ljos --action settings.open --key Ctrl+K --screenshot out.png`. A chord reaches the
shell's keymap, not the focused control.

`check` compiles every file. The native item types the bricks use are `LocalFolderModel`, `ComposerHighlighter`,
`DeviceScreen` (its `DeviceStream`'s newest picture) and `Terminal` (`import Ghostty`, on the `vt100`
crate rather than libghostty-vt: no Zig or C build, and what it lacks is listed in `shell/src/terminal/mod.rs`).

## Tests

```sh
cd apps/desktop-ljos && mise exec -- cargo test -p hal_c2_shell
```

They build the app headlessly through `ljos::App`, compile QML written in the test, and drive time with a
virtual clock.

## Ljós

The shell is an application of the `ljos` facade alone (`App`, `#[derive(QmlObject)]`, `ljos::item`,
`ljos::keys`, `ljos::system`, `ljos::window`, `ljos::dev`, `ljos::render`), and its tests of `ljos::testing`.
`shell/Cargo.toml` names the one crate the tests take from below it.

What the shell still works around, each where it does so:

- Ljós's stream decoder keeps a live stream's newest picture until more video comes (#71), so a
  device's screen finishes the decoder after each batch: `shell/src/device/decoder.rs`.
- The compiler warns on `popup.scale` and `popup.transformOrigin` set through a `ComboBox`'s `popup` (#61), which
  `GitActions.qml` does and Qt accepts; the warning is the only harm.
- `Window.backdrop` is a plain blur: it has no dark or light material and no macOS 26 Liquid Glass (#66, #67), so the
  theme's choice of them does nothing (`shell/src/platform_window.rs`, `apply_window_blur`).
- A test window's clock starts off the 1 ms grid timer deadlines are rounded to, so letting a timer's interval
  pass stops short of it (#65). The tests set a virtual clock at zero first: `shell/tests/common/mod.rs`, `test_window`.
