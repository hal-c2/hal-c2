import OpenTUI

// An image attachment open full size (ImageLightbox; `Shell.state.imageViewer`,
// null when closed): in the conversation pane's place, the image fitted with
// its aspect kept under a row naming it. The timeline stays mounted, so
// closing (Esc via the keymap, or a click) returns to the same scroll position.
Rectangle {
    id: layer
    objectName: "imageViewer"
    readonly property var viewer: Shell.state.imageViewer ?? null

    visible: viewer !== null
    flexDirection: "column"
    flexGrow: 1
    flexShrink: 1
    alignItems: "center"
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    onMouseDown: if (layer.viewer) Qt.callLater(layer.close)

    function close() {
        Shell.dispatch("image.close")
    }

    Item {
        width: Math.max(1, Shell.state.layout.chatWidth - 4)
        height: 1
        flexDirection: "row"
        justifyContent: "space-between"

        Text {
            objectName: "imageViewerTitle"
            flexShrink: 1
            wrapMode: "none"
            text: layer.viewer ? layer.viewer.title : ""
            color: Theme.colors.text
        }
        Text {
            objectName: "imageViewerHint"
            flexShrink: 0
            text: layer.viewer ? layer.viewer.hint : ""
            color: Theme.colors.dim
        }
    }
    Item {
        flexGrow: 1
        width: Math.max(1, Shell.state.layout.chatWidth - 2)
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
