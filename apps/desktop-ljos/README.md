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

Not ahead of time: `ljos::build` would compile them in a build script, but only if the native types moved to a
crate of their own, every QML edit would mean a rebuild where a restart does now, a file that does not compile
would fail the build, and `--qml-dir` would still need the compiler. A second at start-up does not pay for that.

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

`check` compiles every file. The native item types the bricks use are `LocalFolderModel`, `ComposerHighlighter`,
`DeviceScreen` (a frame the decoder hands it; no decoder here) and `Terminal` (`import Ghostty`, on the `vt100`
crate rather than libghostty-vt: no Zig or C build, and what it lacks is listed in `shell/src/terminal/mod.rs`).

## Tests

```sh
cd apps/desktop-ljos && mise exec -- cargo test -p hal_c2_shell
```

They build the app headlessly through `ljos::App`, compile QML written in the test, and drive time with a
virtual clock.

## Ljós

The shell is an application of the `ljos` facade (`App`, `#[derive(QmlObject)]`, `ljos::dev`, `ljos::render`)
except where the facade has no way yet, which `shell/Cargo.toml` names crate by crate:

- Custom items (`Terminal`, `DeviceScreen`, `ComposerHighlighter`) paint and take keys through `ljos_quick`'s
  hooks, in `ljos_engine`'s and `ljos_render`'s types.
- Some types the facade hands out are not named by it: `CoalesceKey` (`UiHandle::send_coalesced`),
  `Time`/`TimerId`, `ClipboardMode`, and `Application` (the window's focus). The system's colour scheme is
  `ljos_quick::color_scheme`.

What the shell still works around, each where it does so:

- Compiled QML gets no base URL from `App::qml_dirs`, so `shell/src/qml.rs` compiles with `ljos::dev` and sets
  one; and a compiled source does not say what it holds, so `--check` counts the files itself.
- No application-wide key filter (hal-c2/ljos-ui#43) or Rust `request_quit` (#44): `controllers/quit.rs`.
- No destroyed signal (#41), and `call_js` neither says why a call threw nor whether a value is callable (#42):
  `commands.rs`.
- No badge (#45): `notifications.rs`. No tree models (#27): `qml/HalC2/Shell/TreeView.qml`.
