import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// "Applying settings for <project> across <environment>" at the top of a
// settings section that edits environments' settings (SettingsScopeController's
// `settingsScope`). The two pickers choose where a change is written; a scope
// that no longer exists says why instead.
ColumnLayout {
    id: sentence

    readonly property var scope: Shell.state.settingsScope ?? null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")

    objectName: "settingsScope"
    Layout.fillWidth: true
    visible: scope !== null
    spacing: 6

    Flow {
        Layout.fillWidth: true
        spacing: 6

        Label {
            height: projectPicker.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Applying settings for")
            color: sentence.muted
            font.pixelSize: 13
        }

        ShellComboBox {
            id: projectPicker

            objectName: "scopeProject"
            outline: true
            implicitWidth: 200
            model: [qsTr("All projects")].concat((sentence.scope?.projects ?? []).map(project => project.title))
            currentIndex: {
                const projects = sentence.scope?.projects ?? [];
                const found = projects.findIndex(project => project.key === sentence.scope.projectKey);
                return found + 1;
            }
            displayText: sentence.scope?.projectLabel ?? ""
            Accessible.name: qsTr("Project scope: %1").arg(displayText)
            onActivated: index => Shell.dispatch("settingsScope.project", { key: index === 0 ? "" : sentence.scope.projects[index - 1].key })
        }

        Label {
            height: projectPicker.height
            verticalAlignment: Text.AlignVCenter
            text: sentence.scope?.connective === "on" ? qsTr("on") : qsTr("across")
            color: sentence.muted
            font.pixelSize: 13
        }

        ShellComboBox {
            objectName: "scopeEnvironment"
            outline: true
            implicitWidth: 200
            // An environment that cannot be reached is marked, not hidden.
            model: [qsTr("All environments")].concat((sentence.scope?.environments ?? []).map(environment => environment.online ? environment.label : qsTr("%1 · Offline").arg(environment.label)))
            currentIndex: {
                const environments = sentence.scope?.environments ?? [];
                return environments.findIndex(environment => environment.id === sentence.scope.environmentId) + 1;
            }
            displayText: sentence.scope?.environmentLabel ?? ""
            Accessible.name: qsTr("Environment scope: %1").arg(displayText)
            onActivated: index => Shell.dispatch("settingsScope.environment", { id: index === 0 ? "" : sentence.scope.environments[index - 1].id })
        }
    }

    Label {
        objectName: "scopeNotice"
        Layout.fillWidth: true
        visible: text.length > 0
        text: sentence.scope?.disabledReason ?? ""
        color: sentence.warning
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
}
