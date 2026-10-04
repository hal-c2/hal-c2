import QtQml

// What a Plugin puts into the slot named `slot`: its one child, made once per
// PluginSlot of that name. A child declaring `property var slotData` is given
// the slot's data.
QtObject {
    property string slot: ""
    // The terminal client's ownership modes; a slot here always owns the item.
    property string mode: "host"
    default property Component delegate
}
