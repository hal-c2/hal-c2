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
            // Shift+Tab comes back to the field, and leaves it for the button above.
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            verify(json.activeFocus);
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            compare(json.text, "x");
            verify(findChild(dialog.contentItem, "chooseFiles").activeFocus);
            keyClick(Qt.Key_Escape);
            tryVerify(() => !dialog.visible);
            tryVerify(() => composer.activeFocus);
        }

        // Leaving the dialog any way but a choice cancels the import, so an
        // installed theme it was asking about is dropped.
        function test_escapeCancelsWhatTheImportWasAskingAbout() {
            const dialog = openImport();
            Themes.importConflicts = ["Nord"];
            keyClick(Qt.Key_Escape);
            tryVerify(() => !dialog.visible);
            compare(Themes.calls.filter(call => call.name === "resolveImport").map(call => call.args[0]), ["cancel"]);
            compare(Themes.importConflicts, []);
        }

        // A choice made in the dialog is the only call: closing after it does not cancel.
        function test_aChoiceIsNotFollowedByACancel() {
            for (const [button, choice] of [["keepBoth", "copy"], ["updateExisting", "update"]]) {
                Themes.clear();
                const dialog = openImport();
                Themes.importConflicts = ["Nord"];
                const target = findChild(dialog.contentItem, button);
                tryVerify(() => target.visible);
                waitForRendering(dialog.contentItem);
                mouseClick(target);
                tryVerify(() => !dialog.visible);
                compare(Themes.calls.filter(call => call.name === "resolveImport").map(call => call.args[0]), [choice]);
            }
        }

        // The appearance dropdown is a popup of its own that can reach past the editor;
        // choosing from it is not a press outside the editor.
        function test_choosingFromTheAppearanceDropdownKeepsTheEditorOpen() {
            const editor = openEditor();
            const combo = findChild(editor.contentItem, "appearance");
            verify(combo, "the editor has an appearance choice");
            mouseClick(combo);
            tryVerify(() => combo.popup.opened);
            const row = combo.popup.contentItem.itemAtIndex(1);
            verify(row, "the dropdown lists Dark");
            mouseClick(row);
            tryVerify(() => !combo.popup.opened);
            verify(editor.opened && Themes.editorOpen, "the editor stays open");
        }

        // features/navigation/theme-editor.feature: the editor closes on a
        // press outside it, but not on the press that picks a colour.
        function test_aPressOutsideClosesTheEditorExceptWhileItPicks() {
            const editor = openEditor();
            Themes.inspecting = true;
            mouseClick(composer);
            verify(editor.visible, "the press that picks does not close it");
            Themes.pick("#ff0000");
            mouseClick(composer);
            tryVerify(() => !editor.visible);
            verify(!Themes.editorOpen);
            // Closed the way that keeps unsaved changes.
            compare(Themes.calls.filter(call => call.name === "hideEditor").length, 1);
        }

        // Escape, Cancel and Save let the draft go; only a press outside keeps it.
        function test_onlyAPressOutsideKeepsTheDraft() {
            for (const close of [
                editor => keyClick(Qt.Key_Escape),
                editor => mouseClick(findChild(editor.contentItem, "cancel")),
                editor => mouseClick(findChild(editor.contentItem, "save"))
            ]) {
                Themes.clear();
                const editor = openEditor();
                tryVerify(() => findChild(editor.contentItem, "name").activeFocus);
                close(editor);
                tryVerify(() => !editor.visible);
                verify(!Themes.editorOpen);
                compare(Themes.calls.filter(call => call.name === "hideEditor").length, 0);
            }
        }

        // features/navigation/theme-editor.feature: after a colour is picked
        // the keyboard is the editor's again.
        function test_theKeyboardReturnsToTheEditorAfterAPick() {
            const editor = openEditor();
            const pick = findChild(editor.contentItem, "pick");
            Themes.inspecting = true;
            composer.forceActiveFocus();
            verify(!pick.activeFocus);
            Themes.pick("#ff0000");
            tryVerify(() => pick.activeFocus);
            keyClick(Qt.Key_Escape);
            tryVerify(() => !editor.visible);
        }
    }
}
