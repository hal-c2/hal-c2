import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks when snoozed threads should wake (Shell.state.customSnooze: {keys,
// date, time, error}, SidebarController): a date and time of day, or a
// duration from now. The shell checks the answer and says what is wrong
// with it in `error`.
Dialog {
    id: dialog

    readonly property var request: Shell.state.customSnooze ?? null
    property string mode: "date"

    function submit() {
        Shell.dispatch("snooze.custom.submit", {
            mode: dialog.mode,
            date: dateField.text.trim(),
            time: timeField.text.trim(),
            amount: amountField.text.trim(),
            unit: ["minutes", "hours", "days"][unitBox.currentIndex]
        });
    }

    objectName: "customSnoozeDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(380, (parent?.width ?? 412) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Custom snooze")
    onRequestChanged: {
        if (request === null) {
            close();
        } else if (!opened) {
            mode = "date";
            dateField.text = request.date;
            timeField.text = request.time;
            amountField.text = "2";
            unitBox.currentIndex = 1;
            open();
        }
    }
    onRejected: Shell.dispatch("snooze.custom.cancel", {})

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: 17
        font.weight: Font.DemiBold
        color: Theme.palette.color("text", "#e4e4e7")
    }
    contentItem: ColumnLayout {
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: qsTr("Choose when snoozed threads return to your inbox.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            ShellButton {
                objectName: "customSnoozeDateMode"
                Layout.fillWidth: true
                text: qsTr("Date and time")
                primary: dialog.mode === "date"
                onClicked: dialog.mode = "date"
            }
            ShellButton {
                objectName: "customSnoozeDurationMode"
                Layout.fillWidth: true
                text: qsTr("Duration")
                primary: dialog.mode === "duration"
                onClicked: dialog.mode = "duration"
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: dialog.mode === "date"
            spacing: 8

            ShellTextField {
                id: dateField

                objectName: "customSnoozeDate"
                Layout.fillWidth: true
                placeholderText: qsTr("YYYY-MM-DD")
                Accessible.name: qsTr("Date")
                onAccepted: dialog.submit()
            }
            ShellTextField {
                id: timeField

                objectName: "customSnoozeTime"
                Layout.preferredWidth: 90
                placeholderText: qsTr("HH:MM")
                Accessible.name: qsTr("Time")
                onAccepted: dialog.submit()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: dialog.mode === "duration"
            spacing: 8

            ShellTextField {
                id: amountField

                objectName: "customSnoozeAmount"
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                Accessible.name: qsTr("Amount")
                onAccepted: dialog.submit()
            }
            ShellComboBox {
                id: unitBox

                objectName: "customSnoozeUnit"
                Layout.preferredWidth: 120
                outline: true
                model: [qsTr("Minutes"), qsTr("Hours"), qsTr("Days")]
                Accessible.name: qsTr("Unit")
            }
        }

        Label {
            objectName: "customSnoozeError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.request?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8

            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "customSnoozeAccept"
                text: qsTr("Snooze")
                primary: true
                onClicked: dialog.submit()
            }
        }
    }
}
