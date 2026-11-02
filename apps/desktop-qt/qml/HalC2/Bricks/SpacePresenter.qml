pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HalC2.Shell

// The deck being presented (Spaces.presenting): the window goes full screen and
// shows one slide at a time, and goes back as it was when the presenter closes.
// Arrow keys, Space and Page Up/Down step, a tap on the left third goes back and
// on the rest goes on, and Escape or Back leaves.
Item {
    id: presenter

    objectName: "spacePresenter"

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property bool presenting: Spaces.presenting
    property int windowWas: Window.Windowed

    function step(by) {
        Shell.dispatch("space.deck.step", { by: by });
    }

    function leave() {
        Shell.dispatch("space.deck.leave", {});
    }

    function giveWindowBack() {
        const window = presenter.Window.window;
        if (window && window.visibility === Window.FullScreen)
            window.visibility = presenter.windowWas;
    }

    onPresentingChanged: {
        const window = presenter.Window.window;
        if (!presenting) {
            giveWindowBack();
        } else if (window) {
            presenter.windowWas = window.visibility;
            window.visibility = Window.FullScreen;
        }
    }
    Component.onDestruction: {
        if (presenting)
            giveWindowBack();
    }

    Popup {
        id: stage

        objectName: "spacePresenterStage"
        parent: Overlay.overlay
        x: 0
        y: 0
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        padding: 0
        modal: true
        focus: true
        closePolicy: Popup.NoAutoClose
        visible: presenter.presenting
        background: Rectangle {
            color: Theme.palette.color("canvas", "#09090b")
        }
        onOpened: keys.forceActiveFocus()

        contentItem: Item {
            id: keys

            objectName: "spacePresenterKeys"
            focus: true

            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Right:
                case Qt.Key_Down:
                case Qt.Key_Space:
                case Qt.Key_PageDown:
                    presenter.step(1);
                    break;
                case Qt.Key_Left:
                case Qt.Key_Up:
                case Qt.Key_Backspace:
                case Qt.Key_PageUp:
                    presenter.step(-1);
                    break;
                case Qt.Key_Escape:
                case Qt.Key_Back:
                    presenter.leave();
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            MouseArea {
                objectName: "spacePresenterTap"
                anchors.fill: parent
                onClicked: mouse => presenter.step(mouse.x < width / 3 ? -1 : 1)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Math.round(Math.min(keys.width, keys.height) * 0.08)
                spacing: Math.round(keys.height * 0.03)

                Text {
                    objectName: "spacePresenterTitle"
                    Layout.fillWidth: true
                    text: Spaces.slide.title ?? ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: presenter.foreground
                    font.pixelSize: Math.max(20, Math.round(keys.height * 0.07))
                    font.weight: Font.Bold
                }

                Text {
                    objectName: "spacePresenterBody"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    text: Spaces.slide.body ?? ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    color: presenter.foreground
                    font.pixelSize: Math.max(16, Math.round(keys.height * 0.04))
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        objectName: "spacePresenterCount"
                        Layout.fillWidth: true
                        text: qsTr("%1 / %2").arg(Spaces.slideNumber).arg(Spaces.slideCount)
                        color: presenter.muted
                        font.pixelSize: Math.round(14 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spacePresenterBack"
                        subtle: true
                        iconName: "chevron-left"
                        Accessible.name: qsTr("Previous slide")
                        enabled: Spaces.slideNumber > 1
                        onClicked: presenter.step(-1)
                    }

                    ShellButton {
                        objectName: "spacePresenterForward"
                        subtle: true
                        iconName: "chevron-right"
                        Accessible.name: qsTr("Next slide")
                        enabled: Spaces.slideNumber < Spaces.slideCount
                        onClicked: presenter.step(1)
                    }

                    ShellButton {
                        objectName: "spacePresenterLeave"
                        subtle: true
                        iconName: "x"
                        text: qsTr("Leave")
                        onClicked: presenter.leave()
                    }
                }
            }
        }
    }
}
