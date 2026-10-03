import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The right panel's Agents tab: the thread's subagents, running and finished,
// then its running commands, from an AgentsModel (Panel.agents). A subagent
// opens its own thread. Status dots are static; the elapsed times move once a
// second, and only while the tab shows (the model's timer).
//
//   AgentsPanel { anchors.fill: parent; source: Panel.agents }
Rectangle {
    id: root

    property var source: null

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    function dotColor(status) {
        if (status === "pending" || status === "running" || status === "waiting")
            return Theme.palette.color("info", "#38bdf8");
        if (status === "completed")
            return Theme.palette.color("success", "#22c55e");
        if (status === "failed")
            return root.errorColor;
        return root.muted;
    }

    objectName: "agentsPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    Text {
        objectName: "agentsEmpty"
        anchors.centerIn: parent
        width: parent.width - 32
        visible: list.count === 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: qsTr("No subagents or running commands in this thread.")
        color: root.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    ListView {
        id: list

        objectName: "agentsList"
        anchors.fill: parent
        anchors.margins: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.source
        section.property: "kind"
        section.delegate: Text {
            required property string section

            width: ListView.view.width
            topPadding: 8
            bottomPadding: 4
            leftPadding: 6
            text: section === "command" ? qsTr("Running commands") : qsTr("Agents")
            color: root.muted
            font.pixelSize: Math.round(11 * Theme.fontScale)
            font.weight: Font.Medium
        }

        delegate: AbstractButton {
            id: row

            required property string agentId
            required property string kind
            required property string title
            required property string status
            required property string statusLabel
            required property string elapsed
            required property string detail
            required property string modelName
            required property string childThreadKey

            readonly property bool opens: childThreadKey.length > 0

            objectName: "agentRow-" + agentId
            width: ListView.view.width
            height: kind === "command" ? 30 : 58
            enabled: opens
            hoverEnabled: opens
            Accessible.role: opens ? Accessible.Button : Accessible.StaticText
            Accessible.name: row.title + ", " + row.statusLabel
            onClicked: Shell.dispatch("rightPanel.openThread", {
                threadKey: row.childThreadKey
            })
            background: Rectangle {
                radius: 6
                color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
            }

            Rectangle {
                id: dot

                x: 8
                y: 12
                width: 6
                height: 6
                radius: 3
                color: root.dotColor(row.status)
            }

            Text {
                id: titleText

                anchors.left: dot.right
                anchors.leftMargin: 8
                anchors.right: elapsedText.left
                anchors.rightMargin: 8
                y: 6
                text: row.title
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.foreground
                font.pixelSize: row.kind === "command" ? 12 : 13
                font.family: row.kind === "command" ? root.mono : Qt.application.font.family
                font.weight: row.kind === "command" ? Font.Normal : Font.Medium
            }

            Text {
                id: elapsedText

                anchors.right: parent.right
                anchors.rightMargin: 8
                y: 7
                text: row.elapsed
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
                font.family: root.mono
            }

            Text {
                anchors.left: titleText.left
                anchors.right: parent.right
                anchors.rightMargin: 8
                y: 26
                visible: row.kind === "subagent"
                text: row.detail.split("\n")[0]
                elide: Text.ElideRight
                maximumLineCount: 1
                color: row.status === "failed" ? root.errorColor : root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Text {
                anchors.left: titleText.left
                anchors.right: parent.right
                anchors.rightMargin: 8
                y: 42
                visible: row.kind === "subagent"
                text: [row.statusLabel, row.modelName].filter(part => part.length > 0).join(" · ")
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
                font.family: root.mono
            }
        }
    }
}
