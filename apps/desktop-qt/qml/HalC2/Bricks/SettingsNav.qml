import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages

// Settings navigation: sections, search, and a way back. The sections are
// js/settingsPages.js: the shell's own pages (General, Appearance, Cluster,
// Connections, ...) are listed once their state is there, the ones the
// embedded page still renders while it lists them. Picking a native section
// with an `action` dispatches it; any other navigates the route, which the
// page follows.
Rectangle {
    id: nav

    readonly property var model: Shell.state.settings ?? null
    readonly property bool active: model !== null && model.active
    // The section showing: the shell's route once it has one, else the page's.
    readonly property var route: Shell.state.route ?? null
    readonly property string currentSection: Pages.resolve(route !== null && route.kind === "settings" ? route.section : model !== null ? model.activeSection : "")
    readonly property string query: search.text.trim().toLowerCase()
    // Every row says whether it is a search result, so a row never reads the
    // other shape while the query and the rows change together.
    readonly property var rows: {
        const state = Shell.state;
        if (query.length === 0) {
            return Pages.navRows(model === null ? [] : model.sections, state).map(section => ({
                        result: false,
                        to: section.to,
                        label: section.label,
                        action: section.action
                    }));
        }
        const pageResults = Pages.pageResults(model === null ? [] : model.searchResults);
        const own = Pages.searchRows(query, state).map(section => ({
                    result: true,
                    to: section.to,
                    title: section.label,
                    sectionLabel: section.detail ?? section.label,
                    action: section.action,
                    targetId: section.targetId
                }));
        return pageResults.map(row => Object.assign({
                    result: true
                }, row)).concat(own);
    }
    readonly property color foreground: Theme.palette.color("sidebarForeground", "#e4e4e7")
    readonly property color muted: Theme.palette.color("sidebarMutedForeground", "#8b8b93")

    implicitWidth: 260
    color: Theme.palette.color("sidebar", "#0a0a0a")

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
            text: nav.model ? nav.model.searchQuery : ""
            onTextEdited: Shell.dispatch("settings.search", {
                query: text
            })
            // Clears here, and the page's query while it keeps one: the
            // binding follows the page again, or empties without it.
            Keys.onEscapePressed: {
                Shell.dispatch("settings.search", {
                    query: ""
                });
                text = Qt.binding(() => nav.model ? nav.model.searchQuery : "");
            }
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
}
