# Mobile (Qt) client

`apps/mobile-qt` is the phone and tablet client, replacing the React Native app in `apps/mobile`.
How to build and run it is in its [README](../../apps/mobile-qt/README.md). This page records why
it is shaped the way it is.

## The desktop's shell with another root

The phone is not a second client. It compiles the desktop's `hal_c2_native` (the MC client, the
store and every controller) and `HalC2.Bricks` from `apps/desktop-qt`, and adds one QML module,
`HalC2.Mobile`, whose root lays the same bricks out for a phone. A behaviour fixed in a controller
or a brick is fixed on both, which is what `@shared` in `features/` means.

So a brick must not learn about phones. Where the phone needs a brick to behave differently, the
brick gets a property that defaults to what the desktop does (`ShellWindow.firstRunGate`,
`Sidebar.touchRows`), and the phone's root sets it. The same holds for controllers
(`DraftController::setLandsOnDraft`).

## No host, so the phone pairs itself

The desktop gets its MC from a Node host process that starts or finds one. A phone runs neither
Node nor an MC, so [`Pairing`](../../apps/mobile-qt/src/Pairing.h) does the host's attach in C++:
it spends a pairing link's token on a session, keeps that session in the app's private storage,
and opens the shell's connection with it. The exchange itself is shared with the desktop's
`connection.pair` ([`PairingExchange`](../../apps/desktop-qt/src/native/PairingExchange.h)).

The phone remembers one environment. MCs cluster and share one sidebar, so one pairing already
shows every machine in the cluster, and `NativeShell`, `McClient` and `ShellStore` were written for
one MC per process. Pairing with another MC replaces the one remembered. The scenarios in
`features/mobile/` that speak of several paired environments stay in the backlog until that
changes.

The first product reaches an MC over Tailscale: `mise run mc:pair --tailscale` publishes the MC
through Tailscale Serve and prints an `https://` link. That is why the Android package carries
OpenSSL (Qt for Android has no TLS of its own), and why the relay and QR scanning can wait.

## A development build must be told its home

On a phone the app's files are its private storage. The same binary built for a desktop, to work
on the layout, would resolve the HAL-C2 home the installed desktop app uses and write its window
state, drafts and session there. It refuses to start without `--home-dir` instead; `mise run
mobile` passes the checkout's `.hal-c2/mobile`.

## Two Controls styles in one engine

The bricks import `QtQuick.Controls.Basic` and take every colour from `Theme`, so a user's theme
applies. The phone's own chrome imports `QtQuick.Controls.Material` for the platform's touch
behaviour, and `MobileShell.qml` is the one place that hands the Theme's colours to Material.
Two traps:

- Whichever style a QML file imports first becomes the run-time style, which sets every control's
  starting font and palette. `main.cpp` pins it to Basic so the bricks look as they do on the
  desktop whatever the root imports.
- Material draws its filled buttons, tool bar, dialogs and menus through layer effects that the
  software renderer leaves out, so they are invisible in `--screenshot` and in the tests. The
  phone's surfaces are drawn from Theme roles for that reason.

`QtQuick.Controls.Native`, which imports the platform's style by one name, arrives in Qt 6.12.
When that is the oldest Qt the repo builds with, the Material imports become that one import, and
an iOS build gets the iOS style from the same files.

## What the phone build leaves out

- **The terminal.** `Ghostty` (qml-ghostty, a Zig build) is not built for Android. The bricks that
  import it load only where a layout instantiates them, so the phone's layout must not: that
  includes the first-run wizard, whose Agents step opens a terminal, and the Providers settings
  section. Until the wizard has a phone form, a phone paired with an MC that has no projects can
  show that MC but not set it up.
- **FFmpeg.** A Device tab's screen is decoded with FFmpeg loaded at run time, which Android does
  not have (`HAL_C2_HAS_FFMPEG`).
- **A user's own shell on iOS.** `ShellRuntime` loads `<config>/shell/shell.qml` when there is one,
  on Android too. App Store guideline 2.5.2 forbids an app running code it did not ship, so an iOS
  build has to compile that path out rather than leave it unreachable.

## What the QML compiler does for it

`qt_add_qml_module` already runs `qmlcachegen`, and a device only has the compiled-in QML, so
nothing is parsed or compiled at start. Of the bricks' bindings and functions, 40% compile to C++
(3341 of 8343, Qt 6.11.1); the rest stay bytecode. The largest causes are `var` data from
`Shell.state` (the view models are `QVariantMap`s), the `HalC2.Shell` singletons being registered
from C++ without type information, and ids used across delegate boundaries. Typing the three main
singletons would reach about 50%. Android runs the bytecode through the JIT; iOS has none, so the
share matters more there. `qmltc` is not an option while QML loads from disk for hot reload and
for a user's shell. Measure with the `all_aotstats` target.
