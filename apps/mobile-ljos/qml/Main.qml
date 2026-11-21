import Ljos.Blocks

// The phone's entry, as desktop-ljos's Main.qml is the desktop's: the
// user's layout, `<config>/shell.qml`, when there is one that loads,
// else the phone's built-in shell (HalC2.Mobile's MobileShell, the one
// window it makes of the bricks). The window shows the shell's Window,
// and a save of the user's file is applied with what the window holds
// kept (desktop-ljos's src/runtime.rs).
ShellLoader {
    objectName: "shellLoader"
    source: "shell.qml"
    fallback: "HalC2/Mobile/MobileShell.qml"
}
