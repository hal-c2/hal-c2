pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The Archive settings section (ArchivedThreadsController publishes
// `archivedThreads`): the archived threads by project, each with a way back
// and a way out.
Rectangle {
    id: page

    objectName: "archivedThreads"

    readonly property var model: Shell.state.archivedThreads ?? null
    readonly property var groups: model ? model.groups : []
    readonly property color foreground: Theme.palette.color("ink", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")

    function act(action, thread) {
        Shell.dispatch("archivedThreads." + action, { environmentId: thread.environmentId, threadId: thread.threadId });
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    Flickable {
        id: flick

        anchors.fill: parent
        contentHeight: column.implicitHeight + 2 * Theme.space.xl
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column

            x: Pages.columnX(flick.width, Theme.space.xl)
            y: Theme.space.xl
            width: Pages.columnWidth(flick.width, Theme.space.xl)
            spacing: Theme.space.md

            SettingsBreadcrumb {
                Layout.fillWidth: true
                section: qsTr("Archive")

                ShellButton {
                    objectName: "refresh"
                    subtle: true
                    enabled: page.model !== null && page.model.status !== "loading"
                    text: qsTr("Refresh")
                    onClicked: Shell.dispatch("archivedThreads.refresh")
                }
            }

            // A picked project or environment narrows the list to its threads.
            SettingsScopeSentence {}

            // Why nothing is listed: loading, failed or empty, in one place.
            ShellEmptyState {
                objectName: "placeholder"
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.space.xxl
                visible: page.model !== null && page.model.title.length > 0
                status: page.model?.status === "loading" || page.model?.status === "error" ? page.model.status : "empty"
                iconName: "archive"
                title: page.model ? page.model.title : ""
                description: page.model ? page.model.description : ""
                actionText: page.model?.status === "error" ? qsTr("Try again") : ""
                onActionTriggered: Shell.dispatch("archivedThreads.refresh")
            }

            Repeater {
                model: page.groups

                // A project's archived threads under its title, each on a hairline.
                delegate: ColumnLayout {
                    id: group

                    required property var modelData

                    objectName: "group_" + modelData.key
                    Layout.fillWidth: true
                    spacing: Theme.space.md

                    SettingsHeading {
                        text: group.modelData.title
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                    }

                    Repeater {
                        model: group.modelData.threads

                        delegate: ColumnLayout {
                            id: row

                            required property var modelData

                            objectName: "thread_" + modelData.key
                            Layout.fillWidth: true
                            spacing: Theme.space.md

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 1
                                color: Theme.palette.color("border", "#27272a")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space.sm

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.space.xxs

                                    Label {
                                        Layout.fillWidth: true
                                        text: row.modelData.title
                                        color: page.foreground
                                        font.pixelSize: Theme.type.body.size
                                        elide: Text.ElideRight
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        text: row.modelData.description
                                        color: page.muted
                                        font.pixelSize: Theme.type.meta.size
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
                                    // Permanent, so it reads as destructive.
                                    tint: Theme.palette.color("errorForeground", "#ef4444")
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
