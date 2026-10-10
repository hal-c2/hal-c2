# HAL-C2 mobile (Qt)

The Android client for phones, tablets and laptops: the desktop's shell (`apps/desktop-qt`'s
`hal_c2_native` and its `HalC2.Bricks`) with a root of its own, `HalC2.Mobile`, which shows the
desktop's layout in a window with room for it and a phone layout below that
(`docs/internals/mobile-qt.md`). It is built for this machine, to work on the layouts, and for
Android arm64.

```sh
mise run mobile            # build for this machine and run it, its files in .hal-c2/mobile
mise run mobile:android    # build the APK; with one device or emulator attached, install and start it
```

`mise run mobile` passes its arguments on, so `mise run mobile -- --home-dir <dir>` moves its
files. The binary does not start on a desktop without `--home-dir`: the default HAL-C2 home there
is the installed desktop app's. `HAL_C2_MOBILE_SIZE=360x640` opens the development window at
another size than the root's 412x915; from 736x480 up it is the desktop's layout.

## Tests

```sh
mise run features:mobile   # build apps/mobile-qt/build/tests when needed, then ctest
```

`Features` runs the `@mobile` and `@shared` scenarios in the feature files `tests/tst_Features.cpp`
lists (`features/mobile/pairing-and-environments.feature` and five more) against the desktop
harness's fake MC, skipping `@backlog`, `@backlog-mobile`, `@dropped` and `@blocked`;
`HAL_C2_FEATURES="mobile/composer.feature"` narrows it, and `HAL_C2_BACKLOG=1` runs only the
backlog ones instead, to see what each still lacks (the task takes them as globs and `--backlog`).
`HAL_C2_SHOTS=<dir>` keeps what the window showed after each step.
Each scenario gets a device of its own: the app as `main.cpp` builds it (`src/MobileApp`), its real
root read from `qml/`, an empty home, and an MC that sells sessions for pairing links
(`tests/PairableMc.h`). It is a phone until a step gives the window another size
(`World::resize`), which is how a tablet, a rotation and a fold are told. Its steps live in
`tests/features/`, one self-registering file per domain, and act as a user does: a touch on the
item with the `objectName`, a mouse's click or drag there, keys into what has the keyboard, a
hardware keyboard's chord through the window's shortcuts, Android's Back. The Gherkin reader and
the step registry are the desktop runner's (`apps/desktop-qt/tests/native/features/Runner.h`).
`Pairing` is the pairing class by itself, with the links it must refuse, and `Scanner` the scanner.

No test opens a camera. The device's is one object (`src/ScanCamera.h`), and the tests put
`tests/FakeCamera.h` in its place: it scripts the user's answer to the system's question and
delivers a picture as an NV12 frame into the preview's own sink, where the scanner reads a real
camera's. The pictures are made with the desktop's encoder (`qr::image`), so a scenario goes from
a link to its code to the reader to a paired environment. A link that opens the app is followed
through `QDesktopServices`, as Qt for Android does it.

## Toolchain for Android

The desktop's requirements (`docs/internals/desktop-qt.md`, "Setup"), with this machine's Qt at
the same version as the one for Android, since its `androiddeployqt` and QML tools make the
package. Then:

```sh
uvx --from aqtinstall aqt install-qt all_os android 6.11.1 android_arm64_v8a -m qtwebsockets qtmultimedia -O ~/Qt
sdkmanager --install "ndk;27.2.12479018" "platforms;android-36" "system-images;android-34;default;arm64-v8a"
avdmanager create avd -n hal-c2-phone -k "system-images;android-34;default;arm64-v8a" -d pixel_7
```

`sdkmanager` and `avdmanager` come with Android Studio's command-line tools, and its bundled JDK
21 is the one Qt 6.11 wants. The system image and the AVD are only for the emulator
(`emulator -avd hal-c2-phone`). Qt Multimedia is the scanner's camera, and this machine's Qt needs
it too, for the tests and `mise run mobile` (Homebrew's `qt` has it); it adds about 106 MB to
`~/Qt`, most of it the FFmpeg backend the package leaves out.

`mise run mobile:android` finds these through `ANDROID_SDK_ROOT` (or `ANDROID_HOME`, default
`~/Library/Android/sdk`), `ANDROID_NDK_ROOT` (that SDK's `ndk/27.2.12479018`),
`QT_ANDROID_PREFIX` (`~/Qt/6.11.1/android_arm64_v8a`), `QT_HOST_PATH` (`qmake6`'s prefix, then
Homebrew's) and `JAVA_HOME` (Android Studio's JDK). They are read when `build/android` is first
configured; delete that directory to change them.

The terminal is the desktop's (qml-ghostty, `apps/desktop-qt/README.md`) and asks for nothing
more to be installed. Its libghostty-vt is built when a build directory is first configured, with
the Zig 0.15.2 and the Ghostty checkout in `~/.cache/qml-ghostty`; a machine that has neither
gets them there first (about two minutes in all). For Android the library is cross-built against
the NDK and kept in that cache as well, in `libghostty-vt-<revision>-aarch64-linux-android.<API
level>`, so only the first `build/android` on a machine builds it, in under a minute.
`cmake -DHAL_C2_TERMINAL=OFF apps/mobile-qt/build/android` (or `build/host`, `build/tests`) leaves
the terminal out of that build directory, also after a configure that stopped for want of Zig.

Two more things are made while the APK is, with what a Mac or a Linux machine set up for the
desktop already has:

- **OpenSSL**, which Qt for Android needs in the APK for `https` and `wss`, is built from its
  release tarball with the NDK when `build/android` is first configured
  (`cmake/AndroidOpenSsl.cmake`). That takes `perl` and `make`, a 53 MB download and about half a
  minute, once per machine: the two libraries are kept in `~/.cache/qt-android-openssl`.
- **The open source notices** the Settings page shows are written by Node during the build
  (`cmake/Licenses.cmake`) and compiled into the binary. It is the desktop's Node, 24 or later,
  and needs no `node_modules`; configuring stops with a sentence saying so when there is none. The
  first build fetches the license texts from GitHub into the repo's gitignored `.generated/`.

## Worth knowing

- The phone layout's chrome and the pairing screen (`qml/HalC2/Mobile`) import
  `QtQuick.Controls.Material` by name and the bricks import Basic. `main.cpp` pins the run-time style to Basic: without it the first style a
  QML file names becomes the run-time style, and with Material first the bricks' switches and spin
  boxes lose their colours. `MobileShell.qml` is the one file that names `Material.` properties.
- Material draws its raised surfaces (filled buttons, dialogs, menus, tool bars) through a layer
  effect, which the software scene graph of an offscreen run (`--screenshot`) leaves out. The
  chrome draws those surfaces itself (`MobileSurface`, `MobileBar`, `MobileButton`), so a
  screenshot shows what a device does. A control added here needs the same care.
- Offscreen screenshots can show a stray icon outside a list or popup: the software renderer
  does not clip a `Shape` (the bricks' `ShellIcon`) whose clip is empty. A device's GPU does.
- The phone layout's home is the thread list, so a window lands on a draft only while the
  desktop's layout shows: the root says which with `layout.desktop`, which `MobileApp` hands to
  `DraftController::setLandsOnDraft`.
- `MobileApp` turns `HAL_C2_HAS_TERMINAL` into `Terminals.supported`, the one thing the bricks
  and controllers ask before they offer or draw a terminal; a build without it offers none. Only
  the desktop's layout draws one, and opens one: the terminal wants a keyboard.
- The first APK build downloads Gradle and the Android Gradle plugin into `~/.gradle`, about
  600 MB.
- TLS on Android is the OpenSSL in the APK, 6.6 MB of it, built from the release pinned by version
  and hash in `cmake/AndroidOpenSsl.cmake`. It has to be a branch OpenSSL still supports, and Qt
  6.11 is built against 3.5; the notice in `third-party-licenses.config.json` names the version
  too. A phone reaches an MC over `https` and `wss`, so a new ABI needs its OpenSSL target there.
- What the APK ships has a notice tagged `mobile-qt` in `third-party-licenses.config.json`, and
  that is all the Settings page lists. A library, font or sound added to the package needs its
  entry there (`docs/internals/open-source-licenses.md`).
- `androiddeployqt` warns that three QML imports "could not be resolved": `HalC2.Shell` is
  registered from C++, and `HalC2.Bricks` and `Ghostty` (the terminal) are compiled into the
  binary.
- The C++ is compiled with `HAL_C2_HAS_TERMINAL` exactly when `Ghostty` is linked in
  (`cmake/Terminal.cmake`). In a build without it the bricks that import `Ghostty` do not load,
  so nothing may instantiate them there.
- The terminal's library is cross-built per ABI by `apps/desktop-qt/cmake/QmlGhosttyAndroid.cmake`,
  which names one Zig target for each: a new ABI needs its line there, as it needs its OpenSSL
  target. The terminal adds about 0.6 MB to the APK.
- A phone build has no FFmpeg, so a Device tab's screen says it is unavailable
  (`HAL_C2_HAS_FFMPEG` in `apps/desktop-qt/cmake/NativeShell.cmake`). That includes Qt
  Multimedia's FFmpeg backend: `cmake/Scanner.cmake` packages its Android backend alone, and the
  scanner adds 1.4 MB to the APK where both backends would add 10 MB.
- The scanner's reader is zxing-cpp, fetched at a pinned commit when a build directory is first
  configured and built with its QR reader only (`cmake/Scanner.cmake`).
- Gradle packages incrementally and leaves the room of files that went in the APK. To compare
  sizes, delete `build/android/android-build/build` and the APK and build again.
- A link opens the app from a shell with
  `adb shell am start -a android.intent.action.VIEW -d 'hal-c2://pair?pairingUrl=<the pairing
link, percent-encoded>'`, whether it is running or not.
- The emulator's back camera can look at a picture: start it with
  `-camera-back virtualscene -virtualscene-poster wall=<png>`, walk the camera to that wall with
  `adb emu automation play <sdk>/emulator/resources/macros/Walk_to_image_room`, and change the
  picture with `adb emu virtualscene-image wall <png>`, under a new file name each time (a name
  it has shown is not read again). From where the macro stops, the wall's left edge is out of
  the frame and a chair covers its bottom: a code drawn in the top right of the picture reads.
- The launcher icon's foreground (`android/res/mipmap-xxxhdpi/ic_launcher_foreground.png`) is
  rendered by `scripts/export-android-icons.ts` (`assets/README.md`); the monochrome layer beside
  it is not.
- The emulator refuses to start an Android 14 image with less than about 7.4 GB of free disk,
  whatever data partition size the AVD asks for.
- The app's own log lines carry the tag `default`:
  `adb logcat --pid="$(adb shell pidof io.github.halc2.mobile)"`.
