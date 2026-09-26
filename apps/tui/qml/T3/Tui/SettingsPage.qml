import OpenTUI

// The read-only settings overview (`Shell.state.settings.groups`) in place
// of the conversation: the thread's provider and git state, then the
// keybinding reference by context. PgUp/PgDn scroll (`scroll`), Esc closes.
Rectangle {
    id: page
    objectName: "settingsPage"
    readonly property var settings: Shell.state.settings

    function scroll(rows) { body.scrollBy({ x: 0, y: rows }) }

    border.width: 1
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Item {
        flexDirection: "row"
        height: 1
        Text { text: "settings"; color: Theme.colors.accent }
        Text { text: "  ·  PgUp/PgDn scroll · Esc close"; color: Theme.colors.dim }
    }
    ScrollView {
        id: body
        objectName: "settingsBody"
        flexGrow: 1
        Repeater {
            model: page.settings.groups
            delegate: Item {
                flexDirection: "column"
                flexShrink: 0
                marginBottom: 1
                Text { text: modelData.title; color: Theme.colors.accent }
                Repeater {
                    model: modelData.rows
                    delegate: Item {
                        flexDirection: "row"
                        height: 1
                        Text {
                            text: "  " + modelData.label.padEnd(16)
                            color: modelData.keys ? Theme.colors.accent : Theme.colors.dim
                        }
                        Text { text: modelData.value; color: Theme.colors.text }
                    }
                }
            }
        }
    }
}
