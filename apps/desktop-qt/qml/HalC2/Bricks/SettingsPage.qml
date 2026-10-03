import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsRows.js" as Rows

// A native settings page: its title, anything the page puts first (its
// children), then `rows` (js/settingsRows.js) under their section headings.
// A settings search result it holds (route.target, an objectName on the page)
// is scrolled into view when opened.
Rectangle {
    id: page

    property string title: ""
    property var rows: []
    default property alias content: lead.data
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color line: Theme.palette.color("border", "#27272a")

    readonly property var route: Shell.state.route ?? null
    readonly property int targetSeq: route !== null && route.targetSeq !== undefined ? route.targetSeq : 0

    function descendant(item, name) {
        for (let i = 0; i < item.children.length; ++i) {
            const child = item.children[i];
            if (child.objectName === name) return child;
            const found = descendant(child, name);
            if (found !== null) return found;
        }
        return null;
    }

    // An opened result is kept in view while the page still lays out (rows
    // that arrive with its state), until the user scrolls.
    property bool following: false

    // The folded sections the user, or a search result inside one, opened.
    property var openFolds: ({})

    function setFold(section, open) {
        if ((openFolds[section] === true) === open) return;
        const next = Object.assign({}, openFolds);
        next[section] = open;
        openFolds = next;
    }

    // Scrolls the route's target to the top of the page, when it is here.
    function reveal() {
        if (route === null || !route.target) return;
        const fold = Rows.foldOf(rows, route.target);
        if (fold.length > 0 && !openFolds[fold]) {
            // Its rows are made once the fold is open.
            setFold(fold, true);
            Qt.callLater(reveal);
            return;
        }
        const target = descendant(column, route.target);
        if (target === null) return;
        following = true;
        const y = target.mapToItem(column, 0, 0).y + column.y - 12;
        flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
    }

    onTargetSeqChanged: Qt.callLater(reveal)
    Component.onCompleted: Qt.callLater(reveal)
    color: Theme.palette.color("canvas", "#0b0b0d")

    Flickable {
        id: flick
        objectName: "scroll"

        anchors.fill: parent
        contentHeight: column.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        onMovementStarted: page.following = false

        ColumnLayout {
            id: column

            onImplicitHeightChanged: if (page.following) Qt.callLater(page.reveal)

            x: 24
            y: 24
            width: Math.min(720, flick.width - 48)
            spacing: 14

            Label {
                Layout.fillWidth: true
                text: page.title
                color: page.foreground
                font.pixelSize: 18
                font.weight: Font.DemiBold
            }

            ColumnLayout {
                id: lead

                Layout.fillWidth: true
                spacing: 14
            }

            Repeater {
                model: Rows.listed(page.rows, Qt.platform.os, page.openFolds)

                delegate: Loader {
                    id: entry

                    required property var modelData

                    Layout.fillWidth: true
                    sourceComponent: modelData.section !== undefined ? heading : modelData.link !== undefined ? linkRow : settingRow

                    Component {
                        id: heading

                        ColumnLayout {
                            readonly property bool folded: entry.modelData.folded === true
                            readonly property bool open: page.openFolds[entry.modelData.section] === true

                            objectName: "settingsSection:" + entry.modelData.section
                            spacing: 6

                            RowLayout {
                                Layout.topMargin: 12
                                spacing: 6

                                Label {
                                    text: entry.modelData.section
                                    color: page.foreground
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                }

                                ShellButton {
                                    objectName: "fold"
                                    visible: parent.parent.folded
                                    subtle: true
                                    text: parent.parent.open ? qsTr("Hide") : qsTr("Show")
                                    Accessible.name: parent.parent.open ? qsTr("Hide %1").arg(entry.modelData.section) : qsTr("Show %1").arg(entry.modelData.section)
                                    onClicked: page.setFold(entry.modelData.section, !parent.parent.open)
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 1
                                color: page.line
                            }
                        }
                    }

                    // A row that opens another section (settings.navigate).
                    Component {
                        id: linkRow

                        RowLayout {
                            objectName: "settingsRow:" + entry.modelData.id
                            spacing: 12

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Label {
                                    text: entry.modelData.title
                                    color: page.foreground
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: entry.modelData.description ?? ""
                                    color: Theme.palette.color("textMuted", "#a1a1aa")
                                    font.pixelSize: 12
                                    wrapMode: Text.Wrap
                                }
                            }

                            ShellButton {
                                objectName: "open"
                                text: entry.modelData.button
                                onClicked: Shell.dispatch("settings.navigate", { to: entry.modelData.link })
                            }
                        }
                    }

                    Component {
                        id: settingRow

                        SettingsRow {
                            spec: entry.modelData
                        }
                    }
                }
            }
        }
    }
}
