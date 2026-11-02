pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// "Set up devices": the first-use wizard in front of the Device tab, three
// steps over ThreadDevices' wizard view (the hub, the platforms, agent
// access). Turning the hub on is the consent to install and start it;
// opening the wizard itself installs nothing. The same machine banners the
// Device tab shows run across its top (DevicePanel's banner rows are this
// file's `banners` model too).
Rectangle {
    id: root

    property var source: null

    readonly property var wizard: source && source.view ? source.view.wizard ?? null : null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")

    property int step: 0
    // The furthest step reached: a later step cannot be jumped to.
    property int furthest: 0

    objectName: "deviceWizard"
    color: Theme.palette.color("surface", "#0f0f11")
    border.color: borderColor
    border.width: 1
    radius: 8

    onVisibleChanged: {
        if (visible) {
            step = 0;
            furthest = 0;
        }
    }

    readonly property var steps: [qsTr("Device hub"), qsTr("Simulators"), qsTr("Agent access")]

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Text {
            text: qsTr("Set up devices")
            color: root.foreground
            font.pixelSize: Math.round(15 * Theme.fontScale)
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: qsTr("Review what runs on this environment before using simulators and emulators.")
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Row {
            spacing: 6

            Repeater {
                model: root.steps

                delegate: ShellButton {
                    required property int index
                    required property string modelData

                    objectName: "wizardStep-" + modelData
                    text: modelData
                    subtle: root.step !== index
                    // A step not reached yet cannot be jumped to, and none
                    // can be chosen while the hub installs or starts.
                    enabled: root.wizard !== null && !root.wizard.busy && root.wizard.pending.length === 0 && index <= root.furthest
                    onClicked: root.step = index
                }
            }
        }

        DeviceBanners {
            width: parent.width
            source: root.source
            namePrefix: "deviceWizardBanner"
        }

        // Step 1: the device hub.
        Column {
            width: parent.width
            spacing: 8
            visible: root.step === 0

            Text {
                text: qsTr("Enable the device hub")
                color: root.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }
            Item {
                width: parent.width
                height: 44

                Text {
                    anchors.left: parent.left
                    anchors.right: hubSwitch.left
                    anchors.rightMargin: 12
                    wrapMode: Text.Wrap
                    text: qsTr("Enable this environment to open simulators and emulators, whether they run here or on a remote device host.")
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
                ShellSwitch {
                    id: hubSwitch

                    objectName: "wizardHubSwitch"
                    anchors.right: parent.right
                    Accessible.name: qsTr("Enable device hub")
                    checked: root.wizard !== null && root.wizard.hubOn
                    enabled: root.wizard !== null && !root.wizard.busy && root.wizard.pending.length === 0
                    onClicked: root.source.wizardSetHub(checked)
                }
            }
            Text {
                objectName: "wizardHubStatus"
                visible: text.length > 0
                text: root.wizard ? root.wizard.hubStatus : ""
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
        }

        // Step 2: what each platform needs.
        Column {
            width: parent.width
            spacing: 8
            visible: root.step === 1

            Text {
                text: qsTr("Check simulator support")
                color: root.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }
            Repeater {
                model: root.wizard ? root.wizard.platforms : []

                delegate: Rectangle {
                    id: platformRow

                    required property var modelData

                    width: parent.width
                    height: 52
                    radius: 6
                    color: "transparent"
                    border.color: root.borderColor

                    Column {
                        x: 12
                        y: 8
                        width: parent.width - 24
                        spacing: 2

                        Text {
                            text: platformRow.modelData.platform
                            color: root.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.Medium
                        }
                        Text {
                            objectName: "wizardPlatform-" + platformRow.modelData.platform
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: platformRow.modelData.message
                            color: root.muted
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                    }
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("You can use either platform. Fixing a missing platform does not block the other one.")
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
            ShellButton {
                objectName: "wizardCheckAgain"
                text: root.wizard && root.wizard.pending === "check" ? qsTr("Checking…") : qsTr("Check again")
                enabled: root.wizard !== null && root.wizard.hubOn && !root.wizard.busy && root.wizard.pending.length === 0
                onClicked: root.source.wizardCheck()
            }
        }

        // Step 3: agent access.
        Column {
            width: parent.width
            spacing: 8
            visible: root.step === 2

            Text {
                text: qsTr("Allow agent control")
                color: root.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }
            Item {
                width: parent.width
                height: 44

                Text {
                    anchors.left: parent.left
                    anchors.right: agentSwitch.left
                    anchors.rightMargin: 12
                    wrapMode: Text.Wrap
                    text: qsTr("Allow new agent sessions in this environment to start and control local and remote devices, with required tools set up automatically.")
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
                ShellSwitch {
                    id: agentSwitch

                    objectName: "wizardAgentSwitch"
                    anchors.right: parent.right
                    Accessible.name: qsTr("Allow agents to control devices")
                    checked: root.wizard !== null && root.wizard.agentOn
                    enabled: root.wizard !== null && root.wizard.hubOn && !root.wizard.busy && root.wizard.pending.length === 0
                    onClicked: root.source.wizardSetAgent(checked)
                }
            }
            Text {
                objectName: "wizardAgentStatus"
                visible: text.length > 0
                text: root.wizard ? root.wizard.agentStatus : ""
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("Leave this off to keep manual device controls without giving agents access.")
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
        }

        Text {
            objectName: "wizardError"
            width: parent.width
            visible: root.wizard !== null && root.wizard.error.length > 0
            wrapMode: Text.Wrap
            text: root.wizard ? root.wizard.error : ""
            color: root.errorColor
            font.pixelSize: Math.round(11 * Theme.fontScale)
        }

        Item {
            width: parent.width
            height: 36

            ShellButton {
                objectName: "wizardCancel"
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: root.step === 0
                text: qsTr("Cancel")
                onClicked: root.source.wizardCancel()
            }
            ShellButton {
                objectName: "wizardBack"
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: root.step > 0
                text: qsTr("Back")
                enabled: root.wizard !== null && !root.wizard.busy && root.wizard.pending.length === 0
                onClicked: root.step -= 1
            }
            ShellButton {
                objectName: "wizardContinue"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.step < 2
                text: qsTr("Continue")
                enabled: root.wizard !== null && root.wizard.canContinue
                onClicked: {
                    root.step += 1;
                    root.furthest = Math.max(root.furthest, root.step);
                }
            }
            ShellButton {
                objectName: "wizardDone"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.step === 2
                text: root.wizard && root.wizard.pending === "complete" ? qsTr("Saving…") : qsTr("Done")
                enabled: root.wizard !== null && root.wizard.canContinue
                onClicked: root.source.wizardDone()
            }
        }
    }
}
