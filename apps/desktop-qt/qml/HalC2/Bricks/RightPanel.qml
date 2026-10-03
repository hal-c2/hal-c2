import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The right panel beside a thread: tabs from Shell.state.panel (the Panel
// controller's) and a native body for each kind js/panelTabs.js lists. Its
// left edge drags to resize it (a double click goes back to the default
// width); the layout keeps the thread `minimumSiblingWidth` of room unless
// the panel is maximized, when the layout hides the thread instead.
Rectangle {
    id: panel

    readonly property var model: Shell.state.panel ?? null
    readonly property bool available: model !== null
    readonly property bool open: available && model.isOpen
    readonly property string activeId: open ? model.activeId : ""
    readonly property var activeTab: open ? (model.tabs.find(tab => tab.id === activeId) ?? null) : null
    readonly property bool maximized: open && model.maximized === true
    // The width the controller keeps, or the one being dragged to.
    property int dragWidth: -1
    readonly property int openWidth: Math.max(minimumWidth, Math.min(dragWidth >= 0 ? dragWidth : (model?.width ?? 540), maximumWidth))
    readonly property int minimumWidth: 360
    // What the layout can give it; set by the layout.
    property real maximumWidth: Infinity
    // Whether the layout hides the thread for a maximized panel
    // (`maximized`); only then is filling the window offered.
    property bool canMaximize: false
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")

    // Whether the panel draws its own open/close button. A layout that puts
    // the toggle in the header strip (Workspace.panelToggle) turns this off,
    // and the closed panel then takes no width.
    property bool ownToggle: true

    // Not animated: a width animation relays out the thread on every frame.
    implicitWidth: open ? openWidth : ownToggle ? 36 : 0
    color: Theme.palette.color("chrome", "#0b0b0d")
    clip: true

    ColumnLayout {
        id: column

        anchors.fill: parent
        spacing: 0

        Item {
            id: header

            Layout.fillWidth: true
            Layout.preferredHeight: 36
            Layout.minimumHeight: 36
            Layout.maximumHeight: 36

            ShellButton {
                id: toggleButton
                subtle: true

                anchors.left: parent.left
                anchors.top: parent.top
                width: 36
                height: 36
                visible: panel.ownToggle
                iconName: panel.open ? "panel-right-close" : "panel-right"
                iconSize: 16
                iconTint: panel.muted
                enabled: panel.available
                Accessible.name: panel.open ? qsTr("Close panel") : qsTr("Open panel")
                onClicked: Shell.dispatch("rightPanel.toggle")
            }

            ListView {
                id: tabs

                anchors.left: parent.left
                anchors.leftMargin: panel.ownToggle ? 36 : 8
                anchors.right: maximizeButton.visible ? maximizeButton.left : addButton.left
                anchors.top: parent.top
                height: 36
                visible: panel.open
                orientation: ListView.Horizontal
                spacing: 2
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: panel.open ? panel.model.tabs : []

                delegate: AbstractButton {
                    id: tab

                    required property var modelData
                    objectName: "panelTab-" + modelData.id

                    readonly property bool active: panel.activeId === modelData.id
                    readonly property string iconName: PanelTabs.tabs[modelData.kind]?.icon ?? ""

                    width: tabRow.implicitWidth + 16
                    height: 36
                    hoverEnabled: true
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.title
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                    onClicked: Shell.dispatch("rightPanel.activate", { id: tab.modelData.id })
                    background: Rectangle {
                        color: tab.active ? Theme.palette.color("surfaceRaised", "#1f1f24") : tab.hovered || tab.visualFocus ? Theme.palette.color("surface", "#141416") : "transparent"
                        radius: 6
                    }

                    Row {
                        id: tabRow

                        anchors.centerIn: parent
                        spacing: 6

                        ShellIcon {
                            visible: tab.iconName.length > 0
                            name: tab.iconName
                            size: 13
                            color: tab.active ? panel.foreground : panel.muted
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: tab.modelData.title
                            color: tab.active ? panel.foreground : panel.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        ShellButton {
                            objectName: "panelClose-" + tab.modelData.id
                            subtle: true
                            iconName: "x"
                            iconSize: 12
                            iconTint: panel.muted
                            width: 20
                            height: 20
                            padding: 4
                            Accessible.name: qsTr("Close %1").arg(tab.modelData.title)
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: Shell.dispatch("rightPanel.close", { id: tab.modelData.id })
                        }
                    }
                }
            }

            ShellButton {
                id: maximizeButton
                objectName: "panelMaximize"
                subtle: true

                anchors.right: addButton.left
                anchors.top: parent.top
                width: 36
                height: 36
                iconName: panel.maximized ? "minimize-2" : "maximize-2"
                iconSize: 14
                iconTint: panel.muted
                visible: panel.open && panel.canMaximize
                Accessible.name: panel.maximized ? qsTr("Show the thread beside the panel") : qsTr("Fill the window")
                onClicked: Shell.dispatch("rightPanel.toggleMaximized")
            }

            ShellButton {
                id: addButton
                subtle: true

                anchors.right: parent.right
                anchors.top: parent.top
                width: 36
                height: 36
                leftPadding: 10
                rightPadding: 10
                iconName: "plus"
                iconSize: 16
                iconTint: panel.muted
                visible: panel.open
                Accessible.name: qsTr("Add panel")
                onClicked: addMenu.open()

                ShellMenu {
                    id: addMenu

                    y: parent.height

                    ShellMenuItem {
                        text: qsTr("Diff")
                        iconName: "file-diff"
                        enabled: panel.open && panel.model.canAdd.diff
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "diff"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Files")
                        iconName: "files"
                        enabled: panel.open && panel.model.canAdd.files
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "files"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Agents")
                        iconName: "bot"
                        enabled: panel.open && panel.model.canAdd.agents === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "agents"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Terminal")
                        iconName: "terminal"
                        enabled: panel.open && panel.model.canAdd.terminal === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "terminal"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Pull requests")
                        iconName: "git-pull-request"
                        enabled: panel.open && panel.model.canAdd.pullRequests === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "pull-requests"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Pull request review")
                        iconName: "git-pull-request"
                        enabled: panel.open && panel.model.canAdd.pullRequest === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "pull-request"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Previews")
                        iconName: "monitor"
                        enabled: panel.open && panel.model.canAdd.previews === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "previews"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Device")
                        iconName: "smartphone"
                        enabled: panel.open && panel.model.canAdd.device === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "device"
                        })
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: panel.open

            // A native tab's body is made the first time it shows and kept,
            // hidden, while another tab shows, so it keeps its scroll and what
            // it loaded.
            Repeater {
                model: Object.keys(PanelTabs.tabs)

                delegate: Loader {
                    id: nativeBody

                    required property string modelData
                    readonly property var tab: PanelTabs.tabs[modelData]
                    readonly property bool shown: panel.activeTab !== null && panel.activeTab.kind === modelData

                    objectName: "panelBody-" + modelData
                    anchors.fill: parent
                    active: false
                    visible: shown
                    onShownChanged: if (shown)
                        active = true
                    Component.onCompleted: {
                        setSource(Qt.resolvedUrl(tab.brick + ".qml"), {
                            source: Qt.binding(() => nativeBody.tab.source ? Panel[nativeBody.tab.source] : null)
                        });
                        active = shown;
                    }
                }
            }
        }
    }

    // The left edge: drag to resize, double click for the default width.
    MouseArea {
        id: edge
        objectName: "panelEdge"

        property real pressX: 0
        property int pressWidth: 0

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 6
        visible: panel.open && !panel.maximized
        cursorShape: Qt.SplitHCursor
        preventStealing: true
        onPressed: mouse => {
            pressX = mapToItem(panel.parent, mouse.x, 0).x;
            pressWidth = panel.openWidth;
        }
        onPositionChanged: mouse => {
            if (pressed)
                panel.dragWidth = Math.round(pressWidth + pressX - mapToItem(panel.parent, mouse.x, 0).x);
        }
        onReleased: {
            const width = panel.openWidth;
            panel.dragWidth = -1;
            if (width !== (panel.model?.width ?? -1))
                Shell.dispatch("rightPanel.resize", { width: width });
        }
        onCanceled: panel.dragWidth = -1
        onDoubleClicked: Shell.dispatch("rightPanel.resize", {})
    }
}
