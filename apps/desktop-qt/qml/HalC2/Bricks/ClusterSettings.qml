pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// This machine's cluster, a native settings page (ClusterController publishes
// `cluster`): its members, an invite link for another machine, joining another
// machine's cluster with its link, and removing a member.
Rectangle {
    id: page

    readonly property var model: Shell.state.cluster ?? null
    readonly property var status: model ? model.status : null
    readonly property bool clustered: status !== null && status.clustered === true
    readonly property var invite: model ? model.invite : null
    readonly property var notice: model ? model.notice : null
    readonly property bool busy: model !== null && model.busy
    // The session cannot manage the cluster: the page explains and locks what it would do.
    readonly property bool needsAdmin: model !== null && model.needsAdmin === true
    readonly property bool canChange: !busy && !needsAdmin
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    color: Theme.palette.color("canvas", "#0b0b0d")

    component Heading: Label {
        Layout.fillWidth: true
        Layout.topMargin: 12
        color: page.foreground
        font.pixelSize: Math.round(14 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    component Note: Label {
        Layout.fillWidth: true
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    component MemberRow: RowLayout {
        id: memberRow

        required property string label
        required property string detail
        property string memberId: ""

        Layout.fillWidth: true
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: memberRow.label
            color: page.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            elide: Text.ElideRight
        }

        Label {
            text: memberRow.detail
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellButton {
            visible: memberRow.memberId.length > 0
            subtle: true
            enabled: !page.busy
            text: qsTr("Remove")
            Accessible.name: qsTr("Remove %1 from the cluster").arg(memberRow.label)
            onClicked: Shell.dispatch("cluster.remove", {
                id: memberRow.memberId
            })
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column

            x: 24
            y: 24
            width: Math.min(640, parent.width - 48)
            spacing: 8

            SettingsBreadcrumb {
                Layout.fillWidth: true
                section: qsTr("Cluster")
            }

            Note {
                text: qsTr("Your machines share one sidebar, and threads move between them.")
            }

            Label {
                objectName: "clusterNotice"
                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: page.notice !== null
                text: page.notice ? page.notice.text : ""
                color: page.notice && page.notice.kind === "error" ? Theme.palette.color("error", "#f87171") : Theme.palette.color("success", "#22c55e")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Heading {
                text: qsTr("Machines")
            }

            Note {
                objectName: "clusterNeedsAdmin"
                visible: page.needsAdmin
                text: qsTr("Managing the cluster needs an administrator session. Pair this desktop with a link that grants Manage access.")
            }

            Note {
                visible: page.status === null && !page.needsAdmin
                text: page.model && page.model.error ? page.model.error : qsTr("Reading…")
            }

            Note {
                visible: page.status !== null && !page.clustered
                text: page.status && !page.clustered ? page.status.reason : ""
            }

            MemberRow {
                visible: page.clustered
                label: page.clustered ? page.status.label : ""
                detail: qsTr("this machine")
            }

            Repeater {
                model: page.clustered ? page.status.members : []

                delegate: MemberRow {
                    required property var modelData
                    label: modelData.label
                    detail: {
                        const connection = modelData.connected ? qsTr("connected") : qsTr("offline");
                        if (modelData.compatible === false)
                            return qsTr("Update your machines to connect (%1)").arg(modelData.version ?? qsTr("unknown version"));
                        if (modelData.updateRecommended)
                            return qsTr("%1 (%2). Please update your machines.").arg(connection).arg(modelData.version);
                        return connection;
                    }
                    memberId: modelData.id
                }
            }

            Note {
                visible: page.clustered && page.status.members.length === 0
                text: qsTr("No other machines yet. Invite one below.")
            }

            Heading {
                text: qsTr("Invite a machine")
            }

            Note {
                text: qsTr("The link is good once and copied when made. Open it on the other machine's Cluster settings.")
            }

            RowLayout {
                spacing: 8

                ShellButton {
                    objectName: "clusterInvite"
                    primary: true
                    enabled: page.canChange
                    text: qsTr("Make an invite")
                    onClicked: Shell.dispatch("cluster.invite")
                }

                ShellButton {
                    objectName: "clusterInviteTailscale"
                    enabled: page.canChange
                    text: qsTr("Invite over Tailscale")
                    onClicked: Shell.dispatch("cluster.invite", {
                        tailscale: true
                    })
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: page.invite !== null
                spacing: 8

                ShellTextField {
                    objectName: "clusterInviteLink"
                    Layout.fillWidth: true
                    readOnly: true
                    selectByMouse: true
                    text: page.invite ? page.invite.link : ""
                }

                ShellButton {
                    text: qsTr("Copy")
                    onClicked: Shell.dispatch("cluster.invite.copy")
                }
            }

            Heading {
                text: qsTr("Join another machine's cluster")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ShellTextField {
                    id: joinLink
                    objectName: "clusterJoinLink"
                    Layout.fillWidth: true
                    enabled: !page.needsAdmin
                    placeholderText: qsTr("Invite link from the other machine…")
                    onAccepted: join.clicked()
                }

                ShellButton {
                    id: join
                    objectName: "clusterJoin"
                    enabled: page.canChange
                    text: qsTr("Join")
                    onClicked: {
                        Shell.dispatch("cluster.join", {
                            link: joinLink.text
                        });
                        if (joinLink.text.trim().length > 0) joinLink.clear();
                    }
                }
            }
        }
    }
}
