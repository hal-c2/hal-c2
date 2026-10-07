pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Open source licenses, natively (the web's OpenSourceLicenses):
// the third-party notices LicensesController reads from the manifest shipped
// beside the app, searchable, each opening to its full text
// (features/settings/licenses.feature). A list, not a SettingsPage: there are
// hundreds, and only those on screen are drawn.
Rectangle {
    id: page

    readonly property var settings: Shell.state.licenses ?? null
    readonly property string status: settings?.status ?? "loading"
    readonly property var entries: settings?.entries ?? []
    readonly property int total: settings?.total ?? 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color line: Theme.palette.color("border", "#27272a")

    objectName: "openSourceLicenses"
    // A list too narrow for a row's name beside its licence (a phone's): the
    // licence goes under the name, and the search under the heading.
    readonly property bool narrow: list.width < 520
    color: Theme.palette.color("canvas", "#0b0b0d")

    ListView {
        id: list
        objectName: "licenseList"

        anchors.fill: parent
        anchors.topMargin: 24
        anchors.bottomMargin: 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        model: page.status === "ready" ? page.entries : []

        header: ColumnLayout {
            x: 24
            width: Math.min(720, list.width - 48)
            spacing: 10

            SettingsBreadcrumb {
                Layout.fillWidth: true
                section: qsTr("Open source licenses")
            }

            GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: 12
                columns: page.narrow ? 2 : 3
                columnSpacing: 12
                rowSpacing: 8

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Third-party notices")
                    color: page.foreground
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                Label {
                    objectName: "licenseCount"
                    visible: page.status === "ready"
                    text: page.entries.length === page.total ? qsTr("%1 notices").arg(page.total)
                                                             : qsTr("%1 of %2").arg(page.entries.length).arg(page.total)
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                ShellTextField {
                    objectName: "licenseSearch"
                    visible: page.status === "ready"
                    Layout.columnSpan: page.narrow ? 2 : 1
                    Layout.fillWidth: page.narrow
                    implicitWidth: 200
                    placeholderText: qsTr("Search licenses")
                    text: page.settings?.query ?? ""
                    Accessible.name: qsTr("Search open-source licenses")
                    Keys.onEscapePressed: Shell.dispatch("licenses.search", { query: "" })
                    onTextEdited: Shell.dispatch("licenses.search", { query: text })
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: page.line
            }

            Label {
                objectName: "licensesLoading"
                visible: page.status === "loading"
                text: qsTr("Loading open-source notices…")
                color: page.muted
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            Label {
                objectName: "noLicenseMatch"
                Layout.fillWidth: true
                Layout.topMargin: 20
                visible: page.status === "ready" && page.entries.length === 0
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("No licenses match that search.")
                color: page.muted
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            ColumnLayout {
                objectName: "licensesError"
                visible: page.status === "error"
                spacing: 6

                Label {
                    text: qsTr("Open-source notices are unavailable")
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Label {
                    Layout.maximumWidth: 560
                    text: page.settings?.message ?? ""
                    color: page.muted
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                ShellButton {
                    objectName: "licensesRetry"
                    text: qsTr("Try again")
                    onClicked: Shell.dispatch("licenses.retry")
                }
            }
        }

        delegate: ColumnLayout {
            id: notice

            required property var modelData
            readonly property bool open: page.settings?.openKey === notice.modelData.key

            objectName: "license:" + notice.modelData.name
            x: 24
            width: Math.min(720, list.width - 48)
            spacing: 0

            GridLayout {
                Layout.fillWidth: true
                columns: page.narrow ? 2 : 3
                columnSpacing: 8
                rowSpacing: 0

                ShellButton {
                    objectName: "toggle"
                    Layout.row: 0
                    Layout.column: 0
                    Layout.fillWidth: true
                    subtle: true
                    chevron: true
                    text: notice.modelData.name + (notice.modelData.version ? "  " + notice.modelData.version : "")
                    Accessible.name: notice.modelData.name
                    onClicked: Shell.dispatch("licenses.open", { key: notice.modelData.key })
                }

                Label {
                    objectName: "summary"
                    Layout.row: page.narrow ? 1 : 0
                    Layout.column: page.narrow ? 0 : 1
                    Layout.columnSpan: page.narrow ? 2 : 1
                    Layout.fillWidth: page.narrow
                    Layout.leftMargin: page.narrow ? 28 : 0
                    Layout.bottomMargin: page.narrow ? 6 : 0
                    Layout.maximumWidth: page.narrow ? -1 : 300
                    text: notice.modelData.license + " · " + notice.modelData.where
                    elide: Text.ElideRight
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                ShellButton {
                    Layout.row: 0
                    Layout.column: page.narrow ? 1 : 2
                    visible: !!notice.modelData.sourceUrl
                    subtle: true
                    iconName: "external-link"
                    iconSize: 12
                    implicitWidth: 22
                    implicitHeight: 22
                    Accessible.name: qsTr("View project source for %1").arg(notice.modelData.name)
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Project source")
                    onClicked: Qt.openUrlExternally(notice.modelData.sourceUrl)
                }
            }

            TextEdit {
                objectName: "noticeText"
                Layout.fillWidth: true
                Layout.leftMargin: 28
                Layout.bottomMargin: 12
                visible: notice.open
                readOnly: true
                selectByMouse: true
                text: notice.open ? page.settings?.noticeText ?? "" : ""
                wrapMode: TextEdit.Wrap
                color: page.foreground
                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }
    }
}
