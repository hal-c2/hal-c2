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

The window makes its shell again when a QML file changes: this checkout's (or `--qml-dir`'s, or
`HAL_C2_QML_DIR`'s) and the config dir's. A `shell.qml` there replaces the built-in shell and `qml/` beside it is
on the import path; one that does not load falls back to the built-in shell with the error in its overlay.

A scripted run is `--action NAME[=JSON]` and `--key CHORD` steps, replayed in the order given 1.5 s apart once
the MC's first snapshot is in, and `--screenshot PNG` (no window; exit 0, or 2 when there is no picture) taken
1.5 s after the last: `hal-c2-ljos --action settings.open --key Ctrl+K --screenshot out.png`. A chord reaches the
shell's keymap, not the focused control.

`check` compiles every file. The native item types the bricks use are `LocalFolderModel`, `ComposerHighlighter`,
`DeviceScreen` (its `DeviceStream`'s newest picture) and `Terminal` (`import Ghostty`, on the `vt100`
crate rather than libghostty-vt: no Zig or C build, and what it lacks is listed in `shell/src/terminal/mod.rs`).

## Inspect

Built with the `mcp` feature, the window serves Ljós's MCP inspector (the scene, clicks, timings and how the
window is painted) when `LJOS_MCP` names its capabilities; the token file goes below `LJOS_MCP_DIR`:

```sh
LJOS_MCP=inspect,input LJOS_MCP_DIR=.hal-c2 cargo run -p hal_c2_shell --features mcp
```

`mise run desktop-ljos:inspect` opens the shell that way (its token in `.hal-c2/desktop-ljos`), `mise run
desktop-ljos:observe` opens Ljós's observer on it (processes, mailboxes, objects, traces, a picture of the object
picked), and `mise run desktop-ljos:attach` serves its inspector on stdio for an MCP client. The last two run
Ljós's own `ljos` command, built at the pinned rev by `mise run desktop-ljos:cli`.

## Tests

```sh
cd apps/desktop-ljos && mise exec -- cargo test -p hal_c2_shell
```

They build the app headlessly through `ljos::App`, compile QML written in the test, and drive time with a
virtual clock.

## Ljós

The shell is an application of the `ljos` facade alone (`App`, `#[derive(QmlObject)]`, `ljos::item`,
`ljos::keys`, `ljos::system`, `ljos::window`, `ljos::dev`, `ljos::render`), and its tests of `ljos::testing`.
