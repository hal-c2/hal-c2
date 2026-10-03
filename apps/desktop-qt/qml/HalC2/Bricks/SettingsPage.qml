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

    // Scrolls the route's target to the top of the page, when it is here.
    function reveal() {
        if (route === null || !route.target) return;
        const target = descendant(column, route.target);
        if (target === null) return;
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

        ColumnLayout {
            id: column

            x: 24
            y: 24
            width: Math.min(720, flick.width - 48)
            spacing: 14

            Label {
                Layout.fillWidth: true
                text: page.title
                color: page.foreground
                font.pixelSize: Math.round(18 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            ColumnLayout {
                id: lead

                Layout.fillWidth: true
                spacing: 14
            }

            Repeater {
                model: Rows.visible(page.rows, Qt.platform.os)

                delegate: Loader {
                    id: entry

                    required property var modelData

                    Layout.fillWidth: true
                    sourceComponent: modelData.section !== undefined ? heading : modelData.link !== undefined ? linkRow : settingRow

                    Component {
                        id: heading

                        ColumnLayout {
                            spacing: 6

                            Label {
                                Layout.topMargin: 12
                                text: entry.modelData.section
                                color: page.foreground
                                font.pixelSize: Math.round(14 * Theme.fontScale)
                                font.weight: Font.DemiBold
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
                                    font.pixelSize: Math.round(13 * Theme.fontScale)
                                    font.weight: Font.Medium
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: entry.modelData.description ?? ""
                                    color: Theme.palette.color("textMuted", "#a1a1aa")
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
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
