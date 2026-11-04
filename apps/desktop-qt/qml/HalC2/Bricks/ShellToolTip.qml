import QtQuick
import HalC2.Shell

// The one look of the app's tooltips. ShellWindow hands it the engine's
// shared attached tooltip (`ToolTip.toolTip`), so `ToolTip.text` on any
// control draws on the popover surface whatever the Controls style: the
// overlay fill (solid), a strong hairline, the meta type step and a small
// radius. It shows and hides at once.
Item {
    id: look

    // The ToolTip to dress: the shared instance attached tooltips use.
    property var tip: null

    // Held in properties, not children: a popup adopts a background or
    // content item only when it has no visual parent yet, and this Item is
    // hidden.
    readonly property Item surface: Rectangle {
        readonly property color overlay: Theme.palette.color("surfaceOverlay", "#22262e")

        objectName: "toolTipSurface"
        radius: Theme.radiusSm
        // Solid whatever the glass opacity: a tip is read over anything.
        color: Qt.rgba(overlay.r, overlay.g, overlay.b, 1)
        border.color: Theme.palette.color("borderStrong", "#343a44")
        border.width: 1
    }

    readonly property Item label: Text {
        objectName: "toolTipLabel"
        text: look.tip ? look.tip.text : ""
        color: Theme.palette.color("ink", "#e4e4e7")
        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
        font.pixelSize: Theme.type.meta.size
        lineHeight: Theme.type.meta.lineHeight
        lineHeightMode: Text.FixedHeight
        wrapMode: Text.Wrap
    }

    visible: false

    Binding {
        when: look.tip !== null
        target: look.tip
        property: "background"
        value: look.surface
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "contentItem"
        value: look.label
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "topPadding"
        value: Theme.space.xs
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "bottomPadding"
        value: Theme.space.xs
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "leftPadding"
        value: Theme.space.sm
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "rightPadding"
        value: Theme.space.sm
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "enter"
        value: null
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "exit"
        value: null
    }
}
