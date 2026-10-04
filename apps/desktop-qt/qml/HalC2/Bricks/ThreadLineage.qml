import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The open thread's relatives (Shell.state.lineage, ThreadLineageController),
// at the start of the conversation: the thread it was forked from, the forks
// made of it, and merging a fork back.
Rectangle {
    id: bar

    readonly property var lineage: Shell.state.lineage ?? null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "threadLineage"
    visible: lineage !== null
    implicitHeight: visible ? flow.implicitHeight + 12 : 0
    color: Qt.alpha(Theme.palette.color("surfaceOverlay", "#18181b"), 0.6)

    Flow {
        id: flow

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8

        Label {
            objectName: "lineageTitle"
            height: 24
            verticalAlignment: Text.AlignVCenter
            text: bar.lineage?.title ?? ""
            color: bar.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            font.weight: Font.Medium
        }

        ShellButton {
            objectName: "lineageParent"
            visible: (bar.lineage?.parent ?? null) !== null
            enabled: bar.lineage?.parent?.missing !== true
            subtle: true
            implicitHeight: 24
            iconName: "git-fork"
            iconSize: 12
            text: bar.lineage?.parent?.missing === true ? (bar.lineage?.parent?.title ?? "") : qsTr("Forked from %1").arg(bar.lineage?.parent?.title ?? "")
            onClicked: Shell.dispatch("lineage.open", {
                key: bar.lineage.parent.key
            })
        }

        Repeater {
            model: bar.lineage?.forks ?? []

            delegate: ShellButton {
                required property var modelData

                subtle: true
                implicitHeight: 24
                iconName: "git-fork"
                iconSize: 12
                text: modelData.running ? qsTr("%1 · running").arg(modelData.title) : modelData.title
                onClicked: Shell.dispatch("lineage.open", {
                    key: modelData.key
                })
            }
        }

        ShellButton {
            objectName: "lineageMergeBack"
            visible: (bar.lineage?.parent ?? null) !== null && bar.lineage?.parent?.missing !== true
            enabled: bar.lineage?.canMerge === true
            subtle: true
            implicitHeight: 24
            iconName: "git-merge"
            iconSize: 12
            text: qsTr("Merge back")
            ToolTip.visible: hovered
            ToolTip.text: bar.lineage?.mergeHint ?? ""
            onClicked: Shell.dispatch("lineage.mergeBack", {})
        }
    }
}
