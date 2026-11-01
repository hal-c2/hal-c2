pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks for a prompt and who draws it. The provider and model come from the same
// picker as the composer's, showing only the providers the MC says can make an
// image right now (`space.imageProviders`); the rest are named with why not.
Dialog {
    id: dialog

    readonly property var offer: Shell.state.space?.imageProviders ?? ({})
    readonly property var providers: offer.providers ?? []
    readonly property var ready: providers.filter(provider => provider.status === "ready").map(provider => provider.instanceId)
    readonly property var notHere: providers.filter(provider => provider.status === "unsupported").map(provider => provider.instanceId)
    // What the user picked, else what the MC would use.
    property var chosenInstance: null
    property var chosenModel: null
    readonly property var instanceId: chosenInstance ?? offer.selection?.instanceId ?? null
    readonly property var model: chosenInstance !== null ? chosenModel : (offer.selection?.model ?? null)

    function submit() {
        const prompt = promptField.text.trim();
        if (prompt.length === 0 || dialog.ready.length === 0)
            return;
        const payload = { prompt: prompt };
        if (dialog.instanceId !== null) {
            payload.modelSelection = { instanceId: dialog.instanceId };
            if (dialog.model)
                payload.modelSelection.model = dialog.model;
        }
        Shell.dispatch("space.image.generate", payload);
        dialog.close();
    }

    objectName: "spaceImageDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(460, (parent?.width ?? 492) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Generate an image")
    onAboutToShow: {
        Shell.dispatch("space.image.providers", {});
        promptField.text = "";
        promptField.forceActiveFocus();
    }

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Math.round(17 * Theme.fontScale)
        font.weight: Font.DemiBold
        color: Theme.palette.color("text", "#e4e4e7")
    }
    contentItem: ColumnLayout {
        spacing: 12

        ShellTextField {
            id: promptField

            objectName: "spaceImagePrompt"
            Layout.fillWidth: true
            placeholderText: qsTr("What should the image show?")
            onAccepted: dialog.submit()
        }

        RowLayout {
            Layout.fillWidth: true
            visible: dialog.ready.length > 0
            spacing: 8

            ModelPicker {
                objectName: "spaceImageModel"
                onlyInstances: dialog.ready
                selectedInstanceId: dialog.instanceId
                selectedModel: dialog.model
                onChosen: (instanceId, model) => {
                    dialog.chosenInstance = instanceId;
                    dialog.chosenModel = model;
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }

        Text {
            objectName: "spaceImageNoProvider"
            Layout.fillWidth: true
            visible: dialog.providers.length > 0 && dialog.ready.length === 0
            wrapMode: Text.Wrap
            text: qsTr("No provider that can make an image is ready. Set up Codex or Grok in Settings.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        Text {
            objectName: "spaceImageNotHere"
            Layout.fillWidth: true
            visible: dialog.notHere.length > 0
            wrapMode: Text.Wrap
            text: qsTr("Not supported here: %1").arg(dialog.notHere.join(", "))
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                text: qsTr("Cancel")
                onClicked: dialog.close()
            }

            ShellButton {
                objectName: "spaceImageSubmit"
                primary: true
                text: qsTr("Generate")
                enabled: promptField.text.trim().length > 0 && dialog.ready.length > 0
                onClicked: dialog.submit()
            }
        }
    }
}
