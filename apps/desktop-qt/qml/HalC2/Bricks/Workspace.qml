pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The header strip: project / thread breadcrumb on the left, the run, open
// and git pills on the right, from Shell.state.workspace. Checkout mode and
// branch live under the Composer.
Rectangle {
    id: strip

    readonly property var model: Shell.state.workspace ?? null
    readonly property bool ready: model !== null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color projectColor: Theme.palette.color("projectForeground", muted)
    readonly property color iconMuted: Theme.palette.color("iconMuted", "#8b8b93")
    readonly property var preferredScript: {
        if (!ready || model.scripts.length === 0) {
            return null;
        }
        return model.scripts.find(script => script.id === model.preferredScriptId) ?? model.scripts[0];
    }

    // Set by the layout: whether the sidebar is collapsed. Null hides the
    // toggle; true shows it in the sidebar's place.
    property var sidebarToggle: null
    // Same for the right panel: null hides the toggle, otherwise whether the
    // panel is open. The header keeps this button next to the pills.
    property var panelToggle: null
    // Whether the thread details column shows, or null away from a thread.
    property var detailsToggle: null
    // The window, for a frameless shell: the strip is its drag handle and
    // carries the window buttons.
    property Window window: null
    readonly property bool framelessChrome: window !== null && Theme.frameless
    // Whether the strip carries the window buttons. A layout that draws them
    // once, in the window's corner, turns this off and says with
    // `trailingInset` how much of the strip's right end they cover.
    property bool windowControls: true
    property real trailingInset: 0
    // How the strip fits its items, decided by what they need rather than a
    // width, giving way in one order so the thread title is the last thing
    // cut: first the project segment of the breadcrumb goes whole
    // (`showProject`), then the pills show icons only (`compact`), then the
    // run and open pills fold into one overflow menu (`tight`; the thread
    // details offer them too), and only then does the title shorten. The
    // title, the git pill and the toggles always stay.
    readonly property real room: width - (sidebarToggle === true ? 52 : 20) - Math.max(20, trailingInset)
    readonly property bool hasScripts: ready && model.scripts.length > 0
    readonly property bool hasEditors: ready && model.editors.length > 0
    readonly property bool hasSshNote: ready && (model.noSshRoute ?? "") !== ""
    readonly property bool hasProject: ready && model.projectTitle !== null
    // The project segment: folder, name (at most 160) and the slash, each
    // with the gap before the next.
    readonly property real projectNeed: hasProject ? folderIcon.implicitWidth + Math.min(Math.ceil(projectLabel.implicitWidth), 160) + crumbSlash.implicitWidth + crumb.spacing * 3 : 0
    // Room the title keeps before anything else keeps its place: all of it,
    // up to about forty characters, so a long title still leaves a wide
    // window everything.
    readonly property real titleReserve: Math.min(titleSlot.implicitWidth, Theme.type.body.size * 24)
    // Room it keeps before the pills fold away: its start.
    readonly property real titleMinimum: Math.min(titleSlot.implicitWidth, 120)
    // The toggles and window buttons, whatever the level (each with the gap before it).
    readonly property real fixedNeed: [terminalToggle, detailsButton, panelButton, windowButtons].reduce((sum, item) => sum + (item.visible ? item.implicitWidth + item.Layout.leftMargin + rowSpacing : 0), 0)
    readonly property real rowSpacing: Theme.space.md
    readonly property real labelledPills: (hasScripts ? scriptsPill.fullWidth + rowSpacing : 0) + (hasSshNote ? sshNote.implicitWidth + rowSpacing : 0) + (hasEditors ? editorPill.fullWidth + rowSpacing : 0) + (gitPill.visible ? gitPill.fullWidth + rowSpacing : 0)
    readonly property real iconPills: (hasScripts ? scriptsPill.compactWidth + rowSpacing : 0) + (hasSshNote ? sshNote.implicitWidth + rowSpacing : 0) + (hasEditors ? editorPill.compactWidth + rowSpacing : 0) + (gitPill.visible ? gitPill.compactWidth + rowSpacing : 0)
    readonly property real fullNeed: projectNeed + labelledNeed
    readonly property real labelledNeed: titleReserve + fixedNeed + labelledPills
    readonly property real iconNeed: titleMinimum + fixedNeed + iconPills
    readonly property bool showProject: hasProject && fullNeed <= room
    readonly property bool compact: labelledNeed > room
    readonly property bool tight: iconNeed > room

    function beginRename() {
        if (strip.ready && !strip.model.isDraft) {
            titleSlot.startEditing();
        }
    }

    implicitHeight: Theme.headerHeight
    color: Theme.palette.color("canvas", "#0f0f12")
    // Never over the panel beside it.
    clip: true
    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Thread header")

    DragHandler {
        enabled: strip.framelessChrome
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onActiveChanged: if (active)
            strip.window.startSystemMove()
    }

    TapHandler {
        objectName: "titleTap"
        enabled: strip.framelessChrome
        // ljos-allow(focus-pointer-only): a double click on the title bar is the pointer's shortcut for the window controls' Maximize button, which the keyboard reaches
        onDoubleTapped: strip.window.visibility === Window.Maximized ? strip.window.showNormal() : strip.window.showMaximized()
    }

    ShellButton {
        x: Theme.space.md
        y: Theme.space.md
        subtle: true
        implicitHeight: Theme.control.md
        visible: strip.sidebarToggle === true
        iconName: "panel-left"
        iconSize: Theme.icon.md
        iconTint: strip.iconMuted
        Accessible.name: qsTr("Show sidebar")
        onClicked: Shell.dispatch("sidebar.toggle")
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: strip.sidebarToggle === true ? 52 : 20
        anchors.rightMargin: Math.max(20, strip.trailingInset)
        spacing: strip.rowSpacing

        // Breadcrumb: project / title.
        RowLayout {
            id: crumb

            Layout.fillWidth: true
            spacing: Theme.space.sm

            ShellIcon {
                id: folderIcon

                visible: strip.showProject
                name: "folder"
                size: 14
                color: strip.iconMuted
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                id: projectLabel
                objectName: "projectLabel"

                Layout.fillWidth: true
                Layout.minimumWidth: 24
                Layout.maximumWidth: Math.min(Math.ceil(implicitWidth), 160)
                visible: strip.showProject
                text: strip.ready ? (strip.model.projectTitle ?? "") : ""
                color: projectHover.hovered ? strip.foreground : strip.projectColor
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
                elide: Text.ElideRight
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("New thread in project")
                Accessible.onPressAction: Shell.dispatch("workspace.newThread")
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        Shell.dispatch("workspace.newThread");
                        event.accepted = true;
                    }
                }
                // The whole name of a project cut short.
                ToolTip.visible: projectHover.hovered && truncated
                ToolTip.delay: 500
                ToolTip.text: text

                HoverHandler {
                    id: projectHover

                    cursorShape: Qt.PointingHandCursor
                }

                // Tab's focus; a click does not take it.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    visible: projectLabel.activeFocus
                    color: "transparent"
                    radius: Theme.radiusXs
                    border.width: 1
                    border.color: Theme.palette.color("focus", "#3b82f6")
                }

                TapHandler {
                    onTapped: Shell.dispatch("workspace.newThread")
                }
            }

            Text {
                id: crumbSlash

                visible: strip.showProject
                text: "/"
                color: strip.iconMuted
                font.pixelSize: Theme.type.body.size
            }

            Item {
                id: titleSlot
                objectName: "titleSlot"

                property bool editing: false
                // The request already answered: one made before this strip
                // was (in a layout without one) is not its to answer.
                property int handledRenameRequest: 0

                Component.onCompleted: handledRenameRequest = strip.ready ? strip.model.renameRequestId : 0

                function openMenu() {
                    if (!strip.ready || strip.model.isDraft) {
                        return;
                    }
                    const p = titleSlot.mapToItem(null, 0, titleSlot.height + 4);
                    Shell.dispatch("workspace.titleMenu", {
                        x: p.x,
                        y: p.y
                    });
                }

                function startEditing() {
                    editing = true;
                    titleEditor.text = strip.model.threadTitle;
                    titleEditor.forceActiveFocus();
                    titleEditor.selectAll();
                }

                Layout.fillWidth: true
                // Room for a few letters of the title beside the chevron (40 px).
                Layout.minimumWidth: Math.min(Math.ceil(titleRow.implicitWidth), 40 + titleRow.spacing + 14)
                implicitHeight: Theme.control.md
                implicitWidth: titleRow.implicitWidth
                activeFocusOnTab: !editing && strip.ready && !strip.model.isDraft
                Accessible.role: Accessible.Button
                Accessible.name: threadLabel.text
                // A draft's title opens nothing.
                Accessible.focusable: activeFocusOnTab
                Accessible.onPressAction: openMenu()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        openMenu();
                        event.accepted = true;
                    }
                }
                // The whole title, which a narrow header cuts short.
                ToolTip.visible: titleHover.hovered && threadLabel.truncated
                ToolTip.delay: 500
                ToolTip.text: threadLabel.text

                Connections {
                    target: strip

                    function onModelChanged() {
                        if (strip.ready && strip.model.renameRequestId !== titleSlot.handledRenameRequest) {
                            titleSlot.handledRenameRequest = strip.model.renameRequestId;
                            if (strip.model.renameRequestId > 0) {
                                titleSlot.startEditing();
                            }
                        }
                    }
                }

                HoverHandler {
                    id: titleHover

                    enabled: !titleSlot.editing && strip.ready && !strip.model.isDraft
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    enabled: !titleSlot.editing
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onTapped: titleSlot.openMenu()
                    onDoubleTapped: {
                        if (strip.ready && !strip.model.isDraft) {
                            titleSlot.startEditing();
                        }
                    }
                }

                Rectangle {
                    x: -4
                    width: titleRow.width + 8
                    height: parent.height
                    visible: titleSlot.activeFocus
                    color: "transparent"
                    radius: Theme.radiusXs
                    border.width: 1
                    border.color: Theme.palette.color("focus", "#3b82f6")
                }

                RowLayout {
                    id: titleRow

                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    // Layouts use whole pixels; rounding down a fractional
                    // text width would elide a title that actually fits.
                    width: Math.min(Math.ceil(implicitWidth), parent.width)
                    visible: !titleSlot.editing
                    spacing: 4

                    Text {
                        id: threadLabel
                        objectName: "threadLabel"
                        Layout.fillWidth: true
                        Layout.maximumWidth: Math.ceil(implicitWidth)
                        text: strip.ready ? strip.model.threadTitle : qsTr("No thread")
                        color: strip.foreground
                        font.pixelSize: Theme.type.body.size
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }

                    ShellChevron {
                        direction: "down"
                        size: Theme.icon.sm
                        color: strip.muted
                        opacity: titleHover.hovered ? 1 : 0
                        Layout.alignment: Qt.AlignVCenter

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 120
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }

                ShellTextField {
                    id: titleEditor

                    anchors.fill: parent
                    visible: titleSlot.editing
                    font.pixelSize: Theme.type.body.size
                    font.weight: Font.Medium
                    onAccepted: {
                        titleSlot.editing = false;
                        Shell.dispatch("workspace.rename", {
                            title: text
                        });
                    }
                    Keys.onEscapePressed: titleSlot.editing = false
                    onActiveFocusChanged: if (!activeFocus && titleSlot.editing) {
                        titleSlot.editing = false;
                    }
                }
            }

            // The thread's environment is unreachable; the header stays, and
            // says so until the environment comes back.
            Text {
                objectName: "offlineLabel"
                visible: strip.ready && strip.model.offline === true
                text: qsTr("Offline")
                color: strip.muted
                font.pixelSize: Theme.type.meta.size
                font.weight: Font.Medium
                Layout.alignment: Qt.AlignVCenter
            }
        }

        ShellSplitButton {
            id: scriptsPill
            objectName: "runActionButton"

            visible: strip.hasScripts && !strip.tight
            compact: strip.compact
            iconName: "play"
            text: strip.preferredScript ? qsTr("Run %1").arg(strip.preferredScript.name) : ""
            onClicked: Shell.dispatch("workspace.runScript", {
                scriptId: strip.preferredScript.id
            })
            onMenuRequested: scriptsMenu.open()

            ShellMenu {
                id: scriptsMenu

                y: parent.height + 4
                x: parent.width - width

                Instantiator {
                    model: strip.ready ? strip.model.scripts : []

                    delegate: ShellMenuItem {
                        required property var modelData

                        text: modelData.name
                        iconName: "play"
                        current: strip.preferredScript !== null && modelData.id === strip.preferredScript.id
                        onTriggered: Shell.dispatch("workspace.runScript", {
                            scriptId: modelData.id
                        })
                    }

                    onObjectAdded: (index, object) => scriptsMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => scriptsMenu.removeItem(object)
                }
                ShellMenuItem {
                    objectName: "addActionMenuItem"
                    text: qsTr("Add action…")
                    iconName: "plus"
                    onTriggered: Shell.dispatch("projectActions.add")
                }
            }
        }

        ShellButton {
            id: sshNote
            objectName: "noSshRoute"
            visible: strip.hasSshNote && !strip.tight
            subtle: true
            iconName: "external-link"
            text: strip.ready ? strip.model.noSshRoute ?? "" : ""
            onClicked: Shell.dispatch("workspace.openInEditor", {})
        }

        ShellSplitButton {
            id: editorPill
            objectName: "openEditorButton"
            visible: strip.hasEditors && !strip.tight
            compact: strip.compact
            iconName: "external-link"
            text: qsTr("Open")
            onClicked: Shell.dispatch("workspace.openInEditor", {})
            onMenuRequested: editorsMenu.open()

            ShellMenu {
                id: editorsMenu

                y: parent.height + 4
                x: parent.width - width

                Instantiator {
                    model: strip.ready ? strip.model.editors : []

                    delegate: ShellMenuItem {
                        required property var modelData

                        text: modelData.label
                        current: strip.ready && modelData.id === strip.model.preferredEditorId
                        onTriggered: Shell.dispatch("workspace.openInEditor", {
                            editorId: modelData.id
                        })
                    }

                    onObjectAdded: (index, object) => editorsMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => editorsMenu.removeItem(object)
                }

                ShellMenuItem {
                    readonly property string note: strip.ready ? strip.model.openOverSsh ?? "" : ""

                    visible: note !== ""
                    height: visible ? implicitHeight : 0
                    enabled: false
                    text: note
                }
            }
        }

        // Run and open, once the strip has no room for their pills.
        ShellButton {
            objectName: "headerOverflow"
            visible: strip.tight && (strip.hasScripts || strip.hasEditors || strip.hasSshNote)
            subtle: true
            // The pills' height, in their place.
            implicitHeight: Theme.control.sm
            iconName: "ellipsis"
            iconSize: Theme.icon.md
            iconTint: strip.iconMuted
            Accessible.name: qsTr("More actions")
            onClicked: overflowMenu.open()

            ShellMenu {
                id: overflowMenu
                objectName: "headerOverflowMenu"

                y: parent.height + Theme.space.xs
                x: parent.width - width

                Instantiator {
                    model: strip.hasScripts ? strip.model.scripts : []

                    delegate: ShellMenuItem {
                        required property var modelData

                        text: qsTr("Run %1").arg(modelData.name)
                        iconName: "play"
                        onTriggered: Shell.dispatch("workspace.runScript", {
                            scriptId: modelData.id
                        })
                    }

                    onObjectAdded: (index, object) => overflowMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => overflowMenu.removeItem(object)
                }

                Instantiator {
                    model: strip.hasEditors ? strip.model.editors : []

                    delegate: ShellMenuItem {
                        required property var modelData

                        text: qsTr("Open in %1").arg(modelData.label)
                        iconName: "external-link"
                        onTriggered: Shell.dispatch("workspace.openInEditor", {
                            editorId: modelData.id
                        })
                    }

                    // After the scripts, whatever order the two fill in.
                    onObjectAdded: (index, object) => overflowMenu.addItem(object)
                    onObjectRemoved: (index, object) => overflowMenu.removeItem(object)
                }

                ShellMenuItem {
                    visible: strip.hasSshNote
                    height: visible ? implicitHeight : 0
                    iconName: "external-link"
                    text: strip.hasSshNote ? strip.model.noSshRoute : ""
                    onTriggered: Shell.dispatch("workspace.openInEditor", {})
                }
            }
        }

        GitActions {
            id: gitPill
            objectName: "gitActions"
            compact: strip.compact
        }

        // The terminal drawer's toggle is the strip's, next to the panel's.
        ShellButton {
            id: terminalToggle
            visible: Terminals.available
            subtle: true
            implicitHeight: Theme.control.md
            iconName: "panel-bottom"
            iconSize: Theme.icon.md
            iconTint: Terminals.open ? strip.foreground : strip.iconMuted
            Layout.leftMargin: Theme.space.xs
            objectName: "terminalToggle"
            Accessible.name: Terminals.open ? qsTr("Hide terminal") : qsTr("Show terminal")
            onClicked: Shell.dispatch("terminal.toggle")
        }

        ShellButton {
            id: detailsButton
            objectName: "threadDetailsToggle"
            visible: strip.detailsToggle !== null
            subtle: true
            implicitHeight: Theme.control.md
            iconName: "info"
            iconSize: Theme.icon.md
            iconTint: strip.detailsToggle === true ? strip.foreground : strip.iconMuted
            Layout.leftMargin: Theme.space.xs
            Accessible.name: strip.detailsToggle === true ? qsTr("Hide thread details") : qsTr("Show thread details")
            onClicked: Shell.dispatch("threadPanel.toggle")
        }

        ShellButton {
            id: panelButton
            objectName: "panelToggle"
            visible: strip.panelToggle !== null
            subtle: true
            implicitHeight: Theme.control.md
            iconName: strip.panelToggle === true ? "panel-right-close" : "panel-right"
            iconSize: Theme.icon.md
            iconTint: strip.iconMuted
            Layout.leftMargin: Theme.space.xs
            Accessible.name: strip.panelToggle === true ? qsTr("Close panel") : qsTr("Open panel")
            onClicked: Shell.dispatch("rightPanel.toggle")
        }

        WindowControls {
            id: windowButtons
            objectName: "windowControls"
            visible: strip.framelessChrome && strip.windowControls && Qt.platform.os !== "osx"
            window: strip.window
            buttonWidth: 32
            buttonHeight: 28
            Layout.leftMargin: Theme.space.sm
        }
    }
}
