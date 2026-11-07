pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages

// Settings → Keybindings, a native settings page over the shell's keymap
// (KeybindingController, the `Keybindings` singleton): every binding with its
// shortcut, condition and source, searchable, and a recorder to rebind, reset,
// remove or add one. Edits go to the MC, whose push refreshes the rows.
Rectangle {
    id: page

    readonly property string query: search.text.trim().toLowerCase()
    readonly property var rows: query.length === 0 ? Keybindings.bindings : Keybindings.bindings.filter(row => row.search.includes(query))
    property bool adding: false
    readonly property int count: rows.length + (adding ? 1 : 0)
    readonly property color foreground: Theme.palette.color("ink", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warningForeground", "#f59e0b")

    function conflictText(labels) {
        if (labels.length === 0)
            return "";
        const listed = labels.length === 1 ? labels[0] : labels.slice(0, 3).join(", ") + (labels.length > 3 ? qsTr(", and more") : "");
        return qsTr("Conflicts with %1. The most recent matching binding wins when both conditions can apply.").arg(listed);
    }

    // A settings search result for a command (route.target "keybinding:<id>")
    // opens at its rows, or with none, at a new keybinding for it.
    readonly property var route: Shell.state.route ?? null
    readonly property int targetSeq: route?.targetSeq ?? 0

    function openTarget() {
        const target = route?.target ?? "";
        if (!target.startsWith("keybinding:"))
            return;
        const wanted = target.slice("keybinding:".length);
        if (Keybindings.bindings.some(row => row.command === wanted)) {
            draft.cancel();
            search.text = wanted;
            return;
        }
        search.text = "";
        draft.cancel();
        page.adding = true;
        command.currentIndex = command.model.indexOf(wanted);
    }

    onTargetSeqChanged: Qt.callLater(openTarget)
    Component.onCompleted: Qt.callLater(openTarget)
    color: Theme.palette.color("canvas", "#0b0b0d")

    // Searching starts from its shortcut while the page shows.
    Shortcut {
        sequences: [StandardKey.Find]
        enabled: page.visible
        onActivated: search.forceActiveFocus()
    }

    // A shortcut field: click it, then press the chord. Escape puts the old
    // key back; a key without a modifier records nothing. While it records
    // it takes every chord, window shortcuts included.
    component KeyRecorder: Rectangle {
        id: recorder

        property string key: ""
        property string label: ""
        property bool recording: false
        signal recorded(string key)

        implicitWidth: 150
        implicitHeight: Theme.control.md
        radius: Theme.radiusMd
        color: Theme.palette.color("input", "#18181b")
        border.width: 1
        border.color: recording || activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("border", "#27272a")
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Shortcut")

        onActiveFocusChanged: if (!activeFocus)
            recording = false

        Label {
            anchors.fill: parent
            anchors.leftMargin: Theme.space.sm
            anchors.rightMargin: Theme.space.sm
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            font.family: "monospace"
            font.pixelSize: Theme.type.meta.size
            color: recorder.recording || recorder.key.length === 0 ? Theme.palette.color("inkTertiary", "#a1a1aa") : Theme.palette.color("ink", "#e4e4e7")
            text: recorder.recording ? qsTr("Press shortcut") : recorder.key.length > 0 ? recorder.label : qsTr("Unassigned")
        }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                recorder.forceActiveFocus();
                recorder.recording = true;
            }
        }

        Keys.onShortcutOverride: event => event.accepted = recorder.recording && event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab
        Keys.onPressed: event => {
            if (!recorder.recording || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                return;
            event.accepted = true;
            if (event.key === Qt.Key_Escape) {
                recorder.recording = false;
                return;
            }
            const next = Keybindings.recordKey(event.key, event.modifiers);
            if (next.length === 0)
                return;
            recorder.recording = false;
            recorder.recorded(next);
        }
        Keys.onReturnPressed: event => {
            if (recorder.recording) {
                event.accepted = true;
                return;
            }
            recorder.recording = true;
        }
    }

    // A condition field with its problems under it.
    component WhenField: ColumnLayout {
        id: whenField

        property alias text: input.text
        readonly property string problem: Keybindings.whenError(input.text)
        readonly property var unknown: problem.length === 0 ? Keybindings.unknownVariables(input.text) : []
        signal accepted

        function edit() {
            input.forceActiveFocus();
        }

        spacing: Theme.space.xxs

        ShellTextField {
            id: input
            objectName: "whenField"
            Layout.fillWidth: true
            placeholderText: qsTr("Always")
            font.family: "monospace"
            font.pixelSize: Theme.type.meta.size
            Accessible.name: qsTr("When expression")
            onAccepted: whenField.accepted()
        }

        // What the typed condition means, in the words the rows show.
        Label {
            objectName: "whenWords"
            Layout.fillWidth: true
            visible: input.text.trim().length > 0 && whenField.problem.length === 0
            text: visible ? Keybindings.whenLabel(input.text) : ""
            color: page.muted
            font.pixelSize: Theme.type.caption.size
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "whenError"
            Layout.fillWidth: true
            visible: whenField.problem.length > 0
            text: whenField.problem
            color: Theme.palette.color("errorForeground", "#f87171")
            font.pixelSize: Theme.type.caption.size
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "unknownVariables"
            Layout.fillWidth: true
            visible: whenField.unknown.length > 0
            text: qsTr("Unknown: %1").arg(whenField.unknown.join(", "))
            color: Theme.palette.color("warningForeground", "#f59e0b")
            font.pixelSize: Theme.type.caption.size
            wrapMode: Text.Wrap
        }
    }

    ColumnLayout {
        x: Pages.columnX(page.width, Theme.space.xl)
        y: Theme.space.xl
        width: Pages.columnWidth(page.width, Theme.space.xl)
        height: page.height - 2 * Theme.space.xl
        spacing: Theme.space.sm

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm

            SettingsBreadcrumb {
                Layout.fillWidth: true
                section: qsTr("Keybindings")
            }

            Label {
                objectName: "keybindingCount"
                text: page.count === 1 ? qsTr("1 binding") : qsTr("%1 bindings").arg(page.count)
                color: page.muted
                font.pixelSize: Theme.type.caption.size
            }

            ShellButton {
                objectName: "keybindingFile"
                subtle: true
                text: qsTr("Open keybindings.json")
                enabled: Keybindings.filePath.length > 0
                onClicked: Keybindings.openFile()
            }

            ShellButton {
                objectName: "keybindingResetAll"
                subtle: true
                text: qsTr("Reset all")
                enabled: Keybindings.customCount > 0 && !Keybindings.saving
                onClicked: Keybindings.resetAll()
            }

            ShellButton {
                objectName: "keybindingAdd"
                subtle: true
                text: qsTr("Add keybinding")
                enabled: !page.adding
                onClicked: page.adding = true
            }
        }

        ShellTextField {
            id: search
            objectName: "keybindingSearch"
            Layout.fillWidth: true
            placeholderText: qsTr("Search keybindings")
            Accessible.name: qsTr("Search keybindings")
            Keys.onEscapePressed: event => {
                if (text.length === 0) {
                    event.accepted = false;
                    return;
                }
                clear();
            }
        }

        // A new binding: a command, a shortcut and an optional condition.
        ShellCard {
            id: draft
            objectName: "keybindingDraft"

            property string key: ""
            property string label: ""

            Layout.fillWidth: true
            visible: page.adding
            implicitHeight: draftColumn.implicitHeight + 2 * Theme.space.sm

            function cancel() {
                page.adding = false;
                key = "";
                label = "";
                command.currentIndex = -1;
                draftWhen.text = "";
            }

            ColumnLayout {
                id: draftColumn

                anchors.fill: parent
                anchors.margins: Theme.space.sm
                spacing: Theme.space.sm

                Label {
                    text: qsTr("New keybinding")
                    color: page.foreground
                    font.pixelSize: Theme.type.body.size
                    font.weight: Font.Medium
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    ShellComboBox {
                        id: command
                        objectName: "command"
                        Layout.fillWidth: true
                        outline: true
                        font.pixelSize: Theme.type.body.size
                        model: page.adding ? Keybindings.commandOptions() : []
                        currentIndex: -1
                        displayText: currentIndex < 0 ? qsTr("Command") : Keybindings.commandLabel(currentValue)
                        delegate: ItemDelegate {
                            required property string modelData
                            width: ListView.view ? ListView.view.width : implicitWidth
                            text: Keybindings.commandLabel(modelData)
                        }
                    }

                    KeyRecorder {
                        objectName: "keyField"
                        key: draft.key
                        label: draft.label
                        onRecorded: next => {
                            draft.key = next;
                            draft.label = Keybindings.keyLabel(next);
                        }
                    }
                }

                WhenField {
                    id: draftWhen
                    Layout.fillWidth: true
                }

                Label {
                    objectName: "conflicts"
                    readonly property var labels: draft.key.length > 0 ? Keybindings.conflicts("", draft.key, draftWhen.text) : []
                    Layout.fillWidth: true
                    visible: labels.length > 0
                    text: page.conflictText(labels)
                    color: page.warning
                    font.pixelSize: Theme.type.caption.size
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    spacing: Theme.space.sm

                    ShellButton {
                        objectName: "save"
                        primary: true
                        enabled: !Keybindings.saving && command.currentIndex >= 0 && draft.key.length > 0 && draftWhen.problem.length === 0
                        text: Keybindings.saving ? qsTr("Saving") : qsTr("Save")
                        onClicked: {
                            Keybindings.save(command.currentValue, draft.key, draftWhen.text);
                            draft.cancel();
                        }
                    }

                    ShellButton {
                        objectName: "cancel"
                        subtle: true
                        text: qsTr("Cancel")
                        Accessible.name: qsTr("Cancel new keybinding")
                        onClicked: draft.cancel()
                    }
                }
            }
        }

        ShellEmptyState {
            objectName: "keybindingEmpty"
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space.xxl
            visible: page.rows.length === 0 && !page.adding
            iconName: "keyboard"
            title: qsTr("No keybindings match your search.")
            actionText: qsTr("Clear search")
            onActionTriggered: search.clear()
        }

        ListView {
            id: list
            objectName: "keybindingRows"

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds
            model: page.rows
            reuseItems: false

            delegate: Rectangle {
                id: row
                objectName: "keybindingRow"

                required property var modelData
                property string keyDraft: modelData.key
                property string labelDraft: modelData.keyLabel
                readonly property bool dirty: keyDraft !== modelData.key || rowWhen.text.trim() !== modelData.when
                readonly property var conflicts: dirty ? Keybindings.conflicts(modelData.id, keyDraft, rowWhen.text) : modelData.conflicts
                // The condition shows in words; its expression opens to edit.
                property bool editingWhen: false

                width: ListView.view.width
                implicitHeight: rowColumn.implicitHeight + 2 * Theme.space.md
                height: implicitHeight
                color: hover.hovered ? Qt.alpha(Theme.palette.color("accentSurface", "#27272a"), 0.4) : "transparent"

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.palette.color("border", "#27272a")
                }

                HoverHandler {
                    id: hover
                }

                ColumnLayout {
                    id: rowColumn

                    x: Theme.space.sm
                    y: Theme.space.md
                    width: parent.width - 2 * Theme.space.sm
                    spacing: Theme.space.xs

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                spacing: Theme.space.sm

                                Label {
                                    objectName: "label"
                                    text: row.modelData.label
                                    color: page.foreground
                                    font.pixelSize: Theme.type.body.size
                                    elide: Text.ElideRight
                                }

                                Label {
                                    objectName: "source"
                                    visible: row.modelData.source !== "Default"
                                    text: row.modelData.source
                                    color: page.muted
                                    font.pixelSize: Theme.type.caption.size
                                    leftPadding: Theme.space.xs
                                    rightPadding: Theme.space.xs
                                    background: Rectangle {
                                        radius: Theme.radiusXs
                                        color: "transparent"
                                        border.width: 1
                                        border.color: Theme.palette.color("border", "#27272a")
                                    }
                                }
                            }

                            Label {
                                text: row.modelData.command
                                color: page.muted
                                font.family: "monospace"
                                font.pixelSize: Theme.type.caption.size
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }

                        KeyRecorder {
                            objectName: "keyField"
                            key: row.keyDraft
                            label: row.labelDraft
                            onRecorded: next => {
                                row.keyDraft = next;
                                row.labelDraft = Keybindings.keyLabel(next);
                            }
                        }

                        ShellButton {
                            objectName: "save"
                            visible: row.dirty
                            primary: true
                            enabled: !Keybindings.saving && row.keyDraft.length > 0 && rowWhen.problem.length === 0
                            text: Keybindings.saving ? qsTr("Saving") : qsTr("Save")
                            onClicked: Keybindings.save(row.modelData.command, row.keyDraft, rowWhen.text, row.modelData)
                        }

                        ShellButton {
                            objectName: "reset"
                            visible: row.modelData.canReset
                            subtle: true
                            enabled: !Keybindings.saving
                            text: qsTr("Reset to default")
                            onClicked: Keybindings.reset(row.modelData)
                        }

                        ShellButton {
                            objectName: "remove"
                            visible: row.modelData.canRemove
                            subtle: true
                            enabled: !Keybindings.saving
                            text: qsTr("Remove")
                            onClicked: Keybindings.remove(row.modelData)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        Label {
                            objectName: "whenLabel"
                            Layout.fillWidth: !rowWhen.visible
                            visible: !rowWhen.visible
                            text: row.modelData.whenLabel
                            color: page.muted
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideRight
                        }

                        ShellButton {
                            objectName: "editWhen"
                            visible: !rowWhen.visible
                            subtle: true
                            text: qsTr("Edit condition")
                            onClicked: {
                                row.editingWhen = true;
                                rowWhen.edit();
                            }
                        }

                        WhenField {
                            id: rowWhen
                            Layout.fillWidth: true
                            visible: row.editingWhen || row.dirty
                            text: row.modelData.when
                            onAccepted: if (row.dirty && rowWhen.problem.length === 0 && row.keyDraft.length > 0)
                                Keybindings.save(row.modelData.command, row.keyDraft, rowWhen.text, row.modelData)
                        }
                    }

                    Label {
                        objectName: "conflicts"
                        Layout.fillWidth: true
                        visible: row.conflicts.length > 0
                        text: page.conflictText(row.conflicts)
                        color: page.warning
                        font.pixelSize: Theme.type.caption.size
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
