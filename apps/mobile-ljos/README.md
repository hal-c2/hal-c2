# mobile-ljos

The phone app on [Ljós](https://github.com/hal-c2/ljos-ui): mobile-qt's
`HalC2.Mobile` (`MobileShell.qml`, in `apps/mobile-qt/qml`) over
desktop-ljos's Rust shell, controllers and MC client
(`apps/desktop-ljos/shell`, `apps/desktop-ljos/mc`), as mobile-qt is
the shared Qt shell with another root. This is the host build (Linux, and
macOS where it costs nothing) that proves the phone's QML on Ljós;
Android comes once Ljós has an Android host (hal-c2/ljos-ui#613). Why the
phone is shaped as it is: `docs/internals/mobile-qt.md`.

- `src/main.rs` is the thin binary (`hal-c2-mobile-ljos`): it registers
  desktop-ljos's `HalC2.Shell`, starts its controllers with the phone's
  beside them, and loads `qml/Main.qml` (the phone's root) instead of the
  desktop's.
- `src/` is what is the phone's alone, each naming the mobile-qt C++ it
  ports or stands in for: `pairing.rs` (Pairing, ported: the pairing
  screen's exchange, `pairing.json`, environments beside the first),
  `mobile_terminal.rs` (MobileTerminal's key row, text size and line
  picking; its menu is H1), `layout.rs` (MobileApp's `layout.desktop`),
  `resume.rs` (Resume's decision, unwired without an Android host),
  `push_crypto.rs` and `push_inbox.rs` (PushCrypto's RFC 8291
  decryption and PushInbox's showing rules, ported; the Android
  receivers that call them wait for hal-c2/ljos-ui#616), and
  stand-ins that publish the C++ state shape until H1 ports them:
  `scanner.rs` (Scanner/ScanCamera/QrReader), `notifications.rs`
  (Notifications over the inbox), `maintenance.rs` (Maintenance).
- `qml/` is the entry and the QML stub in `HalC2.Shell` for the C++
  type the phone's screens name that Ljós cannot do yet,
  `TerminalEvents` (#1624), saying what it cannot do until the real
  type lands. `TurnAgents` is the shell's native type now
  (`apps/desktop-ljos/shell/src/thread_view/turn_agents.rs`).

The crate is its own cargo workspace beside desktop-ljos's (a member
outside that root cannot inherit from it), so its Ljós pin is spelled out
in `Cargo.toml` and follows desktop-ljos's when it moves. The phone's QML
is read where it lives (`apps/mobile-qt/qml`), so both clients show the
same files; the bricks are the shared ones in packages/qml.

As desktop-ljos, the app runs the QML its `build.rs` compiled into it
(its pack: the bricks, `qml/` and mobile-qt's `HalC2.Mobile`), with the
user's `<config>/qml` and `<config>/shell.qml` laid over it; `qml/Main.qml`
is a ShellLoader of `shell.qml`, else the built-in `MobileShell`. A build
with `--features dev-qml` compiles the checkout's directories at
start-up instead and does not follow saves. The bricks' fonts, icons and
models beside their QML are desktop-ljos's assets list's, as before; the
phone's QML directories carry no such files. There is no Android
packaging of this host build yet (above), so nothing else looks for the
QML on disk.

## Run, check and render

Ljós needs rustc 1.98; `mise.toml` here pins it, as desktop-ljos's does.

```sh
mise run mobile-ljos            # the window; pairs with the running MC the first time
mise run mobile-ljos:check      # compile every phone QML file; fails when one does not
mise run mobile-ljos:render     # .hal-c2/mobile-ljos.png without a window
mise run mobile-ljos:render -- --size 412x915 --home-dir <dir>
```

The phone pairs itself, as mobile-qt does: no host and no MC of its own.
`mise run mobile-ljos` spends a pairing link from the running MC
(`mise run mc:pair`) the first time, as entering it in the app does, and
opens the remembered environment after that; `--url LINK` pairs with
another, and a `hal-c2://pair?...` argument is shown on the pairing
screen, never spent. Its files go to the worktree's
`.hal-c2/mobile-ljos`; the binary does not start on a desktop host
without `--home-dir`, whose default home there is the installed desktop
app's. `HAL_C2_MOBILE_SIZE=360x640` (or `--size`) opens the development
window at another size than the root's 412x915; from 736x480 up it is the
desktop's layout.

A scripted run is `--action NAME[=JSON]` and `--key CHORD` steps with
`--screenshot PNG`, as desktop-ljos's.

## Tests

```sh
cd apps/mobile-ljos && mise exec -- cargo test -p hal_c2_mobile
mise run features:mobile-ljos -- mobile/pairing-and-environments.feature
```

The unit and property tests cover the phone's own state machines (the
pairing's phases, the terminal's key row and chosen lines, the resume
decision). The features harness (`tests/features/`, in desktop-ljos's
shape: `main.rs`, a World that is a phone with touch steps, and a
RATCHET) runs `@mobile` scenarios headlessly; what it passes is what the
RATCHET holds, and the rest reports the steps it waits for — pairing
with a real environment's rows wants the fake pairable MC mobile-qt has,
which is its next piece.
