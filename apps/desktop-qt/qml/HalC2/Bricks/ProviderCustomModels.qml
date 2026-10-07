pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A provider instance's custom models on the Providers settings section:
// adding and removing model ids, and the options the composer offers for
// each (ProviderSettingsController's `providerSettings.addModel`, `.editModel`,
// `.modelDraft`, `.saveModel`, `.removeModel`). The model being edited is the
// controller's draft, so it outlives this section being drawn again.
ColumnLayout {
    id: models

    required property var provider
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color danger: Theme.palette.color("error", "#f87171")

    function act(action, extra) {
        Shell.dispatch("providerSettings." + action, Object.assign({ instanceId: models.provider.instanceId }, extra || {}));
    }

    objectName: "customModels"
    spacing: 6

    component Hint: Label {
        Layout.fillWidth: true
        color: models.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // The draft's display name and options. Nothing is saved until Save.
    component Editor: ColumnLayout {
        id: editor

        // {slug, name, options [{id, label, type, choices [{id, label, isDefault}]}]}
        required property var draft
        readonly property var presets: (models.provider.modelPresets ?? []).filter(preset => !editor.draft.options.some(option => option.id === preset.id))

        function change(edit) {
            const next = JSON.parse(JSON.stringify(draft));
            edit(next);
            models.act("modelDraft", { name: next.name, options: next.options });
        }

        objectName: "modelEditor"
        Layout.fillWidth: true
        spacing: 6

        ShellTextField {
            objectName: "modelName"
            Layout.preferredWidth: 280
            text: editor.draft.name
            placeholderText: editor.draft.slug
            Accessible.name: qsTr("Display name")
            onEditingFinished: if (text !== editor.draft.name) editor.change(draft => draft.name = text)
        }

        RowLayout {
            Layout.fillWidth: true

            Label {
                Layout.fillWidth: true
                text: qsTr("Options shown in the composer")
                color: models.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellComboBox {
                objectName: "copyFrom"
                visible: (models.provider.copyFrom ?? []).length > 0
                outline: true
                model: [qsTr("Copy from…")].concat((models.provider.copyFrom ?? []).map(source => source.name))
                Accessible.name: qsTr("Copy options from a built-in model")
                onActivated: index => {
                    if (index > 0)
                        models.act("modelDraft", { copyFrom: models.provider.copyFrom[index - 1].slug });
                    currentIndex = 0;
                }
            }
        }

        Hint {
            visible: editor.draft.options.length === 0
            text: qsTr("No custom options. The composer uses the provider's default options.")
        }

        Repeater {
            model: editor.draft.options

            delegate: ColumnLayout {
                id: optionItem

                required property var modelData
                required property int index
                objectName: "option_" + index
                Layout.fillWidth: true
                spacing: 4

                RowLayout {
                    spacing: 6

                    ShellTextField {
                        objectName: "optionId"
                        Layout.preferredWidth: 150
                        text: optionItem.modelData.id
                        placeholderText: qsTr("id")
                        font.family: "monospace"
                        Accessible.name: qsTr("Option id")
                        onEditingFinished: if (text !== optionItem.modelData.id) editor.change(draft => draft.options[optionItem.index].id = text)
                    }

                    ShellTextField {
                        objectName: "optionLabel"
                        Layout.fillWidth: true
                        text: optionItem.modelData.label
                        placeholderText: qsTr("Label")
                        Accessible.name: qsTr("Option label")
                        onEditingFinished: if (text !== optionItem.modelData.label) editor.change(draft => draft.options[optionItem.index].label = text)
                    }

                    ShellComboBox {
                        objectName: "optionType"
                        outline: true
                        model: [qsTr("Choice"), qsTr("On/off")]
                        currentIndex: optionItem.modelData.type === "boolean" ? 1 : 0
                        Accessible.name: qsTr("Option type")
                        onActivated: index => editor.change(draft => draft.options[optionItem.index].type = index === 1 ? "boolean" : "select")
                    }

                    ShellButton {
                        objectName: "removeOption"
                        subtle: true
                        iconName: "x"
                        Accessible.name: qsTr("Remove option")
                        onClicked: editor.change(draft => draft.options.splice(optionItem.index, 1))
                    }
                }

                Repeater {
                    model: optionItem.modelData.type === "boolean" ? [] : optionItem.modelData.choices

                    delegate: RowLayout {
                        id: choiceItem

                        required property var modelData
                        required property int index
                        objectName: "choice_" + index
                        Layout.leftMargin: 16
                        spacing: 6

                        function edit(key, value) {
                            editor.change(draft => {
                                const choices = draft.options[optionItem.index].choices;
                                // Only one choice is the default.
                                if (key === "isDefault" && value)
                                    choices.forEach(choice => choice.isDefault = false);
                                choices[choiceItem.index][key] = value;
                            });
                        }

                        ShellTextField {
                            objectName: "choiceId"
                            Layout.preferredWidth: 130
                            text: choiceItem.modelData.id
                            placeholderText: qsTr("value")
                            font.family: "monospace"
                            Accessible.name: qsTr("Choice value")
                            onEditingFinished: if (text !== choiceItem.modelData.id) choiceItem.edit("id", text)
                        }

                        ShellTextField {
                            objectName: "choiceLabel"
                            Layout.preferredWidth: 150
                            text: choiceItem.modelData.label
                            placeholderText: qsTr("Label")
                            Accessible.name: qsTr("Choice label")
                            onEditingFinished: if (text !== choiceItem.modelData.label) choiceItem.edit("label", text)
                        }

                        ShellButton {
                            objectName: "choiceDefault"
                            subtle: !choiceItem.modelData.isDefault
                            text: qsTr("Default")
                            Accessible.name: qsTr("Default choice")
                            onClicked: choiceItem.edit("isDefault", !choiceItem.modelData.isDefault)
                        }

                        ShellButton {
                            objectName: "removeChoice"
                            subtle: true
                            iconName: "x"
                            Accessible.name: qsTr("Remove choice")
                            onClicked: editor.change(draft => draft.options[optionItem.index].choices.splice(choiceItem.index, 1))
                        }
                    }
                }

                ShellButton {
                    objectName: "addChoice"
                    Layout.leftMargin: 16
                    visible: optionItem.modelData.type !== "boolean"
                    subtle: true
                    iconName: "plus"
                    text: qsTr("Add choice")
                    onClicked: editor.change(draft => draft.options[optionItem.index].choices.push({ id: "", label: "", isDefault: false }))
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: editor.presets

                delegate: ShellButton {
                    required property var modelData
                    objectName: "preset_" + modelData.id
                    subtle: true
                    iconName: "plus"
                    text: modelData.label
                    onClicked: editor.change(draft => draft.options.push(JSON.parse(JSON.stringify(modelData))))
                }
            }

            ShellButton {
                objectName: "addOption"
                subtle: true
                iconName: "plus"
                text: qsTr("Custom option")
                onClicked: editor.change(draft => draft.options.push({ id: "", label: "", type: "select", choices: [] }))
            }
        }

        RowLayout {
            spacing: 8

            ShellButton {
                objectName: "saveModel"
                text: qsTr("Save")
                onClicked: {
                    // A field still being typed in commits first.
                    forceActiveFocus();
                    models.act("saveModel", { slug: editor.draft.slug });
                }
            }

            ShellButton {
                objectName: "cancelModel"
                subtle: true
                text: qsTr("Cancel")
                onClicked: models.act("editModel", { slug: "" })
            }
        }
    }

    Label {
        text: qsTr("Custom models")
        color: models.foreground
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.Medium
    }

    Repeater {
        model: models.provider.customModels ?? []

        delegate: ColumnLayout {
            id: modelItem

            required property var modelData
            readonly property var draft: models.provider.modelDraft ?? null
            readonly property bool editing: draft !== null && draft.slug === modelData.slug
            objectName: "model_" + modelData.slug
            Layout.fillWidth: true
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Label {
                    Layout.fillWidth: true
                    text: modelItem.modelData.name.length > 0 ? qsTr("%1 (%2)").arg(modelItem.modelData.name).arg(modelItem.modelData.slug) : modelItem.modelData.slug
                    color: models.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    elide: Text.ElideRight
                }

                Label {
                    visible: modelItem.modelData.options.length > 0
                    text: qsTr("%n option(s)", "", modelItem.modelData.options.length)
                    color: models.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "editModel"
                    subtle: true
                    iconName: "pencil"
                    Accessible.name: qsTr("Edit %1").arg(modelItem.modelData.slug)
                    onClicked: models.act("editModel", { slug: modelItem.editing ? "" : modelItem.modelData.slug })
                }

                ShellButton {
                    objectName: "removeModel"
                    subtle: true
                    iconName: "x"
                    Accessible.name: qsTr("Remove %1").arg(modelItem.modelData.slug)
                    onClicked: models.act("removeModel", { slug: modelItem.modelData.slug })
                }
            }

            Loader {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                active: modelItem.editing
                visible: active

                sourceComponent: Editor {
                    draft: modelItem.draft
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        ShellTextField {
            id: slugField

            objectName: "newModel"
            Layout.fillWidth: true
            placeholderText: qsTr("Model slug")
            font.family: "monospace"
            Accessible.name: qsTr("Custom model slug")
            onAccepted: addButton.clicked()
        }

        ShellButton {
            id: addButton

            objectName: "addModel"
            iconName: "plus"
            text: qsTr("Add")
            onClicked: {
                models.act("addModel", { slug: slugField.text });
                slugField.text = "";
            }
        }
    }

    Hint {
        objectName: "modelError"
        visible: text.length > 0
        text: models.provider.modelError ?? ""
        color: models.danger
    }
}
