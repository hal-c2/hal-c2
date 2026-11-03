pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Edits a project's file as a page, from the command palette (`space.files.pick`):
// the files the project's spaces section covers, as the MC listed them
// (SpaceController's `files`), and the scan that writes that section. Open while
// `space.picking` names a project.
Dialog {
    id: dialog

    readonly property var space: Shell.state.space ?? ({})
    readonly property string picking: space.picking ?? ""
    readonly property var projects: space.projects ?? []
    readonly property var listed: (space.files ?? ({}))[picking]
    readonly property var paths: Object.keys(listed?.paths ?? ({})).sort()
    readonly property string projectTitle: projects.find(project => project.id === picking)?.title ?? picking

    onPickingChanged: {
        if (picking !== "")
            open();
        else
            close();
    }
    // The Space view may come on show with the picker already asked for.
    Component.onCompleted: {
        if (picking !== "")
            open();
    }
    onClosed: {
        if (picking !== "")
            Shell.dispatch("space.files.pickClose", {});
    }

    objectName: "spaceFilePicker"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(520, (parent?.width ?? 552) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Edit a project file as a page")

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

        ShellButton {
            id: projectButton

            objectName: "spaceFilePickerProject"
            Layout.fillWidth: true
            subtle: true
            chevron: true
            iconName: "folder-open"
            text: dialog.projectTitle
            toolTip: qsTr("Choose a project")
            enabled: dialog.projects.length > 1
            onClicked: projectMenu.popup(projectButton, 0, projectButton.height + 4)

            ShellMenu {
                id: projectMenu

                Instantiator {
                    model: dialog.projects

                    delegate: ShellMenuItem {
                        required property var modelData

                        text: modelData.title
                        current: modelData.id === dialog.picking
                        onTriggered: Shell.dispatch("space.files.pick", { projectId: modelData.id })
                    }

                    onObjectAdded: (index, object) => projectMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => projectMenu.removeItem(object)
                }
            }
        }

        ListView {
            id: list

            objectName: "spaceFilePickerFiles"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 320)
            visible: dialog.paths.length > 0
            clip: true
            model: dialog.paths
            boundsBehavior: Flickable.StopAtBounds

            delegate: ShellButton {
                id: fileButton

                required property string modelData
                readonly property var entry: dialog.listed.paths[modelData]

                objectName: "spaceFilePickerFile:" + modelData
                width: ListView.view.width
                subtle: true
                text: (entry.title ?? "") !== "" ? qsTr("%1 (the page %2)").arg(modelData).arg(entry.title) : modelData
                onClicked: Shell.dispatch("space.openFile", { projectId: dialog.picking, relativePath: modelData })

                // A list reads from the left, where a button centres its label.
                contentItem: RowLayout {
                    spacing: 6

                    ShellIcon {
                        name: "file-text"
                        size: fileButton.iconSize
                        color: fileButton.iconTint
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Text {
                        text: fileButton.text
                        font: fileButton.font
                        color: fileButton.tint
                        elide: Text.ElideMiddle
                        verticalAlignment: Text.AlignVCenter
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                    }
                }
            }
        }

        Text {
            objectName: "spaceFilePickerEmpty"
            Layout.fillWidth: true
            visible: dialog.paths.length === 0
            wrapMode: Text.Wrap
            text: dialog.listed === undefined
                ? qsTr("Looking for the files of %1…").arg(dialog.projectTitle)
                : (dialog.listed.error ?? "") !== ""
                    ? qsTr("The files of %1 could not be listed: %2").arg(dialog.projectTitle).arg(dialog.listed.error)
                : dialog.listed.config === "invalid"
                    ? qsTr("The spaces section of %1's hal-c2.json cannot be read.").arg(dialog.projectTitle)
                    : qsTr("%1 has no files to edit as pages. A scan writes a spaces section for its Markdown files.").arg(dialog.projectTitle)
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellButton {
                objectName: "spaceFilePickerScan"
                text: qsTr("Scan for Space files")
                iconName: "search"
                onClicked: Shell.dispatch("space.files.scan", { projectId: dialog.picking })
            }

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                text: qsTr("Cancel")
                onClicked: dialog.close()
            }
        }
    }
}
