import OpenTUI

// The settings overview (`Shell.state.settings.groups`) in place of the
// conversation, like SettingsView: the thread's provider and git state, this
// machine's cluster, then the keybinding reference by context, each group
// after the first parted by a blank row. The host draws each row (`line`: the
// label padded to 16, the value clipped to the pane). PgUp/PgDn scroll
// (`scroll`), Esc closes.
Rectangle {
    id: page
    objectName: "settingsPage"
    readonly property var settings: Shell.state.settings

    function scroll(rows) { body.scrollBy({ x: 0, y: rows }) }
    // PgUp / PgDn (keymap `settings.scrollUp` / `settings.scrollDown`).
    readonly property var paneScroll: Shell.state.paneScroll
    onPaneScrollChanged: if (paneScroll.pane === "settings") scroll(paneScroll.by)

    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Item {
        height: 1
        Text {
            text: "settings"
            color: Theme.colors.accent
            Span { text: "  ·  PgUp/PgDn scroll · Esc close"; color: Theme.colors.dim }
        }
    }
    ScrollView {
        id: body
        objectName: "settingsBody"
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0
        Repeater {
            model: page.settings.groups
            delegate: Item {
                flexDirection: "column"
                flexShrink: 0
                marginTop: index > 0 ? 1 : 0
                Text { text: modelData.title; color: Theme.colors.accent }
                Repeater {
                    model: modelData.rows
                    delegate: Text { height: 1; text: modelData.line }
                }
            }
        }
    }
}
