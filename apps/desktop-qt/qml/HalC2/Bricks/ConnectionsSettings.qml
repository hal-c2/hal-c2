import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Connections settings page, native (ConnectionsController publishes
// `connections`): who may reach this machine (pairing links and paired
// clients), and which machine new threads start on (LoadBalancingGroup).
// Other machines join on the Cluster page.
SettingsPage {
    id: page

    readonly property var model: Shell.state.connections ?? null
    readonly property var access: model ? model.access : null
    readonly property var created: model ? model.created : null
    readonly property var notice: model ? model.notice : null
    readonly property bool busy: model !== null && model.busy
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color danger: Theme.palette.color("error", "#f87171")
    // What a pairing link may grant (packages/contracts auth scopes); the
    // standard ones start checked.
    readonly property var scopeOptions: [
        { scope: "orchestration:read", title: qsTr("View environment"), standard: true },
        { scope: "orchestration:operate", title: qsTr("Operate tasks"), standard: true },
        { scope: "terminal:operate", title: qsTr("Use terminals"), standard: true },
        { scope: "review:write", title: qsTr("Write reviews"), standard: true },
        { scope: "relay:read", title: qsTr("View relay"), standard: true },
        { scope: "access:read", title: qsTr("View access"), standard: false },
        { scope: "access:write", title: qsTr("Manage access"), standard: false },
        { scope: "relay:write", title: qsTr("Manage relay"), standard: false }
    ]
    property var chosenScopes: scopeOptions.filter(option => option.standard).map(option => option.scope)

    title: qsTr("Connections")

    function scopeTitles(scopes) {
        return scopeOptions.filter(option => scopes.indexOf(option.scope) >= 0).map(option => option.title).join(", ");
    }

    function when(iso) {
        const date = new Date(iso);
        return isNaN(date.getTime()) ? iso : date.toLocaleString(Qt.locale(), Locale.ShortFormat);
    }

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

    component EntryRow: RowLayout {
        id: row

        required property string label
        required property string detail
        property string action: ""
        property string actionName: ""

        signal activated

        Layout.fillWidth: true
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: row.label
            color: page.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            elide: Text.ElideRight
        }

        Label {
            Layout.maximumWidth: 320
            text: row.detail
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            elide: Text.ElideRight
        }

        ShellButton {
            visible: row.action.length > 0
            subtle: true
            enabled: !page.busy
            text: row.action
            Accessible.name: row.actionName
            onClicked: row.activated()
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            objectName: "connectionsNotice"
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: page.notice !== null
            text: page.notice ? page.notice.text : ""
            color: page.notice && page.notice.kind === "error" ? page.danger : Theme.palette.color("success", "#22c55e")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Heading {
            text: qsTr("This machine")
        }

        ConnectionStatusRow {
            Layout.fillWidth: true
        }

        EnvironmentIconPicker {
            Layout.fillWidth: true
            environmentId: Shell.state.sidebar?.localEnvironmentId ?? ""
        }

        Heading {
            text: qsTr("Other machines")
        }

        EntryRow {
            objectName: "connectionsCluster"
            label: qsTr("Cluster")
            detail: qsTr("Machines that share one sidebar")
            action: qsTr("Open")
            actionName: qsTr("Open the Cluster settings")
            onActivated: Shell.dispatch("cluster.open")
        }

        LoadBalancingGroup {
            Layout.fillWidth: true
            Layout.topMargin: 4
        }

        Heading {
            text: qsTr("Authorized clients")
        }

        Note {
            visible: page.model !== null && page.model.accessError !== null
            text: page.model && page.model.accessError ? page.model.accessError : ""
            color: page.danger
        }

        Note {
            visible: page.access === null && page.model !== null && page.model.accessError === null
            text: qsTr("Reading…")
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.access !== null
            spacing: 8

            Note {
                text: qsTr("A pairing link lets one more device reach this machine. It works once and expires after five minutes.")
            }

            ShellTextField {
                id: linkLabel
                Layout.fillWidth: true
                placeholderText: qsTr("Label, e.g. Phone")
            }

            Flow {
                Layout.fillWidth: true
                spacing: 4

                Repeater {
                    model: page.scopeOptions

                    delegate: CheckBox {
                        required property var modelData

                        text: modelData.title
                        checked: page.chosenScopes.indexOf(modelData.scope) >= 0
                        palette.windowText: page.foreground
                        onToggled: {
                            const others = page.chosenScopes.filter(scope => scope !== modelData.scope);
                            page.chosenScopes = checked ? others.concat([modelData.scope]) : others;
                        }
                    }
                }
            }

            ShellButton {
                primary: true
                enabled: !page.busy
                text: qsTr("Create pairing link")
                onClicked: {
                    Shell.dispatch("connections.pairingLink.create", {
                        label: linkLabel.text,
                        scopes: page.chosenScopes
                    });
                    linkLabel.clear();
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: page.created !== null
                spacing: 8

                ShellTextField {
                    objectName: "connectionsCreatedLink"
                    Layout.fillWidth: true
                    readOnly: true
                    selectByMouse: true
                    text: page.created ? page.created.url : ""
                    // The clipboard refused it: selected, ready to copy by hand.
                    readonly property bool revealed: page.model !== null && page.model.revealed === true
                    onRevealedChanged: if (revealed) {
                        forceActiveFocus();
                        selectAll();
                    }
                }

                ShellButton {
                    text: qsTr("Copy link")
                    onClicked: Shell.dispatch("connections.pairingLink.copy")
                }

                ShellButton {
                    text: qsTr("Copy code")
                    onClicked: Shell.dispatch("connections.pairingLink.copy", {
                        what: "code"
                    })
                }
            }

            Repeater {
                model: page.access ? page.access.pairingLinks : []

                delegate: EntryRow {
                    required property var modelData

                    label: modelData.label ?? qsTr("Pairing link")
                    detail: qsTr("%1 · expires %2").arg(page.scopeTitles(modelData.scopes ?? [])).arg(page.when(modelData.expiresAt))
                    action: qsTr("Revoke")
                    actionName: qsTr("Revoke the pairing link %1").arg(label)
                    onActivated: Shell.dispatch("connections.pairingLink.revoke", {
                        id: modelData.id
                    })
                }
            }

            Repeater {
                model: page.access ? page.access.clients : []

                delegate: EntryRow {
                    required property var modelData

                    label: modelData.client ? (modelData.client.label ?? modelData.client.deviceType) : modelData.sessionId
                    detail: modelData.current ? qsTr("this device") : modelData.connected ? qsTr("connected") : modelData.lastConnectedAt ? qsTr("last seen %1").arg(page.when(modelData.lastConnectedAt)) : qsTr("not connected")
                    action: modelData.current ? "" : qsTr("Revoke")
                    actionName: qsTr("Revoke %1").arg(label)
                    onActivated: Shell.dispatch("connections.client.revoke", {
                        sessionId: modelData.sessionId
                    })
                }
            }

            Note {
                visible: page.access !== null && page.access.pairingLinks.length === 0 && page.access.clients.length === 0
                text: qsTr("No pairing links or client sessions.")
            }

            ShellButton {
                visible: page.access !== null && page.access.clients.some(client => !client.current)
                enabled: !page.busy
                text: qsTr("Revoke every other client")
                onClicked: Shell.dispatch("connections.clients.revokeOthers")
            }
        }
    }
}
