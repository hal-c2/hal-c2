import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// The theme editor and the import dialog as popups over a window: the surface
// they are drawn on, where the keyboard goes, and how tall they are.
Item {
    id: root
    width: 900
    height: 800

    // A light theme's own colours for what the dialogs paint with.
    readonly property var light: ({
            surfaceOverlay: "#ffffff",
            text: "#18181b",
            textMuted: "#52525b",
            border: "#e4e4e7",
            input: "#f4f4f5"
        })

    Component {
        id: editorComponent
        ThemeEditor {}
    }
    Component {
        id: importComponent
        ThemeImportDialog {}
    }

    TestCase {
        name: "ThemeEditorTests"
        when: windowShown

        function init() {
            Shell.reset();
            Themes.clear();
            Theme.colors = {};
        }

        function cleanup() {
            Theme.colors = {};
        }

        // WCAG relative luminance and contrast ratio.
        function luminance(color) {
            const channel = value => value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
            return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
        }

        function contrast(a, b) {
            const one = luminance(a), other = luminance(b);
            return (Math.max(one, other) + 0.05) / (Math.min(one, other) + 0.05);
        }

        function openEditor() {
            Themes.edit(Themes.draft(""));
            const editor = createTemporaryObject(editorComponent, root);
            tryVerify(() => editor.opened);
            return editor;
        }

        function openImport() {
            const dialog = createTemporaryObject(importComponent, root);
            dialog.open();
            tryVerify(() => dialog.opened);
            return dialog;
        }

        // features/navigation/theme-editor.feature: the theme dialogs are
        // drawn in the current theme.
        function test_theDialogsAreDrawnOnTheThemesOverlaySurface() {
            Theme.colors = root.light;
            for (const popup of [openEditor(), openImport()]) {
                verify(Qt.colorEqual(popup.background.color, "#ffffff"), popup.objectName + " is drawn on " + popup.background.color);
                verify(contrast(popup.foreground, popup.background.color) >= 4.5, popup.objectName + "'s text can be read");
                popup.close();
            }
        }
    }
}
