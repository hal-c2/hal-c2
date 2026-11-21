import Ljos.Blocks

// Each window's root: the user's layout, `<config>/shell.qml`, when there is
// one that loads, else the built-in one desktop-qt loads by default
// (Bricks/DefaultShell.qml). The window shows the shell's Window, and a save
// of the user's file is applied with what the window holds kept
// (src/runtime.rs).
ShellLoader {
    objectName: "shellLoader"
    source: "shell.qml"
    fallback: "HalC2/Bricks/DefaultShell.qml"
}
