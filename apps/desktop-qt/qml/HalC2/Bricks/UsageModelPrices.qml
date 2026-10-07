pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Custom model prices, over the usage page (UsagePricesController publishes
// `usagePrices`): a row per model with what a million tokens cost, edited for
// every chosen environment at once, and how the save went on each.
Rectangle {
    id: dialog

    readonly property var model: Shell.state.usagePrices ?? null
    readonly property var fields: [
        { key: "inputCostPerMillionTokens", label: qsTr("Input") },
        { key: "outputCostPerMillionTokens", label: qsTr("Output") },
        { key: "cacheReadCostPerMillionTokens", label: qsTr("Cache read") },
        { key: "cacheWriteCostPerMillionTokens", label: qsTr("Cache write") }
    ]
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "usageModelPrices"
    visible: model !== null && model.open
    color: Theme.palette.color("canvas", "#0b0b0d")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 8

        RowLayout {
            Layout.fillWidth: true

            Label {
                Layout.fillWidth: true
                text: qsTr("Model prices")
                color: dialog.foreground
                font.pixelSize: Math.round(18 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            ShellButton {
                subtle: true
                text: qsTr("Close")
                onClicked: Shell.dispatch("usagePrices.close")
            }
        }

        Label {
            Layout.fillWidth: true
            text: qsTr("US dollars per million tokens. An empty cache price uses the input rate.")
            color: dialog.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Repeater {
            model: dialog.model ? dialog.model.targets : []

            delegate: RowLayout {
                id: target

                required property var modelData

                Layout.fillWidth: true
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: target.modelData.label
                    color: dialog.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    text: target.modelData.status
                    color: target.modelData.error.length > 0 ? Theme.palette.color("error", "#f87171") : Theme.palette.color("success", "#22c55e")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                width: parent.width
                spacing: 4

                Repeater {
                    model: dialog.model ? dialog.model.rows : []

                    delegate: RowLayout {
                        id: row

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 6

                        Label {
                            Layout.preferredWidth: 180
                            text: row.modelData.model
                            color: row.modelData.removed ? dialog.muted : dialog.foreground
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            font.strikeout: row.modelData.removed
                            elide: Text.ElideMiddle
                        }

                        Repeater {
                            model: dialog.fields

                            delegate: ShellTextField {
                                required property var modelData
                                readonly property var cell: row.modelData.cells[modelData.key]

                                Layout.fillWidth: true
                                enabled: !row.modelData.removed
                                text: cell.value
                                placeholderText: cell.placeholder
                                Accessible.name: qsTr("%1 price of %2").arg(modelData.label).arg(row.modelData.model)
                                onTextEdited: Shell.dispatch("usagePrices.edit", {
                                    model: row.modelData.model,
                                    field: modelData.key,
                                    value: text
                                })
                            }
                        }

                        ShellButton {
                            objectName: "priceReset-" + row.modelData.model
                            subtle: true
                            text: row.modelData.removed ? qsTr("Undo") : qsTr("Reset to automatic")
                            onClicked: Shell.dispatch(row.modelData.removed ? "usagePrices.restore" : "usagePrices.remove", {
                                model: row.modelData.model
                            })
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellTextField {
                id: newModel

                Layout.fillWidth: true
                placeholderText: qsTr("Model ID")
                Accessible.name: qsTr("Model ID")
                onAccepted: add.clicked()
            }

            ShellButton {
                id: add

                text: qsTr("Add model")
                onClicked: {
                    Shell.dispatch("usagePrices.add", {
                        model: newModel.text
                    });
                    newModel.clear();
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.model ? dialog.model.error : ""
            color: Theme.palette.color("error", "#f87171")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "pricesRetry"
                visible: dialog.model !== null && dialog.model.canRetry
                text: qsTr("Retry failed saves")
                onClicked: Shell.dispatch("usagePrices.retry")
            }

            ShellButton {
                objectName: "pricesSave"
                primary: true
                enabled: dialog.model !== null && !dialog.model.saving
                text: qsTr("Save")
                onClicked: Shell.dispatch("usagePrices.save")
            }
        }
    }
}
