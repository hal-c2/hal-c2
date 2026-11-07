pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/browser.js" as BrowserJs

// Which presets the browser tab's Devices view shows, and whether it shows
// them on their 3D bodies: both kept on this device (Browser.devicesPresetIds,
// Browser.devices3d).
Popup {
    id: picker

    readonly property var choices: BrowserJs.presets.concat([BrowserJs.desktop])

    padding: 4
    width: 260
    height: 320
    focus: false
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    background: ShellPopoverSurface {}

    contentItem: ColumnLayout {
        spacing: 0

        Flickable {
            id: scroll

            objectName: "browserDevicesScroll"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: list.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            ColumnLayout {
                id: list

                width: scroll.width
                spacing: 0

                Repeater {
                    model: picker.choices

                    delegate: ShellCheckBox {
                        id: entry

                        required property var modelData

                        Layout.fillWidth: true
                        objectName: "browserDevicesPreset-" + modelData.id
                        text: modelData.label + " · " + modelData.width + " × " + modelData.height
                        checked: Browser.devicesPresetIds.indexOf(modelData.id) >= 0
                        onToggled: {
                            const ids = Browser.devicesPresetIds.slice();
                            const at = ids.indexOf(entry.modelData.id);
                            if (entry.checked && at < 0)
                                ids.push(entry.modelData.id);
                            else if (!entry.checked && at >= 0)
                                ids.splice(at, 1);
                            Browser.devicesPresetIds = ids;
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.palette.color("border", "#27272a")
        }

        ShellSwitch {
            objectName: "browserDevices3d"
            Layout.fillWidth: true
            leftPadding: 8
            text: qsTr("Show on 3D devices")
            checked: Browser.devices3d
            onToggled: Browser.devices3d = checked
        }
    }
}
