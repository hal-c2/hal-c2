import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The phone layout's home: every thread of the environment, grouped as the
// desktop's sidebar groups them (the Sidebar brick over `sidebar`), under a
// bar with the environment, settings and a new thread.
ColumnLayout {
    id: screen

    readonly property var model: Shell.state.sidebar ?? null
    readonly property var projects: model !== null ? (model.projects ?? []) : []
    // The project the list is narrowed to (a row's "Filter by" menu item).
    readonly property var scope: model !== null ? (model.scopeProjectKey ?? null) : null
    readonly property string scopeName: {
        const project = projects.find(candidate => candidate.key === scope);
        return project ? project.displayName : "";
    }

    objectName: "homeScreen"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: qsTr("Threads")

        MobileIconButton {
            objectName: "environment"
            iconName: "monitor"
            label: qsTr("Environment")
            // The route is the MC's first snapshot away.
            enabled: (Shell.state.route ?? null) !== null
            onClicked: Shell.dispatch("settings.navigate", { to: "/settings/pairing" })
        }

        MobileIconButton {
            objectName: "settings"
            iconName: "settings"
            label: qsTr("Settings")
            enabled: (Shell.state.route ?? null) !== null
            onClicked: Shell.dispatch("settings.open")
        }

        MobileIconButton {
            objectName: "newThread"
            iconName: "square-pen"
            label: qsTr("New thread")
            enabled: screen.projects.length > 0
            // In the project the list is narrowed to or the only one; with
            // several, the shell asks which (DraftController).
            onClicked: Shell.dispatch("thread.new", screen.scope !== null ? { projectKey: screen.scope } : {})
        }
    }

    // The way out of a narrowed list, and the way to see that it is one.
    RowLayout {
        objectName: "scopeBar"
        Layout.fillWidth: true
        Layout.leftMargin: 16
        Layout.rightMargin: 4
        visible: screen.scope !== null
        spacing: 8

        Label {
            objectName: "scopeLabel"
            Layout.fillWidth: true
            text: qsTr("Only %1").arg(screen.scopeName)
            elide: Text.ElideRight
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
        }

        MobileButton {
            objectName: "scopeClear"
            subtle: true
            text: qsTr("Show all projects")
            onClicked: Shell.dispatch("sidebar.scope", { projectKey: null })
        }
    }

    Sidebar {
        objectName: "threadList"
        Layout.fillWidth: true
        Layout.fillHeight: true
        // Search is the command palette's and the footer's places are the
        // desktop's; the bar above has what a phone starts from here.
        showScope: false
        showFooter: false
        touchRows: true

        // Projects are added where their folders are.
        Label {
            objectName: "noProjectsHint"
            anchors.horizontalCenter: parent.horizontalCenter
            y: 56
            width: Math.min(parent.width - 48, 420)
            visible: screen.model !== null && screen.projects.length === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            text: qsTr("Add a project in HAL-C2 on the environment's machine, and its threads show up here.")
        }
    }
}
