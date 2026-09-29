import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Archive settings section (ArchivedThreadsController publishes
// `archivedThreads`): the archived threads by project, each with a way back
// and a way out.
Rectangle {
    id: page

    objectName: "archivedThreads"

    readonly property var model: Shell.state.archivedThreads ?? null
    readonly property var groups: model ? model.groups : []
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    function act(action, thread) {
        Shell.dispatch("archivedThreads." + action, { environmentId: thread.environmentId, threadId: thread.threadId });
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column

            x: 24
            y: 24
            width: Math.min(720, parent.width - 48)
            spacing: 8

            RowLayout {
                Layout.fillWidth: true

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Archive")
                    color: page.foreground
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }

                ShellButton {
                    objectName: "refresh"
                    subtle: true
                    enabled: page.model !== null && page.model.status !== "loading"
                    text: qsTr("Refresh")
                    onClicked: Shell.dispatch("archivedThreads.refresh")
                }
            }

            // Why nothing is listed.
            ColumnLayout {
                objectName: "placeholder"
                Layout.fillWidth: true
                Layout.topMargin: 12
                visible: page.model !== null && page.model.title.length > 0
                spacing: 4

                Label {
                    objectName: "placeholderTitle"
                    Layout.fillWidth: true
                    text: page.model ? page.model.title : ""
                    color: page.foreground
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                Label {
                    Layout.fillWidth: true
                    text: page.model ? page.model.description : ""
                    color: page.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            Repeater {
                model: page.groups

                delegate: ShellCard {
                    id: group

                    required property var modelData

                    objectName: "group_" + modelData.key
                    Layout.fillWidth: true
                    implicitHeight: groupColumn.implicitHeight + 24

                    ColumnLayout {
                        id: groupColumn

                        x: 12
                        y: 12
                        width: parent.width - 24
                        spacing: 6

                        Label {
                            Layout.fillWidth: true
                            text: group.modelData.title
                            color: page.muted
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Repeater {
                            model: group.modelData.threads

                            delegate: RowLayout {
                                id: row

                                required property var modelData

                                objectName: "thread_" + modelData.key
                                Layout.fillWidth: true
                                spacing: 8

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Label {
                                        Layout.fillWidth: true
                                        text: row.modelData.title
                                        color: page.foreground
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        text: row.modelData.description
                                        color: page.muted
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                }

                                ShellButton {
                                    objectName: "unarchive"
                                    enabled: !row.modelData.busy
                                    text: qsTr("Unarchive")
                                    onClicked: page.act("unarchive", row.modelData)
                                }

                                ShellButton {
                                    objectName: "delete"
                                    subtle: true
                                    enabled: !row.modelData.busy
                                    text: qsTr("Delete")
                                    Accessible.name: qsTr("Delete %1").arg(row.modelData.title)
                                    onClicked: page.act("delete", row.modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
