import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages
import "js/settingsRows.js" as Rows

// Settings navigation: sections, search, and a way back. The sections are
// js/settingsPages.js, each listed once the state it needs is there. Picking
// a section with an `action` dispatches it; any other navigates the route.
Rectangle {
    id: nav

    // The section showing, from the shell's route.
    readonly property var route: Shell.state.route ?? null
    readonly property string currentSection: Pages.resolve(route !== null && route.kind === "settings" ? route.section : "")
    readonly property string query: search.text.trim().toLowerCase()
    // Every row says whether it is a search result, so a row never reads the
    // other shape while the query and the rows change together.
    readonly property var rows: {
        const state = Shell.state;
        if (query.length === 0) {
            return Pages.navRows(state).map(section => ({
                        result: false,
                        to: section.to,
                        label: section.label,
                        action: section.action
                    }));
        }
        return Pages.searchRows(query, state, Keybindings.bindings).map(section => ({
                    result: true,
                    to: section.to,
                    title: section.label,
                    sectionLabel: section.detail ?? section.label,
                    action: section.action,
                    targetId: section.targetId
                }));
    }
    readonly property color foreground: Theme.palette.color("sidebarForeground", "#e4e4e7")
    readonly property color muted: Theme.palette.color("sidebarMutedForeground", "#8b8b93")

    implicitWidth: 260
    color: Theme.palette.color("sidebar", "#0a0a0a")

    // What restoring this device's defaults resets, by name: the theme choice,
    // then each General and Appearance row off its default (the web's
    // useSettingsRestore).
    readonly property bool themeChanged: Themes.themeId !== "" || Themes.mode !== "system" || Object.keys(Themes.halves ?? {}).length > 0
    readonly property var changedRows: {
        // isDefault reads these; the binding follows them.
        Settings.document;
        Settings.device;
        return Rows.changed(key => Settings.isDefault(key), Qt.platform.os);
    }
    readonly property var changedLabels: (Themes.themeId !== "" ? [qsTr("Theme")] : [])
        .concat(Themes.mode !== "system" ? [qsTr("Follow system")] : [])
        .concat(Object.keys(Themes.halves ?? {}).length > 0 ? [qsTr("Theme mix")] : [])
        .concat(changedRows.map(row => row.title))

    // Resets what `changedLabels` lists; a theme that cannot be restored
    // keeps everything as it was.
    function restoreDefaults() {
        const keys = changedRows.map(row => row.key);
        if (themeChanged && !Themes.restoreDefaults()) return;
        if (keys.length > 0) Settings.resetAll(keys);
    }

    // "/" starts a search while the keyboard is not in a text field.
    Shortcut {
        sequence: "/"
        enabled: nav.visible && !(nav.Window.activeFocusItem && nav.Window.activeFocusItem.cursorPosition !== undefined)
        onActivated: search.forceActiveFocus()
    }

    function focusRow(index) {
        list.currentIndex = Math.max(0, Math.min(index, list.count - 1));
        if (list.currentItem) list.currentItem.forceActiveFocus();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 10
            Layout.bottomMargin: 4
            spacing: 8

            ShellButton {
                subtle: true
                text: "←"
                Accessible.name: qsTr("Back")
                onClicked: Shell.dispatch("settings.back")
            }

            Label {
                Layout.fillWidth: true
                text: qsTr("Settings")
                color: nav.foreground
                font.bold: true
            }
        }

        ShellTextField {
            id: search
            objectName: "search"

            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.bottomMargin: 6
            placeholderText: qsTr("Search settings")
            Keys.onEscapePressed: text = ""
        }

        ShellButton {
            objectName: "restoreDefaults"
            Layout.leftMargin: 10
            Layout.bottomMargin: 6
            subtle: true
            enabled: nav.changedLabels.length > 0
            text: qsTr("Restore device defaults")
            onClicked: restoreDialog.open()
        }

        ListView {
            id: list

            readonly property bool searching: nav.query.length > 0

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: nav.rows

            delegate: ItemDelegate {
                id: row

                required property var modelData
                required property int index
                objectName: "settingsRow" + index

                readonly property bool isResult: modelData.result
                readonly property bool current: !isResult && nav.currentSection === modelData.to

                width: ListView.view.width
                implicitHeight: isResult ? 48 : 36
                Accessible.name: isResult ? modelData.title : modelData.label
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                Keys.onDownPressed: nav.focusRow(index + 1)
                Keys.onUpPressed: nav.focusRow(index - 1)
                onClicked: row.modelData.action ? Shell.dispatch(row.modelData.action) : row.isResult && row.modelData.targetId ? Shell.dispatch("settings.openResult", {
                    to: row.modelData.to,
                    targetId: row.modelData.targetId
                }) : Shell.dispatch("settings.navigate", {
                    to: row.modelData.to
                })

                background: Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    radius: 6
                    color: row.current ? Theme.palette.color("sidebarRowSelected", "#2a2a30") : row.hovered || row.visualFocus ? Theme.palette.color("sidebarRowHover", "#1c1c21") : "transparent"
                }

                contentItem: ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 1

                    Text {
                        Layout.fillWidth: true
                        text: row.isResult ? row.modelData.title : row.modelData.label
                        color: nav.foreground
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: row.isResult
                        text: row.isResult ? row.modelData.sectionLabel : ""
                        color: nav.muted
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
            }

            Text {
                objectName: "noMatches"
                anchors.centerIn: parent
                visible: list.searching && list.count === 0
                text: qsTr("No matching settings")
                color: nav.muted
                font.pixelSize: 12
            }
        }
    }

    Dialog {
        id: restoreDialog
        objectName: "restoreDialog"

        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        width: Math.min(440, (parent?.width ?? 472) / scale - 32)
        padding: 20
        title: qsTr("Restore default settings?")
        onAccepted: nav.restoreDefaults()

        background: Rectangle {
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            radius: Math.min(Theme.radius, 16)
        }
        header: Label {
            text: restoreDialog.title
            padding: 20
            bottomPadding: 4
            font.pixelSize: 17
            font.weight: Font.DemiBold
            color: Theme.palette.color("text", "#e4e4e7")
        }
        contentItem: ColumnLayout {
            spacing: 12

            Label {
                objectName: "restoreList"
                Layout.fillWidth: true
                text: qsTr("This will reset: %1.").arg(nav.changedLabels.join(", "))
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "cancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: restoreDialog.reject()
                }

                ShellButton {
                    objectName: "confirm"
                    tint: Theme.palette.color("error", "#ef4444")
                    text: qsTr("Restore defaults")
                    onClicked: restoreDialog.accept()
                }
            }
        }
    }
}
