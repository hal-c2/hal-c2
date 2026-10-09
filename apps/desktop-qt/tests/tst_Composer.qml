import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

Item {
    id: root
    width: 900
    height: 700

    // The keymap arrives as window shortcuts (ShellWindow), mod+Enter
    // and mod+alt+Enter among them.
    property int stolenChords: 0
    Shortcut {
        sequences: ["Ctrl+Alt+Return", "Ctrl+Return", "Meta+Return"]
        context: Qt.WindowShortcut
        onActivated: root.stolenChords++
    }

    Component {
        id: composerComponent

        Composer {
            width: 800
            height: 650
        }
    }

    TestCase {
        name: "ComposerTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_inputAcceptsText() {
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.focus = true;
            input.text = qsTr("Draft message");
            compare(input.text, qsTr("Draft message"));
            input.text = qsTr("12345");
            compare(input.text, qsTr("12345"));
            input.text = qsTr("Plan & review (v2)");
            compare(input.text, qsTr("Plan & review (v2)"));
        }

        function test_eachModelOptionShowsOnce() {
            // The real composer state is a QVariantMap: each read of options
            // hands out fresh objects, so the options are built per read here too.
            const options = () => [
                { id: "reasoningEffort", label: "Reasoning", type: "select", value: "high", choices: [{ id: "low", label: "Low" }, { id: "high", label: "High" }] },
                { id: "contextWindow", label: "Context", type: "select", value: "1m", choices: [{ id: "1m", label: "1M" }] },
                { id: "fastMode", label: "Fast Mode", type: "boolean", value: false, choices: [] }
            ];
            const state = Object.assign({}, Shell.defaultComposer());
            Object.defineProperty(state, "options", { get: options, enumerable: true });
            Shell.state = { composer: state, workspace: null };
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!findChild(composer, "effortPicker"));
            verify(!findChild(composer, "optionPicker:reasoningEffort"), "the effort is not repeated");
            verify(!!findChild(composer, "optionPicker:contextWindow"));
            verify(!!findChild(composer, "optionToggle:fastMode"));
        }

        function test_aTriggerWithNothingToOfferSaysSo() {
            const empty = "No skills found. Try / to browse provider commands.";
            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), {
                triggerKind: "skill", suggestions: [], suggestionsEmptyText: empty
            }), workspace: null };
            let composer = createTemporaryObject(composerComponent, root);
            const label = findChild(composer, "suggestionsEmpty");
            verify(label.visible);
            compare(label.text, empty);
            verify(label.height > 0);
            // The box around it holds the label, not a sliver.
            const box = label.parent;
            verify(box.height >= label.height + 16, "box " + box.height + " label " + label.height);
            verify(label.y >= 0 && label.y + label.height <= box.height);
        }

        function test_theBranchPickerSizesToItsBranches() {
            const branches = n => Array.from({ length: n }, (_, i) => ({ name: "b" + i, current: i === 0, isDefault: false, isRemote: false }));
            const workspace = n => ({
                environments: [], activeEnvironmentId: "here", environmentChangeable: false, envMode: "local",
                envModeLabel: "Local", envModeChangeable: false, git: null, canOpenPullRequest: false,
                branch: "b0", branchChangeable: true, branchSwitchPending: false, branches: branches(n),
                branchesTotal: n, branchesLoading: false
            });
            let composer = createTemporaryObject(composerComponent, root);
            const picker = findChild(composer, "branchPicker");
            Shell.state = Object.assign({}, Shell.state, { workspace: workspace(1) });
            picker.open();
            tryCompare(picker, "opened", true);
            verify(picker.height < 120, "one branch: " + picker.height);
            Shell.state = Object.assign({}, Shell.state, { workspace: workspace(40) });
            tryCompare(picker, "height", 368);
            picker.close();
        }

        function test_wrappedToolbarLinesDoNotOpenWithABar() {
            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), {
                options: [
                    { id: "reasoningEffort", label: "Reasoning", type: "select", value: "high", choices: [{ id: "high", label: "High" }] },
                    { id: "fastMode", label: "Fast Mode", type: "boolean", value: true, choices: [] }
                ],
                runtimeModes: [{ value: "full-access", label: "Full access" }], runtimeMode: "full-access",
                showInteractionModeToggle: true
            }), workspace: null };
            let composer = createTemporaryObject(composerComponent, root, { width: 300 });
            waitForRendering(composer);
            const flow = findChild(composer, "toolbarControls");
            verify(!!flow);
            let lines = new Set();
            for (let i = 0; i < flow.children.length; ++i) {
                const chunk = flow.children[i];
                if (!chunk.visible) continue;
                lines.add(chunk.y);
                for (let j = 0; j < chunk.children.length; ++j) {
                    const bar = chunk.children[j];
                    if (bar.objectName === "toolbarSeparator" && chunk.x === 0) compare(bar.opacity, 0);
                    else if (bar.objectName === "toolbarSeparator") compare(bar.opacity, 1);
                }
            }
            verify(lines.size > 1, "the toolbar wrapped");
            const send = findChild(composer, "primaryAction");
            const last = Math.max(...Array.from(lines));
            const lastBottom = flow.mapToItem(composer, 0, last).y + 32;
            const sendBottom = send.mapToItem(composer, 0, 0).y + send.height;
            verify(Math.abs(sendBottom - lastBottom) < 16, "Send sits by the last line");
        }

        function test_fastModeSaysItIsOn() {
            const state = fast => ({ composer: Object.assign({}, Shell.defaultComposer(), {
                options: [{ id: "fastMode", label: "Fast Mode", type: "boolean", value: fast, choices: [] }]
            }), workspace: null });
            Shell.state = state(true);
            let composer = createTemporaryObject(composerComponent, root);
            const toggle = findChild(composer, "optionToggle:fastMode");
            compare(toggle.iconName, "zap");
            verify(toggle.Accessible.name.indexOf("Fast Mode, on") >= 0);
            Shell.state = state(false);
            compare(toggle.iconName, "");
            verify(toggle.Accessible.name.indexOf("Fast Mode, off") >= 0);
        }

        function test_submitKeepsDraftUntilPageClearsIt() {
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            const draft = qsTr("Keep 123 & retry");
            input.focus = true;
            input.text = draft;
            tryCompare(composer, "publishedText", draft);

            composer.submit("foreground");

            compare(input.text, draft);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].action, "composer.submit");

            Shell.publishComposerText("", 0);
            tryCompare(input, "text", "");
        }

        function test_sendDuringTurnFollowsFollowUpSetting() {
            let composer = createTemporaryObject(composerComponent, root);
            let input = findChild(composer, "input");
            let primary = findChild(composer, "primaryAction");
            verify(!!input && !!primary, "Objects exist");
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, { isRunning: true, followUpBehavior: "queue" })
            });
            compare(primary.Accessible.name, "Stop");

            input.text = "Also check the tests";
            compare(primary.Accessible.name, "Queue");
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, { followUpBehavior: "steer" })
            });
            compare(primary.Accessible.name, "Steer");

            mouseClick(primary);
            const sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.submit");
            compare(sent.payload.intent, "foreground");
        }

        function test_enterFollowsThePagesSendKeys() {
            let composer = createTemporaryObject(composerComponent, root);
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.forceActiveFocus();
            input.text = "Start a side thread";
            // The Control key, which Qt calls Meta on macOS.
            const ctrl = Qt.platform.os === "osx" ? Qt.MetaModifier : Qt.ControlModifier;
            keyClick(Qt.Key_Return, ctrl | Qt.AltModifier);
            let sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.submit");
            compare(sent.payload.intent, "background");
            compare(root.stolenChords, 0);

            // A chord the composer does not send with is a newline.
            const count = Shell.dispatchCount;
            keyClick(Qt.Key_Return, Qt.ShiftModifier);
            verify(Shell.dispatchedActions.slice(count).every(entry => entry.action !== "composer.submit"));

            // Send with mod+Enter once the draft has several lines.
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    isRunning: true,
                    enterIntents: { singleLine: { "": "foreground", ctrl: "alternate" }, multiline: { ctrl: "alternate" } }
                })
            });
            input.text = "Steer this\nwith two lines";
            input.cursorPosition = input.text.length;
            keyClick(Qt.Key_Return);
            verify(Shell.dispatchedActions.slice(count).every(entry => entry.action !== "composer.submit"));
            keyClick(Qt.Key_Return, ctrl);
            sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.submit");
            compare(sent.payload.intent, "alternate");
            compare(root.stolenChords, 0);
        }

        function test_terminalExcerptChipNamesItsLinesAndRemovesIt() {
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    terminalContexts: [{ id: "tc-1", label: "Terminal 1", lineStart: 3, lineEnd: 5 }, { id: "tc-2", label: "Terminal 2", lineStart: 7, lineEnd: 7 }]
                })
            });
            const composer = createTemporaryObject(composerComponent, root);
            const range = findChild(composer, "terminalContext-tc-1");
            verify(!!range);
            compare(range.text, "Terminal 1 lines 3-5");
            compare(findChild(composer, "terminalContext-tc-2").text, "Terminal 2 line 7");
            mouseClick(range);
            const sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.terminalContext.remove");
            compare(sent.payload.id, "tc-1");
        }

        function test_quotedReplyChipTakesACommentAndRemoves() {
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    citations: [{ id: "q-1", text: "Refunds reuse\nthe old rate.", comment: null }, { id: "q-2", text: "Cache keys", comment: "too slow?" }]
                })
            });
            const composer = createTemporaryObject(composerComponent, root);
            const chip = findChild(composer, "citation-q-1");
            verify(!!chip);
            compare(chip.text, "Refunds reuse the old rate.");
            compare(findChild(composer, "citation-q-2").text, "too slow?");
            mouseClick(chip);
            const comment = findChild(chip, "citationComment");
            tryCompare(comment, "activeFocus", true);
            comment.text = "is this still true?";
            keyClick(Qt.Key_Return);
            let sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.citation.comment");
            compare(sent.payload.id, "q-1");
            compare(sent.payload.comment, "is this still true?");
            mouseClick(chip);
            const remove = findChild(chip, "citationRemove");
            tryVerify(() => remove.visible);
            mouseClick(remove);
            sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.citation.remove");
            compare(sent.payload.id, "q-1");
        }

        // Scenario: The draft shows the images attached to it
        function test_attachedImageShowsItsThumbnailAndRemovesIt() {
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    attachments: [{ id: "image-1", name: "cart.png", preview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" }]
                })
            });
            const composer = createTemporaryObject(composerComponent, root);
            const image = findChild(composer, "attachment-image-1");
            verify(!!image);
            tryVerify(() => image.pictured, 2000, "the thumbnail is drawn");
            mouseClick(image, image.width - 8, 8);
            const sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.attachment.remove");
            compare(sent.payload.id, "image-1");
        }

        function test_textDispatchIncludesTarget() {
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");

            input.text = qsTr("Scoped edit 123");

            tryCompare(Shell, "dispatchCount", 1);
            compare(Shell.dispatchedActions[0].action, "composer.text.set");
            compare(Shell.dispatchedActions[0].payload.target, "thread-a");
        }

        function test_targetSwitchDropsPendingDraftEdit() {
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");

            input.text = qsTr("Belongs to thread A");
            Shell.publishComposerTarget("thread-b", "", 0);

            wait(180);
            compare(Shell.dispatchCount, 0);
            compare(input.text, "");
        }

        function test_echoPreservesEditStillWaitingForDebounce() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.focus = true;
            input.text = qsTr("Sent");
            composer.flushText();
            input.text = qsTr("Sent + local");
            input.cursorPosition = input.text.length;

            Shell.publishComposerText(qsTr("Sent"), 4, Shell.dispatchedActions[0].payload.edit);
            compare(input.text, qsTr("Sent + local"));
            compare(input.cursorPosition, 12);
            composer.flushText();
            compare(Shell.dispatchedActions[1].payload.text, qsTr("Sent + local"));
        }

        function test_coalescedEchoThenPageEdit() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.text = qsTr("First");
            composer.flushText();
            input.text = qsTr("Second");
            composer.flushText();
            input.cursorPosition = 2;

            Shell.publishComposerText(qsTr("Second"), 6, Shell.dispatchedActions[1].payload.edit);
            compare(input.text, qsTr("Second"));
            compare(input.cursorPosition, 2);
            // A later page edit may legitimately restore an earlier value.
            Shell.publishComposerText(qsTr("First"), 3);
            compare(input.text, qsTr("First"));
            compare(input.cursorPosition, 3);
        }

        function test_targetSwitchRetiresPreviousEditRevisions() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.text = qsTr("Thread A edit");
            composer.flushText();
            Shell.publishComposerTarget("thread-b", qsTr("Thread B draft"), 4);
            compare(input.text, qsTr("Thread B draft"));
            compare(input.cursorPosition, 4);
            // This helper publishes an external edit for the current target B.
            // The old target's outstanding revision must not suppress it.
            Shell.publishComposerText(qsTr("Thread B page edit"), 2);
            compare(input.text, qsTr("Thread B page edit"));
            compare(input.cursorPosition, 2);
        }

        function test_repeatedTextDoesNotAcknowledgeAnOlderEdit() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            for (const text of ["First", "Second", "First"]) {
                input.text = text;
                composer.flushText();
            }
            input.cursorPosition = 2;

            Shell.publishComposerText("First", 5, Shell.dispatchedActions[0].payload.edit);
            Shell.publishComposerText("Second", 6, Shell.dispatchedActions[1].payload.edit);
            compare(input.text, "First");
            compare(input.cursorPosition, 2);
            Shell.publishComposerText("First", 5, Shell.dispatchedActions[2].payload.edit);
            Shell.publishComposerText("", 0);
            compare(input.text, "");
        }

        function test_coalescedEchoReturningToInitialText() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.text = "Temporary";
            composer.flushText();
            input.text = "";
            composer.flushText();

            Shell.publishComposerText("", 0, Shell.dispatchedActions[1].payload.edit);
            Shell.publishComposerText("Page replacement", 4);
            compare(input.text, "Page replacement");
            compare(input.cursorPosition, 4);
        }

        function test_legacyPageCanStillClearAfterSubmit() {
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.text = "Legacy draft";
            composer.submit("foreground");

            // Remove the field entirely, as pages predating revisions do.
            const state = JSON.parse(JSON.stringify(Shell.state));
            delete state.composer.edit;
            state.composer.text = "";
            state.composer.cursor = 0;
            Shell.state = state;
            compare(input.text, "");
        }

        function test_delayedEchoPreservesNewerTextAndSubmit() {
            Shell.echoTextEdits = false;
            let composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            let input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.focus = true;
            input.text = qsTr("First edit");
            input.cursorPosition = input.text.length;
            composer.flushText();
            input.text = qsTr("First edit + 123");
            input.cursorPosition = input.text.length;
            composer.flushText();
            compare(Shell.dispatchCount, 2);

            Shell.publishComposerText(qsTr("First edit"), 10, Shell.dispatchedActions[0].payload.edit);
            compare(input.text, qsTr("First edit + 123"));
            compare(input.cursorPosition, 16);

            composer.submit("foreground");
            compare(Shell.dispatchedActions[2].payload.text, qsTr("First edit + 123"));
            Shell.publishComposerText(qsTr("First edit + 123"), 16, Shell.dispatchedActions[1].payload.edit);
            compare(input.text, qsTr("First edit + 123"));
            Shell.publishComposerText("", 0, Shell.dispatchedActions[2].payload.edit);
            compare(input.text, "");
        }

        // The edit-queued key reaches the queue from the start of the draft
        // and moves the caret there from anywhere else.
        function test_editQueuedKeyFromTheStartOfTheDraft() {
            let composer = createTemporaryObject(composerComponent, root);
            let input = findChild(composer, "input");
            input.forceActiveFocus();
            input.text = "draft";
            input.cursorPosition = 3;
            Shell.actionRequested("composer.queue.editLast", undefined);
            compare(input.cursorPosition, 0);
            verify(!Shell.dispatchedActions.some(entry => entry.action === "composer.queue.edit"));
            Shell.actionRequested("composer.queue.editLast", undefined);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].action, "composer.queue.edit");
        }

        function test_editingAQueuedMessageCanBeCancelled() {
            let composer = createTemporaryObject(composerComponent, root);
            let cancel = findChild(composer, "queuedEditCancel");
            verify(!cancel.visible);
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, { editingQueuedRunId: "run-2" })
            });
            waitForRendering(composer);
            verify(cancel.visible);
            mouseClick(cancel);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].action, "composer.queue.edit.cancel");
        }
    }
}
