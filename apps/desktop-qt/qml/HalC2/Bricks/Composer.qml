pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell
import "js/providerIcons.js" as ProviderIcons

// The prompt: text input, model/effort/mode pickers, send/stop, with the
// checkout context strip welded under it. Rendered from Shell.state.composer
// and Shell.state.workspace; every change is dispatched back to
// ComposerController, which keeps the drafts and sends over the MC.
Rectangle {
    id: composer

    // Files dropped on the card attach. A layout that lays a ConversationDrop
    // over the whole conversation turns this off, so a drop on a sheet or
    // scrim over the card does not fall through to it.
    property bool takesDrops: true
    readonly property var model: Shell.state.composer ?? null
    readonly property var workspace: Shell.state.workspace ?? null
    // This machine's stashed prompts (ComposerController), newest first.
    readonly property var stashEntries: Shell.state.composerStash?.entries ?? []
    readonly property bool stashOpen: ready && Shell.state.composerStash?.open === true
    readonly property var attachments: ready ? (model.attachments ?? []) : []
    readonly property var citations: ready ? (model.citations ?? []) : []
    // A Space page's own prompt (SpacePage). The prompt aims at a page while
    // one is open, and only the page's composer is ready then; a shell's is
    // ready everywhere else, so a shell that shows its composer when ready
    // never draws a second prompt under a page.
    property bool pageHost: false
    // A Space's images' prompt (SpaceImages): its words make an image, with an
    // image model from the picker. Only it is ready while the images are open,
    // and it offers nothing a turn carries: no attachments, options or stash.
    property bool imagesHost: false
    readonly property bool ready: model !== null && model.target !== null && (model.routeKind === "page") === pageHost && (model.routeKind === "images") === imagesHost
    readonly property string publishedTarget: ready ? model.target : ""
    readonly property string publishedText: ready ? model.text : ""
    readonly property int publishedCursor: ready ? model.cursor : 0
    readonly property var suggestions: ready ? model.suggestions : []
    readonly property bool suggesting: ready && model.triggerKind !== null && (suggestions.length > 0 || model.suggestionsEmptyText !== null)
    readonly property color canvas: Theme.palette.color("canvas", "#0f0f12")
    readonly property color outline: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.05)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    // Claude's mark colour, as the provider icon draws it: its fill for a light or dark theme.
    // A missing variant falls back to the glyph's other fill; the literal is
    // only for a build without the glyph at all.
    readonly property color claudeOrange: {
        const dark = ProviderIcons.darkFor(foreground);
        return ProviderIcons.fill("claudeAgent", dark) ?? ProviderIcons.fill("claudeAgent", !dark) ?? "#d97757";
    }
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color secondary: Theme.palette.color("secondaryLabel", "#a1a1aa")
    readonly property color iconMuted: Theme.palette.color("iconMuted", "#8b8b93")
    readonly property color branchColor: Theme.palette.color("branchForeground", muted)
    // A choice as the option's list names it: the provider's default is marked.
    function choiceLabel(choice) {
        return choice.isDefault ? qsTr("%1 (Default)").arg(choice.label) : choice.label;
    }
    readonly property var effortOption: ready ? (model.options.find(option => option.type === "select") ?? null) : null
    // The model's other options, such as Claude's fast mode and context window.
    // By id: every read of model.options converts to fresh objects, so identity never matches.
    readonly property var otherOptions: ready ? model.options.filter(option => option.id !== effortOption?.id) : []
    readonly property var selectOptions: otherOptions.filter(option => option.type === "select")
    readonly property var toggleOptions: otherOptions.filter(option => option.type !== "select")
    readonly property int maximumCardWidth: 768
    readonly property int gutter: 20

    // The toolbar's chips: no fill at rest, the raised surface under the
    // pointer and while on.
    readonly property color chipFill: Theme.palette.color("surfaceRaised", "#1c1f24")
    readonly property color chipLabel: Theme.palette.color("inkSecondary", "#b8bdc7")

    // The toolbar never wraps. The chips that do not fit beside the model
    // fold into the overflow chip's menu in this order: the model's other
    // pickers (the context window), the effort, its toggles, plan, access.
    readonly property var foldOrder: {
        const selects = [];
        for (let i = 0; i < selectChips.count; ++i) {
            if (selectChips.itemAt(i)) selects.push(selectChips.itemAt(i));
        }
        const toggles = [];
        for (let i = 0; i < toggleChips.count; ++i) {
            if (toggleChips.itemAt(i)) toggles.push(toggleChips.itemAt(i));
        }
        return selects.concat(effortPicker.present ? [effortPicker] : [], toggles,
            planToggle.present ? [planToggle] : [], runtimeModePicker.present ? [runtimeModePicker] : []);
    }
    // A chip's width is its own whether it shows or not, so folding one never
    // changes what fits. Before the toolbar is laid out nothing folds, so the
    // chips do not fold and unfold on the first frame.
    readonly property int foldCount: chipArea.width <= 0 ? 0 : countFolds(foldOrder.map(chip => chip.implicitWidth), chipArea.width, overflowChip.implicitWidth, chipRow.spacing)
    readonly property var folded: foldOrder.slice(0, foldCount)
    // The overflow chip's menu while it is open.
    property ShellMenu overflowMenu: null

    // How many of these chips, from the first, must fold for the rest and the
    // overflow chip to fit in `room`.
    function countFolds(widths, room, overflow, spacing) {
        for (let folds = 0; folds < widths.length; ++folds) {
            const kept = widths.slice(folds);
            const chips = kept.length + (folds > 0 ? 1 : 0);
            const need = kept.reduce((sum, width) => sum + width, 0) + (folds > 0 ? overflow : 0) + spacing * (chips - 1);
            if (need <= room) return folds;
        }
        return widths.length;
    }

    // Opens the overflow chip's menu: a row per folded chip in toolbar
    // order, a picker as a submenu of its choices and a toggle as a row
    // reading On or Off, with a check in the icon column while on. `chip`,
    // when given, is the row the keyboard starts on.
    function openOverflow(chip) {
        if (overflowMenu !== null) {
            overflowMenu.close();
            return;
        }
        const menu = overflowMenuComponent.createObject(composer, {
            parent: overflowChip
        });
        const shown = [effortPicker].concat(
            Array.from({ length: selectChips.count }, (_, i) => selectChips.itemAt(i)),
            Array.from({ length: toggleChips.count }, (_, i) => toggleChips.itemAt(i)),
            [runtimeModePicker, planToggle]).filter(item => item && folded.includes(item));
        let start = -1;
        for (const item of shown) {
            if (item === chip) start = menu.count;
            if (item.choices !== undefined) {
                const sub = overflowSubmenuComponent.createObject(null, {
                    objectName: "composerOverflow:" + item.objectName,
                    title: item.Accessible.name,
                    detail: item.displayText
                });
                menu.built.push(sub);
                item.choices.forEach((label, index) => {
                    const row = overflowItemComponent.createObject(null, {
                        text: label,
                        current: index === item.currentIndex
                    });
                    row.triggered.connect(() => item.activated(index));
                    menu.built.push(row);
                    sub.addItem(row);
                });
                menu.addMenu(sub);
            } else {
                const row = overflowItemComponent.createObject(null, {
                    objectName: "composerOverflow:" + item.objectName,
                    text: item.menuTitle,
                    detail: item.checked ? qsTr("On") : qsTr("Off"),
                    iconName: item.checked ? "check" : ""
                });
                row.triggered.connect(() => item.flip());
                menu.built.push(row);
                menu.addItem(row);
            }
        }
        overflowMenu = menu;
        // Above the chip and flush with its right edge, once its rows have
        // a size.
        menu.x = Qt.binding(() => overflowChip.width - menu.width);
        menu.y = Qt.binding(() => -menu.height - Theme.space.xs);
        menu.open();
        if (start >= 0) menu.currentIndex = start;
    }

    // Vim keys (Settings → General): Escape leaves insert mode.
    readonly property bool vimKeys: {
        Settings.device;
        return Settings.setting("composerVimKeys") === true;
    }
    readonly property alias vim: vim
    // Rich text (Settings → General): the draft's Markdown reads as formatted.
    readonly property bool richText: {
        Settings.device;
        return Settings.setting("composerRichTextEnabled") !== false;
    }

    // Collapse on scroll (Settings → General): while the user scrolls an
    // existing thread's conversation (the layout says so), a one-line prompt
    // rests as a single line without its context strip; focusing the editor or
    // typing brings it back.
    property bool conversationScrolled: false
    readonly property bool collapseOnScroll: {
        Settings.device;
        return Settings.setting("composerCollapseOnScroll") !== false;
    }
    property bool scrollCollapsed: false
    readonly property bool resting: scrollCollapsed && collapseOnScroll && ready && model.routeKind !== "draft" && !/[\r\n]/.test(input.text)

    onConversationScrolledChanged: scrollCollapsed = conversationScrolled

    // An Escape nothing in the composer wanted (not the suggestions, the
    // stash or vim keys, which take theirs in the editor first) folds the
    // expanded notices above it back to the front one; the banners over
    // the conversation do the same from ThreadView.
    Keys.onEscapePressed: event => {
        if ((Shell.state.noticeStack ?? null)?.expanded === true)
            Shell.dispatch("noticeStack.collapse", {});
        else
            event.accepted = false;
    }

    // Opt-in input plugins share the same draft synchronization as typing.
    property alias editor: input
    property alias editorActions: editorActions.data
    signal editorKeyPressed(var event)

    function focusInput() {
        if (input.enabled) input.forceActiveFocus();
    }

    function toggleCheckoutPicker() {
        if (!envModePicker.enabled || !envModePicker.visible) return;
        envModePicker.forceActiveFocus();
        if (envModePicker.popup.visible) envModePicker.popup.close();
        else envModePicker.popup.open();
    }

    function insertText(text, target) {
        if (!ready || model.editorDisabled || (target !== undefined && target !== publishedTarget) || typeof text !== "string" || text.length === 0) {
            return false;
        }
        const start = input.selectionStart;
        const end = input.selectionEnd;
        // Its own undo step: Qt merges an edit into the one before it only
        // while the document reads as modified.
        input.textDocument.modified = false;
        input.remove(start, end);
        input.insert(start, text);
        input.textDocument.modified = false;
        input.cursorPosition = start + text.length;
        flushText();
        return true;
    }

    // The last text this brick sent; an echo of it from the controller is not an edit.
    property string lastSentText: ""
    property int lastSentCursor: -1
    property string editingTarget: ""
    readonly property string editClientId: Date.now().toString(36) + Math.random().toString(36).slice(2)
    property int nextEditRevision: 0
    property int lastSentRevision: 0

    implicitHeight: turnRequests.implicitHeight + stack.implicitHeight + gutter
    color: canvas

    // The model-picker and toolbar keybindings land here while this
    // brick hosts those controls: the one on show (a Space page has its own).
    Connections {
        target: Shell
        enabled: composer.visible
        function onActionRequested(action, payload) {
            if (action === "composer.modelPicker.toggle") {
                if (modelPicker.popup.visible) {
                    modelPicker.popup.close();
                } else if (modelPicker.enabled) {
                    modelPicker.forceActiveFocus();
                    modelPicker.popup.open();
                }
            } else if (action === "composer.control.open") {
                composer.openControl(payload.command);
            } else if (action === "composer.stash.key" && composer.ready) {
                // The stash takes the text as typed, not as last debounced.
                composer.flushText();
                Shell.dispatch("composer.stash");
            } else if (action === "composer.submit.key") {
                // composer.sendAlternate or sendBackground bound to another key.
                composer.submit(payload.intent);
            } else if (action === "composer.focus") {
                // A dismissed command palette hands the keyboard back.
                composer.focusInput();
            } else if (action === "composer.queue.editLast" && composer.ready && input.activeFocus) {
                // From the start of the draft the key reaches the queue;
                // anywhere else it moves there first.
                if (input.cursorPosition > 0) {
                    input.cursorPosition = 0;
                    return;
                }
                composer.flushText();
                Shell.dispatch("composer.queue.edit", {});
            }
        }
    }

    function openControl(command) {
        if (command === "composer.branch") {
            if (branchButton.visible && branchButton.enabled) branchPicker.open();
            return;
        }
        const picker = {
            "composer.effort": effortPicker,
            "composer.mode": runtimeModePicker,
            "composer.host": hostPicker,
            "composer.workspace": envModePicker
        }[command];
        if (!picker || !picker.enabled) return;
        // A folded picker is reached through the overflow menu, on its row.
        if (folded.includes(picker)) {
            if (overflowMenu === null) openOverflow(picker);
            return;
        }
        if (!picker.visible) return;
        picker.forceActiveFocus();
        picker.popup.open();
    }

    // Shift+Tab flips plan and build where the provider has a plan mode.
    function toggleInteractionMode() {
        if (!composer.ready || !composer.model.showInteractionModeToggle) return false;
        Shell.dispatch("composer.interactionMode.set", {
            mode: composer.model.interactionMode === "plan" ? "default" : "plan"
        });
        return true;
    }

    // Up on the editor's first line recalls the thread's earlier prompts and
    // Down on its last steps forward again; ComposerController decides whether
    // the draft is one a recall may replace. With nothing recalled the key
    // takes the caret to that edge of the draft. True when the key was used.
    function stepPromptHistory(direction) {
        const caret = input.positionToRectangle(input.cursorPosition).y;
        const edge = input.positionToRectangle(direction === "backward" ? 0 : input.length).y;
        if (!composer.ready || caret !== edge) return false;
        const before = input.text;
        composer.flushText();
        Shell.dispatch("composer.history.step", {
            direction: direction
        });
        if (input.text === before) input.cursorPosition = direction === "backward" ? 0 : input.length;
        return true;
    }

    // A new line in a Markdown list item ("- ", "* ", "+ ", "1. ", "1) ", a
    // task) starts the next item, numbered one on and with its task unticked;
    // on an item with nothing written it ends the list instead. True when it
    // took the new line.
    function continueList() {
        if (input.selectionStart !== input.selectionEnd) return false;
        const at = input.cursorPosition;
        const lineStart = input.text.lastIndexOf("\n", at - 1) + 1;
        const lineEnd = input.text.indexOf("\n", at) < 0 ? input.text.length : input.text.indexOf("\n", at);
        const line = input.text.slice(lineStart, lineEnd);
        const item = /^(\s*)(?:([-*+])|(\d{1,9})([.)]))[ \t]+(\[[ xX]\][ \t]+)?/.exec(line);
        if (!item || at - lineStart < item[0].length) return false;
        if (line.slice(item[0].length).trim().length === 0) {
            input.remove(lineStart, lineEnd);
            return true;
        }
        const marker = item[2] ?? (Number(item[3]) + 1) + item[4];
        const next = "\n" + item[1] + marker + " " + (item[5] ? "[ ] " : "");
        // Split in the middle of an item, the first half keeps no trailing space.
        let cut = at;
        while (cut > lineStart + item[0].length && /[ \t]/.test(input.text[cut - 1])) --cut;
        // Never inside a reference "[label](target)" the caret sits in: the new
        // line starts after it.
        const refs = /\[[^\]\n]*\]\([^)\n]*\)/g;
        for (let ref = refs.exec(line); ref; ref = refs.exec(line)) {
            const from = lineStart + ref.index;
            const to = from + ref[0].length;
            if (at > from && at < to) {
                cut = to;
                break;
            }
        }
        // The spaces after the split point go with it, so the new item reads "- x", not "-  x".
        let end = Math.max(cut, at);
        while (end < lineEnd && /[ \t]/.test(input.text[end])) ++end;
        input.remove(cut, end);
        input.insert(cut, next);
        input.cursorPosition = cut + next.length;
        return true;
    }

    // An opening mark typed over a selection wraps it and keeps it selected,
    // unless the selection holds a reference or Markdown of its own, which the
    // mark replaces as any typed letter does.
    function wrapSelection(mark) {
        const closing = { "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "<": ">", "*": "*", "_": "_" }[mark];
        const start = input.selectionStart;
        const end = input.selectionEnd;
        if (closing === undefined || start === end) return false;
        const selected = input.text.slice(start, end);
        const around = input.text.slice(Math.max(0, start - 1), end + 1);
        if (/[*_~`\[\]@]/.test(around) || /hal-c2-context:/.test(selected)) return false;
        input.remove(start, end);
        input.insert(start, mark + selected + closing);
        input.select(start + 1, start + 1 + selected.length);
        return true;
    }

    function runtimeIcon(mode) {
        switch (mode) {
        case "approval-required":
            return "lock";
        case "auto-accept-edits":
            return "pen-line";
        case "auto":
            return "sparkles";
        default:
            return "lock-open";
        }
    }

    function nextEdit() {
        lastSentRevision = ++nextEditRevision;
        return {
            clientId: editClientId,
            revision: lastSentRevision
        };
    }

    function flushText() {
        textDebounce.stop();
        if (input.text !== composer.lastSentText || input.cursorPosition !== composer.lastSentCursor) {
            composer.lastSentText = input.text;
            composer.lastSentCursor = input.cursorPosition;
            Shell.dispatch("composer.text.set", {
                target: composer.publishedTarget,
                edit: composer.nextEdit(),
                text: input.text,
                cursor: input.cursorPosition
            });
        }
    }

    function restoreStash(id) {
        composer.flushText();
        Shell.dispatch("composer.stash.restore", {
            id: id
        });
    }

    function selectSuggestion(index) {
        const item = composer.suggestions[index];
        if (!item) {
            return;
        }
        Shell.dispatch("composer.suggest.select", {
            id: item.id
        });
    }

    // Files join the draft (or the answer the agent waits on); a folder is
    // named by its path. The picker and ConversationDrop hand them here.
    function attach(urls) {
        const files = Shell.readAttachmentFiles(urls);
        const folders = Shell.directoryPaths(urls);
        if (files.length === 0 && folders.length === 0) {
            return;
        }
        Shell.dispatch("composer.attach", {
            files: files,
            folders: folders
        });
    }

    // A copied picture is attached, and so are copied files when there is no
    // text to paste instead (Shell.clipboardFiles). A paste too large for the
    // prompt becomes a text file; Paste as Text (mod+shift+V) keeps it in the
    // editor.
    function paste(asText) {
        const text = Shell.clipboardText();
        const files = asText ? [] : Shell.clipboardFiles();
        if (files.length > 0) {
            Shell.dispatch("composer.attach", {
                files: files
            });
            return true;
        }
        if (text.length === 0) return false;
        const selected = input.selectionEnd - input.selectionStart;
        if (!asText && Shell.pasteAttaches(text, input.length - selected)) {
            // A paste the controller cannot file is spliced into its draft:
            // hand it the editor's words and caret first, debounce or not,
            // or it splices at a caret the user has already moved from and
            // its echo drops the typing it never saw.
            composer.flushText();
            Shell.dispatch("composer.attach", {
                files: [{ name: "pasted-text.txt", text: text }]
            });
            return true;
        }
        return composer.insertText(text);
    }

    // What Enter with these modifiers sends, as the controller resolves it from the
    // send shortcut setting and the keybindings (composer.enterIntents); ""
    // leaves the key to the editor as a newline.
    function enterIntent(modifiers) {
        // Qt calls the Command key Control on macOS, where the keybindings call it meta.
        const mac = Qt.platform.os === "osx";
        const held = [];
        if (modifiers & (mac ? Qt.MetaModifier : Qt.ControlModifier)) held.push("ctrl");
        if (modifiers & (mac ? Qt.ControlModifier : Qt.MetaModifier)) held.push("meta");
        if (modifiers & Qt.AltModifier) held.push("alt");
        if (modifiers & Qt.ShiftModifier) held.push("shift");
        const mod = mac ? "meta" : "ctrl";
        // Without enterIntents: Enter sends, mod+Enter the alternative.
        const table = composer.model.enterIntents ?? {
            singleLine: { "": "foreground", [mod]: composer.model.isRunning ? "alternate" : "background" }
        };
        const intents = /[\r\n]/.test(input.text) ? table.multiline ?? table.singleLine : table.singleLine;
        return intents[held.join("+")] ?? "";
    }

    function submit(intent) {
        if (!composer.ready) {
            return;
        }
        // canSend reflects the text the controller has seen, which lags this
        // input by the debounce; with local text, let the controller validate
        // the send (it echoes the prompt back if it declines).
        if (!composer.model.canSend && input.text.trim().length === 0 && composer.attachments.length === 0 && (composer.model.editingQueuedRunId ?? null) === null) {
            return;
        }
        textDebounce.stop();
        // What the keyboard is still composing (dictation, a correction it
        // is about to make) is part of the message: settle it first.
        Qt.inputMethod.commit();
        const text = input.text;
        // The controller clears its published prompt only after accepting the send.
        // Until then this remains the user's recoverable draft.
        composer.lastSentText = text;
        composer.lastSentCursor = input.cursorPosition;
        Shell.dispatch("composer.submit", {
            edit: composer.nextEdit(),
            text: text,
            intent: intent
        });
    }

    onModelChanged: {
        const target = model?.target ?? "";
        const text = target ? model.text : "";
        const cursor = Math.min(target ? model.cursor : 0, text.length);
        if (target !== editingTarget) {
            textDebounce.stop();
            editingTarget = target;
            lastSentRevision = 0;
            lastSentText = text;
            lastSentCursor = cursor;
            input.text = text;
            input.cursorPosition = cursor;
            return;
        }
        // Compare the publication's edit revision, not its text: returning to
        // an earlier value and coalesced publications must still acknowledge
        // the right edit. Older echoes cannot move the local text or caret.
        const edit = model?.edit;
        // An absent field means a publisher without revision support.
        if (edit !== undefined && lastSentRevision > 0 && (!edit || edit.clientId !== editClientId || edit.revision < lastSentRevision)) {
            return;
        }
        if (text !== input.text && text !== lastSentText) {
            lastSentText = text;
            input.text = text;
            input.cursorPosition = cursor;
            lastSentCursor = cursor;
        }
    }

    // A draft already there when the composer is built keeps its caret.
    Component.onCompleted: input.cursorPosition = Math.min(publishedCursor, input.length)

    onSuggestionsChanged: suggestionList.currentIndex = suggestions.length > 0 ? 0 : -1

    ComposerVimKeys {
        id: vim
        objectName: "vimKeys"

        composer: composer
        vimEnabled: composer.vimKeys
    }

    ComposerHighlighter {
        document: input.textDocument
        rich: composer.richText
        markerColor: Qt.alpha(composer.muted, 0.6)
        codeFont: Theme.fontMono
    }

    Timer {
        id: textDebounce

        interval: 120
        onTriggered: composer.flushText()
    }

    // The last keystrokes do not wait for the debounce when the app stops being
    // in front (a phone may never run it again) or the composer goes.
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state !== Qt.ApplicationActive)
                composer.flushText();
        }
    }
    Component.onDestruction: composer.flushText()

    // What the turn waits on from the user sits on the prompt, so every shell
    // that hosts the composer can answer it.
    TurnRequests {
        id: turnRequests
        objectName: "turnRequests"

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: implicitHeight
    }

    ColumnLayout {
        id: stack

        anchors.top: turnRequests.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - composer.gutter * 2, composer.maximumCardWidth)
        spacing: 0

        // @file, $skill and /command suggestions, computed by the controller for the
        // caret it was last told about: a popover 4px above the card, its edges
        // flush with the prompt's, as tall as its whole rows.
        Item {
            objectName: "suggestionsPopover"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.md
            Layout.rightMargin: Theme.space.md
            Layout.bottomMargin: visible ? Theme.space.xs : 0
            visible: composer.suggesting
            implicitHeight: !visible ? 0 : (suggestionList.count > 0 ? Math.min(suggestionList.contentHeight, Theme.control.md * 8) : Theme.control.md) + Theme.space.xs * 2

            ShellPopoverSurface {
                anchors.fill: parent
            }

            ListView {
                id: suggestionList
                objectName: "suggestionList"

                anchors.fill: parent
                anchors.margins: Theme.space.xs
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: composer.suggestions
                highlightMoveDuration: 0
                keyNavigationWraps: true

                delegate: Rectangle {
                    id: suggestion

                    required property var modelData
                    required property int index

                    // The prompt's arrows move through the rows and Enter or
                    // Tab takes one.
                    Accessible.role: Accessible.ListItem
                    Accessible.name: [suggestion.modelData.label, suggestion.modelData.description].filter(part => (part ?? "").length > 0).join(", ")
                    Accessible.selected: ListView.isCurrentItem
                    Accessible.onPressAction: {
                        composer.flushText();
                        composer.selectSuggestion(suggestion.index);
                    }
                    width: ListView.view.width
                    height: Theme.control.md
                    radius: Math.max(0, Theme.radiusLg - Theme.space.xs)
                    color: ListView.isCurrentItem || suggestionHover.hovered ? composer.chipFill : "transparent"

                    HoverHandler {
                        id: suggestionHover
                    }

                    TapHandler {
                        onTapped: {
                            composer.flushText();
                            composer.selectSuggestion(suggestion.index);
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.md
                        anchors.rightMargin: Theme.space.md
                        spacing: Theme.space.sm

                        Text {
                            text: suggestion.modelData.label
                            color: composer.foreground
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Font.Medium
                            elide: Text.ElideMiddle
                            Layout.maximumWidth: parent.width * 0.5
                        }

                        Text {
                            Layout.fillWidth: true
                            text: suggestion.modelData.description
                            color: composer.muted
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideRight
                        }
                    }
                }

            }

            // Nothing to offer: one quiet row where the first suggestion's
            // label would start, outside the list, which has no rows.
            Text {
                id: suggestionsEmpty
                objectName: "suggestionsEmpty"

                anchors.fill: parent
                anchors.topMargin: Theme.space.xs
                anchors.bottomMargin: Theme.space.xs
                anchors.leftMargin: Theme.space.xs + Theme.space.md
                anchors.rightMargin: Theme.space.xs + Theme.space.md
                visible: suggestionList.count === 0
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: composer.ready && composer.model.suggestionsEmptyText ? composer.model.suggestionsEmptyText : ""
                color: Theme.palette.color("inkTertiary", "#8b919e")
                font.pixelSize: Theme.type.body.size
            }
        }

        NoticeStackPeek {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.xl
            Layout.rightMargin: Theme.space.xl
        }

        ComposerUsageLimits {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.xl
            Layout.rightMargin: Theme.space.xl
        }

        // The stash (composer.stash), on the card's top edge: a row
        // restores its prompt, its cross deletes it.
        Rectangle {
            objectName: "stashList"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.xl
            Layout.rightMargin: Theme.space.xl
            visible: composer.stashOpen && !composer.suggesting
            implicitHeight: visible ? stashHeader.height + Math.min(Math.max(stashList.contentHeight, Theme.control.md), Theme.control.md * 8) + Theme.space.xs * 2 : 0
            topLeftRadius: Theme.radiusXl
            topRightRadius: Theme.radiusXl
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: composer.outline
            border.width: 1

            RowLayout {
                id: stashHeader

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.space.xs
                height: Theme.control.md
                spacing: Theme.space.sm

                ShellIcon {
                    Layout.leftMargin: Theme.space.sm
                    name: "bookmark"
                    size: Theme.icon.md
                    color: composer.muted
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Stash")
                    color: composer.muted
                    font.pixelSize: Theme.type.meta.size
                }

                Text {
                    text: composer.stashEntries.length
                    color: composer.muted
                    font.pixelSize: Theme.type.meta.size
                }

                ShellButton {
                    objectName: "stashClose"
                    subtle: true
                    iconName: "x"
                    iconSize: Theme.icon.sm
                    implicitHeight: Theme.control.sm
                    Accessible.name: qsTr("Close stash")
                    onClicked: Shell.dispatch("composer.stash.menu", { open: false })
                }
            }

            ListView {
                id: stashList

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: stashHeader.bottom
                anchors.bottom: parent.bottom
                anchors.margins: Theme.space.xs
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: composer.stashEntries
                highlightMoveDuration: 0
                currentIndex: count > 0 ? 0 : -1

                delegate: Rectangle {
                    id: stashRow

                    required property var modelData
                    required property int index

                    objectName: "stashEntry-" + index
                    // The prompt's arrows move through the rows and Enter
                    // restores one.
                    Accessible.role: Accessible.ListItem
                    Accessible.name: qsTr("Restore stashed prompt: %1").arg(stashRow.modelData.snippet)
                    Accessible.selected: ListView.isCurrentItem
                    Accessible.onPressAction: composer.restoreStash(stashRow.modelData.id)
                    width: ListView.view.width
                    height: Theme.control.md
                    radius: Math.max(0, Theme.radiusLg - Theme.space.xs)
                    color: ListView.isCurrentItem ? composer.chipFill : "transparent"

                    HoverHandler {
                        onHoveredChanged: if (hovered) stashList.currentIndex = stashRow.index
                    }

                    TapHandler {
                        onTapped: composer.restoreStash(stashRow.modelData.id)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.md
                        anchors.rightMargin: Theme.space.xs
                        spacing: Theme.space.sm

                        ShellIcon {
                            name: "file-text"
                            size: Theme.icon.md
                            color: composer.muted
                        }

                        Text {
                            Layout.fillWidth: true
                            text: stashRow.modelData.snippet
                            color: composer.foreground
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideRight
                            Accessible.name: qsTr("Restore stashed prompt: %1").arg(text)
                        }

                        Text {
                            objectName: "stashAge-" + stashRow.index
                            text: Format.relative(stashRow.modelData.createdAt)
                            color: composer.muted
                            font.pixelSize: Theme.type.meta.size
                        }

                        ShellButton {
                            objectName: "stashDelete-" + stashRow.index
                            subtle: true
                            iconName: "x"
                            iconSize: Theme.icon.sm
                            implicitHeight: Theme.control.sm
                            Accessible.name: qsTr("Delete stashed prompt")
                            onClicked: Shell.dispatch("composer.stash.delete", { id: stashRow.modelData.id })
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: stashList.count === 0
                    width: parent.width - Theme.space.xl
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: (Shell.state.composerStash?.shortcut ?? "") !== ""
                        ? qsTr("Nothing stashed yet. Press %1 with a prompt in the composer to stash it.").arg(Shell.state.composerStash.shortcut)
                        : qsTr("Nothing stashed yet.")
                    color: composer.muted
                    font.pixelSize: Theme.type.meta.size
                }
            }
        }

        // The glass card.
        Rectangle {
            id: card
            objectName: "composerCard"

            Layout.fillWidth: true
            implicitHeight: cardColumn.implicitHeight
            z: 1
            radius: Theme.radiusXl
            color: Theme.palette.color("surface", "#141416")
            border.color: Theme.palette.color("border", "#262a31")
            border.width: 1

            // A press anywhere in the card that no control takes, around
            // or under a short prompt, goes to the prompt.
            MouseArea {
                anchors.fill: parent
                enabled: input.enabled
                cursorShape: Qt.IBeamCursor
                onPressed: input.forceActiveFocus(Qt.MouseFocusReason)
            }

            ConversationDrop {
                objectName: "composerDrop"
                anchors.fill: parent
                z: 1
                enabled: composer.takesDrops && !composer.imagesHost
                composer: composer
            }

            ColumnLayout {
                id: cardColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 0

                // The card's padding holds the prompt and its toolbar.
                ColumnLayout {
                    id: cardBody

                    Layout.fillWidth: true
                    Layout.margins: Theme.space.md
                    spacing: Theme.space.sm

                    // A queued message open for editing: sending saves it.
                    RowLayout {
                        Layout.fillWidth: true
                        visible: composer.ready && (composer.model.editingQueuedRunId ?? null) !== null
                        spacing: Theme.space.sm

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Editing a queued message")
                            color: composer.muted
                            font.pixelSize: Theme.type.meta.size
                        }

                        ShellButton {
                            objectName: "queuedEditCancel"
                            implicitHeight: Theme.control.sm
                            subtle: true
                            text: qsTr("Cancel")
                            onClicked: Shell.dispatch("composer.queue.edit.cancel")
                        }
                    }

                    // Attached images, terminal selections and quoted replies living on the draft.
                    // A draft can carry a hundred: the chips scroll in a strip
                    // a few rows tall instead of pushing the prompt off screen.
                    ScrollView {
                        id: attachmentsScroll

                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(attachmentsFlow.implicitHeight, Theme.control.md * 3)
                        visible: composer.ready && (composer.attachments.length > 0 || composer.model.terminalContexts.length > 0 || (composer.model.reviewComments ?? []).length > 0 || (composer.model.threadContexts ?? []).length > 0 || composer.citations.length > 0)
                        clip: true
                        contentWidth: availableWidth
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                        Flow {
                            id: attachmentsFlow

                            width: attachmentsScroll.availableWidth
                            spacing: Theme.space.sm

                        Repeater {
                            model: composer.attachments

                            delegate: ComposerAttachment {
                                required property var modelData

                                attachment: modelData
                                onRemoveRequested: Shell.dispatch("composer.attachment.remove", {
                                    id: modelData.id
                                })
                                onRetryRequested: Shell.dispatch("composer.attachment.retry", {
                                    id: modelData.id
                                })
                                // An edited queued message's own is the MC's; a draft's is here.
                                onOpenRequested: modelData.sent === true ? Shell.dispatch("attachment.sent.view", {
                                    id: modelData.id,
                                    name: modelData.name,
                                    mimeType: modelData.mimeType ?? ""
                                }) : Shell.dispatch("attachment.view", {
                                    id: modelData.id
                                })
                            }
                        }

                        // Notes on a diff's lines; a click takes one off the prompt.
                        Repeater {
                            model: composer.ready ? composer.model.reviewComments ?? [] : []

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "reviewComment-" + modelData.id
                                implicitHeight: Theme.control.sm
                                iconName: "message-square"
                                text: modelData.label
                                font.pixelSize: Theme.type.meta.size
                                Accessible.name: qsTr("Remove the comment on %1").arg(text)
                                ToolTip.visible: hovered
                                ToolTip.text: modelData.text
                                onClicked: Shell.dispatch("composer.reviewComment.remove", {
                                    id: modelData.id
                                })
                            }
                        }

                        Repeater {
                            model: composer.ready ? composer.model.terminalContexts : []

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "terminalContext-" + modelData.id
                                implicitHeight: Theme.control.sm
                                iconName: "terminal"
                                text: modelData.lineStart === modelData.lineEnd ? qsTr("%1 line %2").arg(modelData.label).arg(modelData.lineStart) : qsTr("%1 lines %2-%3").arg(modelData.label).arg(modelData.lineStart).arg(modelData.lineEnd)
                                font.pixelSize: Theme.type.meta.size
                                Accessible.name: qsTr("Remove terminal selection %1").arg(text)
                                onClicked: Shell.dispatch("composer.terminalContext.remove", {
                                    id: modelData.id
                                })
                            }
                        }

                        // Threads carried as context; a click takes one off.
                        Repeater {
                            model: composer.ready ? composer.model.threadContexts ?? [] : []

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "threadContext-" + modelData.id
                                implicitHeight: Theme.control.sm
                                iconName: "message-square"
                                text: modelData.label
                                font.pixelSize: Theme.type.meta.size
                                Accessible.name: qsTr("Remove the thread %1").arg(text)
                                // Removing it strips its link from the draft, so the
                                // controller needs the editor's live words and caret first.
                                onClicked: {
                                    composer.flushText();
                                    Shell.dispatch("composer.terminalContext.remove", {
                                        id: modelData.id
                                    });
                                }
                            }
                        }

                        // A quoted reply shows the user's comment on it, or the
                        // start of the quote; it opens to comment on or remove.
                        Repeater {
                            model: composer.citations

                            delegate: ShellButton {
                                id: citationChip

                                required property var modelData
                                readonly property string preview: (modelData.comment ?? modelData.text).replace(/\s+/g, " ").trim()

                                function saveComment() {
                                    const comment = citationComment.text;
                                    citationEditor.close();
                                    Shell.dispatch("composer.citation.comment", {
                                        id: modelData.id,
                                        comment: comment
                                    });
                                }

                                objectName: "citation-" + modelData.id
                                implicitHeight: Theme.control.sm
                                iconName: modelData.comment === null ? "quote" : "pencil"
                                text: preview.length > 40 ? preview.slice(0, 40) + "\u2026" : preview
                                font.pixelSize: Theme.type.meta.size
                                Accessible.name: qsTr("Assistant quote: %1").arg(preview)
                                onClicked: citationEditor.open()

                                Popup {
                                    id: citationEditor
                                    objectName: "citationEditor"

                                    scale: Shell.state.layout?.zoom ?? 1
                                    transformOrigin: Item.BottomLeft
                                    y: -height - Theme.space.xs
                                    width: 360
                                    padding: Theme.space.sm
                                    onOpened: {
                                        citationComment.text = citationChip.modelData.comment ?? "";
                                        citationComment.forceActiveFocus();
                                    }

                                    background: ShellPopoverSurface {}

                                    contentItem: ColumnLayout {
                                        spacing: Theme.space.sm

                                        Text {
                                            Layout.fillWidth: true
                                            text: citationChip.modelData.text
                                            textFormat: Text.PlainText
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 6
                                            elide: Text.ElideRight
                                            color: composer.muted
                                            font.pixelSize: Theme.type.meta.size
                                        }

                                        ShellTextField {
                                            id: citationComment
                                            objectName: "citationComment"

                                            Layout.fillWidth: true
                                            maximumLength: 8000
                                            placeholderText: qsTr("Add a comment")
                                            Accessible.name: qsTr("Comment on the quote")
                                            Keys.onReturnPressed: citationChip.saveComment()
                                            Keys.onEnterPressed: citationChip.saveComment()
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.space.sm

                                            ShellButton {
                                                objectName: "citationRemove"
                                                implicitHeight: Theme.control.sm
                                                subtle: true
                                                text: qsTr("Remove quote")
                                                font.pixelSize: Theme.type.meta.size
                                                onClicked: {
                                                    const id = citationChip.modelData.id;
                                                    citationEditor.close();
                                                    Shell.dispatch("composer.citation.remove", {
                                                        id: id
                                                    });
                                                }
                                            }

                                            Item {
                                                Layout.fillWidth: true
                                            }

                                            ShellButton {
                                                objectName: "citationSave"
                                                implicitHeight: Theme.control.sm
                                                primary: true
                                                text: qsTr("Save")
                                                font.pixelSize: Theme.type.meta.size
                                                onClicked: citationChip.saveComment()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        }
                    }

                    ScrollView {
                        id: promptScroll

                        // The caret's line stays in view as the prompt wraps
                        // past the lines shown, whatever keyboard is typing.
                        function keepCaretInView() {
                            const flick = promptScroll.contentItem;
                            if (!flick || flick.contentY === undefined)
                                return;
                            const caret = input.cursorRectangle;
                            const y = input.y + caret.y;
                            if (y < flick.contentY)
                                flick.contentY = y;
                            else if (y + caret.height > flick.contentY + flick.height)
                                flick.contentY = y + caret.height - flick.height;
                        }

                        objectName: "promptScroll"
                        Layout.fillWidth: true
                        // Two lines at rest, one while scrolled away, and up to
                        // 40% of the window with the card's other rows.
                        Layout.preferredHeight: composer.resting ? Math.min(input.implicitHeight, promptLine.lineHeight) : Math.min(Math.max(input.implicitHeight, promptLine.lineHeight * 2), maximumHeight)
                        readonly property real maximumHeight: Math.max(promptLine.lineHeight * 2, Math.round(composer.Window.height * 0.4) - toolbar.implicitHeight - Theme.space.md * 2 - Theme.space.sm - (contextStrip.visible ? contextStrip.implicitHeight : 0))
                        clip: true
                        // The prompt never scrolls sideways: a long placeholder
                        // would otherwise make a horizontal bar that, unseen,
                        // takes the clicks meant for the prompt.
                        contentWidth: availableWidth
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                        FontMetrics {
                            id: promptLine

                            readonly property real lineHeight: Math.ceil(lineSpacing)

                            font: input.font
                        }

                        TextArea {
                            id: input
                            objectName: "input"

                            // ShellWindow reads it for the keymap's composerFocus.
                            readonly property bool composerInput: true

                            // A resting composer comes back when the user turns to it.
                            onActiveFocusChanged: if (activeFocus) composer.scrollCollapsed = false
                            onPressed: composer.scrollCollapsed = false
                            onCursorRectangleChanged: promptScroll.keepCaretInView()

                            padding: 0
                            enabled: composer.ready && !composer.model.editorDisabled
                            placeholderText: composer.ready ? composer.model.placeholder : qsTr("Open a thread to start")
                            placeholderTextColor: composer.muted
                            color: composer.foreground
                            // The placeholder is one line, elided: an empty prompt
                            // does not wrap, so neither does it.
                            wrapMode: length > 0 || preeditText.length > 0 ? TextEdit.Wrap : TextEdit.NoWrap
                            // The scroll view sizes the editor to its unwrapped text
                            // and not again when wrapping starts: a long prompt
                            // arriving whole (a recall, a restore) would stay one line.
                            onWrapModeChanged: if (wrapMode !== TextEdit.NoWrap) width = promptScroll.contentItem.width
                            selectByMouse: true
                            background: null
                            // The prompt has its own font and size (Settings → Appearance).
                            font.pixelSize: Theme.fontSizePrompt
                            font.family: Theme.fontPrompt.length > 0 ? Theme.fontPrompt : Application.font.family
                            Accessible.name: qsTr("Message")
                            onTextChanged: {
                                if (text !== composer.lastSentText) {
                                    textDebounce.restart();
                                }
                            }
                            // Keybindings are window shortcuts too (ShellWindow);
                            // an Enter chord that sends is the composer's, not theirs.
                            Keys.onShortcutOverride: event => {
                                event.accepted = (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                    && composer.enterIntent(event.modifiers) !== "";
                            }
                            Keys.onPressed: event => {
                                composer.scrollCollapsed = false;
                                event.accepted = false;
                                composer.editorKeyPressed(event);
                                if (event.accepted) return;
                                // A prompt that fits has nothing to page through: the keys
                                // page the conversation.
                                if ((event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) && event.modifiers === Qt.NoModifier && input.contentHeight <= input.height && !composer.suggesting) {
                                    event.accepted = Keybindings.commands.run(event.key === Qt.Key_PageUp ? "timeline.pageUp" : "timeline.pageDown");
                                    if (event.accepted) return;
                                }
                                if (event.key === Qt.Key_V && (event.modifiers & ~Qt.ShiftModifier) === Qt.ControlModifier) {
                                    event.accepted = composer.paste((event.modifiers & Qt.ShiftModifier) !== 0);
                                    if (event.accepted) return;
                                } else if (event.matches(StandardKey.Paste)) {
                                    // Shift+Insert and the platform's other paste keys.
                                    event.accepted = composer.paste(false);
                                    if (event.accepted) return;
                                }
                                if (editorMenu.keyPressed(event)) {
                                    event.accepted = true;
                                    return;
                                }
                                if (composer.suggesting && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) {
                                    if (event.key === Qt.Key_Escape) {
                                        event.accepted = true;
                                        Shell.dispatch("composer.suggest.dismiss");
                                        return;
                                    }
                                    if (composer.suggestions.length > 0 && !(event.modifiers & Qt.ShiftModifier)) {
                                        if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                                            event.accepted = true;
                                            if (event.key === Qt.Key_Down) suggestionList.incrementCurrentIndex();
                                            else suggestionList.decrementCurrentIndex();
                                            return;
                                        }
                                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                            event.accepted = true;
                                            const index = suggestionList.currentIndex;
                                            composer.flushText();
                                            composer.selectSuggestion(index);
                                            return;
                                        }
                                    }
                                }
                                // The stash list, open above the card: arrows pick,
                                // Enter restores, mod+Backspace deletes, Escape closes.
                                if (composer.stashOpen && !composer.suggesting) {
                                    const entry = composer.stashEntries[stashList.currentIndex] ?? null;
                                    const mod = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier);
                                    event.accepted = true;
                                    if (event.key === Qt.Key_Escape) Shell.dispatch("composer.stash.menu", { open: false });
                                    else if (event.key === Qt.Key_Down && !mod) stashList.incrementCurrentIndex();
                                    else if (event.key === Qt.Key_Up && !mod) stashList.decrementCurrentIndex();
                                    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !mod && entry) composer.restoreStash(entry.id);
                                    else if (event.key === Qt.Key_Backspace && mod && entry) Shell.dispatch("composer.stash.delete", { id: entry.id });
                                    else event.accepted = false;
                                    if (event.accepted) return;
                                }
                                if (event.key === Qt.Key_Backtab) {
                                    event.accepted = composer.toggleInteractionMode();
                                    return;
                                }
                                if (event.key === Qt.Key_Tab && event.modifiers === Qt.NoModifier) {
                                    // Tab indents a list item, anywhere else it
                                    // leaves the editor for the composer's controls.
                                    event.accepted = true;
                                    const lineStart = input.text.lastIndexOf("\n", input.cursorPosition - 1) + 1;
                                    const lineEnd = input.text.indexOf("\n", input.cursorPosition);
                                    const line = input.text.slice(lineStart, lineEnd < 0 ? input.text.length : lineEnd);
                                    if (input.selectionStart === input.selectionEnd && /^\s*([-*+]|\d+[.)])\s/.test(line)) {
                                        input.insert(lineStart, "  ");
                                    } else {
                                        input.nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason);
                                    }
                                    return;
                                }
                                if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down) && event.modifiers === Qt.NoModifier) {
                                    event.accepted = composer.stepPromptHistory(event.key === Qt.Key_Up ? "backward" : "forward");
                                    return;
                                }
                                if (event.text.length === 1 && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)) && composer.wrapSelection(event.text)) {
                                    event.accepted = true;
                                    return;
                                }
                                if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) {
                                    return;
                                }
                                // Enter that accepts the input method's word is the
                                // input method's.
                                if (input.preeditText.length > 0) {
                                    event.accepted = true;
                                    return;
                                }
                                const intent = composer.enterIntent(event.modifiers);
                                if (intent === "") {
                                    event.accepted = !event.isAutoRepeat && composer.continueList();
                                    return;
                                }
                                event.accepted = true;
                                // A held Enter sends once, on its first press.
                                if (!event.isAutoRepeat) composer.submit(intent);
                            }

                            // Its Paste is the composer's, which attaches copied
                            // pictures and files. A MouseArea, as it takes the
                            // press from Qt's own TextArea menu.
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onClicked: mouse => editorMenu.openAt(mouse.x, mouse.y)
                            }
                            TextEditMenu {
                                id: editorMenu
                                objectName: "editorMenu"
                                editor: input
                                paste: () => composer.paste(false)
                            }
                        }
                    }

                    // The toolbar is one line: the model, the chips that fit
                    // beside it, the "•••" chip holding the rest, then send.
                    RowLayout {
                        id: toolbar
                        objectName: "toolbar"

                        Layout.fillWidth: true
                        spacing: Theme.space.xs

                        Chip {
                            objectName: "attachButton"
                            visible: !composer.imagesHost
                            iconName: "paperclip"
                            enabled: composer.ready && !composer.model.editorDisabled
                            Accessible.name: qsTr("Attach files")
                            onClicked: imagePicker.open()

                            FileDialog {
                                id: imagePicker

                                title: qsTr("Attach files")
                                fileMode: FileDialog.OpenFiles
                                nameFilters: [qsTr("All files (*)"), qsTr("Images (*.png *.jpg *.jpeg *.gif *.webp *.heic *.heif)")]
                                onAccepted: composer.attach(selectedFiles)
                            }
                        }

                        // Never folds: it gives up width, eliding, once
                        // everything else has folded.
                        ModelPicker {
                            id: modelPicker
                            objectName: "modelPicker"

                            Layout.preferredWidth: Math.min(implicitWidth, Theme.control.md * 8)
                            Layout.minimumWidth: Math.min(implicitWidth, Theme.control.md * 2)
                            enabled: composer.ready && instances.length > 0 && composer.model.isSendBusy !== true
                            selectedInstanceId: composer.ready ? composer.model.selectedInstanceId : null
                            selectedModel: composer.ready ? composer.model.selectedModel : null
                        }

                        // The room left beside the model; the chips that fit it
                        // show, in this order, and the overflow chip ends them.
                        Item {
                            id: chipArea

                            Layout.fillWidth: true
                            Layout.preferredWidth: overflowChip.implicitWidth
                            Layout.minimumWidth: overflowChip.implicitWidth
                            implicitHeight: Theme.control.md

                            Row {
                                id: chipRow
                                objectName: "toolbarChips"

                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.space.xs

                                ChipPicker {
                                    id: effortPicker
                                    objectName: "effortPicker"

                                    present: composer.effortOption !== null
                                    visible: present && !composer.folded.includes(effortPicker)
                                    model: composer.effortOption ? composer.effortOption.choices.map(choice => composer.choiceLabel(choice)) : []
                                    currentIndex: composer.effortOption ? composer.effortOption.choices.findIndex(choice => choice.id === composer.effortOption.value) : -1
                                    displayText: currentIndex < 0 ? (composer.effortOption ? composer.effortOption.label : "") : composer.effortOption.choices[currentIndex].label
                                    Accessible.name: composer.effortOption ? composer.effortOption.label : ""
                                    onActivated: index => Shell.dispatch("composer.option.set", {
                                            id: composer.effortOption.id,
                                            value: composer.effortOption.choices[index].id
                                        })
                                }

                                // By count, so a value picked here updates its control rather
                                // than rebuilding them all (and dropping the focus).
                                Repeater {
                                    id: selectChips

                                    model: composer.selectOptions.length

                                    delegate: ChipPicker {
                                        id: selectChip

                                        required property int index
                                        readonly property var option: composer.selectOptions[index] ?? ({})

                                        objectName: "optionPicker:" + option.id
                                        visible: !composer.folded.includes(selectChip)
                                        model: (option.choices ?? []).map(choice => composer.choiceLabel(choice))
                                        currentIndex: (option.choices ?? []).findIndex(choice => choice.id === option.value)
                                        displayText: currentIndex < 0 ? (option.label ?? "") : option.choices[currentIndex].label
                                        Accessible.name: option.label ?? ""
                                        onActivated: index => Shell.dispatch("composer.option.set", {
                                                id: selectChip.option.id,
                                                value: selectChip.option.choices[index].id
                                            })
                                    }
                                }

                                Repeater {
                                    id: toggleChips

                                    model: composer.toggleOptions.length

                                    delegate: Chip {
                                        id: toggleChip

                                        required property int index
                                        readonly property var option: composer.toggleOptions[index] ?? ({})
                                        readonly property bool fast: option.id === "fastMode"
                                        readonly property string menuTitle: option.label ?? ""

                                        // The click asks; the state's answer checks it.
                                        function flip() {
                                            Shell.dispatch("composer.option.set", {
                                                id: toggleChip.option.id,
                                                value: !toggleChip.checked
                                            });
                                        }

                                        objectName: "optionToggle:" + option.id
                                        visible: !composer.folded.includes(toggleChip)
                                        checked: option.value === true
                                        // On is the fill and a leading check; fast mode's
                                        // is its bolt, filled, in Claude's orange on a
                                        // Claude model.
                                        iconName: !checked ? "" : fast ? "zap" : "check"
                                        iconSize: checked && !fast ? Theme.icon.sm : Theme.icon.md
                                        iconFilled: fast && checked
                                        iconTint: fast && checked && modelPicker.activeInstance?.driverKind === "claudeAgent" ? Qt.alpha(composer.claudeOrange, 0.8) : tint
                                        text: option.label ?? ""
                                        Accessible.name: qsTr("%1, %2").arg(option.label ?? "").arg(checked ? qsTr("on") : qsTr("off"))
                                        Accessible.checkable: true
                                        Accessible.checked: checked
                                        onClicked: flip()
                                    }
                                }

                                ChipPicker {
                                    id: runtimeModePicker
                                    objectName: "runtimeModePicker"

                                    present: composer.ready && !composer.imagesHost
                                    visible: present && !composer.folded.includes(runtimeModePicker)
                                    iconName: composer.ready ? composer.runtimeIcon(composer.model.runtimeMode) : "lock"
                                    model: composer.ready ? composer.model.runtimeModes.map(mode => mode.label) : []
                                    currentIndex: composer.ready ? composer.model.runtimeModes.findIndex(mode => mode.value === composer.model.runtimeMode) : -1
                                    Accessible.name: qsTr("Permissions")
                                    onActivated: index => Shell.dispatch("composer.runtimeMode.set", {
                                            mode: composer.model.runtimeModes[index].value
                                        })
                                }

                                Chip {
                                    id: planToggle
                                    objectName: "planToggle"

                                    readonly property bool present: composer.ready && composer.model.showInteractionModeToggle
                                    readonly property string menuTitle: qsTr("Plan")

                                    function flip() {
                                        Shell.dispatch("composer.interactionMode.set", {
                                            mode: planToggle.checked ? "default" : "plan"
                                        });
                                    }

                                    visible: present && !composer.folded.includes(planToggle)
                                    checked: composer.ready && composer.model.interactionMode === "plan"
                                    iconName: checked ? "pencil-ruler" : "bot"
                                    text: checked ? qsTr("Plan") : qsTr("Build")
                                    Accessible.checkable: true
                                    Accessible.checked: checked
                                    onClicked: flip()
                                }

                                // What did not fit, in a menu.
                                Chip {
                                    id: overflowChip
                                    objectName: "composerOverflow"

                                    visible: composer.foldCount > 0
                                    iconName: "ellipsis"
                                    checked: composer.overflowMenu !== null
                                    Accessible.name: qsTr("More options")
                                    onClicked: composer.openOverflow(null)
                                }
                            }
                        }

                        Text {
                            objectName: "vimMode"
                            visible: composer.vimKeys
                            text: vim.modeLabel
                            color: composer.muted
                            font.pixelSize: Theme.type.caption.size
                            Accessible.name: qsTr("Vim mode: %1").arg(text)
                        }

                        ContextWindowMeter {
                            available: composer.ready && !composer.imagesHost && !composer.pageHost
                        }

                        // The stash's count, which opens and closes its list.
                        Chip {
                            objectName: "stashBadge"
                            visible: composer.ready && !composer.imagesHost && composer.stashEntries.length > 0
                            iconName: "bookmark"
                            text: composer.stashEntries.length
                            Accessible.name: qsTr("Stashed prompts: %1. Open stash.").arg(composer.stashEntries.length)
                            onClicked: Shell.dispatch("composer.stash.menu")
                        }

                        // Approvals and the plan's Implement live in TurnRequests above.

                        // Send, or Stop while a turn runs and there is nothing to
                        // send. The accent is for a prompt that can go.
                        AbstractButton {
                            id: primaryAction
                            objectName: "primaryAction"

                            // An edit of a queued message saves with its Update button, even emptied (the controller says why not).
                            readonly property bool editing: composer.ready && (composer.model.editingQueuedRunId ?? null) !== null
                            readonly property bool stopMode: composer.ready && composer.model.isRunning && !editing && input.text.trim().length === 0 && composer.attachments.length === 0
                            readonly property bool sendable: composer.ready && !stopMode && (editing || composer.model.canSend || input.text.trim().length > 0 || composer.attachments.length > 0)
                            // A send during a turn joins it or waits behind it, per the
                            // follow-up setting; the button says which before the click.
                            readonly property string followUp: composer.model?.isRunning && !stopMode && !editing ? (composer.model.followUpBehavior ?? "steer") : ""
                            readonly property color accent: Theme.palette.color("accent", "#3b6fe0")

                            implicitWidth: Theme.control.md
                            implicitHeight: Theme.control.md
                            enabled: stopMode || sendable
                            hoverEnabled: true
                            scale: down ? 0.97 : 1
                            Accessible.role: Accessible.Button
                            // With a plan offered, sending implements it, or refines it with what was typed.
                            readonly property string planAction: composer.model?.planAction ?? ""
                            // What the button does, which is also its accessible name.
                            readonly property string label: stopMode ? qsTr("Stop")
                                : editing ? qsTr("Update queued message")
                                // With no connection the message waits on this device to be sent.
                                : composer.model?.waitsForConnection === true ? qsTr("Queue")
                                : followUp === "steer" ? qsTr("Steer") : followUp === "queue" ? qsTr("Queue")
                                : planAction === "refine" ? qsTr("Refine") : planAction === "implement" ? qsTr("Implement") : qsTr("Send")
                            Accessible.name: label
                            ToolTip.visible: hovered && followUp.length > 0
                            ToolTip.delay: 400
                            ToolTip.text: followUp === "steer"
                                ? qsTr("Steer the running turn (%1+Enter to queue)").arg(Qt.platform.os === "osx" ? "⌘" : "Ctrl")
                                : qsTr("Queue after the running turn (%1+Enter to steer)").arg(Qt.platform.os === "osx" ? "⌘" : "Ctrl")
                            // The other ways to send during a turn, on a long press
                            // (a finger's) or the secondary button: the opposite of
                            // the follow-up setting, and restarting the turn with
                            // the message. A provider that cannot steer offers none.
                            readonly property bool sendModesOffered: followUp.length > 0 && sendable && composer.model?.canSteer !== false
                            property bool holdOpened: false
                            onPressed: holdOpened = false
                            onPressAndHold: {
                                if (!sendModesOffered)
                                    return;
                                holdOpened = true;
                                sendModes.popup();
                            }
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                enabled: primaryAction.sendModesOffered
                                onTapped: sendModes.popup()
                            }
                            ShellMenu {
                                id: sendModes

                                objectName: "sendModes"

                                ShellMenuItem {
                                    objectName: "sendModeQueue"
                                    text: qsTr("Queue after this turn")
                                    iconName: "list-plus"
                                    visible: primaryAction.followUp !== "queue"
                                    onTriggered: composer.submit("queue")
                                }
                                ShellMenuItem {
                                    objectName: "sendModeSteer"
                                    text: qsTr("Steer this turn")
                                    iconName: "corner-down-right"
                                    visible: primaryAction.followUp !== "steer"
                                    onTriggered: composer.submit("steer")
                                }
                                ShellMenuItem {
                                    objectName: "sendModeRestart"
                                    text: qsTr("Restart the turn with this")
                                    iconName: "rotate-ccw"
                                    onTriggered: composer.submit("restart")
                                }
                            }
                            onClicked: {
                                if (holdOpened)
                                    return;
                                if (stopMode)
                                    Shell.dispatch("composer.interrupt");
                                else
                                    composer.submit("foreground");
                            }

                            Behavior on scale {
                                NumberAnimation {
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                            }

                            background: Rectangle {
                                radius: Theme.radiusMd
                                color: !primaryAction.sendable ? composer.chipFill
                                    : primaryAction.down ? Qt.darker(primaryAction.accent, 1.15)
                                    : primaryAction.hovered ? Qt.lighter(primaryAction.accent, 1.08) : primaryAction.accent
                                // Stop answers the pointer with an edge; its fill is already raised.
                                border.width: primaryAction.stopMode && primaryAction.hovered ? 1 : 0
                                border.color: Theme.palette.color("borderStrong", "#343a44")

                                // The keyboard's ring, just outside the button.
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: -Theme.space.xxs
                                    radius: parent.radius + Theme.space.xxs
                                    visible: primaryAction.visualFocus
                                    color: "transparent"
                                    border.width: 2
                                    border.color: Theme.palette.color("focus", "#3b82f6")
                                }
                            }

                            contentItem: Item {
                                ShellIcon {
                                    anchors.centerIn: parent
                                    visible: !primaryAction.stopMode
                                    name: primaryAction.followUp === "steer" ? "corner-down-right" : primaryAction.followUp === "queue" ? "list-plus" : "arrow-up"
                                    size: Theme.icon.md
                                    color: primaryAction.sendable ? Theme.palette.color("accentForeground", "#ffffff") : Theme.palette.color("placeholder", "#6e7480")
                                }

                                Rectangle {
                                    objectName: "stopGlyph"
                                    anchors.centerIn: parent
                                    visible: primaryAction.stopMode
                                    width: Theme.icon.sm - Theme.space.xxs
                                    height: width
                                    radius: Theme.radiusXs
                                    color: composer.foreground
                                }
                            }
                        }
                    }

                    // Optional plugin controls wrap without squeezing the model
                    // picker or overlapping the send button.
                    Flow {
                        id: editorActions
                        objectName: "editorActions"
                        Layout.fillWidth: true
                        // A layout's own controls, or a plugin's.
                        visible: children.length > 1 || actionsSlot.shown.length > 0
                        spacing: Theme.space.sm

                        PluginSlot {
                            id: actionsSlot

                            objectName: "composerActionsSlot"
                            name: "composer.actions"
                            mode: "append"
                            visible: shown.length > 0
                        }
                    }
                }

                // Context strip: environment, checkout mode, PR, branch, at
                // the foot of the card under a hairline.
                Item {
                    id: contextStrip

                    readonly property var ws: composer.workspace
                    readonly property bool wsReady: ws !== null
                    readonly property string envModeIcon: !wsReady ? "folder" : ws.envMode === "worktree" ? "folder-git-2" : "folder-git"

                    Layout.fillWidth: true
                    implicitHeight: stripRow.implicitHeight + Theme.space.xs * 2
                    visible: wsReady && (composer.model?.showContextStrip ?? true) && !composer.resting

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 1
                        color: Theme.palette.color("border", "#262a31")
                    }

                    // The chips' own padding lines their labels up with the prompt.
                    RowLayout {
                        id: stripRow

                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.xs
                        anchors.rightMargin: Theme.space.xs
                        anchors.topMargin: Theme.space.xs
                        anchors.bottomMargin: Theme.space.xs
                        spacing: Theme.space.xs

                        ShellComboBox {
                            id: hostPicker
                            objectName: "hostPicker"

                            visible: contextStrip.wsReady && contextStrip.ws.environments.length > 1
                            implicitHeight: Theme.control.sm
                            iconSize: Theme.icon.sm
                            chevronSize: Theme.icon.sm
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Theme.type.meta.weight
                            hoverFill: composer.chipFill
                            iconName: "monitor"
                            enabled: contextStrip.wsReady && contextStrip.ws.environmentChangeable
                            model: contextStrip.wsReady ? contextStrip.ws.environments.map(env => env.label) : []
                            currentIndex: contextStrip.wsReady ? contextStrip.ws.environments.findIndex(env => env.environmentId === contextStrip.ws.activeEnvironmentId) : -1
                            Accessible.name: qsTr("Environment")
                            onActivated: index => Shell.dispatch("workspace.environment.set", {
                                    environmentId: contextStrip.ws.environments[index].environmentId,
                                    key: contextStrip.ws.environments[index].key
                                })
                        }

                        ShellComboBox {
                            visible: contextStrip.wsReady && contextStrip.ws.envModeChangeable
                            implicitHeight: Theme.control.sm
                            iconSize: Theme.icon.sm
                            chevronSize: Theme.icon.sm
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Theme.type.meta.weight
                            hoverFill: composer.chipFill
                            iconName: contextStrip.envModeIcon
                            id: envModePicker
                            objectName: "envModePicker"
                            // A draft can go back to the worktree the project worked in last.
                            readonly property var previous: contextStrip.wsReady ? contextStrip.ws.previousWorktree ?? null : null
                            readonly property string currentLabel: contextStrip.wsReady ? contextStrip.ws.currentWorkspaceLabel ?? "" : ""
                            model: previous ? [currentLabel, qsTr("New worktree"), previous.label] : [currentLabel, qsTr("New worktree")]
                            currentIndex: contextStrip.wsReady && contextStrip.ws.envMode === "worktree" ? 1 : 0
                            Accessible.name: qsTr("Checkout mode")
                            onActivated: index => {
                                if (index === 2)
                                    Shell.dispatch("workspace.previousWorktree");
                                else
                                    Shell.dispatch("workspace.envMode.set", {
                                        mode: index === 1 ? "worktree" : "local"
                                    });
                            }
                        }

                        RowLayout {
                            id: envModeLocked
                            objectName: "envModeLocked"

                            readonly property string hint: contextStrip.wsReady ? contextStrip.ws.envModeHint ?? "" : ""

                            visible: contextStrip.wsReady && !contextStrip.ws.envModeChangeable
                            spacing: Theme.space.sm
                            Layout.leftMargin: Theme.space.sm
                            Accessible.description: hint

                            HoverHandler {
                                id: envModeLockedHover
                            }

                            ToolTip.visible: envModeLockedHover.hovered && hint.length > 0
                            ToolTip.text: hint

                            ShellIcon {
                                name: contextStrip.envModeIcon
                                size: Theme.icon.sm
                                color: composer.iconMuted
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Text {
                                objectName: "envModeLockedLabel"
                                text: contextStrip.wsReady ? contextStrip.ws.envModeLabel : ""
                                color: composer.secondary
                                font.pixelSize: Theme.type.meta.size
                                font.weight: Font.Medium
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        // PR badge.
                        AbstractButton {
                            id: prBadge

                            readonly property var pr: contextStrip.wsReady && contextStrip.ws.git ? contextStrip.ws.git.pullRequest : null
                            readonly property color prColor: pr === null ? "transparent" : pr.state === "merged" ? Theme.palette.color("merged", "#a855f7") : pr.state === "closed" ? Theme.palette.color("errorForeground", "#f87171") : Theme.palette.color("success", "#34d399")

                            visible: pr !== null && contextStrip.ws.canOpenPullRequest
                            text: pr ? "#" + pr.number : ""
                            Accessible.name: qsTr("%1 Open pull request").arg(text)
                            focusPolicy: Qt.TabFocus
                            implicitWidth: prLabel.implicitWidth + Theme.space.sm
                            implicitHeight: Theme.control.sm - Theme.space.xs
                            padding: 0
                            onClicked: Shell.dispatch("workspace.openPullRequest")

                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                            }

                            background: Rectangle {
                                radius: Theme.radiusXs
                                color: Qt.alpha(prBadge.prColor, 0.15)
                                border.color: Theme.palette.color("focus", "#3b82f6")
                                border.width: prBadge.visualFocus ? 1 : 0
                            }

                            contentItem: Text {
                                id: prLabel

                                text: prBadge.text
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: prBadge.prColor
                                font.pixelSize: Theme.type.caption.size
                                font.weight: Font.Medium
                            }
                        }

                        ShellButton {
                            id: branchButton
                            objectName: "branchButton"

                            visible: contextStrip.wsReady && (contextStrip.ws.branch !== null || contextStrip.ws.branchChangeable)
                            enabled: contextStrip.wsReady && contextStrip.ws.branchChangeable && !contextStrip.ws.branchSwitchPending
                            subtle: true
                            hoverFill: composer.chipFill
                            implicitHeight: Theme.control.sm
                            Layout.maximumWidth: Theme.control.md * 8
                            iconName: "git-branch"
                            iconSize: Theme.icon.sm
                            iconTint: Theme.palette.color("inkTertiary", "#8b919e")
                            tint: branchButton.hovered ? Theme.palette.color("inkSecondary", "#b8bdc7") : composer.branchColor
                            chevron: contextStrip.wsReady && contextStrip.ws.branchChangeable
                            chevronSize: Theme.icon.sm
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Theme.type.meta.weight
                            text: contextStrip.wsReady ? (contextStrip.ws.branch ?? qsTr("Pick branch")) : ""
                            Accessible.name: qsTr("Switch branch")
                            onClicked: branchPicker.open()

                            // "Copy branch name", on the secondary button
                            // (a finger has no buttons, and would count as it).
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onTapped: branchMenu.popup()
                            }
                            ShellMenu {
                                id: branchMenu

                                ShellMenuItem {
                                    objectName: "copyBranchName"
                                    text: qsTr("Copy branch name")
                                    iconName: "copy"
                                    enabled: contextStrip.wsReady && (contextStrip.ws.branch ?? "").length > 0
                                    onTriggered: Shell.dispatch("workspace.branch.copy")
                                }
                            }

                            Popup {
                                id: branchPicker
                                objectName: "branchPicker"

                                scale: Shell.state.layout?.zoom ?? 1
                                transformOrigin: Item.TopLeft
                                x: parent.width - width
                                y: -height - Theme.space.xs
                                width: 320
                                // The rows' height up to 368; a repo with one branch
                                // gets a short popup.
                                height: Math.min(368, branchColumn.implicitHeight + padding * 2)
                                padding: Theme.space.xs
                                // Opening loads the refs afresh, unfiltered.
                                onOpened: {
                                    branchSearch.text = "";
                                    branchSearch.forceActiveFocus();
                                    Shell.dispatch("workspace.branch.search", {
                                        query: ""
                                    });
                                }

                                enter: Transition {
                                    NumberAnimation {
                                        property: "opacity"
                                        from: 0
                                        to: 1
                                        duration: 120
                                        easing.type: Easing.OutCubic
                                    }
                                }

                                // Closing is instant: a fade could swallow the next open.
                                exit: null

                                background: ShellPopoverSurface {}

                                ColumnLayout {
                                    id: branchColumn

                                    // A Popup is no Item, so its name is on its content.
                                    Accessible.role: Accessible.Pane
                                    Accessible.name: qsTr("Branches")
                                    anchors.fill: parent
                                    spacing: Theme.space.xs

                                    ShellTextField {
                                        id: branchSearch

                                        Layout.fillWidth: true
                                        placeholderText: qsTr("Search or create a branch")
                                        Accessible.name: qsTr("Search or create a branch")
                                        onTextEdited: Shell.dispatch("workspace.branch.search", {
                                            query: text
                                        })
                                        Keys.onReturnPressed: {
                                            const name = text.trim();
                                            if (name.length === 0) {
                                                return;
                                            }
                                            const exact = contextStrip.ws.branches.find(ref => ref.name === name);
                                            Shell.dispatch(exact ? "workspace.branch.select" : "workspace.branch.create", {
                                                name: name
                                            });
                                            branchPicker.close();
                                        }

                                        background: Rectangle {
                                            color: "transparent"

                                            Rectangle {
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.bottom: parent.bottom
                                                height: 1
                                                color: Qt.alpha(composer.foreground, 0.08)
                                            }
                                        }
                                    }

                                    ListView {
                                        id: branchList

                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        Layout.preferredHeight: Math.max(contentHeight, 40)
                                        clip: true
                                        // Where the list was when it asked for more, so
                                        // the longer list opens at the same place.
                                        property real keptY: -1

                                        boundsBehavior: Flickable.StopAtBounds
                                        model: contextStrip.wsReady ? contextStrip.ws.branches : []
                                        // The end of a list with more to it loads the next page.
                                        onAtYEndChanged: {
                                            if (atYEnd && count > 0 && contextStrip.wsReady && contextStrip.ws.branchesTotal > count) {
                                                keptY = contentY;
                                                Shell.dispatch("workspace.branch.more");
                                            }
                                        }
                                        onCountChanged: {
                                            if (keptY >= 0) {
                                                contentY = keptY;
                                                keptY = -1;
                                            }
                                        }

                                        delegate: Rectangle {
                                            id: branchRow

                                            required property var modelData

                                            readonly property string badge: modelData.current ? qsTr("current") : modelData.isDefault ? qsTr("default") : modelData.isRemote ? qsTr("remote") : ""

                                            // Typing a ref's name and Enter picks it from the keyboard.
                                            Accessible.role: Accessible.ListItem
                                            Accessible.name: [branchRow.modelData.name, branchRow.badge].filter(part => part.length > 0).join(", ")
                                            Accessible.onPressAction: {
                                                Shell.dispatch("workspace.branch.select", {
                                                    name: branchRow.modelData.name
                                                });
                                                branchPicker.close();
                                            }
                                            width: ListView.view.width
                                            height: Theme.control.md
                                            radius: Theme.radiusSm
                                            color: rowHover.hovered ? composer.chipFill : "transparent"

                                            HoverHandler {
                                                id: rowHover
                                            }

                                            TapHandler {
                                                onTapped: {
                                                    Shell.dispatch("workspace.branch.select", {
                                                        name: branchRow.modelData.name
                                                    });
                                                    branchPicker.close();
                                                }
                                            }

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: Theme.space.sm
                                                anchors.rightMargin: Theme.space.sm
                                                spacing: Theme.space.sm

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: branchRow.modelData.name
                                                    color: branchRow.modelData.isRemote ? composer.muted : composer.foreground
                                                    font.pixelSize: Theme.type.body.size
                                                    elide: Text.ElideMiddle
                                                }

                                                Text {
                                                    visible: branchRow.badge.length > 0
                                                    text: branchRow.badge
                                                    color: composer.muted
                                                    font.pixelSize: Theme.type.caption.size
                                                }
                                            }
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: branchList.count === 0
                                            text: contextStrip.wsReady && contextStrip.ws.branchesLoading ? qsTr("Loading refs…") : qsTr("No matching refs — Enter creates one")
                                            color: composer.muted
                                            font.pixelSize: Theme.type.meta.size
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: Theme.space.sm
                                        Layout.bottomMargin: Theme.space.xs
                                        visible: contextStrip.wsReady && contextStrip.ws.branchesTotal > contextStrip.ws.branches.length
                                        text: contextStrip.wsReady ? qsTr("Showing %1 of %2 refs — type to narrow").arg(contextStrip.ws.branches.length).arg(contextStrip.ws.branchesTotal) : ""
                                        wrapMode: Text.Wrap
                                        color: composer.muted
                                        font.pixelSize: Theme.type.caption.size
                                    }

                                    // Only when picking the base of a new thread's new
                                    // worktree; the setting stays as it is.
                                    ColumnLayout {
                                        objectName: "startFromOriginRow"
                                        visible: contextStrip.wsReady && contextStrip.ws.isDraft && contextStrip.ws.envMode === "worktree" && !contextStrip.ws.worktreePath
                                        Layout.fillWidth: true
                                        Layout.leftMargin: Theme.space.sm
                                        Layout.rightMargin: Theme.space.xs
                                        Layout.bottomMargin: Theme.space.xs
                                        spacing: Theme.space.xxs

                                        RowLayout {
                                            Layout.fillWidth: true

                                            Text {
                                                Layout.fillWidth: true
                                                text: qsTr("Start from origin")
                                                color: composer.foreground
                                                font.pixelSize: Theme.type.meta.size
                                            }

                                            ShellSwitch {
                                                id: startFromOrigin
                                                objectName: "startFromOrigin"
                                                Accessible.name: qsTr("Start from origin")
                                                onToggled: Shell.dispatch("workspace.startFromOrigin.set", {
                                                    enabled: checked
                                                })

                                                Binding on checked {
                                                    value: contextStrip.wsReady && contextStrip.ws.startFromOrigin === true
                                                }
                                            }
                                        }

                                        Text {
                                            objectName: "startFromOriginHelp"
                                            Layout.fillWidth: true
                                            Layout.rightMargin: Theme.space.xs
                                            text: qsTr("Creates the worktree from the latest matching branch on origin instead of your local branch.")
                                            color: composer.muted
                                            wrapMode: Text.Wrap
                                            font.pixelSize: Theme.type.caption.size
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The toolbar's ghost chip, a button or (ChipPicker) a picker: one
    // height, body type, the secondary ink at rest.
    component Chip: ShellButton {
        subtle: true
        hoverFill: composer.chipFill
        tint: checked || hovered || down ? composer.foreground : composer.chipLabel
        iconSize: Theme.icon.md
        font.weight: Theme.type.body.weight
    }

    component ChipPicker: ShellComboBox {
        // Whether the model has this control at all; one it lacks never folds.
        property bool present: true
        // The labels the overflow menu offers.
        readonly property var choices: model

        hoverFill: composer.chipFill
        labelColor: hovered || down || popup.visible ? composer.foreground : composer.chipLabel
        font.weight: Theme.type.body.weight
    }

    Component {
        id: overflowMenuComponent

        ShellMenu {
            id: overflowMenu
            objectName: "composerOverflowMenu"

            // Everything built for this menu, destroyed with it.
            property var built: []

            // A press on the chip is its own: it closes the menu, not reopens
            // it. Not modal, so that press reaches the chip.
            modal: false
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
            onClosed: {
                if (composer.overflowMenu === overflowMenu) composer.overflowMenu = null;
                for (const object of built) object.destroy();
                built = [];
                overflowMenu.destroy();
            }
        }
    }

    Component {
        id: overflowSubmenuComponent

        ShellMenu {}
    }

    Component {
        id: overflowItemComponent

        ShellMenuItem {}
    }
}
