import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The window's shortcuts (ShellWindow) over a Space page
// (features/space/prompt.feature: The palette's key opens the palette over a
// page, whatever has the keyboard):
// they reach the shell whatever field of the page has the keyboard, and a popup
// that leaves the keyboard there holds none of them. One with the keyboard, or a
// modal one, still does.
Item {
    id: root
    width: 200
    height: 100

    Component {
        id: windowComponent
        ShellWindow {
            width: 1100
            height: 760

            SpaceWorkspace {
                anchors.fill: parent
            }

            // Release notes a hover opens: the keyboard stays where it was.
            Popup {
                objectName: "hoverNotes"
                x: 10
                y: 10
                width: 80
                height: 40
            }

            ShellMenu {
                objectName: "menu"
                MenuItem {
                    text: "Rename"
                }
            }

            Popup {
                objectName: "dialog"
                modal: true
                closePolicy: Popup.CloseOnEscape
                width: 200
                height: 100
                Overlay.modal: ShellScrim {}
            }
        }
    }

    function block(id, text) {
        return { id: id, kind: "paragraph", text: text, checked: false, linkedPageId: "", linkedTitle: "", byAgent: false, openComments: 0, level: 0, language: "", imageId: "", imageState: "", imageUrl: "", imageWidth: 0, imageHeight: 0 };
    }

    TestCase {
        name: "ShellShortcutsTests"
        when: windowShown

        function init() {
            Shell.reset();
            Spaces.reset();
            Keybindings.pressed = [];
            PaletteModel.open = false;
            PaletteModel.query = "";
            // The palette's key, as KeybindingController publishes it: the
            // shell's everywhere but in a terminal.
            Keybindings.shortcuts = [{ sequence: "Ctrl+K", autoRepeat: true, chrome: true, composer: true, editable: true, terminal: false, preview: false }];
        }

        function cleanup() {
            Keybindings.shortcuts = [];
            PaletteModel.open = false;
        }

        // A page with its prompt, shown in an active window.
        function openPage() {
            Spaces.load({
                spaceId: "space-1",
                spaceName: "Research",
                spaces: [{ id: "space-1", name: "Research" }],
                pages: [{ id: "page-1", title: "AGENTS.md", depth: 0, parentPageId: "", hasChildren: false, fromThread: false }],
                blocks: [root.block("b1", "One"), root.block("b2", "Two")],
                page: { id: "page-1", title: "AGENTS.md", parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "" }
            });
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, { target: "page#page-1", routeKind: "page", pageId: "page-1", project: { id: "shop", title: "shop" }, projects: [{ id: "shop", title: "shop" }] })
            });
            const window = createTemporaryObject(windowComponent, root);
            window.show();
            window.requestActivate();
            tryVerify(() => window.active);
            return window;
        }

        function focusPrompt(window) {
            const input = findChild(window, "input");
            verify(input, "the page has a prompt");
            input.forceActiveFocus();
            tryVerify(() => input.activeFocus);
            return input;
        }

        function pressPalette() {
            Keybindings.pressed = [];
            keyClick(Qt.Key_K, Qt.ControlModifier);
            return Keybindings.pressed;
        }

        function test_the_palette_key_reaches_the_shell_from_the_page_prompt() {
            const window = openPage();
            focusPrompt(window);
            compare(pressPalette(), ["Ctrl+K"]);
            // As the shell runs commandPalette.toggle: its search takes the
            // keyboard, and what is typed next is a search, not the page's.
            PaletteModel.toggle();
            tryVerify(() => window.activeFocusItem?.objectName === "commandPaletteSearch");
            keyClick(Qt.Key_A);
            compare(PaletteModel.query, "a");
            compare(findChild(window, "input").text, "");
            // Its own key still reaches the shell, to put it away.
            compare(pressPalette(), ["Ctrl+K"]);
        }

        function test_the_palette_key_reaches_the_shell_from_a_block_being_edited() {
            const window = openPage();
            tryVerify(() => findChild(window.contentItem, "spaceBlock:One") !== null, 5000, "the block is shown");
            const shown = findChild(window.contentItem, "spaceBlock:One");
            shown.edit();
            const editor = shown.editor;
            tryVerify(() => editor.activeFocus);
            compare(pressPalette(), ["Ctrl+K"]);
            compare(editor.text, "One");
        }

        // The `/` menu leaves the keyboard in the prompt; Qt used to give it
        // every window shortcut, and the keys went on into the page.
        function test_the_slash_menu_holds_no_shortcut() {
            const window = openPage();
            const input = focusPrompt(window);
            keyClick(Qt.Key_Slash);
            const slash = findChild(window, "spaceSlashMenu");
            tryVerify(() => slash && slash.opened, 3000, "the slash menu opens");
            verify(input.activeFocus, "the prompt keeps the keyboard");
            compare(pressPalette(), ["Ctrl+K"], "Ctrl+K reached the shell past the slash menu");
            compare(input.text, "/");
        }

        function test_a_popup_that_leaves_the_keyboard_holds_no_shortcut() {
            const window = openPage();
            const input = focusPrompt(window);
            const notes = findChild(window, "hoverNotes");
            notes.open();
            tryVerify(() => notes.opened);
            verify(input.activeFocus, "the prompt keeps the keyboard");
            compare(pressPalette(), ["Ctrl+K"], "Ctrl+K reached the shell past the open notes");
            notes.close();
        }

        // A menu has the keyboard: its keys are its own.
        function test_a_popup_with_the_keyboard_holds_the_shortcuts() {
            const window = openPage();
            focusPrompt(window);
            const menu = findChild(window, "menu");
            menu.popup(20, 20);
            tryVerify(() => menu.opened && window.activeFocusItem !== findChild(window, "input"));
            compare(pressPalette(), []);
            menu.close();
            tryVerify(() => !menu.visible);
            compare(pressPalette(), ["Ctrl+K"]);
        }

        // A modal dialog holds them even with the keyboard left under it.
        function test_a_modal_popup_holds_the_shortcuts() {
            const window = openPage();
            const input = focusPrompt(window);
            const dialog = findChild(window, "dialog");
            dialog.open();
            tryVerify(() => dialog.opened);
            compare(pressPalette(), []);
            dialog.close();
            tryVerify(() => !dialog.visible);
            input.forceActiveFocus();
            tryVerify(() => input.activeFocus);
            compare(pressPalette(), ["Ctrl+K"]);
        }
    }
}
