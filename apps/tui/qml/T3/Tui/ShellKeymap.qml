import OpenTUI

// The client's chords: one Keymap per input mode, bound from
// `Shell.state.keybindings.layers` (chord → host action). Only the layer of
// the current `Shell.state.mode` is live; the global layer (quit, back to the
// prompt) sits under it everywhere but the terminal drawer, which passes ^C to
// the shell. Plain typing and Enter reach a focused field first.
Item {
    id: keys
    readonly property var layers: Shell.state.keybindings.layers
    readonly property string mode: Shell.state.mode
    height: 0

    Keymap { priority: 1; enabled: keys.mode === "compose"; bindings: keys.layers.compose; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "terminal"; bindings: keys.layers.terminal; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "command"; bindings: keys.layers.command; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "select"; bindings: keys.layers.select; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "contextMenu"; bindings: keys.layers.contextMenu; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "diff"; bindings: keys.layers.diff; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "files"; bindings: keys.layers.files; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "settings"; bindings: keys.layers.settings; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "panel"; bindings: keys.layers.panel; onActivated: (action) => Shell.dispatch(action) }
    Keymap { priority: 1; enabled: keys.mode === "filter"; bindings: keys.layers.filter; onActivated: (action) => Shell.dispatch(action) }
    Keymap { enabled: keys.mode !== "terminal"; bindings: keys.layers.global; onActivated: (action) => Shell.dispatch(action) }
}
