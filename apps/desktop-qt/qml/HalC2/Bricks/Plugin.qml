import QtQml

// The root of a UI plugin file: its Contributions fill the shell's
// PluginSlots, and anything else it declares (a Timer, state) lives as long
// as the plugin is loaded. The same file runs in the terminal client, whose
// runtime names this module OpenTUI.
//
//   Plugin {
//       pluginId: "clock"
//       Contribution { slot: "statusbar"; Text { text: "12:00" } }
//   }
QtObject {
    // What the plugin is listed as; its file's name when empty.
    property string pluginId: ""
    // Lower comes first in a slot; plugins of one order keep load order.
    property int order: 0
    property string description: ""
    default property list<QtObject> contributions
}
