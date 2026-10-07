# Mobile (Qt) client

`apps/mobile-qt` is the Android client for phones, tablets and laptops, replacing the React Native
app in `apps/mobile`. How to build and run it is in its
[README](../../apps/mobile-qt/README.md). This page records why it is shaped the way it is.

## The desktop's shell with another root

It is not a second client. It compiles the desktop's `hal_c2_native` (the MC client, the store and
every controller) and `HalC2.Bricks` from `apps/desktop-qt`, and adds one QML module,
`HalC2.Mobile`, with a root of its own. A behaviour fixed in a controller or a brick is fixed on
both, which is what `@shared` in `features/` means.

So a brick must not learn about phones. Where this client needs a brick to behave differently,
the brick gets a property that defaults to what the desktop does (`ShellWindow.firstRunGate`,
`Sidebar.touchRows`), and the root sets it. The same holds for controllers
(`DraftController::setLandsOnDraft`).

## One root, two layouts

The root, `MobileShell.qml`, shows the pairing screen until there is an environment, and then one
of two layouts of the same bricks. Where the window has room it is the desktop's own,
[`DefaultLayout`](../../apps/desktop-qt/qml/HalC2/Bricks/DefaultLayout.qml), the item
`DefaultShell` fills its window with, so a tablet or a laptop gets the desktop client and not a
stretched phone. Below that it is the phone layout: one screen at a time, a back bar, and menus as
a sheet.

Room is the window's size, never the device's kind: a window is resized freely on a laptop, split
on a tablet, and changes when a foldable opens. The desktop's layout needs 736 by 480
density-independent pixels. 736 is its thread list beside its thread (`LayoutController`'s 256 and
480); under that width the list is cut off, on the desktop as well, so Android's medium width
class (from 600) is too early. 480 is Android's compact height class, which keeps a phone on its
side in the phone layout. The height is taken with the on-screen keyboard down, or typing on a
short tablet would swap the layout under the user.

Both layouts read the same `route` and the same controllers, and a brick hands what it holds to
its controller when it goes (`Composer` flushes its text), so the window changes layout mid-thread
without losing its place. What the phone layout turns off of the desktop's window follows the
layout in use rather than being set once: the first-run wizard, popup menus at the pointer, and
the two that live in C++, which the root reports with `layout.desktop` (`MobileApp`): landing on
a draft, and whether a thread has anywhere to show a terminal. The wizard has no phone form, so
in the phone layout a device paired with an MC that has no projects says where projects are
added and cannot set it up. Two things do not follow the layout:

- `Sidebar.touchRows` is on in both. A tablet's list is under a finger too, and a row so marked
  still lets a mouse arrange it by dragging.
- The connection notice is the root's in both, above the layout and inside the system's insets,
  which the window's own notice knows nothing of.

The environment and the way to forget it are a settings section, `PairingSettings`, listed only
where `pairing` is published. Settings open only once the MC has answered
(`NavigationController`), so the root offers the same way out beside the connection notice while
the connection is down: an environment that never comes back can still be forgotten.

## No host, so the phone pairs itself

The desktop gets its MC from a Node host process that starts or finds one. A phone runs neither
Node nor an MC, so [`Pairing`](../../apps/mobile-qt/src/Pairing.h) does the host's attach in C++:
it spends a pairing link's token on a session, keeps that session in the app's private storage,
and opens the shell's connection with it. The exchange itself is shared with the desktop's
`connection.pair` ([`PairingExchange`](../../apps/desktop-qt/src/native/PairingExchange.h)).

It remembers one environment. MCs cluster and share one sidebar, so one pairing already
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
applies. The phone layout's chrome and the pairing screen import `QtQuick.Controls.Material` for
the platform's touch behaviour, and `MobileShell.qml` is the one place that hands the Theme's
colours to Material.
Two traps:

- Whichever style a QML file imports first becomes the run-time style, which sets every control's
  starting font and palette. `main.cpp` pins it to Basic so the bricks look as they do on the
  desktop whatever the root imports.
- Material draws its filled buttons, tool bar, dialogs and menus through layer effects that the
  software renderer leaves out, so they are invisible in `--screenshot` and in the tests. The
  phone layout's surfaces are drawn from Theme roles for that reason.

`QtQuick.Controls.Native`, which imports the platform's style by one name, arrives in Qt 6.12.
When that is the oldest Qt the repo builds with, the Material imports become that one import, and
an iOS build gets the iOS style from the same files.

## The terminal is optional, and FFmpeg is absent

- **The terminal.** The terminal bricks draw with `Ghostty` (qml-ghostty, whose library is a Zig
  build), which is built for Android and for this machine unless `-DHAL_C2_TERMINAL=OFF`
  ([`cmake/Terminal.cmake`](../../apps/mobile-qt/cmake/Terminal.cmake)). A QML file that imports
  a module the binary lacks fails to load, and takes every file that names its type down with
  it, so a build without the module must never instantiate one. The switch is one fact,
  `Terminals.supported`: `MobileApp` clears it when `HAL_C2_HAS_TERMINAL` is not defined
  (`TerminalController::setSupported`), and then no thread has a place for a terminal, its
  commands are not registered, `DefaultLayout` does not load the drawer, and the two places that
  would open a sign-in terminal say that this build has none. A brick that would reach a
  terminal asks that one property and nothing else.
- **The terminal under a finger.** qml-ghostty's item does not raise the on-screen keyboard when
  tapped, takes a finger's drag for a selection rather than a scroll, and ignores the input
  method's composing text. It is for a device with a keyboard, which is why only the desktop's
  layout draws it, and why in the phone layout a thread has no place for one
  (`TerminalController::setDrawn`): the terminal's key would otherwise open a shell on the MC
  that nothing shows.
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
