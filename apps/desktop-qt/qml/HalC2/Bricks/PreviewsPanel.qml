pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The right panel's Previews tab: the thread's browser tabs as the MC keeps
// them, from a ThreadPreviews model (Panel.previews). The desktop embeds no
// browser: a row opens its page in the user's browser, and closes from here.
// An empty tab (the add menu's "Browser tab") offers where to go: the web
// servers on the MC's machine, the project's preview addresses and the pages
// opened last, or an address typed in.
//
//   PreviewsPanel { anchors.fill: parent; source: Panel.previews }
Rectangle {
    id: root

    property var source: null

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")

    objectName: "previewsPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    Item {
        id: header

        width: parent.width
        height: 40

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: reload.left
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Browser tabs open in your browser")
            elide: Text.ElideRight
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellButton {
            id: reload

            objectName: "previewsReload"
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            subtle: true
            iconName: "refresh-cw"
            Accessible.name: qsTr("Reload browser tabs")
            ToolTip.visible: hovered
            ToolTip.text: Accessible.name
            onClicked: root.source.reload()
        }
    }

    Text {
        id: failure

        objectName: "previewsProblem"
        anchors.top: header.bottom
        x: 12
        width: parent.width - 24
        visible: root.source !== null && root.source.status === "failed"
        height: visible ? implicitHeight + 6 : 0
        wrapMode: Text.Wrap
        text: root.source ? qsTr("Could not list browser tabs: %1").arg(root.source.message) : ""
        color: root.errorColor
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    Text {
        objectName: "previewsEmpty"
        anchors.centerIn: parent
        width: parent.width - 32
        visible: list.count === 0 && root.source !== null && root.source.status === "ready"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: qsTr("No browser tabs in this thread. Tabs the agent opens show here.")
        color: root.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    readonly property string emptyTab: root.source?.emptyTab ?? ""

    ListView {
        id: list

        objectName: "previewsList"
        anchors.top: failure.bottom
        anchors.bottom: suggestions.top
        width: parent.width
        leftMargin: 6
        rightMargin: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.source

        delegate: AbstractButton {
            id: row

            required property string tabId
            required property string url
            required property string title
            required property string status
            required property string problem

            objectName: "previewRow-" + tabId
            width: ListView.view.width - 12
            height: 46
            enabled: url.length > 0
            hoverEnabled: true
            Accessible.role: Accessible.Button
            Accessible.name: row.title
            onClicked: root.source.open(row.tabId)
            background: Rectangle {
                radius: 6
                color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
            }

            ShellIcon {
                id: glyph

                x: 8
                y: 8
                size: 14
                name: row.status === "failed" ? "circle-x" : "monitor"
                color: row.status === "failed" ? root.errorColor : root.muted
            }

            Text {
                id: titleText

                anchors.left: glyph.right
                anchors.leftMargin: 8
                anchors.right: closeButton.left
                anchors.rightMargin: 4
                y: 6
                text: row.title
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            Text {
                anchors.left: titleText.left
                anchors.right: closeButton.left
                anchors.rightMargin: 4
                y: 25
                text: row.problem.length > 0 ? row.problem : row.url
                elide: Text.ElideMiddle
                maximumLineCount: 1
                color: row.problem.length > 0 ? root.errorColor : root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }

            ShellButton {
                id: closeButton

                objectName: "previewClose"
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Close browser tab")
                onClicked: root.source.close(row.tabId)
            }
        }
    }

    // What the empty tab can open.
    Column {
        id: suggestions

        objectName: "previewSuggestions"
        anchors.bottom: parent.bottom
        x: 12
        width: parent.width - 24
        visible: root.emptyTab.length > 0
        height: visible ? implicitHeight + 12 : 0
        spacing: 4

        Text {
            text: qsTr("Open in the new tab")
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellTextField {
            objectName: "previewAddress"
            width: parent.width
            placeholderText: qsTr("http://localhost:3000")
            Accessible.name: qsTr("Address")
            onAccepted: {
                if (text.trim().length > 0)
                    root.source.navigate(root.emptyTab, text.trim());
            }
        }

        Repeater {
            model: suggestions.visible && root.source !== null ? root.source.suggestions : []

            delegate: ShellButton {
                id: suggestion

                required property var modelData
                required property int index

                objectName: "previewSuggestion-" + index
                width: suggestions.width
                subtle: true
                horizontalPadding: 8
                iconName: modelData.kind === "server" ? "server" : modelData.kind === "recent" ? "clock" : "monitor"
                text: modelData.url
                Accessible.name: modelData.label.length > 0 ? qsTr("%1, %2").arg(modelData.url).arg(modelData.label) : modelData.url
                onClicked: root.source.navigate(root.emptyTab, modelData.url)
            }
        }
    }
}
