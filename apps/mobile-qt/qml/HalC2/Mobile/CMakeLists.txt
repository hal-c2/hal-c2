# The phone's own QML: its root and the screens only a phone has. The qmldir is
# hand-written (no `prefer` line), as the bricks' is, so the directory works
# compiled into the binary and as a disk import path for hot reload.
qt_add_qml_module(hal_c2_mobile
  URI HalC2.Mobile
  VERSION 1.0
  STATIC
  NO_GENERATE_QMLDIR
  NO_PLUGIN_OPTIONAL
  QML_FILES
    HomeScreen.qml
    MobileBar.qml
    MobileButton.qml
    MobileIconButton.qml
    MobileMenu.qml
    MobileShell.qml
    MobileSurface.qml
    PairingScreen.qml
    RenameThreadDialog.qml
    ScanScreen.qml
    SettingsScreen.qml
    ThreadScreen.qml
  RESOURCES
    qmldir
)
