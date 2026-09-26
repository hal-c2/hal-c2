import OpenTUI

// The row of actions under the prompt. Plugins append their own through the
// "composer.actions" slot, after the built-in hints.
Slot {
    id: actions
    objectName: "composerActionsSlot"
    name: "composer.actions"
    mode: "append"
    height: 1
    flexDirection: "row"
    paddingX: 1

    Text {
        objectName: "composerActionsBuiltIn"
        text: "Enter send · ^K commands "
        color: Theme.colors.faint
    }
}
