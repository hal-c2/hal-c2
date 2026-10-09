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

    // What the window has under the dialogs: a field holding the keyboard,
    // as the composer does, and the editor's shortcut.
    TextArea {
        id: composer

        width: 200
        height: 60
    }

    Shortcut {
        sequence: "Ctrl+Alt+Shift+T"
        context: Qt.WindowShortcut
        onActivated: Themes.editorOpen = !Themes.editorOpen
    }

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
            composer.clear();
            composer.forceActiveFocus();
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

        // features/navigation/theme-editor.feature: opening the theme editor
        // moves the keyboard into it.
        function test_theEditorTakesTheKeyboardAndGivesItBack() {
            verify(composer.activeFocus);
            const editor = openEditor();
            const name = findChild(editor.contentItem, "name");
            tryVerify(() => name.activeFocus);
            for (let index = 0; index < 6; index += 1) keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_X);
            compare(composer.text, "");
            verify(!composer.activeFocus);
            keyClick(Qt.Key_Escape);
            tryVerify(() => !editor.visible);
            verify(!Themes.editorOpen);
            tryVerify(() => composer.activeFocus);
        }

        // The window's shortcuts stay live under the open editor.
        function test_theEditorsShortcutClosesIt() {
            const editor = openEditor();
            tryVerify(() => findChild(editor.contentItem, "name").activeFocus);
            keySequence("Ctrl+Alt+Shift+T");
            tryVerify(() => !editor.visible);
            verify(!Themes.editorOpen);
        }

        // features/navigation/theme-editor.feature: the editor is as tall
        // as what it shows.
        function test_theEditorIsAsTallAsItsContent() {
            const editor = openEditor();
            const save = findChild(editor.contentItem, "save");
            const advanced = findChild(editor.contentItem, "advanced");
            // Nothing but the row spacing between the last control and the buttons.
            const gap = () => save.mapToItem(editor.contentItem, 0, 0).y - (advanced.y + advanced.height);
            tryVerify(() => editor.height === editor.implicitHeight);
            verify(editor.height < 320, "the simple view is " + editor.height + " tall");
            compare(gap(), editor.contentItem.spacing);
            const simple = editor.height;
            mouseClick(advanced);
            tryCompare(editor, "height", 640);
            tryVerify(() => findChild(editor.contentItem, "roles").height > 200);
            mouseClick(advanced);
            tryCompare(editor, "height", simple);
        }

        // features/navigation/theme-editor.feature: the import dialog takes
        // the keyboard and Escape closes it.
        function test_theImportDialogTakesTheKeyboardAndClosesOnEscape() {
            const dialog = openImport();
            const json = findChild(dialog.contentItem, "json");
            tryVerify(() => json.activeFocus);
            keyClick(Qt.Key_X);
            compare(json.text, "x");
            compare(composer.text, "");
            keyClick(Qt.Key_Tab);
            compare(json.text, "x");
            verify(!json.activeFocus && !composer.activeFocus);
            keyClick(Qt.Key_Escape);
            tryVerify(() => !dialog.visible);
            tryVerify(() => composer.activeFocus);
        }
    }
}
