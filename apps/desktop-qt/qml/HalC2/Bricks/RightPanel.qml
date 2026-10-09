pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The right panel beside a thread: tabs from Shell.state.panel (the Panel
// controller's) and a native body for each kind js/panelTabs.js lists. Its
// left edge drags to resize it (a double click goes back to the default
// width); the layout keeps the thread room of its own (`maximumWidth`), shows
// the panel over the thread where there is none (`resizable` off), or hides
// the thread for a maximized panel.
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
    // Whether its left edge drags. A layout showing the panel over the thread
    // gives it a width of its own, which is not the one to remember.
    property bool resizable: true
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")

    // Whether the panel draws its own open/close button. A layout that puts
    // the toggle in the header strip (Workspace.panelToggle) turns this off,
    // and the closed panel then takes no width.
    property bool ownToggle: true
    // How much of the tab strip's right end the layout's window buttons cover.
    property real trailingInset: 0

    // Snaps by default: a width animation relays out the thread on every
    // frame. With Panel animations set, a toggle slides for that long
    // (model.transitionMs, none for a thread's own layout or reduced motion).
    readonly property int targetWidth: open ? openWidth : ownToggle ? 36 : 0
    property real shownWidth: targetWidth

    implicitWidth: shownWidth
    onTargetWidthChanged: {
        const duration = dragWidth < 0 ? (model?.transitionMs ?? 0) : 0;
        slide.stop();
        if (duration > 0) {
            slide.from = shownWidth;
            slide.to = targetWidth;
            slide.duration = duration;
            slide.start();
        } else {
            shownWidth = targetWidth;
        }
    }

    NumberAnimation {
        id: slide
        objectName: "panelSlide"

        target: panel
        property: "shownWidth"
        easing.type: Easing.OutCubic
    }
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

                // The room before the scroll buttons take any, so whether the
                // strip overflows does not depend on the buttons being shown.
                readonly property real fullWidth: (maximizeButton.visible ? maximizeButton.x : addButton.x) - x
                readonly property bool overflowing: contentWidth > fullWidth

                function showActive() {
                    const index = (panel.model?.tabs ?? []).findIndex(entry => entry.id === panel.activeId);
                    if (index < 0)
                        return;
                    positionViewAtIndex(index, ListView.Contain);
                    // The view guesses the size of tabs it has not built yet,
                    // so settle on the built tab's real edges.
                    const item = itemAtIndex(index);
                    if (!item)
                        return;
                    if (item.x < contentX)
                        contentX = item.x;
                    else if (item.x + item.width > contentX + width)
                        contentX = item.x + item.width - width;
                }

                anchors.left: parent.left
                anchors.leftMargin: panel.ownToggle ? 36 : 8
                anchors.right: scrollButtons.visible ? scrollButtons.left : maximizeButton.visible ? maximizeButton.left : addButton.left
                anchors.top: parent.top
                height: 36
                visible: panel.open
                onCountChanged: showActive()
                onWidthChanged: showActive()
                onContentWidthChanged: showActive()
                Connections {
                    target: panel
                    function onActiveIdChanged() {
                        tabs.showActive();
                    }
                }
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
                    ToolTip.visible: hovered && titleText.truncated
                    ToolTip.delay: 600
                    ToolTip.text: modelData.title
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
                            id: titleText

                            text: tab.modelData.title
                            width: Math.min(implicitWidth, 112)
                            elide: Text.ElideRight
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

            Row {
                id: scrollButtons

                objectName: "panelScrollTabs"
                anchors.right: maximizeButton.visible ? maximizeButton.left : addButton.left
                anchors.top: parent.top
                visible: panel.open && tabs.overflowing

                ShellButton {
                    objectName: "panelScrollLeft"
                    subtle: true
                    width: 28
                    height: 36
                    iconName: "chevron-left"
                    iconSize: 14
                    iconTint: panel.muted
                    enabled: !tabs.atXBeginning
                    Accessible.name: qsTr("Scroll tabs left")
                    onClicked: tabs.contentX = Math.max(tabs.originX, tabs.contentX - tabs.width / 2)
                }

                ShellButton {
                    objectName: "panelScrollRight"
                    subtle: true
                    width: 28
                    height: 36
                    iconName: "chevron-right"
                    iconSize: 14
                    iconTint: panel.muted
                    enabled: !tabs.atXEnd
                    Accessible.name: qsTr("Scroll tabs right")
                    onClicked: tabs.contentX = Math.min(tabs.originX + tabs.contentWidth - tabs.width, tabs.contentX + tabs.width / 2)
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
                anchors.rightMargin: panel.trailingInset
                anchors.top: parent.top
                width: 36
                height: 36
                leftPadding: 10
                rightPadding: 10
                iconName: "plus"
                iconSize: 16
                iconTint: panel.muted
                visible: panel.open
                objectName: "panelAdd"
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
                        reason: enabled ? "" : panel.model?.addReasons?.files ?? ""
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
                        // Not offered by a build without a terminal.
                        visible: Terminals.supported
                        height: visible ? implicitHeight : 0
                        enabled: panel.open && panel.model.canAdd.terminal === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "terminal"
                        })
                    }

                    ShellMenuItem {
                        objectName: "panelAddPullRequests"
                        text: qsTr("Pull requests")
                        iconName: "link-2"
                        enabled: panel.open && panel.model.canAdd.pullRequests === true
                        reason: enabled ? "" : panel.model?.addReasons?.pullRequests ?? ""
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "pull-requests"
                        })
                    }

                    ShellMenuItem {
                        objectName: "panelAddPullRequest"
                        text: qsTr("Pull request review")
                        iconName: "git-pull-request-arrow"
                        enabled: panel.open && panel.model.canAdd.pullRequest === true
                        reason: enabled ? "" : panel.model?.addReasons?.pullRequest ?? ""
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "pull-request"
                        })
                    }

                    // An empty browser tab on the MC, filled from the Previews tab.
                    ShellMenuItem {
                        objectName: "panelAddBrowser"
                        text: qsTr("Browser tab")
                        iconName: "globe"
                        enabled: panel.open && panel.model.canAdd.previews === true
                        onTriggered: Shell.dispatch("rightPanel.add", {
                            kind: "browser"
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

    // The panel's leading edge, so it reads apart from the thread in themes
    // where `chrome` and `canvas` match.
    Rectangle {
        objectName: "panelBorder"

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        visible: panel.open && !panel.maximized
        color: Theme.palette.color("border", "#27272a")
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
        visible: panel.open && !panel.maximized && panel.resizable
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
