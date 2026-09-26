import OpenTUI

// The controls under the prompt, in reading order: model, effort, plan or
// build, access, then the primary action. A compact composer keeps the model
// and the primary action; the rest live in the palette (^K). Clicking a
// control opens its picker; clicking it again closes it. Plugins add their
// own controls through the "composer.actions" slot, after the built-in ones
// (`actionsMode: "replace"` swaps them out).
Item {
    id: footer
    property var composer: Shell.state.composer
    property alias actionsMode: actionsSlot.mode
    flexDirection: "row"
    height: 1

    Slot {
        id: actionsSlot
        objectName: "composerActionsSlot"
        name: "composer.actions"
        mode: "append"
        height: 1
        flexDirection: "row"
        flexShrink: 1

        Text {
            objectName: "composerModel"
            text: "model " + (footer.composer.selectedModel !== null ? footer.composer.selectedModel : "—") + " ▾"
            color: Theme.colors.text
            onMouseDown: Shell.dispatch("composer.modelPicker.toggle")
        }
        Text {
            objectName: "composerEffort"
            visible: !footer.composer.compact && footer.composer.effort !== null
            text: "  effort " + (footer.composer.effort !== null ? footer.composer.effort : "") + " ▾"
            color: Theme.colors.dim
            onMouseDown: Shell.dispatch("composer.effortPicker.toggle")
        }
        Text {
            objectName: "composerMode"
            visible: !footer.composer.compact
            text: "  ^B " + footer.composer.interactionModeLabel
            color: footer.composer.interactionMode === "plan" ? Theme.colors.accent : Theme.colors.dim
            onMouseDown: Shell.dispatch("composer.interactionMode.toggle")
        }
        Text {
            objectName: "composerAccess"
            visible: !footer.composer.compact
            text: "  ^O " + footer.composer.runtimeModeLabel
            color: Theme.colors.dim
            onMouseDown: Shell.dispatch("composer.runtimePicker.toggle")
        }
        Text {
            objectName: "composerOptions"
            visible: footer.composer.compact
            text: "  ^K options"
            color: Theme.colors.faint
            onMouseDown: Shell.dispatch("palette.open")
        }
    }
    Item { flexGrow: 1 }
    Text {
        objectName: "composerPrimaryAction"
        text: footer.composer.primaryAction === "Stop"
            ? "■ Stop Esc"
            : footer.composer.primaryAction === "Submit answer" ? "▸ Submit answer ⏎" : "▸ Send ⏎"
        color: footer.composer.primaryAction === "Stop" ? Theme.colors.error : Theme.colors.accent
        onMouseDown: Shell.dispatch(footer.composer.primaryAction === "Stop" ? "composer.interrupt" : "composer.submit")
    }
}
