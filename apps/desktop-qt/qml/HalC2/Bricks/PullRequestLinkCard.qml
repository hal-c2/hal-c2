import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The card a pull request link in the conversation shows on hover, as the
// web's PullRequestLinkPreview drew it: repository, number and state, the
// title, the author and when it was opened. A link the MC could not read
// shows its address. Nothing shows while it reads.
ToolTip {
    id: card

    // A PullRequestLinkPreviews.
    property var previews: null
    // The pointer is on the claimed link `address`.
    property bool shown: false
    property string address: ""
    // The pointer, in the parent's coordinates: the card opens below it, or
    // above when the window has no room, and never under it, which would
    // take the pointer off the link and close the card.
    property point pointer: Qt.point(0, 0)

    readonly property string status: previews?.status ?? ""
    readonly property var preview: previews?.card ?? ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family

    function stateColor(state) {
        if (state === "open")
            return Theme.palette.color("success", "#22c55e");
        if (state === "merged")
            return Theme.palette.color("merged", "#a855f7");
        if (state === "closed")
            return Theme.palette.color("errorForeground", "#ef4444");
        return muted;
    }

    objectName: "pullRequestLinkCard"
    visible: shown && (status === "ready" || status === "failed")
    delay: 350
    x: pointer.x - 12
    y: {
        const below = pointer.y + 20;
        const window = parent?.Window.window;
        if (!parent || !window)
            return below;
        const scene = parent.mapToItem(null, 0, below);
        return scene.y + implicitHeight <= window.height ? below : pointer.y - implicitHeight - 12;
    }
    width: Math.min(320, contentItem.implicitWidth + leftPadding + rightPadding)
    padding: 12
    background: ShellPopoverSurface {}
    contentItem: ColumnLayout {
        spacing: 4

        Label {
            visible: card.status === "failed"
            Layout.maximumWidth: 296
            text: card.address
            color: card.muted
            font.family: card.uiFamily
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.WrapAnywhere
        }
        RowLayout {
            visible: card.status === "ready"
            spacing: 6
            Label {
                Layout.maximumWidth: 180
                text: card.preview.repository ?? ""
                color: card.muted
                elide: Text.ElideRight
                font.family: card.uiFamily
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
            Label {
                text: "#" + (card.preview.number ?? "")
                color: card.muted
                font.family: card.uiFamily
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
            Label {
                text: "·"
                color: card.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
                Accessible.ignored: true
            }
            Label {
                text: card.preview.stateLabel ?? ""
                color: card.stateColor(card.preview.state ?? "")
                font.family: card.uiFamily
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
        }
        Label {
            visible: card.status === "ready"
            Layout.maximumWidth: 296
            text: card.preview.title ?? ""
            color: card.foreground
            wrapMode: Text.Wrap
            font.family: card.uiFamily
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.Medium
        }
        RowLayout {
            visible: card.status === "ready"
            spacing: 6
            Layout.topMargin: 4
            Label {
                Layout.maximumWidth: 180
                text: card.preview.author ?? ""
                color: card.muted
                elide: Text.ElideRight
                font.family: card.uiFamily
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
            Label {
                text: "·"
                color: card.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                Accessible.ignored: true
            }
            Label {
                text: qsTr("opened %1").arg(card.preview.opened ?? "")
                color: card.muted
                font.family: card.uiFamily
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }
    }
}
