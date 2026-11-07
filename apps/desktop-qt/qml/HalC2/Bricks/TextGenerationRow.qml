import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → General's text generation model (TextGenerationController's
// `textGeneration`): the model that writes thread titles and other generated
// text on the selected environments, or why none can be chosen.
RowLayout {
    id: row

    required property var spec
    readonly property var model: Shell.state.textGeneration ?? null
    readonly property var models: model?.models ?? []
    readonly property string unavailable: model?.unavailable ?? ""

    objectName: "settingsRow:" + spec.id
    Layout.fillWidth: true
    spacing: Theme.space.md

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.space.xxs

        RowLayout {
            spacing: Theme.space.xs

            Label {
                text: row.spec.title
                color: Theme.palette.color("ink", "#e4e4e7")
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
            }

            ShellButton {
                objectName: "reset"
                visible: row.model?.resettable ?? false
                subtle: true
                iconName: "undo-2"
                iconSize: 12
                implicitWidth: 20
                implicitHeight: 20
                Accessible.name: qsTr("Reset text generation model to default")
                onClicked: Shell.dispatch("textGeneration.reset")
            }
        }

        Label {
            Layout.fillWidth: true
            text: row.spec.description
            color: Theme.palette.color("inkTertiary", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
        }
    }

    Label {
        objectName: "unavailable"
        visible: row.unavailable.length > 0
        text: row.unavailable
        color: Theme.palette.color("inkTertiary", "#a1a1aa")
        font.pixelSize: Theme.type.meta.size
    }

    ShellComboBox {
        objectName: "control"
        visible: row.unavailable.length === 0
        enabled: Shell.state.settingsScope?.editable ?? false
        outline: true
        implicitWidth: 220
        model: row.models
        textRole: "label"
        currentIndex: row.models.findIndex(model => model.key === (row.model?.value ?? ""))
        displayText: row.model?.label ?? ""
        Accessible.name: row.spec.title
        onActivated: index => Shell.dispatch("textGeneration.choose", { key: row.models[index].key })
    }
}
