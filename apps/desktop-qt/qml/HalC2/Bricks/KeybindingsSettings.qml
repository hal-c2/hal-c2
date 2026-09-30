import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Keybindings, a native settings page over the shell's keymap
// (KeybindingController, the `Keybindings` singleton): every binding with its
// shortcut, condition and source, searchable, and a recorder to rebind, reset,
// remove or add one. Edits go to the node, whose push refreshes the rows.
Rectangle {
    id: page

    readonly property string query: search.text.trim().toLowerCase()
    readonly property var rows: query.length === 0 ? Keybindings.bindings : Keybindings.bindings.filter(row => row.search.includes(query))
    property bool adding: false
    readonly property int count: rows.length + (adding ? 1 : 0)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#f59e0b")
    readonly property color error: Theme.palette.color("error", "#f87171")

    function conflictText(labels) {
        if (labels.length === 0)
            return "";
        const listed = labels.length === 1 ? labels[0] : labels.slice(0, 3).join(", ") + (labels.length > 3 ? qsTr(", and more") : "");
        return qsTr("Conflicts with %1. The most recent matching binding wins when both conditions can apply.").arg(listed);
    }

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
        implicitHeight: 28
        radius: Math.min(Theme.radius, 8)
        color: Theme.palette.color("input", "#18181b")
        border.width: 1
        border.color: recording ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("border", "#27272a")
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Shortcut")

        onActiveFocusChanged: if (!activeFocus)
            recording = false

        Label {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            font.family: "monospace"
            font.pixelSize: 12
            color: recorder.recording || recorder.key.length === 0 ? page.muted : page.foreground
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

        spacing: 2

        ShellTextField {
            id: input
            objectName: "whenField"
            Layout.fillWidth: true
            placeholderText: qsTr("Always")
            font.family: "monospace"
            font.pixelSize: 12
            Accessible.name: qsTr("When expression")
            onAccepted: whenField.accepted()
        }

        Label {
            objectName: "whenError"
            Layout.fillWidth: true
            visible: whenField.problem.length > 0
            text: whenField.problem
            color: page.error
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "unknownVariables"
            Layout.fillWidth: true
            visible: whenField.unknown.length > 0
            text: qsTr("Unknown: %1").arg(whenField.unknown.join(", "))
            color: page.warning
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: 760
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: qsTr("Keybindings")
                color: page.foreground
                font.pixelSize: 18
                font.weight: Font.DemiBold
            }

            Label {
                objectName: "keybindingCount"
                text: page.count === 1 ? qsTr("1 binding") : qsTr("%1 bindings").arg(page.count)
                color: page.muted
                font.pixelSize: 11
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
            Layout.maximumWidth: 760
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
            Layout.maximumWidth: 760
            visible: page.adding
            implicitHeight: draftColumn.implicitHeight + 20

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
                anchors.margins: 10
                spacing: 6

                Label {
                    text: qsTr("New keybinding")
                    color: page.foreground
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ShellComboBox {
                        id: command
                        objectName: "command"
                        Layout.fillWidth: true
                        outline: true
                        font.pixelSize: 13
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
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    spacing: 8

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

        Label {
            objectName: "keybindingEmpty"
            Layout.fillWidth: true
            Layout.maximumWidth: 760
            visible: page.rows.length === 0 && !page.adding
            text: qsTr("No keybindings match your search.")
            color: page.muted
            font.pixelSize: 12
        }

        ListView {
            id: list
            objectName: "keybindingRows"

            Layout.fillWidth: true
            Layout.maximumWidth: 760
            Layout.fillHeight: true
            clip: true
            spacing: 2
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

                width: ListView.view.width
                implicitHeight: rowColumn.implicitHeight + 12
                height: implicitHeight
                radius: Math.min(Theme.radius, 8)
                color: hover.hovered ? Qt.alpha(Theme.palette.color("accentSurface", "#27272a"), 0.4) : "transparent"

                HoverHandler {
                    id: hover
                }

                ColumnLayout {
                    id: rowColumn

                    x: 8
                    y: 6
                    width: parent.width - 16
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                spacing: 6

                                Label {
                                    objectName: "label"
                                    text: row.modelData.label
                                    color: page.foreground
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                }

                                Label {
                                    objectName: "source"
                                    visible: row.modelData.source !== "Default"
                                    text: row.modelData.source
                                    color: page.muted
                                    font.pixelSize: 10
                                    leftPadding: 5
                                    rightPadding: 5
                                    background: Rectangle {
                                        radius: 4
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
                                font.pixelSize: 11
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
                        spacing: 6

                        Label {
                            text: qsTr("When")
                            color: page.muted
                            font.pixelSize: 11
                        }

                        WhenField {
                            id: rowWhen
                            Layout.fillWidth: true
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
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
