import QtQuick
import QtQuick.Controls.Basic

// Stands in for QtQuick.Controls TreeViewDelegate: a row of a tree that is
// a ListView over visible rows (see TreeView.qml). The expand arrow and a
// double click toggle the folder; a click makes the row the current one of
// the view's selection model.
ItemDelegate {
    id: delegate

    required property int index
    required property int depth
    required property bool expanded
    required property bool hasChildren

    readonly property bool isTreeNode: true
    readonly property int row: index
    readonly property int column: 0
    readonly property real indentation: 16
    readonly property real indicatorWidth: 24
    readonly property var treeView: ListView.view
    readonly property bool current: treeView?.selectionModel?.currentIndex === index

    leftPadding: depth * indentation + indicatorWidth

    function toggle() {
        if (hasChildren && treeView?.model)
            treeView.model.toggleExpanded(index)
    }

    onClicked: treeView?.selectionModel?.setCurrentIndex(index, 0)
    onDoubleClicked: toggle()

    Text {
        x: delegate.depth * delegate.indentation
        width: delegate.indicatorWidth
        height: delegate.height
        visible: delegate.hasChildren
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: delegate.expanded ? "▾" : "▸"
        color: delegate.palette.text
        TapHandler { onTapped: delegate.toggle() }
    }
}
