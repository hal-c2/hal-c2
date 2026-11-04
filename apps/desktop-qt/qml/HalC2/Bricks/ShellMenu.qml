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

    // Whether any row has an icon: then rows without one keep its column
    // empty, so every label starts at the same place.
    readonly property bool hasIcons: {
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i);
            if (item && ((item.iconName ?? "").length > 0 || (item.badge ?? null) !== null)) {
                return true;
            }
        }
        return false;
    }

    function widest() {
        let widest = 0;
        for (let i = 0; i < count; ++i) {
            widest = Math.max(widest, itemAt(i).implicitWidth);
        }
        return widest;
    }

    // The row a submenu is reached through.
    delegate: ShellMenuItem {}

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

    background: ShellPopoverSurface {}
}
