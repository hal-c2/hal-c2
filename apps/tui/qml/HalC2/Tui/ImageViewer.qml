import OpenTUI

// An image attachment open full size (`Shell.state.imageViewer`, null when
// closed): the image fitted inside the terminal with its aspect kept, over
// everything else. The timeline stays mounted underneath, so closing (Esc via
// the keymap, or a click) returns to the same scroll position.
Item {
    id: layer
    objectName: "imageViewerLayer"
    readonly property var viewer: Shell.state.imageViewer ?? null

    visible: viewer !== null
    position: "absolute"
    left: 0
    top: 0
    width: Shell.state.size.columns
    height: Shell.state.size.rows
    z: 110
    onMouseDown: if (layer.viewer) Qt.callLater(layer.close)

    function close() {
        Shell.dispatch("image.close")
    }

    Rectangle {
        objectName: "imageViewer"
        width: Shell.state.size.columns
        height: Shell.state.size.rows
        flexDirection: "column"
        alignItems: "center"
        border.width: 1
        border.style: "rounded"
        border.color: Theme.colors.accent
        color: Theme.colors.bg

        Item {
            width: Math.max(1, Shell.state.size.columns - 4)
            height: 1
            flexDirection: "row"
            justifyContent: "space-between"

            Text {
                flexShrink: 1
                wrapMode: "none"
                text: layer.viewer ? layer.viewer.title : ""
            }
            Text {
                flexShrink: 0
                text: layer.viewer ? layer.viewer.hint : ""
                color: Theme.colors.dim
            }
        }
        Item {
            flexGrow: 1
            alignItems: "center"
            justifyContent: "center"

            Image {
                objectName: "imageViewerImage"
                width: layer.viewer ? layer.viewer.columns : 0
                height: layer.viewer ? layer.viewer.rows : 0
                fit: "fill"
                protocol: "kitty"
                source: layer.viewer ? layer.viewer.source : null
            }
        }
    }
}
