pragma ComponentBehavior: Bound
import QtQuick
import QtWebEngine
import HalC2.Shell
import "js/browser.js" as BrowserJs

// A browser tab's Devices view: the same page, loaded into one WebEngineView
// per picked preset (js/browser.js), side by side in bezelled frames sized
// and scaled to the preset's CSS viewport (BrowserJs.layoutDevices). Frames
// follow `pageUrl`; they are views only and never report to the MC
// themselves (BrowserPanel's own page does that), and show the page on its
// own background in the tab's `appearance`. `show3d` puts phone and tablet
// frames on their 3D bodies (DeviceBody3D).
Item {
    id: root

    property string pageUrl: ""
    property var profile: null
    // The tab's prefers-color-scheme: "system", "light" or "dark".
    property string appearance: "system"
    property var presetIds: []
    property bool show3d: false

    readonly property color edge: Theme.palette.color("border", "#27272a")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    // The window's zoom, undone around each page as BrowserPanel does.
    readonly property real appZoom: Shell.state.layout ? (Shell.state.layout.zoom ?? 1) : 1
    readonly property var frames: BrowserJs.layoutDevices(root.presetIds, root.width, root.height, 32, 24, 22)

    objectName: "browserDevicesView"
    clip: true

    // What the devices sit on, as under a single device size.
    Rectangle {
        anchors.fill: parent
        color: Theme.palette.color("canvas", "#09090b")
    }

    Repeater {
        model: root.frames

        delegate: Item {
            id: frameItem

            required property var modelData

            x: modelData.x
            y: modelData.y
            width: modelData.frameWidth
            height: modelData.frameHeight

            readonly property bool body3d: root.show3d && modelData.kind !== "desktop"

            Text {
                objectName: "browserDevicesLabel-" + frameItem.modelData.id
                anchors.horizontalCenter: parent.horizontalCenter
                y: -height - 14
                width: parent.width + 28
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: frameItem.modelData.label + " · " + frameItem.modelData.width + " × " + frameItem.modelData.height
                color: root.muted
                font.pixelSize: Theme.type.caption.size
            }

            // The device's body around the page, one thickness for every
            // device so their tops line up; the 3D body draws its own.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -8
                visible: !frameItem.body3d
                color: root.edge
                radius: frameItem.modelData.kind === "desktop" ? Theme.radiusSm : Theme.radiusXl
            }

            // The page's own pixels: the app's zoom undone.
            Item {
                scale: 1 / root.appZoom
                transformOrigin: Item.TopLeft

                WebEngineView {
                    id: view

                    objectName: "browserDevicesFrame-" + frameItem.modelData.id
                    visible: !frameItem.body3d
                    layer.enabled: frameItem.body3d
                    width: frameItem.modelData.width
                    height: frameItem.modelData.height
                    scale: frameItem.modelData.scale * root.appZoom
                    transformOrigin: Item.TopLeft
                    profile: root.profile
                    settings.errorPageEnabled: false
                    settings.focusOnNavigationEnabled: false

                    function applyAppearance() {
                        view.userScripts.clear();
                        if (root.appearance !== "system") {
                            const script = WebEngine.script();
                            script.name = "hal-c2-appearance";
                            script.sourceCode = BrowserJs.appearanceScript(root.appearance);
                            script.injectionPoint = WebEngineScript.DocumentCreation;
                            script.worldId = WebEngineScript.MainWorld;
                            script.runsOnSubFrames = true;
                            view.userScripts.insert(script);
                        }
                    }

                    Component.onCompleted: {
                        view.applyAppearance();
                        if (root.pageUrl.length > 0)
                            view.url = root.pageUrl;
                    }

                    Connections {
                        target: root
                        function onPageUrlChanged() {
                            if (root.pageUrl.length > 0 && view.url.toString() !== root.pageUrl)
                                view.url = root.pageUrl;
                        }
                        function onAppearanceChanged() {
                            view.applyAppearance();
                            if (view.url.toString().length > 0)
                                view.reload();
                        }
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
