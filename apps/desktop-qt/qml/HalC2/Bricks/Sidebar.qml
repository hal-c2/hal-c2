import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// The thread sidebar, rendered from the view model the native shell publishes
// under Shell.state.sidebar (see packages/contracts/src/shell.ts). Every
// click is dispatched as a shell action; nothing here talks to the server.
Rectangle {
    id: sidebar

    // Local extensions may filter or order rows without replacing the row controls.
    property var model: Shell.state.sidebar ?? null
    // A rice that puts project scope and the app's places elsewhere (an icon
    // rail, say) turns these off so the brick is just the thread list.
    property bool showScope: true
    property bool showFooter: true
    // The brand band ("HAL-C2" plus the collapse toggle) is what the web app
    // shows above its sidebar; a rice with its own title bar leaves it off.
    // When frameless it doubles as the window's drag handle.
    property bool showBrand: false
    // A list that may be under a finger (a phone's, a tablet's): a finger
    // dragging a row scrolls the list instead of arranging the row, and its
    // long press opens the row's menu, which holds every row action and Move
    // up and Move down. A mouse or trackpad arranges rows as ever.
    property bool touchRows: false
    // The build the MC is (StageController): {label, artwork, pill}.
    readonly property var stage: Shell.state.stage ?? null
    property Window window: null
    readonly property var projects: model ? model.projects : []
    readonly property var projectNames: {
        const names = {};
        for (const project of projects) {
            names[project.key] = project.displayName;
        }
        return names;
    }
    readonly property string scopeLabel: {
        if (!model || model.scopeProjectKey === null) {
            return qsTr("All projects");
        }
        return projectNames[model.scopeProjectKey] ?? qsTr("All projects");
    }
    property var collapsed: ({})
    readonly property var rows: buildRows(model, collapsed)
    readonly property color foreground: Theme.palette.color("sidebarForeground", "#e4e4e7")
    readonly property color muted: Theme.palette.color("sidebarMutedForeground", "#8b8b93")
    readonly property color iconColor: Theme.palette.color("iconMuted", "#8b8b93")
    readonly property color hairline: Theme.palette.color("sidebarBorder", "#27272a")

    // Update rows in place so live publications keep hover, focus and scroll.
    ListModel {
        id: rowModel
        dynamicRoles: true
    }

    function syncRows() {
        for (let index = 0; index < rows.length; ++index) {
            const data = rows[index];
            const key = data.rowKey ?? data.kind;
            let existing = index;
            while (existing < rowModel.count && rowModel.get(existing).stableKey !== key) {
                existing += 1;
            }
            if (existing === rowModel.count) {
                rowModel.insert(index, {
                    stableKey: key,
                    rowData: data
                });
            } else {
                if (existing !== index) {
                    rowModel.move(existing, index, 1);
                }
                rowModel.setProperty(index, "rowData", data);
            }
        }
        if (rowModel.count > rows.length) {
            rowModel.remove(rows.length, rowModel.count - rows.length);
        }
    }

    onRowsChanged: syncRows()
    Component.onCompleted: syncRows()

    implicitWidth: 256
    color: Theme.palette.color("sidebar", "#0a0a0a")
    // Content keeps its width while the shell animates ours.
    clip: true

    function toggleSection(key) {
        const next = Object.assign({}, collapsed);
        next[key] = !next[key];
        collapsed = next;
    }

    function buildRows(state, folded) {
        if (!state) {
            return [];
        }
        const out = [];
        for (const draft of state.drafts) {
            out.push({
                kind: "draft",
                section: "draft",
                rowKey: "draft:" + draft.draftId,
                item: draft
            });
        }
        for (const item of state.pinned) {
            out.push({
                kind: "thread",
                section: "pinned",
                rowKey: item.key,
                item: item
            });
        }
        if (state.pinned.length > 0 && state.active.length > 0) {
            out.push({
                kind: "divider"
            });
        }
        for (const item of state.active) {
            out.push({
                kind: "thread",
                section: "active",
                rowKey: item.key,
                item: item
            });
        }
        const section = (key, label, items) => {
            if (items.length === 0) {
                return;
            }
            const open = !folded[key];
            out.push({
                kind: "header",
                key: key,
                rowKey: "header:" + key,
                label: label,
                count: items.length,
                open: open
            });
            if (!open) {
                return;
            }
            for (const item of items) {
                out.push({
                    kind: "slim",
                    section: key,
                    rowKey: item.key,
                    item: item
                });
            }
        };
        section("snoozed", qsTr("Snoozed"), state.snoozed);
        section("settled", qsTr("Settled"), state.settled);
        if (!folded.settled && state.settledTotal > state.settled.length) {
            out.push({
                kind: "note",
                label: qsTr("%1 more settled in the app").arg(state.settledTotal - state.settled.length)
            });
        }
        return out;
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: Math.min(0, sidebar.width - sidebar.implicitWidth)
        spacing: 0

        // Brand band: sidebar toggle and wordmark.
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            visible: sidebar.showBrand

            // A Nightly MC marks the band (StageController): a night sky, or
            // a pill by the wordmark, as Environment identification says.
            Rectangle {
                objectName: "stageArtwork"
                anchors.fill: parent
                visible: sidebar.stage !== null && sidebar.stage.artwork === "nightly"
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#121a33" }
                    GradientStop { position: 0.5; color: "#1b1746" }
                    GradientStop { position: 1; color: "#2a1a5e" }
                }

                Repeater {
                    model: parent.visible ? [[14, 10, 0.85], [38, 22, 0.55], [58, 8, 0.7], [84, 16, 0.5], [104, 7, 0.8], [126, 20, 0.55], [148, 11, 0.7], [170, 24, 0.5], [192, 9, 0.8], [214, 18, 0.55], [236, 8, 0.7]] : []

                    delegate: Rectangle {
                        required property var modelData

                        x: modelData[0]
                        y: modelData[1] + 8
                        width: 2
                        height: 2
                        radius: 1
                        color: Qt.rgba(1, 1, 1, modelData[2])
                    }
                }
            }

            DragHandler {
                enabled: sidebar.window !== null && Theme.frameless
                target: null
                grabPermissions: PointerHandler.CanTakeOverFromAnything
                onActiveChanged: if (active)
                    sidebar.window.startSystemMove()
            }

            ShellButton {
                x: 12
                y: 12
                subtle: true
                implicitHeight: 28
                iconName: "panel-left-close"
                iconSize: 16
                iconTint: sidebar.iconColor
                Accessible.name: qsTr("Hide sidebar")
                onClicked: Shell.dispatch("sidebar.toggle")
            }

            HalC2Wordmark {
                id: wordmark

                x: 52
                size: 11
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                objectName: "stagePill"
                visible: sidebar.stage !== null && !!sidebar.stage.pill
                anchors.left: wordmark.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: pillText.implicitWidth + 12
                implicitHeight: 18
                radius: 9
                color: Theme.palette.color("secondary", "#27272a")

                Text {
                    id: pillText

                    anchors.centerIn: parent
                    text: sidebar.stage !== null ? (sidebar.stage.pill ?? "") : ""
                    color: Theme.palette.color("secondaryForeground", "#e4e4e7")
                    font.pixelSize: Math.round(10 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }
            }
        }

        // Search + new thread, scope + add project.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: 8
            spacing: 4
            visible: sidebar.showScope

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                ShellButton {
                    Layout.fillWidth: true
                    implicitHeight: 32
                    subtle: true
                    iconName: "search"
                    iconSize: 16
                    iconTint: Qt.alpha(sidebar.muted, 0.8)
                    tint: sidebar.foreground
                    objectName: "search"
                    text: qsTr("Search")
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    onClicked: PaletteModel.show()

                    background: Rectangle {
                        radius: 8
                        color: parent.hovered || parent.down ? Theme.palette.color("sidebarRowHover", "#1c1c21") : Theme.palette.color("sidebarControlSurface", "#141416")

                        Behavior on color {
                            ColorAnimation {
                                duration: 120
                            }
                        }
                    }
                }

                ShellButton {
                    subtle: true
                    implicitHeight: 32
                    iconName: "square-pen"
                    iconSize: 16
                    iconTint: sidebar.iconColor
                    objectName: "newThread"
                    Accessible.name: qsTr("New thread")
                    onClicked: Shell.dispatch("thread.new", sidebar.model && sidebar.model.scopeProjectKey !== null ? {
                        projectKey: sidebar.model.scopeProjectKey
                    } : {})
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                ShellButton {
                    id: scopeButton

                    Layout.fillWidth: true
                    implicitHeight: 32
                    leftPadding: 9
                    subtle: true
                    chevron: true
                    chevronSize: 16
                    iconName: "folder"
                    iconSize: 16
                    iconTint: Qt.alpha(sidebar.muted, 0.8)
                    tint: Qt.alpha(sidebar.muted, 0.8)
                    text: sidebar.scopeLabel
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    Accessible.name: qsTr("Project scope")
                    onClicked: scopeMenu.open()

                    ShellMenu {
                        id: scopeMenu

                        y: parent.height + 4
                        width: Math.max(parent.width, 200)

                        ShellMenuItem {
                            text: qsTr("All projects")
                            current: sidebar.model !== null && sidebar.model.scopeProjectKey === null
                            onTriggered: Shell.dispatch("sidebar.scope", {
                                projectKey: null
                            })
                        }

                        Instantiator {
                            model: sidebar.projects

                            delegate: ShellMenuItem {
                                required property var modelData

                                // The most urgent state among the project's threads.
                                readonly property string statusWord: ({
                                        approval: qsTr("Approval"),
                                        input: qsTr("Input"),
                                        working: qsTr("Working"),
                                        waiting: qsTr("Waiting"),
                                        limited: qsTr("Limited"),
                                        failed: qsTr("Failed")
                                    })[modelData.status] ?? ""

                                text: statusWord.length > 0 ? qsTr("%1 · %2").arg(modelData.displayName).arg(statusWord) : modelData.displayName
                                iconName: "folder"
                                badge: Shell.state.projectIcons?.[modelData.environmentId + ":" + modelData.projectId] ?? null
                                current: sidebar.model !== null && sidebar.model.scopeProjectKey === modelData.key
                                onTriggered: Shell.dispatch("sidebar.scope", {
                                    projectKey: modelData.key
                                })
                            }

                            onObjectAdded: (index, object) => scopeMenu.insertItem(index + 1, object)
                            onObjectRemoved: (index, object) => scopeMenu.removeItem(object)
                        }
                    }
                }

                ShellButton {
                    subtle: true
                    implicitHeight: 32
                    iconName: "folder-plus"
                    iconSize: 16
                    iconTint: sidebar.iconColor
                    objectName: "addProject"
                    Accessible.name: qsTr("Add project")
                    // A local folder is picked here; without local folders the command palette asks.
                    onClicked: Shell.localFolderImportEnabled && (sidebar.model?.localEnvironmentId ?? null) !== null ? addProjectDialog.open() : Shell.dispatch("project.add")
                }

                FolderDialog {
                    id: addProjectDialog
                    objectName: "addProjectDialog"
                    title: qsTr("Add a project folder")
                    onAccepted: {
                        const path = Shell.localDirectoryPath(selectedFolder);
                        if (path.length > 0) {
                            Shell.dispatch("project.add", {
                                path: path
                            });
                        }
                    }
                }
            }
        }

        ListView {
            id: list
            objectName: "list"

            // The keyboard cursor, by row key so it survives the list being
            // rebuilt around it. Up/Down/Home/End move it over the rows that
            // can be acted on, Enter opens (or folds) the row, Menu or
            // Shift+F10 opens its context menu.
            property string cursorKey: ""
            readonly property int cursorIndex: sidebar.rows.findIndex(r => r.rowKey !== undefined && r.rowKey === list.cursorKey)

            function moveCursor(delta) {
                let i = cursorIndex;
                do {
                    i += delta;
                    if (i < 0 || i >= sidebar.rows.length) {
                        return;
                    }
                } while (sidebar.rows[i].rowKey === undefined);
                cursorKey = sidebar.rows[i].rowKey;
                positionViewAtIndex(i, ListView.Contain);
            }

            function moveCursorToEdge(delta) {
                const rows = sidebar.rows;
                for (let i = delta > 0 ? 0 : rows.length - 1; i >= 0 && i < rows.length; i += delta) {
                    if (rows[i].rowKey !== undefined) {
                        cursorKey = rows[i].rowKey;
                        positionViewAtIndex(i, ListView.Contain);
                        return;
                    }
                }
            }

            function settleCursor() {
                if (cursorIndex >= 0) {
                    return;
                }
                const current = sidebar.rows.find(r => r.rowKey !== undefined && sidebar.model !== null && (r.kind === "draft" ? r.item.draftId === sidebar.model.activeDraftId : r.kind !== "header" && r.item.key === sidebar.model.activeThreadKey));
                const first = current ?? sidebar.rows.find(r => r.rowKey !== undefined);
                cursorKey = first ? first.rowKey : "";
            }

            function activateCursor() {
                const row = sidebar.rows[cursorIndex];
                if (!row) {
                    return;
                }
                switch (row.kind) {
                case "header":
                    sidebar.toggleSection(row.key);
                    break;
                case "draft":
                    Shell.dispatch("draft.open", {
                        draftId: row.item.draftId
                    });
                    break;
                default:
                    Shell.dispatch("thread.open", {
                        key: row.item.key
                    });
                }
            }

            // A row being dragged, and where it would land: before the row
            // `dropBeforeKey` of `dropSection` (at its end without one).
            property string dragKey: ""
            property string dropSection: ""
            property var dropBeforeKey: null
            property real dropLineY: -1

            function sectionKeys(section) {
                return sidebar.model ? (sidebar.model[section] ?? []).map(item => item.key) : [];
            }

            function trackDrop(key, windowY) {
                dragKey = key;
                const y = mapFromItem(null, 0, windowY).y;
                const index = indexAt(width / 2, y + contentY);
                const row = index >= 0 ? sidebar.rows[index] : undefined;
                const item = index >= 0 ? itemAtIndex(index) : null;
                dropSection = "";
                dropBeforeKey = null;
                dropLineY = -1;
                if (!row || !item) {
                    return;
                }
                const top = item.y - contentY;
                const upper = y < top + item.height / 2;
                if (row.kind === "header") {
                    dropSection = row.key;
                    dropLineY = top + item.height;
                } else if (row.kind === "divider") {
                    dropSection = "active";
                    dropBeforeKey = sectionKeys("active")[0] ?? null;
                    dropLineY = top + item.height;
                } else if (row.kind === "thread" || row.kind === "slim") {
                    const keys = sectionKeys(row.section);
                    const at = keys.indexOf(row.item.key);
                    // With nothing pinned, the top edge of the list pins.
                    if (row.section === "active" && at === 0 && sectionKeys("pinned").length === 0 && y < top + 12) {
                        dropSection = "pinned";
                        dropLineY = top;
                        return;
                    }
                    dropSection = row.section;
                    dropBeforeKey = upper ? row.item.key : (keys[at + 1] ?? null);
                    dropLineY = upper ? top : top + item.height;
                }
            }

            function finishDrop(dropped) {
                if (dropped && dragKey.length > 0 && dropSection.length > 0 && dropBeforeKey !== dragKey) {
                    Shell.dispatch("thread.drop", {
                        key: dragKey,
                        section: dropSection,
                        beforeKey: dropBeforeKey
                    });
                }
                dragKey = "";
                dropSection = "";
                dropBeforeKey = null;
                dropLineY = -1;
            }

            // Where the dragged row would land.
            Rectangle {
                objectName: "dropLine"
                parent: list
                visible: list.dropLineY >= 0
                x: 6
                y: list.dropLineY - 1
                width: list.width - 12
                height: 2
                radius: 1
                color: Theme.palette.color("focus", "#3b82f6")
            }

            function menuAtCursor() {
                const row = sidebar.rows[cursorIndex];
                const item = itemAtIndex(cursorIndex);
                if (!row || !item || row.kind === "header") {
                    return;
                }
                const p = item.mapToItem(null, item.width / 2, item.height / 2);
                if (row.kind === "draft") {
                    Shell.dispatch("draft.menu", {
                        draftId: row.item.draftId,
                        x: p.x,
                        y: p.y
                    });
                    return;
                }
                Shell.dispatch("thread.menu", {
                    key: row.item.key,
                    x: p.x,
                    y: p.y
                });
            }

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 9
            Layout.rightMargin: 8
            Layout.bottomMargin: 4
            clip: true
            model: rowModel
            reuseItems: true
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            keyNavigationEnabled: false
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Threads")
            onActiveFocusChanged: {
                if (activeFocus) {
                    settleCursor();
                }
            }
            Keys.onUpPressed: moveCursor(-1)
            Keys.onDownPressed: moveCursor(1)
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Home:
                    moveCursorToEdge(1);
                    break;
                case Qt.Key_End:
                    moveCursorToEdge(-1);
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    activateCursor();
                    break;
                case Qt.Key_Menu:
                    menuAtCursor();
                    break;
                case Qt.Key_Escape:
                    if (!sidebar.model || sidebar.model.selectedKeys.length === 0) {
                        return;
                    }
                    Shell.dispatch("thread.select.clear", {});
                    break;
                case Qt.Key_F10:
                    if (!(event.modifiers & Qt.ShiftModifier)) {
                        return;
                    }
                    menuAtCursor();
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            delegate: Item {
                id: entry

                required property var rowData
                readonly property var modelData: rowData

                readonly property string kind: modelData.kind
                readonly property bool focused: list.activeFocus && modelData.rowKey !== undefined && modelData.rowKey === list.cursorKey

                width: ListView.view.width
                implicitHeight: kind === "header" ? 36 : kind === "divider" ? 13 : kind === "note" ? 28 : kind === "slim" ? 36 : 82

                // Collapsible section header with a hairline (settled) or tint (snoozed).
                Item {
                    objectName: entry.kind === "header" ? "header:" + entry.modelData.key : ""
                    anchors.fill: parent
                    visible: entry.kind === "header"

                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.palette.color("focus", "#3b82f6")
                        visible: entry.focused
                    }

                    HoverHandler {
                        id: headerHover
                    }

                    TapHandler {
                        onTapped: sidebar.toggleSection(entry.modelData.key)
                    }

                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        anchors.bottomMargin: 4
                        height: 20
                        spacing: 8

                        Text {
                            text: entry.kind === "header" ? entry.modelData.label : ""
                            color: entry.kind === "header" && entry.modelData.key === "snoozed" ? Theme.palette.color("info", "#60a5fa") : Qt.alpha(sidebar.muted, headerHover.hovered ? 0.8 : 0.5)
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.Medium
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: Qt.alpha(sidebar.hairline, 0.6)
                            visible: entry.kind === "header" && entry.modelData.key === "settled"
                        }

                        Item {
                            Layout.fillWidth: true
                            visible: !(entry.kind === "header" && entry.modelData.key === "settled")
                        }

                        Text {
                            objectName: "headerCount"
                            visible: entry.kind === "header" && !entry.modelData.open
                            text: entry.kind === "header" ? entry.modelData.count : ""
                            color: Qt.alpha(sidebar.muted, 0.5)
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                        }

                        ShellIcon {
                            name: "chevron-down"
                            size: 12
                            color: Qt.alpha(sidebar.muted, 0.5)
                            rotation: entry.kind === "header" && entry.modelData.open ? 0 : -90
                            Layout.alignment: Qt.AlignVCenter

                            Behavior on rotation {
                                NumberAnimation {
                                    duration: 150
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    height: 1
                    visible: entry.kind === "divider"
                    color: Qt.alpha(sidebar.hairline, 0.6)
                }

                Text {
                    anchors.centerIn: parent
                    visible: entry.kind === "note"
                    text: entry.kind === "note" ? entry.modelData.label : ""
                    color: Qt.alpha(sidebar.muted, 0.6)
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                }

                Loader {
                    anchors.fill: parent
                    anchors.topMargin: entry.kind === "thread" ? 2 : 0
                    anchors.bottomMargin: entry.kind === "thread" ? 2 : 0
                    active: entry.kind === "thread" || entry.kind === "slim" || entry.kind === "draft"

                    sourceComponent: SidebarThreadRow {
                        objectName: "threadRow:" + entry.modelData.rowKey
                        slim: entry.kind !== "thread"
                        section: entry.modelData.section
                        focused: entry.focused
                        touch: sidebar.touchRows
                        item: entry.kind === "draft" ? {
                            title: entry.modelData.item.label,
                            status: "ready",
                            statusLabel: null,
                            unread: false,
                            branch: null,
                            updatedAt: null
                        } : entry.modelData.item
                        projectName: sidebar.projectNames[entry.modelData.item.projectKey] ?? ""
                        active: sidebar.model !== null && (entry.kind === "draft" ? entry.modelData.item.draftId === sidebar.model.activeDraftId : entry.modelData.item.key === sidebar.model.activeThreadKey)
                        onActivated: {
                            list.cursorKey = entry.modelData.rowKey;
                            if (entry.kind === "draft") {
                                Shell.dispatch("draft.open", {
                                    draftId: entry.modelData.item.draftId
                                });
                            } else {
                                Shell.dispatch("thread.open", {
                                    key: entry.modelData.item.key
                                });
                            }
                        }
                        onFilesDropped: urls => {
                            const files = Shell.readImageFiles(urls);
                            if (files.length > 0) {
                                Shell.dispatch("thread.attachFiles", {
                                    key: entry.modelData.item.key,
                                    files: files
                                });
                            }
                        }
                        onDragMoved: windowY => list.trackDrop(entry.modelData.item.key, windowY)
                        onDragEnded: dropped => list.finishDrop(dropped)
                        onSelectionToggled: Shell.dispatch("thread.select.toggle", {
                            key: entry.modelData.item.key
                        })
                        onRangeSelected: Shell.dispatch("thread.select.range", {
                            key: entry.modelData.item.key
                        })
                        onMenuRequested: (windowX, windowY) => {
                            if (entry.kind === "draft") {
                                Shell.dispatch("draft.menu", {
                                    draftId: entry.modelData.item.draftId,
                                    x: windowX,
                                    y: windowY
                                });
                            } else {
                                Shell.dispatch("thread.menu", {
                                    key: entry.modelData.item.key,
                                    x: windowX,
                                    y: windowY
                                });
                            }
                        }
                        onSettleRequested: Shell.dispatch("thread.settle", {
                            key: entry.modelData.item.key
                        })
                        onUnsettleRequested: Shell.dispatch("thread.unsettle", {
                            key: entry.modelData.item.key
                        })
                        onUnpinRequested: Shell.dispatch("thread.unpin", {
                            key: entry.modelData.item.key
                        })
                        onUnsnoozeRequested: Shell.dispatch("thread.unsnooze", {
                            key: entry.modelData.item.key
                        })
                        onSnoozeRequested: (windowX, windowY) => Shell.dispatch("thread.snoozeMenu", {
                            key: entry.modelData.item.key,
                            x: windowX,
                            y: windowY
                        })
                        onWokeDismissed: Shell.dispatch("thread.wokeDismiss", {
                            key: entry.modelData.item.key
                        })
                    }
                }
            }

            Text {
                objectName: "emptyText"
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                visible: list.count === 0
                text: sidebar.model === null ? qsTr("Waiting for the app…") : sidebar.projects.length === 0 ? qsTr("No projects yet") : qsTr("No threads yet")
                color: Qt.alpha(sidebar.muted, 0.6)
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
            }
        }

        // Sections plugins add below the threads.
        PluginSlot {
            objectName: "sidebarSectionsSlot"
            name: "sidebar.sections"
            vertical: true
            visible: shown.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.topMargin: 4
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8
            spacing: 4
            visible: sidebar.showFooter

            FooterButton {
                iconName: "settings"
                Accessible.name: qsTr("Settings")
                onClicked: Shell.dispatch("settings.open")
            }

            FooterButton {
                iconName: "git-pull-request"
                Accessible.name: qsTr("Pull requests")
                onClicked: Shell.dispatch("pullRequests.open")
            }

            FooterButton {
                iconName: "chart-no-axes-column"
                Accessible.name: qsTr("Usage")
                onClicked: Shell.dispatch("usage.open")
            }

            Item {
                Layout.fillWidth: true
            }

            // What plugins add to the footer (the terminal client's "sidebar.footer").
            PluginSlot {
                objectName: "sidebarFooterSlot"
                name: "sidebar.footer"
                visible: shown.length > 0
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    component FooterButton: ShellButton {
        subtle: true
        implicitHeight: 32
        iconSize: 16
        iconTint: sidebar.iconColor
    }
}
