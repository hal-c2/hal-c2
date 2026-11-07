pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import HalC2.Bricks
import HalC2.Shell

// A video or audio file from `source`, with its controls. Loaded by a Loader, so
// a machine without Qt Multimedia only loses this view. The arrow keys seek
// while it has focus. `failed` says the source could not be played.
FocusScope {
    id: root

    objectName: "mediaPlayerView"
    property url source
    property bool video: true
    property bool autoPlay: false
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property bool loaded: player.mediaStatus !== MediaPlayer.NoMedia && player.mediaStatus !== MediaPlayer.LoadingMedia && player.mediaStatus !== MediaPlayer.InvalidMedia
    readonly property real position: player.position
    readonly property real seekStep: 5000
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    signal failed(url source)

    function toggle() {
        if (playing)
            player.pause();
        else
            player.play();
    }

    function clock(ms) {
        const seconds = Math.floor(ms / 1000);
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
    }

    Keys.onLeftPressed: player.position = Math.max(0, player.position - seekStep)
    Keys.onRightPressed: player.position = Math.min(player.duration, player.position + seekStep)
    Keys.onSpacePressed: toggle()

    MediaPlayer {
        id: player

        source: root.source
        videoOutput: output
        audioOutput: AudioOutput {}
        onErrorOccurred: root.failed(root.source)
    }

    Component.onCompleted: {
        if (autoPlay) {
            player.play();
            forceActiveFocus();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        VideoOutput {
            id: output

            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.video

            TapHandler {
                onTapped: {
                    root.forceActiveFocus();
                    root.toggle();
                }
            }
        }
        Item {
            Layout.fillHeight: true
            visible: !root.video
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellButton {
                objectName: "mediaPlayerToggle"
                subtle: true
                text: root.playing ? qsTr("Pause") : qsTr("Play")
                onClicked: {
                    root.forceActiveFocus();
                    root.toggle();
                }
            }
            Rectangle {
                id: track

                Layout.fillWidth: true
                implicitHeight: 4
                radius: Theme.radiusPill
                color: Theme.palette.color("border", "#3f3f46")

                Rectangle {
                    width: player.duration > 0 ? parent.width * player.position / player.duration : 0
                    height: parent.height
                    radius: Theme.radiusPill
                    color: Theme.palette.color("text", "#e4e4e7")
                }
                TapHandler {
                    margin: 8
                    onTapped: point => player.position = player.duration * point.position.x / track.width
                }
            }
            Text {
                text: root.clock(player.position) + " / " + root.clock(player.duration)
                color: root.muted
                font.pixelSize: Theme.type.meta.size
            }
        }
        Item {
            Layout.fillHeight: true
            visible: !root.video
        }
    }
}
