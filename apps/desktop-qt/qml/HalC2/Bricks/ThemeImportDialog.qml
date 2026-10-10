import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// Adds themes to this device (Themes.importFiles, importText): theme files
// picked or dropped, or JSON pasted. A file too large or unreadable says so,
// and a theme already installed asks whether to update it or keep both.
Popup {
    id: dialog

    readonly property bool conflicted: Themes.importConflicts.length > 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    function localPath(url) {
        return decodeURIComponent(url.toString().replace(/^file:\/\//, ""));
    }

    function finish(done) {
        if (done && !conflicted && Themes.importError.length === 0) close();
    }

    objectName: "themeImport"
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(520, parent ? parent.width / scale - 48 : 520)
    modal: true
    focus: true
    padding: 16
    onOpened: {
        json.clear();
        json.forceActiveFocus();
    }

    background: Rectangle {
        radius: Theme.radius
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
    }

    contentItem: ColumnLayout {
        spacing: 10

        Label {
            text: qsTr("Import theme")
            color: dialog.foreground
            font.pixelSize: Math.round(16 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        ShellButton {
            objectName: "chooseFiles"
            iconName: "folder-open"
            text: qsTr("Choose theme files")
            onClicked: picker.open()
        }

        TextArea {
            id: json

            objectName: "json"
            Layout.fillWidth: true
            Layout.preferredHeight: 160
            placeholderText: qsTr("Or paste a theme's JSON")
            color: dialog.foreground
            wrapMode: TextEdit.Wrap
            Accessible.name: qsTr("Theme JSON")
            // Tab and Shift+Tab leave the field for the buttons rather than indenting the JSON.
            Keys.onTabPressed: nextItemInFocusChain().forceActiveFocus(Qt.TabFocusReason)
            Keys.onBacktabPressed: nextItemInFocusChain(false).forceActiveFocus(Qt.BacktabFocusReason)
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: Math.round(12 * Theme.fontScale)
            background: Rectangle {
                radius: Math.min(Theme.radius, 8)
                color: Theme.palette.color("input", "#18181b")
                border.color: Theme.palette.color("border", "#27272a")
            }
        }

        Label {
            objectName: "importError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: Themes.importError
            color: Theme.palette.color("error", "#f87171")
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Label {
            objectName: "importConflict"
            Layout.fillWidth: true
            visible: dialog.conflicted
            text: qsTr("%1 is already installed.").arg(Themes.importConflicts.join(", "))
            color: dialog.foreground
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "cancel"
                subtle: true
                text: qsTr("Cancel")
                onClicked: {
                    Themes.resolveImport("cancel");
                    dialog.close();
                }
            }

            ShellButton {
                objectName: "keepBoth"
                visible: dialog.conflicted
                text: qsTr("Keep both")
                onClicked: {
                    Themes.resolveImport("copy");
                    dialog.finish(true);
                }
            }

            ShellButton {
                objectName: "updateExisting"
                visible: dialog.conflicted
                primary: true
                text: qsTr("Update existing")
                onClicked: {
                    Themes.resolveImport("update");
                    dialog.finish(true);
                }
            }

            ShellButton {
                objectName: "import"
                visible: !dialog.conflicted
                primary: true
                enabled: json.text.trim().length > 0
                text: qsTr("Import")
                onClicked: dialog.finish(Themes.importText(json.text))
            }
        }
    }

    FileDialog {
        id: picker

        title: qsTr("Choose theme files")
        fileMode: FileDialog.OpenFiles
        nameFilters: [qsTr("Theme files (*.json)")]
        onAccepted: {
            Themes.importFiles(selectedFiles.map(dialog.localPath));
            dialog.finish(true);
        }
    }
}
