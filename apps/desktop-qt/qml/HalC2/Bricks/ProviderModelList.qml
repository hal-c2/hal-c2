import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A provider instance's models as this device's model picker offers them, on
// the Providers settings section: hiding one, showing it again, and moving it
// up or down (`providerSettings.modelHidden`, `.modelMove`).
ColumnLayout {
    id: list

    required property var provider

    function act(action, extra) {
        Shell.dispatch("providerSettings." + action, Object.assign({ instanceId: list.provider.instanceId }, extra));
    }

    objectName: "modelList"
    visible: (provider.models ?? []).length > 0
    spacing: 2

    Label {
        Layout.fillWidth: true
        text: qsTr("Models in the picker on this device")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    Repeater {
        model: list.provider.models ?? []

        delegate: RowLayout {
            id: row

            required property var modelData
            required property int index

            Layout.fillWidth: true
            spacing: 4

            Label {
                Layout.fillWidth: true
                text: row.modelData.name.length > 0 ? row.modelData.name : row.modelData.slug
                color: Theme.palette.color(row.modelData.hidden ? "textMuted" : "text", row.modelData.hidden ? "#a1a1aa" : "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.strikeout: row.modelData.hidden
                elide: Text.ElideRight
            }

            ShellButton {
                subtle: true
                iconName: "chevron-up"
                enabled: row.index > 0
                Accessible.name: qsTr("Move %1 up").arg(row.modelData.name)
                onClicked: list.act("modelMove", { slug: row.modelData.slug, by: -1 })
            }

            ShellButton {
                subtle: true
                iconName: "chevron-down"
                enabled: row.index < list.provider.models.length - 1
                Accessible.name: qsTr("Move %1 down").arg(row.modelData.name)
                onClicked: list.act("modelMove", { slug: row.modelData.slug, by: 1 })
            }

            ShellButton {
                objectName: "modelHidden-" + row.modelData.slug
                subtle: true
                text: row.modelData.hidden ? qsTr("Show") : qsTr("Hide")
                Accessible.name: row.modelData.hidden ? qsTr("Show %1 in the picker").arg(row.modelData.name) : qsTr("Hide %1 from the picker").arg(row.modelData.name)
                onClicked: list.act("modelHidden", { slug: row.modelData.slug, hidden: !row.modelData.hidden })
            }
        }
    }
}
