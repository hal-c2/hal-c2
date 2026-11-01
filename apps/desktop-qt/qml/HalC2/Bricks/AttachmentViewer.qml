pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// An attachment opened to look at (`attachmentViewer`,
// AttachmentViewerController): an image, Markdown, a table or a page rendered
// or as its source, other text, or a note that it cannot be shown here. A
// draft's can be taken off the draft from here; a sent one's can be saved.
Dialog {
    id: dialog

    readonly property var attachment: Shell.state.attachmentViewer ?? null
    readonly property string kind: attachment?.kind ?? ""
    readonly property bool hasSource: kind === "markdown" || kind === "table" || kind === "page"
    property string shownId
    property bool source: false
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    objectName: "attachmentViewer"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(720, (parent?.width ?? 752) / scale - 32)
    height: Math.min(560, (parent?.height ?? 592) / scale - 32)
    padding: 16
    closePolicy: Popup.CloseOnEscape
    onAttachmentChanged: {
        if (attachment === null) {
            close();
            return;
        }
        // The same attachment published again keeps how it is being read.
        if (attachment.id !== shownId) source = false;
        shownId = attachment.id;
        open();
    }
    onRejected: {
        shownId = "";
        Shell.dispatch("attachment.viewer.close");
    }

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    contentItem: ColumnLayout {
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                objectName: "attachmentViewerName"
                Layout.fillWidth: true
                text: dialog.attachment?.name ?? ""
                color: dialog.foreground
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
            }
            Label {
                text: dialog.attachment?.origin ?? ""
                color: dialog.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
            ShellButton {
                objectName: "attachmentViewerSource"
                visible: dialog.hasSource
                subtle: true
                text: dialog.source ? qsTr("Rendered") : qsTr("Source")
                onClicked: {
                    dialog.source = !dialog.source;
                    // A sent page's source is read fresh; it may not be text at all.
                    if (dialog.source && dialog.kind === "page")
                        Shell.dispatch("attachment.viewer.source");
                }
            }
            ShellButton {
                objectName: "attachmentViewerCopy"
                visible: (dialog.attachment?.text ?? null) !== null
                subtle: true
                text: dialog.attachment?.truncated ? qsTr("Copy part shown") : qsTr("Copy")
                onClicked: Shell.dispatch("attachment.viewer.copy")
            }
            ShellButton {
                objectName: "attachmentViewerSave"
                visible: dialog.attachment?.origin === qsTr("Sent") && dialog.kind !== "loading" && dialog.kind !== "failed"
                subtle: true
                text: qsTr("Save")
                onClicked: Shell.dispatch("attachment.viewer.save")
            }
            ShellButton {
                objectName: "attachmentViewerRemove"
                visible: dialog.attachment?.removable === true
                text: qsTr("Remove")
                tint: Theme.palette.color("error", "#ef4444")
                onClicked: Shell.dispatch("attachment.viewer.remove")
            }
            ShellButton {
                objectName: "attachmentViewerClose"
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Close")
                onClicked: dialog.reject()
            }
        }

        Image {
            objectName: "attachmentViewerImage"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dialog.kind === "image"
            source: dialog.kind === "image" ? dialog.attachment.url : ""
            sourceSize: Qt.size(1440, 1120)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        Flickable {
            id: page

            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dialog.kind === "text" || dialog.hasSource
            clip: true
            contentHeight: (body.item as Item)?.implicitHeight ?? 0
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                Accessible.name: qsTr("Scroll attachment")
            }

            Loader {
                id: body

                width: page.width
                active: page.visible
                sourceComponent: dialog.kind === "text" || dialog.source ? plain : dialog.kind === "page" ? page_ : rendered
            }
            Component {
                id: rendered

                Markdown {
                    objectName: "attachmentViewerMarkdown"
                    text: dialog.attachment?.rendered ?? dialog.attachment?.text ?? ""
                    onLinkActivated: link => Shell.openExternal(link)
                }
            }
            Component {
                id: page_

                Text {
                    objectName: "attachmentViewerPage"
                    text: dialog.attachment?.text ?? ""
                    textFormat: Text.RichText
                    color: dialog.foreground
                    wrapMode: Text.Wrap
                    onLinkActivated: link => Shell.openExternal(link)
                }
            }
            Component {
                id: plain

                Text {
                    objectName: "attachmentViewerText"
                    text: dialog.kind === "page" ? (dialog.attachment?.sourceProblem ?? dialog.attachment?.source ?? "") : (dialog.attachment?.text ?? "")
                    textFormat: Text.PlainText
                    color: dialog.foreground
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                    font.pixelSize: Theme.fontSizeCode
                    wrapMode: Text.Wrap
                }
            }
        }
        Label {
            objectName: "attachmentViewerLoading"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dialog.kind === "loading"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Loading the attachment…")
            color: dialog.muted
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dialog.kind === "failed"
            spacing: 10

            Item { Layout.fillHeight: true }
            Label {
                objectName: "attachmentViewerProblem"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: dialog.attachment?.problem ?? ""
                color: dialog.foreground
                wrapMode: Text.Wrap
            }
            ShellButton {
                objectName: "attachmentViewerRetry"
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Try again")
                onClicked: Shell.dispatch("attachment.viewer.retry")
            }
            Item { Layout.fillHeight: true }
        }
        Label {
            objectName: "attachmentViewerUnsupported"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dialog.kind === "unsupported"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("This attachment cannot be shown here.")
            color: dialog.muted
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
    }
}
