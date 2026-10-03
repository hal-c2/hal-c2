import OpenTUI

// The controls under the prompt, like ComposerFooter: model │ effort │ access
// │ mode on the left and the primary action on the right, each styled by the
// host (`composer.footer`). A compact composer shows the model and "^K
// options" on one row and the primary action under it. Clicking a control
// opens its picker; clicking it again closes it. Plugins add their own
// controls through the "composer.actions" slot, after the built-in ones
// (`actionsMode: "replace"` swaps them out).
Item {
    id: footer
    readonly property var composer: Shell.state.composer
    readonly property bool compact: composer.compact
    property alias actionsMode: actionsSlot.mode
    flexDirection: compact ? "column" : "row"
    marginTop: 1
    flexShrink: 0

    Item {
        flexDirection: "row"
        height: 1
        flexGrow: footer.compact ? 0 : 1
        flexShrink: 1
        overflow: "hidden"

        Slot {
            id: actionsSlot
            objectName: "composerActionsSlot"
            name: "composer.actions"
            mode: "append"
            height: 1
            flexDirection: "row"
            flexShrink: 0

            Text {
                objectName: "composerModel"
                flexShrink: 0
                text: footer.compact ? footer.composer.footer.compactModel : footer.composer.footer.model
                onMouseDown: Shell.dispatch("composer.modelPicker.toggle")
            }
            Text { visible: !footer.compact; flexShrink: 0; text: " │ "; color: Theme.colors.faint }
            Text {
                objectName: "composerEffort"
                visible: !footer.compact
                flexShrink: 0
                text: footer.composer.footer.effort
                onMouseDown: Shell.dispatch("composer.effortPicker.toggle")
            }
            Text { visible: !footer.compact; flexShrink: 0; text: " │ "; color: Theme.colors.faint }
            Text {
                objectName: "composerAccess"
                visible: !footer.compact
                flexShrink: 0
                text: footer.composer.footer.access
                onMouseDown: Shell.dispatch("composer.runtimePicker.toggle")
            }
            Text { visible: !footer.compact; flexShrink: 0; text: " │ "; color: Theme.colors.faint }
            Text {
                objectName: "composerMode"
                visible: !footer.compact
                flexShrink: 0
                text: footer.composer.footer.mode
                onMouseDown: Shell.dispatch("composer.interactionMode.toggle")
            }
        }
        Item { flexGrow: 1 }
        Text {
            objectName: "composerOptions"
            visible: footer.compact && footer.composer.footer.showOptions
            flexShrink: 0
            text: "^K options"
            color: Theme.colors.dim
            onMouseDown: Shell.dispatch("composer.optionsPicker.toggle")
        }
    }
    Item {
        flexDirection: "row"
        height: 1
        flexShrink: 0
        Item { flexGrow: 1 }
        Text {
            objectName: "composerPrimaryAction"
            flexShrink: 0
            text: footer.composer.footer.primary
            onMouseDown: Shell.dispatch(footer.composer.primaryAction === "Stop"
                ? "composer.interrupt"
                : footer.composer.primaryAction === "Submit answer" ? "userInput.submit" : "composer.submit")
        }
    }
}
