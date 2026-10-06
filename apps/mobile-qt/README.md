# HAL-C2 mobile (Qt)

The phone and tablet client: the desktop's shell (`apps/desktop-qt`'s `hal_c2_native` and its
`HalC2.Bricks`) with a root of its own, `HalC2.Mobile`. It is built for this machine, to work on
the layout, and for Android arm64.

```sh
mise run mobile            # build for this machine and run it, its files in .hal-c2/mobile
mise run mobile:android    # build the APK; with one device or emulator attached, install and start it
```

`mise run mobile` passes its arguments on, so `mise run mobile -- --home-dir <dir>` moves its
files. The binary does not start on a desktop without `--home-dir`: the default HAL-C2 home there
is the installed desktop app's. `HAL_C2_MOBILE_SIZE=360x640` opens the development window at
another size than the root's 412x915.

## Tests

```sh
mise run features:mobile   # build apps/mobile-qt/build/tests when needed, then ctest
```

`Features` runs the `@mobile` and `@shared` scenarios in the feature files `tests/tst_Features.cpp`
lists (`features/mobile/pairing-and-environments.feature` and four more) against the desktop
harness's fake MC, skipping `@backlog`, `@backlog-mobile`, `@dropped` and `@blocked`;
`HAL_C2_FEATURES="mobile/composer.feature"` narrows it, and `HAL_C2_BACKLOG=1` runs only the
backlog ones instead, to see what each still lacks (the task takes them as globs and `--backlog`).
Each scenario gets a phone of its own: the app as `main.cpp` builds it (`src/MobileApp`), its real
root read from `qml/`, an empty home, and an MC that sells sessions for pairing links
(`tests/PairableMc.h`). Its steps live in `tests/features/`, one self-registering file per domain,
and act as a user does: a touch on the item with the `objectName`, keys into what has the
keyboard, Android's Back. The Gherkin reader and the step registry are the desktop runner's
(`apps/desktop-qt/tests/native/features/Runner.h`). `Pairing` is the pairing class by itself.

## Toolchain for Android

The desktop's requirements (`docs/internals/desktop-qt.md`, "Setup"), with this machine's Qt at
the same version as the one for Android, since its `androiddeployqt` and QML tools make the
package. Then:

```sh
uvx --from aqtinstall aqt install-qt all_os android 6.11.1 android_arm64_v8a -m qtwebsockets -O ~/Qt
sdkmanager --install "ndk;27.2.12479018" "platforms;android-36" "system-images;android-34;default;arm64-v8a"
avdmanager create avd -n hal-c2-phone -k "system-images;android-34;default;arm64-v8a" -d pixel_7
```

`sdkmanager` and `avdmanager` come with Android Studio's command-line tools, and its bundled JDK
21 is the one Qt 6.11 wants. The system image and the AVD are only for the emulator
(`emulator -avd hal-c2-phone`).

`mise run mobile:android` finds these through `ANDROID_SDK_ROOT` (or `ANDROID_HOME`, default
`~/Library/Android/sdk`), `ANDROID_NDK_ROOT` (that SDK's `ndk/27.2.12479018`),
`QT_ANDROID_PREFIX` (`~/Qt/6.11.1/android_arm64_v8a`), `QT_HOST_PATH` (`qmake6`'s prefix, then
Homebrew's) and `JAVA_HOME` (Android Studio's JDK). They are read when `build/android` is first
configured; delete that directory to change them.

## Worth knowing

- The phone's own chrome (`qml/HalC2/Mobile`) imports `QtQuick.Controls.Material` by name and the
  bricks import Basic. `main.cpp` pins the run-time style to Basic: without it the first style a
  QML file names becomes the run-time style, and with Material first the bricks' switches and spin
  boxes lose their colours. `MobileShell.qml` is the one file that names `Material.` properties.
- Material draws its raised surfaces (filled buttons, dialogs, menus, tool bars) through a layer
  effect, which the software scene graph of an offscreen run (`--screenshot`) leaves out. The
  chrome draws those surfaces itself (`MobileSurface`, `MobileBar`, `MobileButton`), so a
  screenshot shows what a device does. A control added here needs the same care.
- Offscreen screenshots can show a stray icon outside a list or popup: the software renderer
  does not clip a `Shape` (the bricks' `ShellIcon`) whose clip is empty. A device's GPU does.
- Home is the thread list, so `main.cpp` turns off the desktop's landing on a draft
  (`DraftController::setLandsOnDraft`).
- The first APK build downloads Gradle and the Android Gradle plugin into `~/.gradle`, about
  600 MB. Configuring downloads the two OpenSSL libraries the APK carries (5 MB).
- TLS on Android is that OpenSSL, pinned by hash in `cmake/AndroidPackage.cmake`. A phone reaches
  an MC over `https` and `wss`, so a new ABI needs its own pair there.
- `androiddeployqt` warns that three QML imports "could not be resolved": `HalC2.Shell` is
  registered from C++, `HalC2.Bricks` is compiled into the binary, and `Ghostty` (the terminal) is
  not part of the phone build. The bricks that import `Ghostty` load only where the layout
  instantiates them, which the phone's must not.
- A phone build has no FFmpeg, so a Device tab's screen says it is unavailable
  (`HAL_C2_HAS_FFMPEG` in `apps/desktop-qt/cmake/NativeShell.cmake`).
- The launcher icon is the legacy app's (`apps/mobile/assets/android-icon-*.png`, rendered by
  `scripts/export-android-icons.ts`), copied into the package when it is configured.
- The emulator refuses to start an Android 14 image with less than about 7.4 GB of free disk,
  whatever data partition size the AVD asks for.
- The app's own log lines carry the tag `default`:
  `adb logcat --pid="$(adb shell pidof io.github.halc2.mobile)"`.
