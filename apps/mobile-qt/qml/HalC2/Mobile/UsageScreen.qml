import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The usage page (the UsagePage brick over `usage`) under a bar that leads
// back, and, while the Subscription usage widget is on the home screen, which
// windows it shows of each provider (`usageWidget`, SubscriptionWidget).
ColumnLayout {
    id: screen

    readonly property var widget: Shell.state.usageWidget ?? null
    readonly property bool limitsShown: (Shell.state.usage ?? null) !== null && Shell.state.usage.metric === "limits"

    signal backRequested

    objectName: "usageScreen"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        canGoBack: true
        title: qsTr("Usage")
        onBackRequested: screen.backRequested()
    }

    ColumnLayout {
        objectName: "usageWidgetChoices"
        Layout.fillWidth: true
        Layout.leftMargin: 16
        Layout.rightMargin: 16
        Layout.topMargin: 12
        visible: screen.limitsShown && screen.widget !== null && screen.widget.placed && screen.widget.providers.length > 0
        spacing: 4

        Label {
            text: qsTr("Home screen widget")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
            font.weight: Font.DemiBold
        }

        Repeater {
            model: screen.widget !== null ? screen.widget.providers : []

            delegate: RowLayout {
                id: choice

                required property var modelData

                Layout.fillWidth: true
                spacing: 4

                Label {
                    Layout.fillWidth: true
                    text: choice.modelData.label
                    color: Theme.palette.color("text", "#e4e4e7")
                    elide: Text.ElideRight
                }

                Repeater {
                    model: [["session", qsTr("Session")], ["weekly", qsTr("Weekly")], ["both", qsTr("Both")]]

                    delegate: ShellButton {
                        required property var modelData

                        objectName: "widgetShow_" + choice.modelData.driver + "_" + modelData[0]
                        implicitHeight: 40
                        text: modelData[1]
                        subtle: true
                        checked: choice.modelData.show === modelData[0]
                        onClicked: Shell.dispatch("usageWidget.show", { driver: choice.modelData.driver, show: modelData[0] })
                    }
                }
            }
        }
    }

    UsagePage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        // The bar says what the page is.
        titled: false
    }
}
