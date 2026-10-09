import QtQuick
import QtTest
import "../qml/HalC2/Bricks/js/lucide.js" as Lucide

TestCase {
    name: "ShellIconTests"

    // Every icon id ThreadMenuController puts on a thread menu entry.
    readonly property var threadMenuIcons: ["message-square-plus", "pin", "pin-off", "arrow-up", "arrow-down", "circle-check", "clock", "pencil", "refresh-cw", "mail-open", "folder-tree", "copy", "folder", "git-branch", "hash", "link", "settings", "git-fork", "arrow-right-left", "archive", "trash"]

    function test_threadMenuIconsHaveGlyphs() {
        for (const icon of threadMenuIcons) {
            verify(Lucide.path(icon).length > 0, "no glyph for " + icon);
        }
    }
}
