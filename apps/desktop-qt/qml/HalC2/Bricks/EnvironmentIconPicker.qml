import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The kind of machine an environment runs on (`environmentIcons`,
// IdentityController): its icon, and a choice of kinds with the detected one
// marked. A kind that cannot be chosen says why.
RowLayout {
    id: root

    property string environmentId: ""
    readonly property var machine: Shell.state.environmentIcons?.[environmentId] ?? null
    readonly property var kinds: machine?.kinds ?? []
    readonly property bool locked: (machine?.lock ?? "").length > 0

    objectName: "environmentIconPicker"
    visible: machine !== null
    spacing: 8

    ShellIcon {
        objectName: "environmentIcon"
        name: root.machine?.icon ?? "server"
        size: 16
        color: Theme.palette.color("textMuted", "#8b8b93")
    }
    ShellComboBox {
        objectName: "environmentIconKind"
        outline: true
        enabled: !root.locked
        model: root.kinds.map(entry => entry.kind === root.machine?.detected ? qsTr("%1 (detected)").arg(entry.label) : entry.label)
        currentIndex: root.kinds.findIndex(entry => entry.kind === root.machine?.kind)
        Accessible.name: qsTr("Kind of machine")
        onActivated: index => Shell.dispatch("environmentIcon.set", {
            environmentId: root.environmentId,
            kind: root.kinds[index].kind
        })
    }
    Text {
        objectName: "environmentIconLock"
        Layout.fillWidth: true
        visible: root.locked
        text: root.machine?.lock ?? ""
        color: Theme.palette.color("textMuted", "#8b8b93")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }
}
