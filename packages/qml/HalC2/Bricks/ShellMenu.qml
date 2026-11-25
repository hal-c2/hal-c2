import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A popup menu on the popover surface; use ShellMenuItem for entries. It
// fades in like ShellPopover and is gone the moment it closes.
Menu {
    id: control

    padding: Theme.space.xs
    // Wide enough for its longest row, between 220 and 360.
    implicitWidth: Math.max(220, Math.min(360, widest() + leftPadding + rightPadding))
    // As tall as its rows, up to the window: a longer menu stops on a whole
    // row and scrolls, with the edge hint saying there is more. A menu that
    // fits never measures its rows, which are still being laid out while a
    // host adds them one by one.
    height: implicitHeight <= rows.room ? implicitHeight : fitted(rows.room)

    // Whether any row has an icon: then rows without one keep its column
    // empty, so every label starts at the same place.
    readonly property bool hasIcons: {
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i);
            if (item && (item.hasIcon ?? false)) {
                return true;
            }
        }
        return false;
    }

    // The height of the rows that fit whole in `room`, with the padding.
    function fitted(room) {
        let height = topPadding + bottomPadding;
        for (let i = 0; i < count; ++i) {
            const row = itemAt(i);
            const step = row ? row.height : 0;
            if (height + step > room)
                break;
            height += step;
        }
        return height;
    }

    function widest() {
        let widest = 0;
        for (let i = 0; i < count; ++i) {
            widest = Math.max(widest, itemAt(i).implicitWidth);
        }
        return widest;
    }

    // A submenu's current value, beside its title on the row that opens it
    // ("Reasoning   High ›").
    property string detail: ""

    // The row a submenu is reached through.
    delegate: ShellMenuItem {
        detail: subMenu?.detail ?? ""
    }

    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    exit: null

    // The style's list, with the edge hint for a menu longer than the window.
    contentItem: ListView {
        id: rows

        // The window's height, once the menu is in one.
        readonly property real room: Window.window ? Window.height : Number.MAX_VALUE

        objectName: "menuRows"
        implicitHeight: contentHeight
        model: control.contentModel
        interactive: Window.window ? contentHeight + control.topPadding + control.bottomPadding > control.height : false
        clip: true
        currentIndex: control.currentIndex
        boundsBehavior: Flickable.StopAtBounds

        ShellScrollEdge {
            target: rows
        }
    }

    background: ShellPopoverSurface {}
}
