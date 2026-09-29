import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The right panel beside a thread: tabs from Shell.state.panel (the Panel
// controller's), a native body for the kinds js/panelTabs.js lists, and for
// every other tab the app's embed route in a second web surface that shares
// the primary surface's session. Tab actions go to the controller, which
// tells the page what to show.
Rectangle {
    id: panel

    readonly property var model: Shell.state.panel ?? null
    readonly property bool available: model !== null
    readonly property bool open: available && model.isOpen
    readonly property string activeId: open ? model.activeId : ""
    readonly property var activeTab: open ? (model.tabs.find(tab => tab.id === activeId) ?? null) : null
    // The page draws the active tab: its embed shows.
    readonly property bool pageShown: activeTab !== null && !activeTab.native
    readonly property int openWidth: 520
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property url embedUrl: {
        if (!available) {
            return "";
        }
        const page = (Shell.pageUrl ?? "").toString();
        const origin = page.match(/^(https?:\/\/[^/]+)/);
        return origin ? origin[1] + model.embedPath : "";
    }

    // Whether the panel draws its own open/close button. A layout that puts
    // the toggle in the header strip (Workspace.panelToggle) turns this off,
    // and the closed panel then takes no width.
    property bool ownToggle: true

    // Not animated: the web surface between the panels would be resized (a
    // Chromium relayout and a new GPU surface) on every frame of it.
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
                anchors.right: addButton.left
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
                            font.pixelSize: 12
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
                        text: qsTr("Previews")
                        iconName: "monitor"
                        enabled: panel.open && panel.model.canAdd.previews === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "previews"
                        })
                    }

                    ShellMenuItem {
                        text: qsTr("Pull request review")
                        iconName: "git-pull-request"
                        enabled: panel.open && panel.model.canAdd.pullRequest
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "pull-request"
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
                    readonly property bool shown: panel.activeTab !== null && panel.activeTab.native && panel.activeTab.kind === modelData

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

            Loader {
                id: body

                // Once up, the document stays up: closing the panel, showing a
                // native tab or leaving the thread route (settings) hides it
                // instead of destroying the terminals and scroll state it holds.
                readonly property bool wanted: panel.pageShown && panel.embedUrl.toString().length > 0

                objectName: "panelPage"
                anchors.fill: parent
                active: false
                visible: panel.pageShown
                onWantedChanged: if (wanted)
                    active = true
                Component.onCompleted: if (wanted)
                    active = true

                // The document follows thread changes itself (halC2Shell.onState), so
                // the URL is only the starting point; rebinding it would reload.
                sourceComponent: WebSurface {
                    surfaceId: "rightPanel"
                    sleepsWhenHidden: true
                    // The panel's own radius rounds the document's corners too.
                    radius: panel.radius
                    Component.onCompleted: url = panel.embedUrl
                }
            }
        }
    }
}
