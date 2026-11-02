pragma ComponentBehavior: Bound
import QtQuick
import QtWebEngine
import HalC2.Shell
import "js/browser.js" as BrowserJs

// A browser tab's Devices view: the same page, loaded into one WebEngineView
// per picked preset (js/browser.js), side by side in bezelled frames sized
// and scaled to the preset's CSS viewport (BrowserJs.layoutDevices). Frames
// follow `pageUrl`; they are views only and never report to the MC
// themselves (BrowserPanel's own page does that). `show3d` puts phone and
// tablet frames on their 3D bodies (DeviceBody3D), skipped when QtQuick3D is
// not built in.
Item {
    id: root

    property string pageUrl: ""
    property var profile: null
    property color pageBackground: "#0f0f11"
    property var presetIds: []
    property bool show3d: false

    readonly property color edge: Theme.palette.color("border", "#27272a")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property var frames: BrowserJs.layoutDevices(root.presetIds, root.width, root.height, 24, 16, 22)

    objectName: "browserDevicesView"
    clip: true

    Repeater {
        model: root.frames

        delegate: Item {
            id: frameItem

            required property var modelData

            x: modelData.x
            y: modelData.y
            width: modelData.frameWidth
            height: modelData.frameHeight

            readonly property bool body3d: root.show3d && modelData.kind !== "desktop" && bodyLoader.status !== Loader.Error

            Text {
                objectName: "browserDevicesLabel-" + frameItem.modelData.id
                anchors.horizontalCenter: parent.horizontalCenter
                // Every frame centres at a different y below the label
                // strip; undo that so every label still sits in one row.
                y: -frameItem.y + 4
                text: frameItem.modelData.label + " · " + frameItem.modelData.width + " × " + frameItem.modelData.height
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }

            // The device's edge, under the page; the 3D body draws its own.
            Rectangle {
                anchors.fill: parent
                visible: !frameItem.body3d
                color: "transparent"
                border.color: root.edge
                radius: 2
            }

            WebEngineView {
                id: view

                objectName: "browserDevicesFrame-" + frameItem.modelData.id
                visible: !frameItem.body3d
                layer.enabled: frameItem.body3d
                x: 0
                y: 0
                width: frameItem.modelData.width
                height: frameItem.modelData.height
                scale: frameItem.modelData.scale
                transformOrigin: Item.TopLeft
                profile: root.profile
                backgroundColor: root.pageBackground
                settings.errorPageEnabled: false
                settings.focusOnNavigationEnabled: false

                Component.onCompleted: if (root.pageUrl.length > 0)
                    view.url = root.pageUrl

                Connections {
                    target: root
                    function onPageUrlChanged() {
                        if (root.pageUrl.length > 0 && view.url.toString() !== root.pageUrl)
                            view.url = root.pageUrl;
                    }
                }
            }

            Loader {
                id: bodyLoader

                anchors.fill: parent
                anchors.margins: -Math.min(parent.width, parent.height) * 0.14
                active: root.show3d && frameItem.modelData.kind !== "desktop"
                visible: frameItem.body3d
                source: "DeviceBody3D.qml"
                onLoaded: {
                    item.deviceName = frameItem.modelData.kind === "tablet" ? "iPad" : "iPhone";
                    item.platform = "ios";
                    item.screenItem = view;
                }
            }
        }
    }
}
