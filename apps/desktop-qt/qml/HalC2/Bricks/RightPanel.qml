pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The right panel beside a thread: the tabs of Shell.state.panel (the Panel
// controller's) docked here rather than on the stage, each drawn by its
// kind's body (js/panelTabs.js) borrowed from `bodies`. Its left edge drags to
// resize it (a double click goes back to the default width); the layout keeps
// the thread room of its own (`maximumWidth`), or shows the panel over the
// thread where there is none (`resizable` off). "Open in centre" moves the
// shown tab to the stage, and a tab dragged from the stage docks back here.
Rectangle {
    id: panel

    readonly property var model: Shell.state.panel ?? null
    readonly property bool available: model !== null
    readonly property bool open: available && model.isOpen
    readonly property string activeId: open ? model.activeId : ""
    readonly property var activeTab: open ? (model.tabs.find(tab => tab.id === activeId) ?? null) : null
    // The tabs docked here; the rest are on the stage.
    readonly property var docked: open ? model.tabs.filter(tab => tab.dock !== "stage") : []
    // The bodies to show tabs with, shared with the stage: the window's
    // (ShellWindow.panelBodies) by default, else the panel's own.
    property PanelBodies bodies: (Window.window as ShellWindow)?.panelBodies ?? null
    readonly property PanelBodies pool: bodies ?? (ownBodies.item as PanelBodies)
    // The width the controller keeps, or the one being dragged to.
    property int dragWidth: -1
    readonly property int openWidth: Math.max(minimumWidth, Math.min(dragWidth >= 0 ? dragWidth : (model?.width ?? 540), maximumWidth))
    readonly property int minimumWidth: 360
    // What the layout can give it; set by the layout.
    property real maximumWidth: Infinity
    // Whether its left edge drags. A layout showing the panel over the thread
    // gives it a width of its own, which is not the one to remember.
    property bool resizable: true
    readonly property color foreground: Theme.palette.color("ink", "#f2f3f5")
    readonly property color muted: Theme.palette.color("inkTertiary", "#8b919e")
    // The tab strip's height, and the width of the closed panel's toggle.
    readonly property int stripHeight: Theme.control.xl

    // The tab being renamed in place (double-click its title), else "".
    property string editingId: ""

    // Whether the panel draws its own open/close button. A layout that puts
    // the toggle in the header strip (Workspace.panelToggle) turns this off,
    // and the closed panel then takes no width.
    property bool ownToggle: true
    // How much of the tab strip's right end the layout's window buttons cover.
    property real trailingInset: 0

    // Snaps by default: a width animation relays out the thread on every
    // frame. With Panel animations set, a toggle slides for that long
    // (model.transitionMs, none for a thread's own layout or reduced motion).
    readonly property int targetWidth: open ? openWidth : ownToggle ? stripHeight : 0
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
            Layout.preferredHeight: panel.stripHeight
            Layout.minimumHeight: panel.stripHeight
            Layout.maximumHeight: panel.stripHeight

            ShellButton {
                id: toggleButton
                subtle: true

                anchors.left: parent.left
                anchors.top: parent.top
                width: panel.stripHeight
                height: panel.stripHeight
                visible: panel.ownToggle
                iconName: panel.open ? "panel-right-close" : "panel-right"
                iconSize: Theme.icon.md
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
                    const index = panel.docked.findIndex(entry => entry.id === panel.activeId);
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
                anchors.leftMargin: panel.ownToggle ? panel.stripHeight : Theme.space.sm
                anchors.right: scrollButtons.visible ? scrollButtons.left : maximizeButton.visible ? maximizeButton.left : addButton.left
                anchors.top: parent.top
                height: panel.stripHeight
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
                spacing: Theme.space.xxs
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                // Scrolled by its buttons and the wheel: a drag moves a tab.
                interactive: false
                model: panel.docked

                WheelHandler {
                    onWheel: event => {
                        const delta = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y;
                        tabs.contentX = Math.max(tabs.originX, Math.min(tabs.originX + tabs.contentWidth - tabs.width, tabs.contentX - delta / 2));
                    }
                }

                delegate: AbstractButton {
                    id: tab

                    required property var modelData
                    objectName: "panelTab-" + modelData.id

                    readonly property bool active: panel.activeId === modelData.id
                    readonly property string iconName: PanelTabs.tabs[modelData.kind]?.icon ?? ""

                    width: tabRow.implicitWidth + Theme.space.lg
                    height: panel.stripHeight
                    hoverEnabled: true
                    ToolTip.visible: hovered && titleText.truncated
                    ToolTip.delay: 600
                    ToolTip.text: modelData.title
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.title
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                    onClicked: Shell.dispatch("rightPanel.activate", { id: tab.modelData.id })
                    // A pill inset in the strip; the shown tab is raised and outlined.
                    background: Rectangle {
                        anchors.fill: parent
                        anchors.topMargin: Theme.space.xs
                        anchors.bottomMargin: Theme.space.xs
                        color: tab.active ? Theme.palette.color("surfaceRaised", "#1f1f24") : tab.hovered ? Theme.palette.color("surfaceOverlay", "#1c1f25") : "transparent"
                        radius: Theme.radiusMd
                        border.width: tab.visualFocus || tab.active ? 1 : 0
                        border.color: tab.visualFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("border", "#262a31")
                    }

                    PanelTabDrag {
                        anchors.fill: parent
                        bodies: panel.pool
                        tabId: tab.modelData.id
                        title: tab.modelData.title
                        iconName: tab.iconName
                    }

                    Row {
                        id: tabRow

                        anchors.centerIn: parent
                        spacing: Theme.space.sm

                        ShellIcon {
                            visible: tab.iconName.length > 0
                            name: tab.iconName
                            size: Theme.icon.sm
                            color: tab.active ? panel.foreground : panel.muted
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            id: titleText

                            visible: panel.editingId !== tab.modelData.id
                            text: tab.modelData.title
                            width: Math.min(implicitWidth, 3.5 * Theme.space.xxl)
                            elide: Text.ElideRight
                            color: tab.active ? panel.foreground : panel.muted
                            font.pixelSize: Theme.type.meta.size
                            anchors.verticalCenter: parent.verticalCenter

                            TapHandler {
                                onDoubleTapped: {
                                    panel.editingId = tab.modelData.id;
                                    renameField.text = tab.modelData.title;
                                    renameField.forceActiveFocus();
                                    renameField.selectAll();
                                }
                            }
                        }

                        ShellTextField {
                            id: renameField

                            objectName: "panelRename-" + tab.modelData.id
                            visible: panel.editingId === tab.modelData.id
                            width: 3.5 * Theme.space.xxl
                            anchors.verticalCenter: parent.verticalCenter
                            property bool cancelled: false
                            onAccepted: {
                                Shell.dispatch("rightPanel.rename", {
                                    id: tab.modelData.id,
                                    title: text
                                });
                                panel.editingId = "";
                            }
                            onEditingFinished: {
                                if (panel.editingId === tab.modelData.id && !cancelled) {
                                    Shell.dispatch("rightPanel.rename", {
                                        id: tab.modelData.id,
                                        title: text
                                    });
                                }
                                cancelled = false;
                                if (panel.editingId === tab.modelData.id)
                                    panel.editingId = "";
                            }
                            Keys.onEscapePressed: {
                                cancelled = true;
                                panel.editingId = "";
                            }
                        }

                        ShellButton {
                            objectName: "panelClose-" + tab.modelData.id
                            subtle: true
                            iconName: "x"
                            iconSize: Theme.icon.sm
                            iconTint: panel.muted
                            width: Theme.icon.md + Theme.space.xs
                            height: Theme.icon.md + Theme.space.xs
                            padding: Theme.space.xs
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
                    width: Theme.control.md
                    height: panel.stripHeight
                    iconName: "chevron-left"
                    iconSize: Theme.icon.md
                    iconTint: panel.muted
                    enabled: !tabs.atXBeginning
                    Accessible.name: qsTr("Scroll tabs left")
                    onClicked: tabs.contentX = Math.max(tabs.originX, tabs.contentX - tabs.width / 2)
                }

                ShellButton {
                    objectName: "panelScrollRight"
                    subtle: true
                    width: Theme.control.md
                    height: panel.stripHeight
                    iconName: "chevron-right"
                    iconSize: Theme.icon.md
                    iconTint: panel.muted
                    enabled: !tabs.atXEnd
                    Accessible.name: qsTr("Scroll tabs right")
                    onClicked: tabs.contentX = Math.min(tabs.originX + tabs.contentWidth - tabs.width, tabs.contentX + tabs.width / 2)
                }
            }

            // Moves the shown tab to the stage, with the timeline put away.
            ShellButton {
                id: maximizeButton
                objectName: "panelMaximize"
                subtle: true

                anchors.right: addButton.left
                anchors.top: parent.top
                width: panel.stripHeight
                height: panel.stripHeight
                iconName: "panel-left-open"
                iconSize: Theme.icon.md
                iconTint: panel.muted
                visible: panel.open && panel.activeTab !== null
                Accessible.name: qsTr("Open in centre")
                onClicked: Shell.dispatch("rightPanel.dock", {
                    id: panel.activeId,
                    dock: "stage",
                    focus: true
                })
            }

            ShellButton {
                id: addButton
                subtle: true

                anchors.right: parent.right
                anchors.rightMargin: panel.trailingInset
                anchors.top: parent.top
                width: panel.stripHeight
                height: panel.stripHeight
                leftPadding: Theme.space.sm
                rightPadding: Theme.space.sm
                iconName: "plus"
                iconSize: Theme.icon.md
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

        // The shown tab's body, kept while another tab shows (PanelBodies).
        PanelBodySlot {
            objectName: "panelBodySlot"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: panel.open
            bodies: panel.pool
            tabId: panel.open ? panel.activeId : ""
        }
    }

    Loader {
        id: ownBodies

        active: panel.bodies === null
        sourceComponent: PanelBodies {}
    }

    // A tab dragged here from the stage docks back in the panel.
    DropArea {
        objectName: "panelDrop"
        anchors.fill: parent
        keys: ["hal-c2/panel-tab"]
        enabled: panel.open && panel.pool !== null && panel.pool.dragging.length > 0 && !panel.docked.some(tab => tab.id === panel.pool.dragging)
        onDropped: drop => {
            const id = panel.pool.dragging;
            drop.accept();
            // After the drag has let go of the tab it moves.
            Qt.callLater(() => Shell.dispatch("rightPanel.dock", {
                    id: id,
                    dock: "panel"
                }));
        }

        Rectangle {
            anchors.fill: parent
            visible: parent.containsDrag
            color: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.12)
            border.color: Theme.palette.color("accent", "#2563eb")
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
        visible: panel.open
        color: Theme.palette.color("border", "#27272a")
    }

    // The left edge: drag to resize, double click for the default width.
    // From the keyboard it is a Tab stop: the arrows move it, Enter puts the
    // default width back.
    MouseArea {
        id: edge
        objectName: "panelEdge"

        property real pressX: 0
        property int pressWidth: 0

        function step(by: int) {
            Shell.dispatch("rightPanel.resize", { width: Math.max(panel.minimumWidth, Math.min(panel.openWidth + by, panel.maximumWidth)) });
        }

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Theme.space.sm
        visible: panel.open && panel.resizable
        cursorShape: Qt.SplitHCursor
        preventStealing: true
        activeFocusOnTab: true
        Accessible.role: Accessible.Splitter
        Accessible.name: qsTr("Resize panel")
        Accessible.onPressAction: Shell.dispatch("rightPanel.resize", {})
        Keys.onLeftPressed: step(Theme.space.lg)
        Keys.onRightPressed: step(-Theme.space.lg)
        Keys.onReturnPressed: Shell.dispatch("rightPanel.resize", {})
        Keys.onEnterPressed: Shell.dispatch("rightPanel.resize", {})
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

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Theme.space.xxs
            visible: edge.activeFocus
            color: Theme.palette.color("focus", "#3b82f6")
        }
    }
}
