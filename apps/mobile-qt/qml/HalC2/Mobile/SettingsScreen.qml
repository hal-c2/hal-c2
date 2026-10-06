import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Settings in two steps: the desktop's sections (SettingsNav), then the one
// picked (SettingsHost) under a bar that leads back to them.
Item {
    id: screen

    // The section the route names; the bare settings route is the list.
    required property string section
    readonly property bool sectionOpen: section.length > 0

    signal backRequested

    objectName: "settingsScreen"

    SettingsNav {
        objectName: "settingsSections"
        anchors.fill: parent
        visible: !screen.sectionOpen
        // Not on a phone: keys it has none of, plugin slots and captures
        // this layout does not host, the providers' sign-in terminal, and
        // the machine's own access and cluster, which need more than a
        // phone's session and are worded for the desktop.
        leftOut: ["/settings/keybindings", "/settings/plugins", "/settings/snap-shot", "/settings/providers", "/settings/connections", "/settings/cluster"]
    }

    Loader {
        anchors.fill: parent
        active: screen.sectionOpen

        sourceComponent: ColumnLayout {
            spacing: 0

            MobileBar {
                Layout.fillWidth: true
                canGoBack: true
                title: qsTr("Settings")
                onBackRequested: screen.backRequested()
            }

            SettingsHost {
                objectName: "settingsSection"
                Layout.fillWidth: true
                Layout.fillHeight: true
                section: screen.section
            }
        }
    }
}
