import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings navigation: sections, search, and a way back. Pages the shell
// renders itself (Cluster and Connections, from their controllers) sit beside the sections the
// embedded page still renders until they move to QML; picking one of those
// hands navigation to the page.
Rectangle {
    id: nav

    readonly property var model: Shell.state.settings ?? null
    readonly property bool active: model !== null && model.active
    readonly property var cluster: Shell.state.cluster ?? null
    readonly property var connections: Shell.state.connections ?? null
    // The section showing: the shell's route once it has one, else the page's.
    readonly property var route: Shell.state.route ?? null
    readonly property string currentSection: route !== null && route.section ? route.section : model !== null && model.activeSection ? model.activeSection : ""
    readonly property bool clusterOpen: currentSection === "/settings/cluster"
    readonly property bool keybindingsOpen: currentSection === "/settings/keybindings"
    readonly property bool connectionsOpen: currentSection === "/settings/connections"
    readonly property string query: search.text.trim().toLowerCase()
    // The shell's own pages, as rows shaped like the page's sections and
    // search results; `action` is what picking one dispatches. Every row
    // says whether it is a search result, so a row never reads the other
    // shape while the query and the rows change together.
    readonly property var nativeRows: (cluster === null ? [] : [{
                label: qsTr("Cluster"),
                title: qsTr("Cluster"),
                sectionLabel: qsTr("Machines, invites and joining"),
                keywords: "cluster machines invite join remove tailscale",
                action: "cluster.open",
                current: clusterOpen
            }]).concat(connections === null ? [] : [{
                label: qsTr("Connections"),
                title: qsTr("Connections"),
                sectionLabel: qsTr("Environments, pairing links and clients"),
                keywords: "connections environments pairing link code clients revoke access remote",
                action: "connections.open",
                current: connectionsOpen
            }]).concat([{
                label: qsTr("Keybindings"),
                title: qsTr("Keybindings"),
                sectionLabel: qsTr("Shortcuts and when they apply"),
                keywords: "keybindings shortcuts keys hotkeys conditions",
                action: "keybindings.open",
                current: keybindingsOpen
            }])
    readonly property var rows: {
        const searching = query.length > 0;
        // The page's own Connections and Keybindings sections give way to the shell's.
        const pageRows = (model === null ? [] : searching ? model.searchResults : model.sections).filter(row => !(connections !== null && row.to && row.to.startsWith("/settings/connections")) && !String(row.to ?? "").startsWith("/settings/keybindings"));
        const own = searching ? nativeRows.filter(row => row.keywords.includes(query) || row.title.toLowerCase().includes(query)) : nativeRows;
        return pageRows.concat(own).map(row => Object.assign({
                result: searching
            }, row));
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
            Keys.onEscapePressed: {
                Shell.dispatch("settings.search", {
                    query: ""
                });
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
                readonly property bool isNative: modelData.action !== undefined
                readonly property bool current: isNative ? !isResult && modelData.current : !isResult && nav.currentSection === modelData.to

                width: ListView.view.width
                implicitHeight: isResult ? 48 : 36
                Accessible.name: isResult ? modelData.title : modelData.label
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                Keys.onDownPressed: nav.focusRow(index + 1)
                Keys.onUpPressed: nav.focusRow(index - 1)
                onClicked: row.isNative ? Shell.dispatch(row.modelData.action) : row.isResult ? Shell.dispatch("settings.openResult", {
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
                anchors.centerIn: parent
                visible: list.searching && list.count === 0
                text: qsTr("No matching settings")
                color: nav.muted
                font.pixelSize: 12
            }
        }
    }
}
