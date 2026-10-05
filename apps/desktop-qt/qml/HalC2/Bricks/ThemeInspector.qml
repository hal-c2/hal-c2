import QtQuick
import HalC2.Shell

// Picks a colour off the app for the theme editor (Themes.inspecting): laid
// over the window, it takes the next click, finds what is drawn under it and
// hands its colour to Themes.pick. Escape stops without picking.
Item {
    id: inspector

    // The colour of the topmost thing drawn at a point of `under` (the
    // inspector's siblings): the item there, else the nearest one behind it
    // that paints a colour.
    function colorAt(x, y) {
        const siblings = inspector.parent.children;
        for (let index = siblings.length - 1; index >= 0; index -= 1) {
            const sibling = siblings[index];
            if (sibling === inspector || !sibling.visible || sibling.childAt === undefined) continue;
            const point = inspector.mapToItem(sibling, x, y);
            if (!sibling.contains(point)) continue;
            let item = sibling;
            let at = point;
            for (let child = item.childAt(at.x, at.y); child !== null; child = item.childAt(at.x, at.y)) {
                at = item.mapToItem(child, at.x, at.y);
                item = child;
            }
            for (let node = item; node; node = node.parent) {
                if (node.color !== undefined && node.color.a > 0) return node.color.toString();
            }
        }
        return "";
    }

    visible: Themes.inspecting
    focus: visible
    onVisibleChanged: if (visible) forceActiveFocus()
    Keys.onEscapePressed: Themes.inspecting = false

    MouseArea {
        objectName: "themeInspector"
        anchors.fill: parent
        cursorShape: Qt.CrossCursor
        onClicked: mouse => Themes.pick(inspector.colorAt(mouse.x, mouse.y))
    }
}
