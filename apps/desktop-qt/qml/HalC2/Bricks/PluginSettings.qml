import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// One MC plugin's settings, at /settings/plugin/<environment>/<id>: the
// plugin's own settings page when it adds one, else a field for each setting
// it declares, saved together to its MC (`McPlugins.saveSettings`). A secret
// comes back masked, and saving the mask keeps it. What the plugin refuses
// stays unsaved, with its message.
SettingsPage {
    id: page

    readonly property string path: (Shell.state.route?.section ?? "").replace(/^\/settings\/plugin\//, "")
    readonly property string environment: path.slice(0, Math.max(0, path.lastIndexOf("/")))
    readonly property string pluginId: path.slice(path.lastIndexOf("/") + 1)
    readonly property var entry: {
        const environment = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === page.environment);
        return environment?.plugins.find(plugin => plugin.id === page.pluginId) ?? null;
    }
    readonly property var fields: entry?.settingsSchema ?? []
    readonly property string ownPage: entry?.settingsPageUrl ?? ""
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    // The values the fields show, saved together.
    property var values: ({})
    property bool dirty: false
    // The save on its way (-1 for none), and why the last one was refused.
    property int saving: -1
    property string refusal: ""
    // The keys of the JSON fields whose text does not parse: the page is not saved
    // until it does, so what is shown is what is saved.
    property var unparsed: []

    function reset() {
        const values = {};
        for (const field of page.fields) {
            if (field.default !== undefined)
                values[field.key] = field.default;
        }
        page.values = Object.assign(values, page.entry?.settings ?? {});
        page.dirty = false;
        page.refusal = "";
        page.unparsed = [];
    }

    function set(key, value) {
        const next = Object.assign({}, page.values);
        next[key] = value;
        page.values = next;
        page.dirty = true;
    }

    function setJson(key, text) {
        let value;
        try {
            value = JSON.parse(text);
        } catch (error) {
            if (!page.unparsed.includes(key))
                page.unparsed = page.unparsed.concat([key]);
            page.dirty = true;
            return;
        }
        page.unparsed = page.unparsed.filter(each => each !== key);
        page.set(key, value);
    }

    objectName: "pluginSettings"
    title: entry !== null ? (entry.name || entry.id) : qsTr("Plugin")
    onEntryChanged: if (!dirty)
        reset()
    Component.onCompleted: reset()

    Connections {
        target: McPlugins

        function onAnswered(request, result, error) {
            if (request !== page.saving)
                return;
            page.saving = -1;
            if (error.length > 0)
                page.refusal = error;
            else
                page.reset();
        }
    }

    component FieldText: Label {
        Layout.fillWidth: true
        color: page.muted
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    component LongText: TextArea {
        Layout.fillWidth: true
        Layout.preferredHeight: 96
        wrapMode: TextEdit.Wrap
        color: page.foreground
        font.pixelSize: Math.round(13 * Theme.fontScale)
        background: Rectangle {
            radius: Math.min(Theme.radius, 8)
            color: Theme.palette.color("input", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
        }
    }

    Label {
        objectName: "pluginSettingsMissing"
        visible: page.entry === null
        text: qsTr("This plugin is not on that MC any more.")
        color: page.muted
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    RowLayout {
        Layout.fillWidth: true
        visible: page.entry !== null && (page.entry.status === "failed" || page.entry.status === "error")
        spacing: 12

        Label {
            objectName: "pluginSettingsFailure"
            Layout.fillWidth: true
            text: qsTr("Failed: %1").arg(page.entry?.error || page.entry?.lastError || "")
            color: page.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellButton {
            objectName: "pluginSettingsRestart"
            text: qsTr("Restart")
            // A package that did not load is fixed in its files, not by a restart.
            visible: page.entry?.status === "failed"
            onClicked: Shell.dispatch("mcPlugins.restart", { environment: page.environment, id: page.pluginId })
        }
    }

    // The plugin's own page.
    PluginPart {
        objectName: "pluginOwnSettings"
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        visible: page.ownPage.length > 0
        url: page.ownPage
        pluginId: page.pluginId
        environments: [page.environment]
    }

    Label {
        visible: page.entry !== null && page.ownPage.length === 0 && page.fields.length === 0
        text: qsTr("This plugin has no settings.")
        color: page.muted
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    Repeater {
        model: page.ownPage.length === 0 ? page.fields : []

        delegate: ColumnLayout {
            id: field

            required property var modelData
            readonly property var value: page.values[modelData.key]

            objectName: "pluginSetting:" + modelData.key
            Layout.fillWidth: true
            spacing: 6

            Label {
                text: field.modelData.label
                color: page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            FieldText {
                visible: text.length > 0
                text: field.modelData.description ?? ""
            }

            ShellTextField {
                objectName: "control"
                Layout.fillWidth: true
                visible: ["text", "secret", "number"].indexOf(field.modelData.type) >= 0
                echoMode: field.modelData.type === "secret" ? TextInput.Password : TextInput.Normal
                inputMethodHints: field.modelData.type === "number" ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
                text: field.value === undefined || field.value === null ? "" : String(field.value)
                Accessible.name: field.modelData.label
                onTextEdited: {
                    if (field.modelData.type !== "number")
                        page.set(field.modelData.key, text);
                    else
                        page.set(field.modelData.key, text.trim().length > 0 && !isNaN(Number(text)) ? Number(text) : text);
                }
            }

            LongText {
                objectName: "control"
                visible: ["longText", "list", "object"].indexOf(field.modelData.type) >= 0
                placeholderText: field.modelData.type === "list" ? qsTr("One per line") : ""
                text: {
                    const value = field.value;
                    if (field.modelData.type === "list")
                        return (value ?? []).join("\n");
                    if (field.modelData.type === "object")
                        return value === undefined ? "" : JSON.stringify(value, null, 2);
                    return value ?? "";
                }
                Accessible.name: field.modelData.label
                onTextChanged: {
                    if (!activeFocus)
                        return;
                    if (field.modelData.type === "list") {
                        page.set(field.modelData.key, text.split("\n").map(line => line.trim()).filter(line => line.length > 0));
                    } else if (field.modelData.type === "object") {
                        page.setJson(field.modelData.key, text);
                    } else {
                        page.set(field.modelData.key, text);
                    }
                }
            }

            Switch {
                objectName: "control"
                visible: field.modelData.type === "boolean"
                checked: field.value === true
                Accessible.name: field.modelData.label
                onToggled: page.set(field.modelData.key, checked)
            }

            ShellComboBox {
                readonly property var options: field.modelData.options ?? []

                objectName: "control"
                visible: field.modelData.type === "choice"
                outline: true
                implicitWidth: 220
                model: options.map(option => option.label)
                disabledRows: options.map((option, index) => option.disabled === true ? index : -1).filter(index => index >= 0)
                currentIndex: options.findIndex(option => option.value === field.value)
                Accessible.name: field.modelData.label
                onActivated: index => {
                    if (options[index].disabled === true)
                        currentIndex = Qt.binding(() => options.findIndex(option => option.value === field.value));
                    else
                        page.set(field.modelData.key, options[index].value);
                }
            }
        }
    }

    Label {
        objectName: "pluginSettingsRefusal"
        Layout.fillWidth: true
        visible: page.refusal.length > 0
        text: qsTr("Not saved: %1").arg(page.refusal)
        color: page.errorColor
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    Label {
        objectName: "pluginSettingsUnparsed"
        Layout.fillWidth: true
        visible: page.unparsed.length > 0
        text: qsTr("Not valid JSON: %1").arg(page.fields.filter(field => page.unparsed.includes(field.key)).map(field => field.label || field.key).join(", "))
        color: page.errorColor
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    RowLayout {
        Layout.fillWidth: true
        visible: page.ownPage.length === 0 && page.fields.length > 0
        spacing: 8

        Item {
            Layout.fillWidth: true
        }

        ShellButton {
            objectName: "pluginSettingsReset"
            subtle: true
            text: qsTr("Discard changes")
            enabled: page.dirty && page.saving < 0
            onClicked: page.reset()
        }

        ShellButton {
            objectName: "pluginSettingsSave"
            primary: true
            text: qsTr("Save")
            enabled: page.dirty && page.saving < 0 && page.unparsed.length === 0
            onClicked: {
                page.refusal = "";
                page.saving = McPlugins.saveSettings(page.environment, page.pluginId, page.values);
            }
        }
    }
}
