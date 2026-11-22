import QtQuick

// Makes what it is in clickable, reachable by Tab, and named for screen readers.
MouseArea {
    id: touchable

    readonly property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property string name: ""
    property color ring: "#ffd84a"
    readonly property bool pointedAt: containsMouse || activeFocus

    signal activated

    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    hoverEnabled: true
    activeFocusOnTab: true
    cursorShape: Qt.PointingHandCursor
    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.onPressAction: activated()
    onClicked: activated()
    Keys.onReturnPressed: activated()
    Keys.onEnterPressed: activated()
    Keys.onSpacePressed: activated()
    onActiveFocusChanged: if (activeFocus) world?.reveal(touchable)

    Rectangle {
        visible: touchable.activeFocus
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: touchable.ring
    }
}
