pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// The prompt: text input, model/effort/mode pickers, send/stop, with the
// checkout context strip welded under it. Rendered from Shell.state.composer
// and Shell.state.workspace; every change is dispatched back to
// ComposerController, which keeps the drafts and sends over the MC.
Rectangle {
    id: composer

    readonly property var model: Shell.state.composer ?? null
    readonly property var workspace: Shell.state.workspace ?? null
    // This machine's stashed prompts (ComposerController), newest first.
    readonly property var stashEntries: Shell.state.composerStash?.entries ?? []
    readonly property bool stashOpen: ready && Shell.state.composerStash?.open === true
    readonly property var attachments: ready ? (model.attachments ?? []) : []
    readonly property var citations: ready ? (model.citations ?? []) : []
    readonly property bool ready: model !== null && model.target !== null
    readonly property string publishedTarget: ready ? model.target : ""
    readonly property string publishedText: ready ? model.text : ""
    readonly property int publishedCursor: ready ? model.cursor : 0
    readonly property var suggestions: ready ? model.suggestions : []
    readonly property bool suggesting: ready && model.triggerKind !== null && (suggestions.length > 0 || model.suggestionsEmptyText !== null)
    readonly property color canvas: Theme.palette.color("canvas", "#0f0f12")
    readonly property color outline: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.05)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color secondary: Theme.palette.color("secondaryLabel", "#a1a1aa")
    readonly property color iconMuted: Theme.palette.color("iconMuted", "#8b8b93")
    readonly property color branchColor: Theme.palette.color("branchForeground", Qt.alpha(muted, 0.7))
    readonly property var effortOption: ready ? (model.options.find(option => option.type === "select") ?? null) : null
    // The model's other options, such as Claude's fast mode and context window.
    readonly property var otherOptions: ready ? model.options.filter(option => option !== effortOption) : []
    readonly property int maximumCardWidth: 768
    readonly property int gutter: 20

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
        input.remove(start, end);
        input.insert(start, text);
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
    // brick hosts those controls.
    Connections {
        target: Shell
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
                // anywhere else it moves there first, as the web's does.
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
        if (!picker || !picker.visible || !picker.enabled) return;
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
    // the draft is one a recall may replace.
    function stepPromptHistory(direction) {
        const caret = input.positionToRectangle(input.cursorPosition).y;
        const edge = input.positionToRectangle(direction === "backward" ? 0 : input.length).y;
        if (!composer.ready || caret !== edge) return;
        composer.flushText();
        Shell.dispatch("composer.history.step", {
            direction: direction
        });
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
    // named by its path.
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
        if (!composer.model.canSend && input.text.trim().length === 0 && composer.attachments.length === 0) {
            return;
        }
        textDebounce.stop();
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
        // caret it was last told about; they sit on the card's top edge.
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 22
            Layout.rightMargin: 22
            visible: composer.suggesting
            implicitHeight: visible ? Math.min(suggestionList.contentHeight, 240) + 8 : 0
            topLeftRadius: 16
            topRightRadius: 16
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: composer.outline
            border.width: 1

            ListView {
                id: suggestionList

                anchors.fill: parent
                anchors.margins: 4
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: composer.suggestions
                highlightMoveDuration: 0
                keyNavigationWraps: true

                delegate: Rectangle {
                    id: suggestion

                    required property var modelData
                    required property int index

                    width: ListView.view.width
                    height: 34
                    radius: 10
                    color: ListView.isCurrentItem ? Theme.palette.color("accentSurface", "#2a2a30") : suggestionHover.hovered ? Theme.palette.color("sidebarRowHover", "#1c1c21") : "transparent"

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
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8

                        Text {
                            text: suggestion.modelData.label
                            color: composer.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.Medium
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                            elide: Text.ElideMiddle
                            Layout.maximumWidth: parent.width * 0.5
                        }

                        Text {
                            Layout.fillWidth: true
                            text: suggestion.modelData.description
                            color: composer.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                            elide: Text.ElideMiddle
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: suggestionList.count === 0
                    text: composer.ready && composer.model.suggestionsEmptyText ? composer.model.suggestionsEmptyText : ""
                    color: composer.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        ComposerUsageLimits {
            Layout.fillWidth: true
            Layout.leftMargin: 22
            Layout.rightMargin: 22
        }

        // The stash (composer.stash), on the card's top edge like the
        // suggestions: a row restores its prompt, its cross deletes it.
        Rectangle {
            objectName: "stashList"
            Layout.fillWidth: true
            Layout.leftMargin: 22
            Layout.rightMargin: 22
            visible: composer.stashOpen && !composer.suggesting
            implicitHeight: visible ? stashHeader.height + Math.min(Math.max(stashList.contentHeight, 34), 240) + 8 : 0
            topLeftRadius: 16
            topRightRadius: 16
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: composer.outline
            border.width: 1

            RowLayout {
                id: stashHeader

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 4
                height: 30
                spacing: 8

                ShellIcon {
                    Layout.leftMargin: 8
                    name: "bookmark"
                    size: 14
                    color: composer.muted
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Stash")
                    color: composer.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                }

                Text {
                    text: composer.stashEntries.length
                    color: composer.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "stashClose"
                    subtle: true
                    iconName: "x"
                    iconSize: 14
                    implicitHeight: 24
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
                anchors.margins: 4
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
                    width: ListView.view.width
                    height: 34
                    radius: 10
                    color: ListView.isCurrentItem ? Theme.palette.color("accentSurface", "#2a2a30") : "transparent"

                    HoverHandler {
                        onHoveredChanged: if (hovered) stashList.currentIndex = stashRow.index
                    }

                    TapHandler {
                        onTapped: composer.restoreStash(stashRow.modelData.id)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 4
                        spacing: 8

                        ShellIcon {
                            name: "file-text"
                            size: 14
                            color: composer.muted
                        }

                        Text {
                            Layout.fillWidth: true
                            text: stashRow.modelData.snippet
                            color: composer.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                            elide: Text.ElideRight
                            Accessible.name: qsTr("Restore stashed prompt: %1").arg(text)
                        }

                        ShellButton {
                            objectName: "stashDelete-" + stashRow.index
                            subtle: true
                            iconName: "x"
                            iconSize: 14
                            implicitHeight: 24
                            Accessible.name: qsTr("Delete stashed prompt")
                            onClicked: Shell.dispatch("composer.stash.delete", { id: stashRow.modelData.id })
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: stashList.count === 0
                    width: parent.width - 24
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: (Shell.state.composerStash?.shortcut ?? "") !== ""
                        ? qsTr("Nothing stashed yet. Press %1 with a prompt in the composer to stash it.").arg(Shell.state.composerStash.shortcut)
                        : qsTr("Nothing stashed yet.")
                    color: composer.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        // The glass card.
        Rectangle {
            id: card

            Layout.fillWidth: true
            implicitHeight: cardColumn.implicitHeight
            z: 1
            radius: 22
            color: Theme.palette.color("surface", "#141416")
            border.color: composer.outline
            border.width: 1

            DropArea {
                anchors.fill: parent
                keys: ["text/uri-list"]
                onDropped: drop => {
                    if (drop.hasUrls) {
                        composer.attach(drop.urls);
                        drop.accept(Qt.CopyAction);
                    }
                }
            }

            ColumnLayout {
                id: cardColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 0

                // A queued message open for editing: sending saves it.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 10
                    Layout.topMargin: 8
                    visible: composer.ready && (composer.model.editingQueuedRunId ?? null) !== null
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Editing a queued message")
                        color: composer.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                    }

                    ShellButton {
                        objectName: "queuedEditCancel"
                        implicitHeight: 24
                        subtle: true
                        text: qsTr("Cancel")
                        onClicked: Shell.dispatch("composer.queue.edit.cancel")
                    }
                }

                // Attached images, terminal selections and quoted replies living on the draft.
                Flow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 12
                    visible: composer.ready && (composer.attachments.length > 0 || composer.model.terminalContexts.length > 0 || (composer.model.reviewComments ?? []).length > 0 || composer.citations.length > 0)
                    spacing: 6

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
                            onOpenRequested: Shell.dispatch("attachment.view", {
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
                            implicitHeight: 24
                            iconName: "message-square"
                            text: modelData.label
                            font.pixelSize: Math.round(12 * Theme.fontScale)
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
                            implicitHeight: 24
                            iconName: "terminal"
                            text: modelData.lineStart === modelData.lineEnd ? qsTr("%1 line %2").arg(modelData.label).arg(modelData.lineStart) : qsTr("%1 lines %2-%3").arg(modelData.label).arg(modelData.lineStart).arg(modelData.lineEnd)
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            Accessible.name: qsTr("Remove terminal selection %1").arg(text)
                            onClicked: Shell.dispatch("composer.terminalContext.remove", {
                                id: modelData.id
                            })
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
                            implicitHeight: 24
                            iconName: modelData.comment === null ? "quote" : "pencil"
                            text: preview.length > 40 ? preview.slice(0, 40) + "\u2026" : preview
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            Accessible.name: qsTr("Assistant quote: %1").arg(preview)
                            onClicked: citationEditor.open()

                            Popup {
                                id: citationEditor
                                objectName: "citationEditor"

                                scale: Shell.state.layout?.zoom ?? 1
                                transformOrigin: Item.BottomLeft
                                y: -height - 4
                                width: 360
                                padding: 10
                                onOpened: {
                                    citationComment.text = citationChip.modelData.comment ?? "";
                                    citationComment.forceActiveFocus();
                                }

                                background: Rectangle {
                                    color: Theme.palette.color("surfaceOverlay", "#18181b")
                                    border.color: Qt.alpha(composer.foreground, 0.1)
                                    radius: 10
                                }

                                contentItem: ColumnLayout {
                                    spacing: 8

                                    Text {
                                        Layout.fillWidth: true
                                        text: citationChip.modelData.text
                                        textFormat: Text.PlainText
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 6
                                        elide: Text.ElideRight
                                        color: composer.muted
                                        font.pixelSize: Math.round(12 * Theme.fontScale)
                                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
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
                                        spacing: 6

                                        ShellButton {
                                            objectName: "citationRemove"
                                            implicitHeight: 24
                                            subtle: true
                                            text: qsTr("Remove quote")
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
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
                                            implicitHeight: 24
                                            primary: true
                                            text: qsTr("Save")
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
                                            onClicked: citationChip.saveComment()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 16
                    Layout.bottomMargin: 8
                    Layout.preferredHeight: composer.resting ? Math.min(input.implicitHeight, 24) : Math.min(Math.max(input.implicitHeight, 54), 184)
                    clip: true

                    TextArea {
                        id: input
                        objectName: "input"

                        // ShellWindow reads it for the keymap's composerFocus.
                        readonly property bool composerInput: true

                        // A resting composer comes back when the user turns to it.
                        onActiveFocusChanged: if (activeFocus) composer.scrollCollapsed = false
                        onPressed: composer.scrollCollapsed = false

                        padding: 0
                        enabled: composer.ready && !composer.model.editorDisabled
                        placeholderText: composer.ready ? composer.model.placeholder : qsTr("Open a thread to start")
                        placeholderTextColor: composer.muted
                        color: composer.foreground
                        wrapMode: TextEdit.Wrap
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
                            if (event.key === Qt.Key_V && (event.modifiers & ~Qt.ShiftModifier) === Qt.ControlModifier) {
                                event.accepted = composer.paste((event.modifiers & Qt.ShiftModifier) !== 0);
                                if (event.accepted) return;
                            } else if (event.matches(StandardKey.Paste)) {
                                // Shift+Insert and the platform's other paste keys.
                                event.accepted = composer.paste(false);
                                if (event.accepted) return;
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
                            if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down) && event.modifiers === Qt.NoModifier) {
                                composer.stepPromptHistory(event.key === Qt.Key_Up ? "backward" : "forward");
                                return;
                            }
                            if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) {
                                return;
                            }
                            const intent = composer.enterIntent(event.modifiers);
                            if (intent === "") {
                                return;
                            }
                            event.accepted = true;
                            composer.submit(intent);
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.bottomMargin: 16
                    spacing: 4

                    ShellButton {
                        subtle: true
                        iconName: "paperclip"
                        iconSize: 16
                        iconTint: composer.iconMuted
                        Layout.leftMargin: -10
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

                    ModelPicker {
                        id: modelPicker
                        objectName: "modelPicker"

                        Layout.fillWidth: true
                        Layout.minimumWidth: 72
                        Layout.maximumWidth: Math.min(implicitWidth, 224)
                        enabled: composer.ready && instances.length > 0
                        selectedInstanceId: composer.ready ? composer.model.selectedInstanceId : null
                        selectedModel: composer.ready ? composer.model.selectedModel : null
                    }

                    Separator {
                        visible: composer.effortOption !== null
                    }

                    ShellComboBox {
                        id: effortPicker
                        objectName: "effortPicker"

                        visible: composer.effortOption !== null
                        model: composer.effortOption ? composer.effortOption.choices.map(choice => choice.label) : []
                        currentIndex: composer.effortOption ? composer.effortOption.choices.findIndex(choice => choice.id === composer.effortOption.value) : -1
                        displayText: currentIndex < 0 ? (composer.effortOption ? composer.effortOption.label : "") : currentText
                        Accessible.name: composer.effortOption ? composer.effortOption.label : ""
                        onActivated: index => Shell.dispatch("composer.option.set", {
                                id: composer.effortOption.id,
                                value: composer.effortOption.choices[index].id
                            })
                    }

                    Repeater {
                        model: composer.otherOptions

                        delegate: RowLayout {
                            id: optionItem

                            required property var modelData
                            readonly property bool select: modelData.type === "select"

                            spacing: 4

                            Separator {}

                            ShellComboBox {
                                objectName: "optionPicker:" + optionItem.modelData.id

                                visible: optionItem.select
                                model: optionItem.select ? optionItem.modelData.choices.map(choice => choice.label) : []
                                currentIndex: optionItem.select ? optionItem.modelData.choices.findIndex(choice => choice.id === optionItem.modelData.value) : -1
                                displayText: currentIndex < 0 ? optionItem.modelData.label : currentText
                                Accessible.name: optionItem.modelData.label
                                onActivated: index => Shell.dispatch("composer.option.set", {
                                        id: optionItem.modelData.id,
                                        value: optionItem.modelData.choices[index].id
                                    })
                            }

                            ShellButton {
                                objectName: "optionToggle:" + optionItem.modelData.id

                                visible: !optionItem.select
                                subtle: true
                                checkable: true
                                checked: optionItem.modelData.value === true
                                tint: checked ? composer.foreground : composer.secondary
                                text: optionItem.modelData.label
                                font.pixelSize: Math.round(14 * Theme.fontScale)
                                leftPadding: 10
                                rightPadding: 10
                                onClicked: Shell.dispatch("composer.option.set", {
                                    id: optionItem.modelData.id,
                                    value: checked
                                })
                            }
                        }
                    }

                    Separator {}

                    ShellComboBox {
                        id: runtimeModePicker
                        objectName: "runtimeModePicker"

                        iconName: composer.ready ? composer.runtimeIcon(composer.model.runtimeMode) : "lock"
                        enabled: composer.ready
                        model: composer.ready ? composer.model.runtimeModes.map(mode => mode.label) : []
                        currentIndex: composer.ready ? composer.model.runtimeModes.findIndex(mode => mode.value === composer.model.runtimeMode) : -1
                        Accessible.name: qsTr("Permissions")
                        onActivated: index => Shell.dispatch("composer.runtimeMode.set", {
                                mode: composer.model.runtimeModes[index].value
                            })
                    }

                    Separator {
                        visible: planToggle.visible
                    }

                    ShellButton {
                        id: planToggle
                        objectName: "planToggle"

                        subtle: true
                        visible: composer.ready && composer.model.showInteractionModeToggle
                        checkable: true
                        checked: composer.ready && composer.model.interactionMode === "plan"
                        iconName: checked ? "pencil-ruler" : "bot"
                        iconSize: 16
                        iconTint: checked ? composer.foreground : composer.secondary
                        tint: checked ? composer.foreground : composer.secondary
                        text: checked ? qsTr("Plan") : qsTr("Build")
                        font.pixelSize: Math.round(14 * Theme.fontScale)
                        leftPadding: 10
                        rightPadding: 10
                        onClicked: Shell.dispatch("composer.interactionMode.set", {
                            mode: checked ? "plan" : "default"
                        })
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    Text {
                        objectName: "vimMode"
                        visible: composer.vimKeys
                        text: vim.modeLabel
                        color: composer.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                        Accessible.name: qsTr("Vim mode: %1").arg(text)
                    }

                    // The stash's count, which opens and closes its list.
                    ShellButton {
                        objectName: "stashBadge"
                        visible: composer.ready && composer.stashEntries.length > 0
                        subtle: true
                        iconName: "bookmark"
                        iconSize: 14
                        iconTint: composer.iconMuted
                        text: composer.stashEntries.length
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        Accessible.name: qsTr("Stashed prompts: %1. Open stash.").arg(composer.stashEntries.length)
                        onClicked: Shell.dispatch("composer.stash.menu")
                    }

                    // Approvals and the plan's Implement live in TurnRequests above.

                    // Round send / stop.
                    AbstractButton {
                        id: primaryAction
                        objectName: "primaryAction"

                        readonly property bool stopMode: composer.ready && composer.model.isRunning && input.text.trim().length === 0 && composer.attachments.length === 0
                        // A send during a turn joins it or waits behind it, per the
                        // follow-up setting; the button says which before the click.
                        readonly property string followUp: composer.model?.isRunning && !stopMode ? (composer.model.followUpBehavior ?? "steer") : ""

                        implicitWidth: 32
                        implicitHeight: 32
                        enabled: composer.ready && (stopMode || composer.model?.canSend || input.text.trim().length > 0 || composer.attachments.length > 0)
                        hoverEnabled: true
                        opacity: enabled ? 1 : 0.3
                        scale: down ? 0.97 : hovered ? 1.05 : 1
                        Accessible.role: Accessible.Button
                        Accessible.name: stopMode ? qsTr("Stop") : followUp === "steer" ? qsTr("Steer") : followUp === "queue" ? qsTr("Queue") : qsTr("Send")
                        ToolTip.visible: hovered && followUp.length > 0
                        ToolTip.delay: 400
                        ToolTip.text: followUp === "steer"
                            ? qsTr("Steer the running turn (%1+Enter to queue)").arg(Qt.platform.os === "osx" ? "⌘" : "Ctrl")
                            : qsTr("Queue after the running turn (%1+Enter to steer)").arg(Qt.platform.os === "osx" ? "⌘" : "Ctrl")
                        onClicked: stopMode ? Shell.dispatch("composer.interrupt") : composer.submit("foreground")

                        Behavior on scale {
                            NumberAnimation {
                                duration: 120
                                easing.type: Easing.OutCubic
                            }
                        }

                        background: Rectangle {
                            radius: 16
                            color: primaryAction.stopMode ? Qt.alpha(Theme.palette.color("error", "#ef4444"), 0.9) : Theme.palette.color("messageAction", "#2563eb")

                            Behavior on color {
                                ColorAnimation {
                                    duration: 120
                                }
                            }
                        }

                        contentItem: Item {
                            ShellIcon {
                                anchors.centerIn: parent
                                visible: !primaryAction.stopMode
                                name: primaryAction.followUp === "steer" ? "corner-down-right" : primaryAction.followUp === "queue" ? "list-plus" : "arrow-up"
                                size: 16
                                strokeWidth: 2.5
                                color: Theme.palette.color("messageActionForeground", "#ffffff")
                            }

                            Rectangle {
                                anchors.centerIn: parent
                                visible: primaryAction.stopMode
                                width: 11
                                height: 11
                                radius: 2
                                color: Theme.palette.color("errorForeground", "#ffffff")
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
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.bottomMargin: visible ? 16 : 0
                    // A layout's own controls, or a plugin's.
                    visible: children.length > 1 || actionsSlot.shown.length > 0
                    spacing: 6

                    PluginSlot {
                        id: actionsSlot

                        objectName: "composerActionsSlot"
                        name: "composer.actions"
                        mode: "append"
                        visible: shown.length > 0
                    }
                }
            }
        }

        // Context strip: environment, checkout mode, PR, branch — welded under
        // the card and tucked 16px beneath it.
        Item {
            id: contextStrip

            readonly property var ws: composer.workspace
            readonly property bool wsReady: ws !== null
            readonly property string envModeIcon: !wsReady ? "folder" : ws.envMode === "worktree" ? "folder-git-2" : "folder-git"

            Layout.fillWidth: true
            Layout.leftMargin: 22
            Layout.rightMargin: 22
            Layout.topMargin: -16
            implicitHeight: 16 + 4 + 24 + 4
            visible: wsReady && (composer.model?.showContextStrip ?? true) && !composer.resting

            Rectangle {
                anchors.fill: parent
                bottomLeftRadius: 16
                bottomRightRadius: 16
                color: "transparent"
                border.color: composer.outline
                border.width: 1
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 8
                anchors.topMargin: 20
                anchors.bottomMargin: 4
                spacing: 8

                ShellComboBox {
                    id: hostPicker
                    objectName: "hostPicker"

                    visible: contextStrip.wsReady && contextStrip.ws.environments.length > 1
                    implicitHeight: 24
                    leftPadding: 7 + iconSize + 6
                    rightPadding: 7 + chevronSize + 4
                    iconSize: 12
                    chevronSize: 12
                    font.pixelSize: Math.round(12 * Theme.fontScale)
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

                Separator {
                    visible: contextStrip.wsReady && contextStrip.ws.environments.length > 1
                    implicitHeight: 14
                }

                ShellComboBox {
                    visible: contextStrip.wsReady && contextStrip.ws.envModeChangeable
                    implicitHeight: 24
                    leftPadding: 7 + iconSize + 6
                    rightPadding: 7 + chevronSize + 4
                    iconSize: 12
                    chevronSize: 12
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    iconName: contextStrip.envModeIcon
                    id: envModePicker
                    objectName: "envModePicker"
                    // A draft can go back to the worktree the project worked in last.
                    readonly property var previous: contextStrip.wsReady ? contextStrip.ws.previousWorktree ?? null : null
                    model: previous ? [qsTr("Current checkout"), qsTr("New worktree"), previous.label] : [qsTr("Current checkout"), qsTr("New worktree")]
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
                    visible: contextStrip.wsReady && !contextStrip.ws.envModeChangeable
                    spacing: 6
                    Layout.leftMargin: 7

                    ShellIcon {
                        name: contextStrip.envModeIcon
                        size: 12
                        color: composer.iconMuted
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Text {
                        text: contextStrip.wsReady ? contextStrip.ws.envModeLabel : ""
                        color: composer.secondary
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: Font.Medium
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                // PR badge.
                Rectangle {
                    readonly property var pr: contextStrip.wsReady && contextStrip.ws.git ? contextStrip.ws.git.pullRequest : null
                    readonly property color prColor: pr === null ? "transparent" : pr.state === "merged" ? Theme.palette.color("info", "#a78bfa") : pr.state === "closed" ? Theme.palette.color("error", "#f87171") : Theme.palette.color("success", "#34d399")

                    visible: pr !== null && contextStrip.ws.canOpenPullRequest
                    implicitWidth: prLabel.implicitWidth + 8
                    implicitHeight: 18
                    radius: 4
                    color: Qt.alpha(prColor, 0.15)

                    HoverHandler {
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: Shell.dispatch("workspace.openPullRequest")
                    }

                    Text {
                        id: prLabel

                        anchors.centerIn: parent
                        text: parent.pr ? "#" + parent.pr.number : ""
                        color: parent.prColor
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.Medium
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                    }
                }

                ShellButton {
                    id: branchButton
                    objectName: "branchButton"

                    visible: contextStrip.wsReady && (contextStrip.ws.branch !== null || contextStrip.ws.branchChangeable)
                    enabled: contextStrip.wsReady && contextStrip.ws.branchChangeable && !contextStrip.ws.branchSwitchPending
                    subtle: true
                    implicitHeight: 24
                    leftPadding: 7
                    rightPadding: 7
                    Layout.maximumWidth: 240
                    iconName: "git-branch"
                    iconSize: 12
                    iconTint: Qt.alpha(composer.iconMuted, 0.7)
                    tint: branchButton.hovered ? Qt.alpha(composer.foreground, 0.8) : composer.branchColor
                    chevron: contextStrip.wsReady && contextStrip.ws.branchChangeable
                    chevronSize: 12
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    text: contextStrip.wsReady ? (contextStrip.ws.branch ?? qsTr("Pick branch")) : ""
                    Accessible.name: qsTr("Switch branch")
                    onClicked: branchPicker.open()

                    // The web's "Copy branch name", on the secondary button
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
                        y: -height - 4
                        width: 320
                        height: 360
                        padding: 4
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

                        exit: Transition {
                            NumberAnimation {
                                property: "opacity"
                                from: 1
                                to: 0
                                duration: 90
                            }
                        }

                        background: Rectangle {
                            color: Theme.palette.color("surfaceOverlay", "#18181b")
                            border.color: Qt.alpha(composer.foreground, 0.1)
                            radius: 10
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 4

                            ShellTextField {
                                id: branchSearch

                                Layout.fillWidth: true
                                placeholderText: qsTr("Search or create a branch")
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

                                    width: ListView.view.width
                                    height: 28
                                    radius: 6
                                    color: rowHover.hovered ? Theme.palette.color("accentSurface", "#1c1c21") : "transparent"

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
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        spacing: 8

                                        Text {
                                            Layout.fillWidth: true
                                            text: branchRow.modelData.name
                                            color: branchRow.modelData.isRemote ? composer.muted : composer.foreground
                                            font.pixelSize: Math.round(13 * Theme.fontScale)
                                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                                            elide: Text.ElideMiddle
                                        }

                                        Text {
                                            visible: branchRow.badge.length > 0
                                            text: branchRow.badge
                                            color: Qt.alpha(composer.muted, 0.45)
                                            font.pixelSize: Math.round(10 * Theme.fontScale)
                                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                                        }
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: branchList.count === 0
                                    text: contextStrip.wsReady && contextStrip.ws.branchesLoading ? qsTr("Loading refs…") : qsTr("No matching refs — Enter creates one")
                                    color: composer.muted
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 8
                                Layout.bottomMargin: 4
                                visible: contextStrip.wsReady && contextStrip.ws.branchesTotal > contextStrip.ws.branches.length
                                text: contextStrip.wsReady ? qsTr("Showing %1 of %2 refs — type to narrow").arg(contextStrip.ws.branches.length).arg(contextStrip.ws.branchesTotal) : ""
                                color: composer.muted
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }
                        }
                    }
                }
            }
        }
    }

    component Separator: Rectangle {
        implicitWidth: 1
        implicitHeight: 16
        Layout.alignment: Qt.AlignVCenter
        Layout.leftMargin: 2
        Layout.rightMargin: 2
        color: Theme.palette.color("border", "#27272a")
    }
}
