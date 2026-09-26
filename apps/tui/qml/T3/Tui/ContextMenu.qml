import OpenTUI

// The open context menu (`Shell.state.contextMenu`, null when closed): a
// bordered box at the host-clamped position over everything else. Clicking
// an item selects it, clicking anywhere else dismisses the menu; the shell's
// keys move and choose (`contextMenu.move`, `contextMenu.select`).
Item {
    id: layer
    objectName: "contextMenuLayer"
    readonly property var menu: Shell.state.contextMenu

    visible: menu !== null
    position: "absolute"
    left: 0
    top: 0
    width: Shell.state.size.columns
    height: Shell.state.size.rows
    z: 100
    onMouseDown: (mouse) => {
        if (layer.menu) Shell.dispatch("contextMenu.select", { requestId: layer.menu.requestId, id: null })
    }

    Rectangle {
        id: box
        objectName: "contextMenu"
        position: "absolute"
        left: layer.menu ? layer.menu.x : 0
        top: layer.menu ? layer.menu.y : 0
        width: layer.menu ? layer.menu.width : 0
        height: layer.menu ? layer.menu.height : 0
        border.width: 1
        border.color: Theme.colors.accent
        color: Theme.colors.bg
        flexDirection: "column"
        onMouseDown: (mouse) => { mouse.accepted = true }

        Repeater {
            model: layer.menu ? layer.menu.rows : []
            delegate: Item {
                height: 1
                flexDirection: "row"
                onMouseDown: (mouse) => {
                    mouse.accepted = true
                    if (modelData.kind === "item" && !modelData.disabled)
                        Shell.dispatch("contextMenu.select", { requestId: layer.menu.requestId, id: modelData.id })
                }
                Text {
                    flexGrow: 1
                    text: modelData.kind === "separator"
                        ? "─".repeat(Math.max(0, box.width - 2))
                        : (modelData.selected ? "▸ " : "  ") + modelData.label
                    color: modelData.kind === "separator" || modelData.disabled
                        ? Theme.colors.faint
                        : modelData.destructive ? Theme.colors.error
                        : modelData.selected ? Theme.colors.accent : Theme.colors.text
                }
            }
        }
    }
}
