pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A select: the composer's ghost pickers by default
// (icon, muted label, chevron), `outline: true` for a bordered field.
// The popup marks the current value with a check and the row the keyboard is
// on (`highlighted`) with the hover fill; `markCurrent: false` leaves the
// current value unmarked.
// `disabledRows` greys out the rows at those indexes in the popup; keys can still
// reach them, so `onActivated` should refuse them too.
// `note` is a line above the rows, such as why none of them can be chosen.
// `rowAction` is a control at the end of each popup row, which reads its row as
// `parent.row`; pressing it neither chooses the row nor closes the popup.
ComboBox {
    id: control

    property bool outline: false
    property var disabledRows: []
    property string note: ""
    property bool markCurrent: true
    property Component rowAction: null
    property string iconName: ""
    property real iconSize: Theme.icon.md
    property real chevronSize: Theme.icon.sm
    // Rings only when the keyboard reaches it, never after a click.
    readonly property bool showFocusRing: control.visualFocus
    readonly property color accentSurface: Theme.palette.color("accentSurface", "#27272a")
    // The fill under the pointer and the label's colour; the composer's chips set their own.
    property color hoverFill: Qt.alpha(accentSurface, accentSurface.a * (outline ? 0.5 : 1))
    property color labelColor: control.hovered || control.down || control.popup.visible ? Theme.palette.color("text", "#e4e4e7") : Theme.palette.color("secondaryLabel", "#a1a1aa")

    implicitHeight: Theme.control.md
    leftPadding: iconName.length > 0 ? Theme.space.sm + iconSize + Theme.space.sm : Theme.space.sm
    rightPadding: Theme.space.sm + chevronSize + Theme.space.xs
    font.pixelSize: Theme.type.body.size
    font.weight: Font.Medium
    hoverEnabled: true
    opacity: enabled ? 1 : 0.64

    background: Rectangle {
        radius: Theme.radiusMd
        color: control.down || control.hovered || control.popup.visible ? control.hoverFill : control.outline ? Theme.palette.color("inputSurface", "#121317") : "transparent"
        border.color: control.showFocusRing ? Theme.palette.color("focus", "#3b82f6") : control.outline ? Theme.palette.color("input", "#27272a") : "transparent"
        border.width: control.outline || control.showFocusRing ? 1 : 0

        ShellIcon {
            x: Theme.space.sm
            y: (parent.height - height) / 2
            visible: control.iconName.length > 0
            name: control.iconName
            size: control.iconSize
            color: control.labelColor
        }
    }

    contentItem: Text {
        text: control.displayText
        font: control.font
        color: control.labelColor
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    indicator: ShellChevron {
        x: control.width - width - Theme.space.sm
        y: (control.height - height) / 2
        direction: "down"
        size: control.chevronSize
        color: Theme.palette.color("iconMuted", "#8b8b93")
    }

    delegate: ItemDelegate {
        id: item

        required property var model
        required property int index

        width: ListView.view.width
        height: Theme.control.md
        text: item.model[control.textRole] ?? item.model.modelData ?? item.model.display ?? ""
        readonly property bool selected: control.markCurrent && item.index === control.currentIndex

        enabled: !control.disabledRows.includes(item.index)
        highlighted: control.highlightedIndex === item.index
        opacity: enabled ? 1 : 0.5
        leftPadding: Theme.space.sm
        rightPadding: Theme.space.sm
        // No vertical padding: the label takes the whole row and centres on its fill.
        topPadding: 0
        bottomPadding: 0
        hoverEnabled: true

        Accessible.name: item.text
        Accessible.checkable: control.markCurrent
        Accessible.checked: item.selected

        contentItem: RowLayout {
            spacing: Theme.space.sm

            Text {
                text: item.text
                font.pixelSize: Theme.type.body.size
                color: Theme.palette.color("text", "#e4e4e7")
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            ShellIcon {
                objectName: "currentMark"
                visible: item.selected
                name: "check"
                size: Theme.icon.md
                color: Theme.palette.color("accentText", "#5b8cff")
                Layout.alignment: Qt.AlignVCenter
            }

            Loader {
                readonly property int row: item.index
                active: control.rowAction !== null
                visible: active
                sourceComponent: control.rowAction
                Layout.alignment: Qt.AlignVCenter
            }
        }

        background: Rectangle {
            // Nested in the popover: its corner less the popover's padding.
            radius: Math.max(0, Theme.radiusLg - Theme.space.xs)
            // The keyboard row and the pointer's read as one fill; the chosen
            // row carries only its check.
            color: item.highlighted || item.hovered ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
        }
    }

    popup: Popup {
        // Placed through the zoomed body: scaled about that corner, it draws
        // as the combo's child would.
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        // Opens upward when the window has no room below the combo, set as
        // it shows (the combo does not move while it is open).
        property bool upward: false
        y: upward ? -implicitHeight * scale - Theme.space.xs : control.height + Theme.space.xs
        onAboutToShow: upward = control.mapToItem(null, 0, control.height).y + implicitHeight * scale + Theme.space.xs > control.Window.height
        width: Math.max(control.width, control.note.length > 0 ? 280 : 160)
        // Whole rows, up to 320: a long list ends on a full row, with the
        // edge hint saying there is more.
        implicitHeight: Math.min(control.count, Math.floor((320 - 2 * padding) / Theme.control.md)) * Theme.control.md + 2 * padding + (rows.headerItem ? rows.headerItem.height : 0)
        padding: Theme.space.xs

        enter: Transition {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: 120
                easing.type: Easing.OutCubic
            }
        }

        // Closing is instant: a fade could swallow the next open.
        exit: null

        contentItem: ListView {
            id: rows

            objectName: "comboRows"
            clip: true
            // Counted, not measured: the rows exist only once the popup shows,
            // after `onAboutToShow` has chosen which way it opens.
            implicitHeight: control.count * Theme.control.md + (headerItem ? headerItem.height : 0)
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            boundsBehavior: Flickable.StopAtBounds
            header: control.note.length > 0 ? noteLine : null

            ShellScrollEdge {
                target: rows
            }
        }

        background: ShellPopoverSurface {}
    }

    Component {
        id: noteLine

        Text {
            objectName: "comboNote"
            width: ListView.view ? ListView.view.width : implicitWidth
            padding: Theme.space.sm
            text: control.note
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.caption.size
            color: Theme.palette.color("secondaryLabel", "#a1a1aa")
        }
    }
}
