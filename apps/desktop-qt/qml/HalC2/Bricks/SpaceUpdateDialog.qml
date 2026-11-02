pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Gives the open page its update, or changes it: an instruction and a cadence,
// an interval or a time of day. `ask` starts from what the page has. Weekdays
// the MC holds on a time of day are kept, not edited here.
Dialog {
    id: dialog

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property var cadence: cadenceOf(mode.currentIndex === 1, time.text, Number(every.text), unit.currentIndex === 0 ? 3600000 : 60000)
    readonly property bool ready: instruction.text.trim().length > 0 && cadence !== null
    property bool editing: false
    property var weekdays: []

    // The cadence asked for, or null while what is typed cannot be one.
    function cadenceOf(interval, timeOfDay, count, unitMs) {
        if (interval)
            return Number.isInteger(count) && count > 0 ? { type: "interval", everyMs: count * unitMs } : null;
        return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(timeOfDay) ? { type: "fixed_time", timeOfDay: timeOfDay, weekdays: dialog.weekdays } : null;
    }

    function ask() {
        const schedule = Spaces.page.schedule ?? {};
        const given = schedule.cadence ?? {};
        const interval = given.type === "interval";
        const hours = interval && given.everyMs % 3600000 === 0;
        editing = (schedule.instruction ?? "") !== "";
        instruction.text = schedule.instruction ?? "";
        mode.currentIndex = interval || !editing ? 1 : 0;
        time.text = given.timeOfDay ?? "09:00";
        every.text = interval ? String(given.everyMs / (hours ? 3600000 : 60000)) : "2";
        unit.currentIndex = interval && !hours ? 1 : 0;
        weekdays = given.weekdays ?? [];
        open();
        instruction.forceActiveFocus();
    }

    function save() {
        if (!ready)
            return;
        Shell.dispatch("space.page.schedule.set", { pageId: Spaces.pageId, instruction: instruction.text.trim(), cadence: cadence });
        close();
    }

    objectName: "spaceUpdateDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(460, (parent?.width ?? 492) / scale - 32)
    height: Math.min(implicitHeight, (parent?.height ?? 500) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: editing ? qsTr("Change this page's update") : qsTr("Have this page update itself")

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Math.round(17 * Theme.fontScale)
        font.weight: Font.DemiBold
        color: dialog.foreground
    }

    component Caption: Label {
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    contentItem: ColumnLayout {
        spacing: 8

        Caption { text: qsTr("Instruction") }
        TextArea {
            id: instruction

            objectName: "spaceUpdateInstruction"
            Layout.fillWidth: true
            Layout.preferredHeight: 96
            wrapMode: TextEdit.Wrap
            color: dialog.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            placeholderText: qsTr("Summarise yesterday's threads")
            placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
            Accessible.name: qsTr("Instruction")
            background: Rectangle {
                radius: Math.min(Theme.radius, 8)
                color: Theme.palette.color("input", "#18181b")
                border.color: Theme.palette.color("border", "#27272a")
            }
        }

        Caption { text: qsTr("When") }
        ShellComboBox {
            id: mode

            objectName: "spaceUpdateMode"
            Layout.fillWidth: true
            outline: true
            model: [qsTr("At a time of day"), qsTr("Every so often")]
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellTextField {
                id: time

                objectName: "spaceUpdateTime"
                visible: mode.currentIndex === 0
                implicitWidth: 80
                inputMask: "99:99"
                Accessible.name: qsTr("Time of day")
            }

            Caption {
                visible: mode.currentIndex === 0
                text: dialog.weekdays.length > 0 ? qsTr("on the same days as now") : qsTr("every day")
            }

            ShellTextField {
                id: every

                objectName: "spaceUpdateEvery"
                visible: mode.currentIndex === 1
                implicitWidth: 80
                Accessible.name: qsTr("How often")
            }

            ShellComboBox {
                id: unit

                objectName: "spaceUpdateUnit"
                visible: mode.currentIndex === 1
                outline: true
                implicitWidth: 120
                model: [qsTr("hours"), qsTr("minutes")]
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "spaceUpdateCancel"
                text: qsTr("Cancel")
                onClicked: dialog.close()
            }

            ShellButton {
                objectName: "spaceUpdateSave"
                primary: true
                enabled: dialog.ready
                text: qsTr("Save")
                onClicked: dialog.save()
            }
        }
    }
}
