pragma ComponentBehavior: Bound
import QtQuick
import QtQuick3D
import QtQuick3D.AssetUtils
import HalC2.Shell

// The device as a 3D body the user turns (DevicePanel's 3D view): a phone
// or tablet body for an iOS device (models/, made by
// scripts/gen-device-models.py), and a plain body of the device's family
// when there is none or it fails to load — never an error. The live screen
// is a second DeviceScreen as the body's screen texture, on the stream the
// flat view uses.
//
// Dragging turns the body; on release it settles on the nearest turn that
// faces its screen. An iPad's Magic Keyboard is its own model, shown when
// attached (the panel owns that choice, so it survives a flat round-trip).
// The models are portrait; a landscape screen turns the body on its side.
Item {
    id: root

    property var stream: null
    // The shown device's name and platform, for its family and model.
    property string deviceName: ""
    property string platform: ""
    property bool keyboardAttached: false
    // A model file to load instead of the bundled one (a missing or invalid
    // file shows the plain body); "" is the bundled choice.
    property string modelOverride: ""

    readonly property bool tablet: deviceName.indexOf("iPad") >= 0
    readonly property string family: platform === "android" ? "android" : tablet ? "ipad" : "iphone"
    readonly property string bundledModel: platform === "android" ? "" : tablet ? "models/tablet.glb" : "models/phone.glb"
    readonly property string modelSource: modelOverride.length > 0 ? modelOverride : bundledModel
    // No model, or its load failed: the plain family body shows.
    readonly property bool plain: modelSource.length === 0 || modelLoader.status !== RuntimeLoader.Success
    readonly property real aspect: stream ? stream.aspect : 9 / 19.5
    readonly property bool landscape: aspect > 1
    // The screen as shown: its long side is the models' 2.2 units.
    readonly property real screenWidth: landscape ? 2.2 : 2.2 * aspect
    readonly property real screenHeight: landscape ? 2.2 / aspect : 2.2
    // The body's turn, and whether it has settled facing its screen.
    property real yaw: 0
    property real pitch: 0
    readonly property bool settled: !settle.running && Math.abs(((yaw % 360) + 360) % 360) < 0.5 && Math.abs(pitch) < 0.5

    objectName: "deviceBody3d"

    // The live screen, rendered into the body's screen texture below.
    Item {
        id: textureScreen

        width: root.landscape ? 256 * root.aspect : 256
        height: root.landscape ? 256 : 256 / Math.max(root.aspect, 0.01)
        layer.enabled: true
        // Behind the 3D view, which covers it; the layer is what is read.
        z: -1

        // iOS streams its portrait framebuffer while held sideways: the
        // picture takes the turned box and turns into place, as in the flat view.
        DeviceScreen {
            readonly property int turn: root.stream ? root.stream.rotation : 0
            readonly property bool sideways: turn === 90 || turn === -90

            objectName: "deviceBodyScreen"
            anchors.centerIn: parent
            width: sideways ? parent.height : parent.width
            height: sideways ? parent.width : parent.height
            rotation: turn
            stream: root.stream
        }
    }

    View3D {
        anchors.fill: parent

        environment: SceneEnvironment {
            clearColor: Theme.palette.color("canvas", "#09090b")
            backgroundMode: SceneEnvironment.Color
            antialiasingMode: SceneEnvironment.MSAA
        }

        PerspectiveCamera {
            z: 420
            fieldOfView: 35
        }
        DirectionalLight {
            eulerRotation.x: -30
            eulerRotation.y: 20
            brightness: 1.2
        }

        Node {
            id: body

            eulerRotation.y: root.yaw
            eulerRotation.x: root.pitch

            // The specific body, when bundled and loadable.
            RuntimeLoader {
                id: modelLoader

                source: root.modelSource.length > 0 ? Qt.resolvedUrl(root.modelSource) : ""
                scale: Qt.vector3d(100, 100, 100)
                eulerRotation.z: root.landscape ? 90 : 0
                visible: !root.plain
            }

            // The Magic Keyboard's own model, under the iPad held landscape.
            RuntimeLoader {
                id: keyboardModel

                objectName: "deviceMagicKeyboardModel"
                source: root.tablet ? Qt.resolvedUrl("models/tablet-keyboard.glb") : ""
                scale: Qt.vector3d(100, 100, 100)
                visible: root.tablet && root.keyboardAttached && !root.plain
            }

            // The plain family body: a slab of the device's proportions.
            Model {
                id: plainBody

                source: "#Cube"
                visible: root.plain
                scale: Qt.vector3d(root.screenWidth + 0.12, root.screenHeight + 0.12, 0.09)
                materials: PrincipledMaterial {
                    baseColor: "#2a2a2e"
                    roughness: 0.45
                    metalness: 0.4
                }
            }
            Model {
                visible: root.plain && root.tablet && root.keyboardAttached
                source: "#Cube"
                position: Qt.vector3d(0, -(root.screenHeight * 50 + 4), 60)
                eulerRotation.x: 90
                scale: Qt.vector3d(root.screenWidth + 0.12, 1.2, 0.06)
                materials: PrincipledMaterial {
                    baseColor: "#1c1c1f"
                    roughness: 0.7
                }
            }

            // The screen: the models centre it, its long side 2.2 units.
            Model {
                source: "#Rectangle"
                z: 6
                scale: Qt.vector3d(root.screenWidth, root.screenHeight, 1)
                materials: PrincipledMaterial {
                    lighting: PrincipledMaterial.NoLighting
                    baseColorMap: Texture {
                        sourceItem: textureScreen
                    }
                }
            }
        }
    }

    // Named for the steps and assistive tools: whether the keyboard shows.
    Item {
        objectName: "deviceMagicKeyboard"
        visible: root.tablet && root.keyboardAttached
        Accessible.role: Accessible.StaticText
        Accessible.name: qsTr("Magic Keyboard attached")
    }

    NumberAnimation {
        id: settleYaw

        target: root
        property: "yaw"
        duration: 350
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: settlePitch

        target: root
        property: "pitch"
        to: 0
        duration: 350
        easing.type: Easing.OutCubic
    }
    readonly property bool settling: settleYaw.running || settlePitch.running
    property alias settle: settleYaw

    MouseArea {
        anchors.fill: parent
        property real lastX: 0
        property real lastY: 0

        onPressed: event => {
            settleYaw.stop();
            settlePitch.stop();
            lastX = event.x;
            lastY = event.y;
        }
        onPositionChanged: event => {
            if (!pressed)
                return;
            root.yaw += (event.x - lastX) * 0.5;
            root.pitch = Math.max(-60, Math.min(60, root.pitch + (event.y - lastY) * 0.3));
            lastX = event.x;
            lastY = event.y;
        }
        onReleased: {
            settleYaw.to = Math.round(root.yaw / 360) * 360;
            settleYaw.start();
            settlePitch.start();
        }
    }
}
