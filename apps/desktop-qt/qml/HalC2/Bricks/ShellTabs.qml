import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The window's top-level tabs: Threads, then one per page a running MC plugin
// adds (Shell.state.mcPlugins.pages). Absent while no plugin adds a page. In a
// frameless window the strip is a drag handle, and carries the window buttons
// while a plugin page hides the header strip that normally has them.
Rectangle {
    id: strip

    readonly property var pages: Shell.state.mcPlugins?.pages ?? []
    readonly property string selected: Shell.state.route?.tab ?? "threads"
    readonly property var tabs: [{ key: "threads", title: qsTr("Threads"), icon: "message-square" }].concat(pages)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    property Window window: null
    readonly property bool framelessChrome: window !== null && Theme.frameless

    implicitHeight: 36
    color: Theme.palette.color("canvas", "#0f0f12")

    DragHandler {
        enabled: strip.framelessChrome
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onActiveChanged: if (active)
            strip.window.startSystemMove()
    }

    TapHandler {
        enabled: strip.framelessChrome
        onDoubleTapped: strip.window.visibility === Window.Maximized ? strip.window.showNormal() : strip.window.showMaximized()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        spacing: 2

        Repeater {
            model: strip.tabs

            delegate: AbstractButton {
                id: tab

                required property var modelData
                readonly property bool active: strip.selected === modelData.key

                objectName: "tab:" + modelData.key
                Layout.preferredWidth: row.implicitWidth + 20
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                Accessible.role: Accessible.PageTab
                Accessible.name: modelData.title
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                onClicked: Shell.dispatch("tabs.select", { key: tab.modelData.key })
                background: Rectangle {
                    color: tab.active ? Theme.palette.color("surfaceRaised", "#1f1f24") : tab.hovered || tab.visualFocus ? Theme.palette.color("surface", "#141416") : "transparent"
                    radius: 6
                }

                Row {
                    id: row

                    anchors.centerIn: parent
                    spacing: 6

                    ShellIcon {
                        visible: (tab.modelData.icon ?? "").length > 0
                        name: tab.modelData.icon ?? ""
                        size: 13
                        color: tab.active ? strip.foreground : strip.muted
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: tab.modelData.title
                        color: tab.active ? strip.foreground : strip.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
        }

        WindowControls {
            window: strip.window
            buttonWidth: 32
            buttonHeight: 28
            visible: strip.framelessChrome && strip.selected !== "threads" && Qt.platform.os !== "osx"
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
