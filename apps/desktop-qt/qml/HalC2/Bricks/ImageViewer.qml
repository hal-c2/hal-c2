pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A message's images large, over the whole window: stepped through, zoomed up
// to eight times the size that fits, dragged around while zoomed. A Snap Shot's
// captured text can take the picture's place. Closing gives focus back to what
// opened it. Open with showImages().
Popup {
    id: viewer

    // The thread's TimelineModel, which signs the images' addresses.
    property var model: null
    property var images: []
    property int index: 0
    property Item opener: null
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    property bool reading: false
    property var refused: ({})
    // What the last change of zoom told assistive technology.
    property string announcement: ""

    readonly property real maxZoom: 8
    readonly property real wheelStep: 1.25
    readonly property real fastStep: 1.5
    readonly property real panStep: 40
    readonly property var current: images[index] ?? null
    readonly property string address: (current?.url ?? "").toString()
    readonly property bool webAddress: /^https?:/i.test(address)
    readonly property bool pending: current !== null && address.length === 0 && refused[current.id] !== true
    readonly property bool failed: current !== null && !pending && (address.length === 0 || picture.status === Image.Error)
    readonly property real fitted: picture.implicitWidth > 0 && picture.implicitHeight > 0 ? Math.min(1, stage.width / picture.implicitWidth, stage.height / picture.implicitHeight) : 1
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    // Opens `list`'s image `at`; focus goes back to `from` on closing.
    function showImages(list, at, from) {
        images = list;
        opener = from;
        refused = {};
        goTo(at);
        open();
    }

    function goTo(at) {
        index = at;
        reading = false;
        setZoom(1, 0, 0);
        panX = 0;
        panY = 0;
        if (model !== null && current !== null && typeof model.loadAttachment === "function")
            model.loadAttachment(current.id);
    }

    function step(by) {
        if (images.length > 1)
            goTo((index + by + images.length) % images.length);
    }

    // Zooms keeping the picture's point under (atX, atY), from the stage's centre, in place.
    function setZoom(next, atX, atY) {
        const bounded = Math.max(1, Math.min(maxZoom, next));
        if (bounded === zoom)
            return;
        const ratio = bounded / zoom;
        zoom = bounded;
        panX = atX - (atX - panX) * ratio;
        panY = atY - (atY - panY) * ratio;
        clampPan();
        announcement = qsTr("%1% zoom").arg(Math.round(zoom * 100));
        title.Accessible.announce(announcement);
    }

    function clampPan() {
        const reachX = Math.max(0, (picture.width - stage.width) / 2);
        const reachY = Math.max(0, (picture.height - stage.height) / 2);
        panX = Math.max(-reachX, Math.min(reachX, panX));
        panY = Math.max(-reachY, Math.min(reachY, panY));
    }

    function panBy(dx, dy) {
        panX += dx;
        panY += dy;
        clampPan();
    }

    function toggleZoom(atX, atY) {
        setZoom(zoom > 1 ? 1 : 2, atX, atY);
    }

    objectName: "imageViewer"
    parent: Overlay.overlay
    x: 0
    y: 0
    width: parent?.width ?? 0
    height: parent?.height ?? 0
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    onClosed: {
        images = [];
        if (opener !== null)
            opener.forceActiveFocus();
        opener = null;
    }

    background: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.88)
    }

    Connections {
        target: viewer.model
        ignoreUnknownSignals: true
        function onAttachmentSigned(id, url) {
            if (!viewer.visible)
                return;
            const shown = viewer.images.findIndex(image => image.id === id);
            if (shown < 0)
                return;
            const list = viewer.images.slice();
            list[shown] = Object.assign({}, list[shown], { url: url });
            viewer.images = list;
            if (url.toString().length === 0) {
                const refused = Object.assign({}, viewer.refused);
                refused[id] = true;
                viewer.refused = refused;
            }
        }
    }

    contentItem: Item {
        focus: true
        Keys.onPressed: event => {
            const zoomed = viewer.zoom > 1;
            switch (event.key) {
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space:
                viewer.toggleZoom(0, 0);
                break;
            case Qt.Key_Plus:
            case Qt.Key_Equal:
                viewer.setZoom(viewer.zoom * viewer.wheelStep, 0, 0);
                break;
            case Qt.Key_Minus:
                viewer.setZoom(viewer.zoom / viewer.wheelStep, 0, 0);
                break;
            case Qt.Key_0:
                viewer.setZoom(1, 0, 0);
                break;
            case Qt.Key_Left:
                if (zoomed)
                    viewer.panBy(viewer.panStep, 0);
                else
                    viewer.step(-1);
                break;
            case Qt.Key_Right:
                if (zoomed)
                    viewer.panBy(-viewer.panStep, 0);
                else
                    viewer.step(1);
                break;
            case Qt.Key_Up:
                if (zoomed)
                    viewer.panBy(0, viewer.panStep);
                break;
            case Qt.Key_Down:
                if (zoomed)
                    viewer.panBy(0, -viewer.panStep);
                break;
            default:
                return;
            }
            event.accepted = true;
        }

        // A press beside the picture closes; on it, a click zooms and a drag looks around.
        MouseArea {
            id: pointer

            property real lastX
            property real lastY
            property bool dragged

            function fromCentre(point) {
                return Qt.point(point.x - stage.x - stage.width / 2, point.y - stage.y - stage.height / 2);
            }

            objectName: "imageViewerPointer"
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: viewer.zoom > 1 ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
            onPressed: mouse => {
                lastX = mouse.x;
                lastY = mouse.y;
                dragged = false;
            }
            onPositionChanged: mouse => {
                if (!pressed || viewer.zoom <= 1)
                    return;
                if (Math.abs(mouse.x - lastX) + Math.abs(mouse.y - lastY) > 3)
                    dragged = true;
                if (!dragged)
                    return;
                viewer.panBy(mouse.x - lastX, mouse.y - lastY);
                lastX = mouse.x;
                lastY = mouse.y;
            }
            onClicked: mouse => {
                if (dragged)
                    return;
                const on = picture.visible && picture.status === Image.Ready && picture.contains(mapToItem(picture, mouse.x, mouse.y));
                if (mouse.button === Qt.RightButton) {
                    if (on)
                        menu.popup();
                    return;
                }
                if (!on) {
                    viewer.close();
                    return;
                }
                const at = fromCentre(Qt.point(mouse.x, mouse.y));
                viewer.toggleZoom(at.x, at.y);
            }
            onWheel: wheel => {
                if (wheel.angleDelta.y === 0)
                    return;
                const factor = wheel.modifiers & Qt.ControlModifier ? viewer.fastStep : viewer.wheelStep;
                const at = fromCentre(Qt.point(wheel.x, wheel.y));
                viewer.setZoom(wheel.angleDelta.y > 0 ? viewer.zoom * factor : viewer.zoom / factor, at.x, at.y);
            }
        }
        PinchHandler {
            property real startZoom: 1

            target: null
            onActiveChanged: if (active)
                startZoom = viewer.zoom
            onActiveScaleChanged: viewer.setZoom(startZoom * activeScale, 0, 0)
        }

        Item {
            id: stage

            objectName: "imageViewerStage"
            anchors.fill: parent
            anchors.topMargin: 56
            anchors.bottomMargin: 16
            // On a narrow window the stepping buttons lie over the picture.
            anchors.leftMargin: viewer.width < 560 ? 0 : 64
            anchors.rightMargin: viewer.width < 560 ? 0 : 64
            clip: viewer.zoom > 1

            Image {
                id: picture

                objectName: "imageViewerPicture"
                visible: !viewer.reading && !viewer.failed
                width: implicitWidth * viewer.fitted * viewer.zoom
                height: implicitHeight * viewer.fitted * viewer.zoom
                x: (stage.width - width) / 2 + viewer.panX
                y: (stage.height - height) / 2 + viewer.panY
                source: viewer.address
                asynchronous: true
                smooth: true
                Accessible.role: Accessible.Graphic
                Accessible.name: viewer.current?.name ?? ""
            }
            Flickable {
                anchors.fill: parent
                visible: viewer.reading
                clip: true
                contentHeight: captured.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                TextEdit {
                    id: captured

                    objectName: "imageViewerText"
                    width: parent.width
                    readOnly: true
                    selectByMouse: true
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    text: viewer.reading ? (viewer.current?.accessText ?? "") : ""
                    color: viewer.foreground
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                    font.pixelSize: Theme.fontSizeCode
                }
            }
            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: 12
                visible: viewer.failed

                Label {
                    objectName: "imageViewerProblem"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: viewer.foreground
                    text: viewer.webAddress ? qsTr("This image could not be loaded.") : qsTr("Image unavailable. The file may have been moved or deleted.")
                }
                ShellButton {
                    objectName: "imageViewerOriginal"
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: viewer.webAddress
                    text: qsTr("Open original")
                    onClicked: Shell.openExternal(viewer.address)
                }
            }
        }

        Row {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 12
            spacing: 8

            Label {
                id: title

                objectName: "imageViewerName"
                width: parent.width - actions.width - 8
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const name = viewer.current?.name ?? "";
                    return viewer.images.length > 1 ? qsTr("%1 (%2/%3)").arg(name).arg(viewer.index + 1).arg(viewer.images.length) : name;
                }
                color: viewer.foreground
                elide: Text.ElideMiddle
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }
            Row {
                id: actions

                spacing: 8

                Label {
                    objectName: "imageViewerZoom"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: viewer.zoom > 1
                    text: viewer.announcement
                    color: viewer.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
                ShellButton {
                    objectName: "imageViewerAccess"
                    visible: (viewer.current?.accessFormat ?? "").length > 0
                    subtle: true
                    text: viewer.reading ? qsTr("Show screenshot") : viewer.current?.accessFormat === "json" ? qsTr("Show accessibility JSON") : qsTr("Show extracted text")
                    onClicked: viewer.reading = !viewer.reading
                }
                ShellButton {
                    objectName: "imageViewerClose"
                    subtle: true
                    iconName: "x"
                    Accessible.name: qsTr("Close")
                    onClicked: viewer.close()
                }
            }
        }
        ShellButton {
            objectName: "imageViewerPrevious"
            visible: viewer.images.length > 1
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            subtle: true
            iconName: "chevron-left"
            Accessible.name: qsTr("Previous image")
            onClicked: viewer.step(-1)
        }
        ShellButton {
            objectName: "imageViewerNext"
            visible: viewer.images.length > 1
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            subtle: true
            iconName: "chevron-right"
            Accessible.name: qsTr("Next image")
            onClicked: viewer.step(1)
        }
        ShellMenu {
            id: menu

            objectName: "imageViewerMenu"

            ShellMenuItem {
                text: qsTr("Open original")
                enabled: viewer.webAddress
                onTriggered: Shell.openExternal(viewer.address)
            }
        }
    }
}
