import OpenTUI

// The open context menu (`Shell.state.contextMenu`, null when closed): a
// rounded faint box at the host-clamped position over everything else
// (ContextMenu.tsx). The pointer over an item highlights it, clicking runs it,
// clicking anywhere else dismisses the menu; the shell's keys move and choose
// (`contextMenu.move`, `contextMenu.select`).
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
        border.style: "rounded"
        border.color: Theme.colors.faint
        color: Theme.colors.bg
        flexDirection: "column"
        paddingX: 1
        overflow: "hidden"
        onMouseDown: (mouse) => { mouse.accepted = true }

        // Painted by the host (threadActions): the marker and label, or a divider.
        Repeater {
            model: layer.menu ? layer.menu.rows : []
            delegate: Rectangle {
                height: 1
                flexShrink: 0
                color: modelData.kind === "item" && modelData.active ? Theme.colors.selectedBg : Theme.colors.bg
                onMouseMove: if (modelData.kind === "item") Shell.dispatch("contextMenu.hover", { index: modelData.index })
                onMouseDown: (mouse) => {
                    mouse.accepted = true
                    if (modelData.kind === "item" && !modelData.disabled)
                        Shell.dispatch("contextMenu.select", { requestId: layer.menu.requestId, id: modelData.id })
                }
                Text {
                    flexGrow: 1
                    wrapMode: "none"
                    text: modelData.text
                }
            }
        }
    }
}
