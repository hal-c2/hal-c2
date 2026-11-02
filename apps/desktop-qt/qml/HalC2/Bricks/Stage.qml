pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The stage: right-panel tabs brought into the thread's centre
// (Shell.state.panel.stage, RightPanelController's), in one to four panes
// laid out single, side by side, stacked or 2×2. Its strip lists its tabs and
// switches the layout; each pane's header moves its tab back to the side
// panel or closes it. A tab dragged onto a pane's edge splits the pane there,
// onto its middle takes its place; one dragged onto the side panel docks
// there. Bodies are borrowed from `bodies`, which the side panel shares, so a
// tab keeps what it loaded as it moves.
Rectangle {
    id: stage

    required property PanelBodies bodies
    readonly property var panel: Shell.state.panel ?? null
    readonly property var model: panel?.stage ?? null
    readonly property var tabs: model?.tabs ?? []
    readonly property var panes: model?.panes ?? []
    readonly property string layout: model?.layout ?? "single"
    readonly property int focusedPane: model?.focusedPane ?? 0
    // The timeline is put away (`stage.toggleFocus`).
    readonly property bool focusMode: model?.focus === true
    readonly property int columns: layout === "columns" || layout === "grid" ? 2 : 1
    readonly property int rows: layout === "rows" || layout === "grid" ? 2 : 1
    // Where the dividers between panes stand, as a share of the stage; a
    // double click puts one back in the middle.
    property real columnShare: 0.5
    property real rowShare: 0.5

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color accent: Theme.palette.color("accent", "#2563eb")
    readonly property color line: Theme.palette.color("border", "#27272a")

    function tabOf(id) {
        return tabs.find(tab => tab.id === id) ?? null;
    }

    objectName: "stage"
    color: Theme.palette.color("chrome", "#0b0b0d")
    clip: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Stage")

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // The strip: the stage's tabs, then the layouts and the timeline.
        Item {
            id: strip

            Layout.fillWidth: true
            Layout.preferredHeight: 36

            ListView {
                id: stripTabs

                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: controls.left
                anchors.top: parent.top
                height: 36
                orientation: ListView.Horizontal
                spacing: 2
                clip: true
                interactive: false
                model: stage.tabs

                WheelHandler {
                    onWheel: event => {
                        const delta = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y;
                        stripTabs.contentX = Math.max(stripTabs.originX, Math.min(stripTabs.originX + stripTabs.contentWidth - stripTabs.width, stripTabs.contentX - delta / 2));
                    }
                }

                delegate: AbstractButton {
                    id: tab

                    required property var modelData
                    readonly property bool focused: stage.panes[stage.focusedPane] === modelData.id
                    readonly property bool inPane: stage.panes.includes(modelData.id)
                    readonly property string iconName: PanelTabs.tabs[modelData.kind]?.icon ?? ""

                    objectName: "stageTab-" + modelData.id
                    width: tabRow.implicitWidth + 16
                    height: 36
                    hoverEnabled: true
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.title
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                    onClicked: Shell.dispatch("stage.show", {
                        id: tab.modelData.id
                    })
                    background: Rectangle {
                        color: tab.focused ? Theme.palette.color("surfaceRaised", "#1f1f24") : tab.hovered || tab.visualFocus ? Theme.palette.color("surface", "#141416") : "transparent"
                        radius: 6
                    }

                    PanelTabDrag {
                        anchors.fill: parent
                        bodies: stage.bodies
                        tabId: tab.modelData.id
                        title: tab.modelData.title
                        iconName: tab.iconName
                    }

                    Row {
                        id: tabRow

                        anchors.centerIn: parent
                        spacing: 6

                        ShellIcon {
                            visible: tab.iconName.length > 0
                            name: tab.iconName
                            size: 13
                            color: tab.inPane ? stage.foreground : stage.muted
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: tab.modelData.title
                            width: Math.min(implicitWidth, 112)
                            elide: Text.ElideRight
                            color: tab.inPane ? stage.foreground : stage.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        ShellButton {
                            objectName: "stageTabClose-" + tab.modelData.id
                            subtle: true
                            iconName: "x"
                            iconSize: 12
                            iconTint: stage.muted
                            width: 20
                            height: 20
                            padding: 4
                            Accessible.name: qsTr("Close %1").arg(tab.modelData.title)
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: Shell.dispatch("rightPanel.close", {
                                id: tab.modelData.id
                            })
                        }
                    }
                }
            }

            Row {
                id: controls

                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.top: parent.top
                height: 36
                spacing: 2

                Repeater {
                    model: [
                        {
                            layout: "single",
                            icon: "square",
                            name: qsTr("One pane")
                        },
                        {
                            layout: "columns",
                            icon: "columns-2",
                            name: qsTr("Panes side by side")
                        },
                        {
                            layout: "rows",
                            icon: "rows-2",
                            name: qsTr("Panes stacked")
                        },
                        {
                            layout: "grid",
                            icon: "layout-grid",
                            name: qsTr("Four panes")
                        }
                    ]

                    delegate: ShellButton {
                        id: layoutButton

                        required property var modelData
                        readonly property bool current: stage.layout === modelData.layout

                        objectName: "stageLayout-" + modelData.layout
                        subtle: true
                        width: 28
                        height: 28
                        anchors.verticalCenter: parent?.verticalCenter
                        iconName: modelData.icon
                        iconSize: 14
                        iconTint: current ? stage.foreground : stage.muted
                        checkable: false
                        Accessible.role: Accessible.RadioButton
                        Accessible.checked: current
                        Accessible.name: modelData.name
                        onClicked: Shell.dispatch("stage.layout", {
                            layout: layoutButton.modelData.layout
                        })

                        Rectangle {
                            z: -1
                            anchors.fill: parent
                            radius: 6
                            visible: layoutButton.current
                            color: Theme.palette.color("surfaceRaised", "#1f1f24")
                        }
                    }
                }

                Rectangle {
                    width: 1
                    height: 16
                    anchors.verticalCenter: parent.verticalCenter
                    color: stage.line
                }

                ShellButton {
                    objectName: "stageToggleTimeline"
                    subtle: true
                    width: 28
                    height: 28
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "message-square-text"
                    iconSize: 14
                    iconTint: stage.focusMode ? stage.muted : stage.foreground
                    Accessible.name: stage.focusMode ? qsTr("Show the timeline") : qsTr("Hide the timeline")
                    onClicked: Shell.dispatch("stage.toggleFocus")
                }

                ShellButton {
                    objectName: "stageDismiss"
                    subtle: true
                    width: 28
                    height: 28
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "panel-right"
                    iconSize: 14
                    iconTint: stage.muted
                    Accessible.name: qsTr("Move every tab to the side panel")
                    onClicked: Shell.dispatch("stage.dismiss")
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: stage.line
            }
        }

        Item {
            id: area

            readonly property real splitX: stage.columns === 2 ? Math.round(width * stage.columnShare) : width
            readonly property real splitY: stage.rows === 2 ? Math.round(height * stage.rowShare) : height

            Layout.fillWidth: true
            Layout.fillHeight: true

            // By count, so a pane (and the body it shows) stays as the stage changes.
            Repeater {
                model: stage.panes.length

                delegate: Rectangle {
                    id: pane

                    required property int index
                    readonly property string modelData: stage.panes[index] ?? ""
                    readonly property var tab: stage.tabOf(modelData)
                    readonly property int column: index % stage.columns
                    readonly property int row: Math.floor(index / stage.columns)
                    readonly property bool focused: index === stage.focusedPane
                    // The part of the pane a dragged tab would land in.
                    property string zone: ""

                    objectName: "stagePane-" + index
                    x: column === 0 ? 0 : area.splitX + 1
                    y: row === 0 ? 0 : area.splitY + 1
                    width: column === 0 ? area.splitX : area.width - area.splitX - 1
                    height: row === 0 ? area.splitY : area.height - area.splitY - 1
                    color: Theme.palette.color("canvas", "#0f0f12")
                    Accessible.role: Accessible.Pane
                    Accessible.name: tab ? tab.title : qsTr("Empty pane")

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // The pane's tab: dragged by its title, back to the
                        // side panel, or closed.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 30
                            visible: pane.tab !== null
                            color: Theme.palette.color("chrome", "#0b0b0d")

                            PanelTabDrag {
                                anchors.fill: parent
                                bodies: stage.bodies
                                tabId: pane.modelData
                                title: pane.tab?.title ?? ""
                                iconName: PanelTabs.tabs[pane.tab?.kind ?? ""]?.icon ?? ""
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 4
                                spacing: 6

                                ShellIcon {
                                    name: PanelTabs.tabs[pane.tab?.kind ?? ""]?.icon ?? ""
                                    size: 13
                                    color: pane.focused ? stage.foreground : stage.muted
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: pane.tab?.title ?? ""
                                    elide: Text.ElideRight
                                    color: pane.focused ? stage.foreground : stage.muted
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                ShellButton {
                                    objectName: "stagePaneDock-" + pane.index
                                    subtle: true
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    iconName: "panel-right"
                                    iconSize: 13
                                    iconTint: stage.muted
                                    Accessible.name: qsTr("Move %1 to the side panel").arg(pane.tab?.title ?? "")
                                    onClicked: Shell.dispatch("rightPanel.dock", {
                                        id: pane.modelData,
                                        dock: "panel"
                                    })
                                }

                                ShellButton {
                                    objectName: "stagePaneClose-" + pane.index
                                    subtle: true
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    iconName: "x"
                                    iconSize: 12
                                    iconTint: stage.muted
                                    Accessible.name: qsTr("Close %1").arg(pane.tab?.title ?? "")
                                    onClicked: Shell.dispatch("rightPanel.close", {
                                        id: pane.modelData
                                    })
                                }
                            }
                        }

                        PanelBodySlot {
                            objectName: "stageBodySlot-" + pane.index
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: pane.tab !== null
                            bodies: stage.bodies
                            tabId: pane.modelData
                        }

                        // An empty pane offers the tabs no pane shows.
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: pane.tab === null

                            Column {
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 32, 260)
                                spacing: 6

                                Text {
                                    width: parent.width
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.Wrap
                                    text: qsTr("Drag a tab here, or show one:")
                                    color: stage.muted
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                Repeater {
                                    model: (stage.panel?.tabs ?? []).filter(other => !stage.panes.includes(other.id))

                                    delegate: ShellButton {
                                        required property var modelData

                                        objectName: "stagePanePick-" + pane.index + "-" + modelData.id
                                        width: parent?.width ?? 0
                                        height: 28
                                        subtle: true
                                        text: modelData.title
                                        iconName: PanelTabs.tabs[modelData.kind]?.icon ?? ""
                                        onClicked: Shell.dispatch("rightPanel.dock", {
                                            id: modelData.id,
                                            dock: "stage",
                                            pane: pane.index
                                        })
                                    }
                                }
                            }
                        }
                    }

                    // A press anywhere in the pane focuses it, and still
                    // reaches what is under it.
                    Item {
                        anchors.fill: parent
                        z: 2

                        TapHandler {
                            gesturePolicy: TapHandler.DragThreshold
                            onPressedChanged: if (pressed && !pane.focused)
                                Shell.dispatch("stage.focusPane", {
                                    pane: pane.index
                                })
                        }
                    }

                    // The focused pane, when there are others.
                    Rectangle {
                        objectName: "stagePaneOutline-" + pane.index
                        anchors.fill: parent
                        z: 3
                        visible: pane.focused && stage.panes.length > 1
                        color: "transparent"
                        border.color: Qt.alpha(stage.accent, 0.7)
                        border.width: 1
                    }

                    DropArea {
                        anchors.fill: parent
                        z: 4
                        keys: ["hal-c2/panel-tab"]
                        enabled: stage.bodies.dragging.length > 0
                        onExited: pane.zone = ""
                        onPositionChanged: drag => {
                            const across = drag.x / width;
                            const down = drag.y / height;
                            pane.zone = across < 0.25 ? "left" : across > 0.75 ? "right" : down < 0.25 ? "top" : down > 0.75 ? "bottom" : "center";
                        }
                        onDropped: drop => {
                            const id = stage.bodies.dragging;
                            const zone = pane.zone.length > 0 ? pane.zone : "center";
                            pane.zone = "";
                            drop.accept();
                            // After the drag has let go of the tab it moves.
                            Qt.callLater(() => Shell.dispatch("rightPanel.dock", {
                                    id: id,
                                    dock: "stage",
                                    pane: pane.index,
                                    zone: zone
                                }));
                        }

                        Rectangle {
                            objectName: "stagePaneZone-" + pane.index
                            visible: pane.zone.length > 0
                            x: pane.zone === "right" ? parent.width / 2 : 0
                            y: pane.zone === "bottom" ? parent.height / 2 : 0
                            width: pane.zone === "left" || pane.zone === "right" ? parent.width / 2 : parent.width
                            height: pane.zone === "top" || pane.zone === "bottom" ? parent.height / 2 : parent.height
                            color: Qt.alpha(stage.accent, 0.14)
                            border.color: stage.accent
                        }
                    }
                }
            }

            // The dividers between panes: drag to resize, double click to even.
            Rectangle {
                objectName: "stageColumnDivider"
                visible: stage.columns === 2
                x: area.splitX
                width: 1
                height: area.height
                color: stage.line

                MouseArea {
                    anchors.centerIn: parent
                    width: 7
                    height: parent.height
                    cursorShape: Qt.SplitHCursor
                    preventStealing: true
                    onPositionChanged: mouse => {
                        if (pressed)
                            stage.columnShare = Math.max(0.15, Math.min(0.85, mapToItem(area, mouse.x, 0).x / area.width));
                    }
                    onDoubleClicked: stage.columnShare = 0.5
                }
            }

            Rectangle {
                objectName: "stageRowDivider"
                visible: stage.rows === 2
                y: area.splitY
                width: area.width
                height: 1
                color: stage.line

                MouseArea {
                    anchors.centerIn: parent
                    width: parent.width
                    height: 7
                    cursorShape: Qt.SplitVCursor
                    preventStealing: true
                    onPositionChanged: mouse => {
                        if (pressed)
                            stage.rowShare = Math.max(0.15, Math.min(0.85, mapToItem(area, 0, mouse.y).y / area.height));
                    }
                    onDoubleClicked: stage.rowShare = 0.5
                }
            }
        }
    }

    // With the side panel closed, a stage tab dragged to the stage's right
    // edge goes back to it.
    DropArea {
        id: dockDrop

        objectName: "stageDockDrop"
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: 36
        width: 48
        z: 5
        keys: ["hal-c2/panel-tab"]
        enabled: stage.bodies.dragging.length > 0 && stage.panel?.isOpen !== true && stage.tabOf(stage.bodies.dragging) !== null
        onDropped: drop => {
            const id = stage.bodies.dragging;
            drop.accept();
            Qt.callLater(() => Shell.dispatch("rightPanel.dock", {
                    id: id,
                    dock: "panel"
                }));
        }

        Rectangle {
            anchors.fill: parent
            visible: dockDrop.enabled
            color: Qt.alpha(stage.accent, dockDrop.containsDrag ? 0.28 : 0.1)
            border.color: stage.accent

            ShellIcon {
                anchors.centerIn: parent
                name: "panel-right"
                size: 16
                color: stage.foreground
            }
        }
    }
}
