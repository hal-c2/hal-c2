import OpenTUI

// The client's chords: one Keymap per input mode, bound from
// `Shell.state.keybindings.layers` (chord → host action). Only the layer of
// the current `Shell.state.mode` is live; the global layer (quit, back to the
// prompt) sits under it everywhere but the terminal drawer, which passes ^C to
// the shell. An action the host declines (`Shell.dispatch` is not true: no
// approval to walk, the terminal hidden) lets the key through to the next
// binding and then the focused field.
//
// The mode keymaps are unnamed, so a keymap.json top-level entry reaches every
// mode; the thread list's is named "list" and takes the file's "list" section.
Item {
    id: keys
    readonly property var layers: Shell.state.keybindings.layers
    readonly property string mode: Shell.state.mode
    height: 0

    function run(action, event) {
        // A held Esc repeats: the press closes the picker or page, and a repeat
        // landing on the prompt must not go on to clear the draft or stop the turn.
        if (event.isAutoRepeat && event.key === "escape") return
        if (Shell.dispatch(action) !== true) event.accepted = false
    }

    Keymap { priority: 1; enabled: keys.mode === "compose"; bindings: keys.layers.compose; onActivated: (action, event) => keys.run(action, event) }
    // The shortcuts the user gave the open thread's project actions.
    Keymap { enabled: keys.mode === "compose"; bindings: keys.layers.projectActions; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "newThread"; bindings: keys.layers.newThread; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "userInput"; bindings: keys.layers.userInput; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "revert"; bindings: keys.layers.revert; onActivated: (action, event) => keys.run(action, event) }
    Keymap { objectName: "terminalKeymap"; priority: 1; enabled: keys.mode === "terminal"; bindings: keys.layers.terminal; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "command"; bindings: keys.layers.command; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "select"; bindings: keys.layers.select; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "contextMenu"; bindings: keys.layers.contextMenu; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "rename"; bindings: keys.layers.rename; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "join"; bindings: keys.layers.join; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "confirmDelete"; bindings: keys.layers.confirmDelete; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "imagePreview"; bindings: keys.layers.imagePreview; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "diff"; bindings: keys.layers.diff; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "files"; bindings: keys.layers.files; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "settings"; bindings: keys.layers.settings; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "section"; bindings: keys.layers.section; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "sectionInput"; bindings: keys.layers.sectionInput; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "sectionConfirm"; bindings: keys.layers.sectionConfirm; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "panel"; bindings: keys.layers.panel; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "commit"; bindings: keys.layers.commit; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "project"; bindings: keys.layers.project; onActivated: (action, event) => keys.run(action, event) }
    Keymap { priority: 1; enabled: keys.mode === "filter"; bindings: keys.layers.filter; onActivated: (action, event) => keys.run(action, event) }
    Keymap {
        objectName: "listKeymap"
        name: "list"
        priority: 1
        enabled: keys.mode === "list"
        bindings: keys.layers.list
        readonly property var hostActions: ({ next: "thread.next", previous: "thread.previous", leave: "sidebar.list.blur" })
        onActivated: (action, event) => keys.run(hostActions[action] ?? action, event)
    }
    Keymap { objectName: "globalKeymap"; enabled: keys.mode !== "terminal"; bindings: keys.layers.global; onActivated: (action, event) => keys.run(action, event) }
}
