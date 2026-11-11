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
    // The window the card's parent is in, whose height decides above or below.
    property Window hostWindow: null

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
        if (!parent || !hostWindow)
            return below;
        const scene = parent.mapToItem(null, 0, below);
        return scene.y + implicitHeight <= hostWindow.height ? below : pointer.y - implicitHeight - 12;
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
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.WrapAnywhere
        }
        RowLayout {
            visible: card.status === "ready"
            spacing: Theme.space.sm
            Label {
                Layout.maximumWidth: 180
                text: card.preview.repository ?? ""
                color: card.muted
                elide: Text.ElideRight
                font.family: card.uiFamily
                font.pixelSize: Theme.type.caption.size
            }
            Label {
                text: "#" + (card.preview.number ?? "")
                color: card.muted
                font.family: card.uiFamily
                font.pixelSize: Theme.type.caption.size
            }
            Label {
                text: "·"
                color: card.muted
                font.pixelSize: Theme.type.caption.size
                Accessible.ignored: true
            }
            Label {
                text: card.preview.stateLabel ?? ""
                color: card.stateColor(card.preview.state ?? "")
                font.family: card.uiFamily
                font.pixelSize: Theme.type.caption.size
            }
        }
        Label {
            visible: card.status === "ready"
            Layout.maximumWidth: 296
            text: card.preview.title ?? ""
            color: card.foreground
            wrapMode: Text.Wrap
            font.family: card.uiFamily
            font.pixelSize: Theme.type.body.size
            font.weight: Font.Medium
        }
        RowLayout {
            visible: card.status === "ready"
            spacing: Theme.space.sm
            Layout.topMargin: 4
            Label {
                Layout.maximumWidth: 180
                text: card.preview.author ?? ""
                color: card.muted
                elide: Text.ElideRight
                font.family: card.uiFamily
                font.pixelSize: Theme.type.meta.size
            }
            Label {
                text: "·"
                color: card.muted
                font.pixelSize: Theme.type.meta.size
                Accessible.ignored: true
            }
            Label {
                text: qsTr("opened %1").arg(card.preview.opened ?? "")
                color: card.muted
                font.family: card.uiFamily
                font.pixelSize: Theme.type.meta.size
            }
        }
    }
}
