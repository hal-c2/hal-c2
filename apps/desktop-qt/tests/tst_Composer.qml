import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import "../qml/HalC2/Bricks/js/providerIcons.js" as ProviderIcons
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

        // A click anywhere in the input area, the band under a short prompt
        // included, puts the caret in the prompt, whatever had focus.
        function test_aClickInTheInputAreaFocusesThePrompt_data() {
            return [
                { tag: "on the text", at: input => input.mapToItem(root, 4, input.height / 2) },
                { tag: "the scroll view's bottom edge", at: input => input.parent.parent.mapToItem(root, input.parent.parent.width / 2, input.parent.parent.height - 3) },
                { tag: "under the text", at: input => input.parent.parent.mapToItem(root, input.parent.parent.width - 20, input.parent.parent.height + 6) }
            ];
        }

        function test_aClickInTheInputAreaFocusesThePrompt(data) {
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    placeholder: "Ask anything, @tag files/folders, $use skills, or / for commands ".repeat(4)
                })
            });
            const composer = createTemporaryObject(composerComponent, root);
            const input = findChild(composer, "input");
            const other = findChild(composer, "modelPicker");
            waitForRendering(composer);
            other.forceActiveFocus();
            verify(!input.activeFocus);
            const point = data.at(input);
            mouseClick(root, point.x, point.y);
            tryVerify(() => input.activeFocus);
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
            // One quiet row, left-aligned where a suggestion's label starts.
            const box = label.parent;
            compare(box.height, Theme.control.md + Theme.space.xs * 2);
            compare(label.horizontalAlignment, Text.AlignLeft);
            compare(label.x, Theme.space.xs + Theme.space.md);
            verify(label.y >= 0 && label.y + label.height <= box.height);
        }

        function test_suggestionsAnchorToTheCard() {
            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), {
                triggerKind: "path", suggestionsEmptyText: null,
                suggestions: [{ label: "README.md", description: "" }, { label: "src/", description: "" }]
            }), workspace: null };
            let composer = createTemporaryObject(composerComponent, root, { width: 800 });
            const popover = findChild(composer, "suggestionsPopover");
            const card = findChild(composer, "composerCard");
            tryVerify(() => popover.visible && popover.height > 0);
            // Edges flush with the prompt's, inside the card's padding.
            compare(popover.x, card.x + Theme.space.md);
            compare(popover.width, card.width - Theme.space.md * 2);
            // A popover over the card, not a tab on it: a 4px gap, and as
            // tall as its whole rows.
            compare(card.y - (popover.y + popover.height), Theme.space.xs);
            compare(popover.height, Theme.control.md * 2 + Theme.space.xs * 2);
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

        // A model with every chip the toolbar can carry.
        function crowded(extra) {
            return { composer: Object.assign({}, Shell.defaultComposer(), {
                options: [
                    { id: "reasoningEffort", label: "Reasoning", type: "select", value: "high", choices: [{ id: "low", label: "Low" }, { id: "high", label: "High" }] },
                    { id: "contextWindow", label: "Context", type: "select", value: "1m", choices: [{ id: "200k", label: "200K" }, { id: "1m", label: "1M" }] },
                    { id: "fastMode", label: "Fast Mode", type: "boolean", value: true, choices: [] }
                ],
                runtimeModes: [{ value: "approval-required", label: "Ask first" }, { value: "full-access", label: "Full access" }],
                showInteractionModeToggle: true
            }, extra ?? {}), workspace: null };
        }

        function shownChips(composer) {
            const row = findChild(composer, "toolbarChips");
            const shown = [];
            for (let i = 0; i < row.children.length; ++i) {
                const chip = row.children[i];
                if (chip.visible && chip.objectName.length > 0) shown.push(chip);
            }
            return shown;
        }

        // However narrow, the toolbar is one line: what does not fit folds
        // into the overflow chip, the context window first and the effort
        // next, and a chip that folded stays folded as the composer narrows.
        function test_aNarrowToolbarFoldsInsteadOfWrapping() {
            Shell.state = crowded();
            let composer = createTemporaryObject(composerComponent, root);
            const toolbar = findChild(composer, "toolbar");
            const send = findChild(composer, "primaryAction");
            const overflow = findChild(composer, "composerOverflow");
            waitForRendering(composer);
            compare(composer.foldCount, 0, "a wide composer folds nothing");
            verify(!overflow.visible);
            let before = [];
            for (let width = 800; width >= 240; width -= 20) {
                composer.width = width;
                waitForRendering(composer);
                const folded = composer.folded.map(chip => chip.objectName);
                compare(folded.slice(0, before.length), before, "at " + width + " the chips folded before stay folded");
                before = folded;
                compare(overflow.visible, folded.length > 0);
                for (const chip of shownChips(composer)) {
                    verify(folded.indexOf(chip.objectName) < 0, chip.objectName + " folded and shown at " + width);
                    const right = chip.mapToItem(toolbar, chip.width, 0).x;
                    verify(right <= send.mapToItem(toolbar, 0, 0).x, chip.objectName + " runs under Send at " + width);
                    compare(chip.mapToItem(toolbar, 0, chip.height / 2).y, toolbar.height / 2, chip.objectName + " is on the toolbar's one line");
                }
            }
            compare(before[0], "optionPicker:contextWindow");
            compare(before[1], "effortPicker");
            verify(before.length >= 4, "the narrowest composer folds the toggles too");
        }

        function overflowRow(menu, name) {
            for (let i = 0; i < menu.count; ++i) {
                const item = menu.itemAt(i);
                if (item.objectName === name || item.subMenu?.objectName === name) return item;
            }
            return null;
        }

        // The overflow chip's menu holds the folded controls in toolbar
        // order: a picker opens its choices, a toggle flips; its chip, pressed
        // again, closes it.
        function test_theOverflowMenuOffersTheFoldedControls() {
            Shell.state = crowded();
            let composer = createTemporaryObject(composerComponent, root, { width: 260, y: 350, height: 350 });
            waitForRendering(composer);
            const overflow = findChild(composer, "composerOverflow");
            verify(overflow.visible);
            mouseClick(overflow);
            const menu = composer.overflowMenu;
            verify(menu !== null);
            tryVerify(() => menu.opened);
            compare(menu.count, composer.folded.length);
            compare(menu.itemAt(0).subMenu.objectName, "composerOverflow:effortPicker", "toolbar order puts the effort first");
            compare(menu.itemAt(0).subMenu.detail, "High");

            const effort = overflowRow(menu, "composerOverflow:effortPicker").subMenu;
            compare(effort.count, 2);
            verify(effort.itemAt(1).current, "the chosen effort is checked");
            effort.itemAt(0).triggered();
            let sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.option.set");
            compare(sent.payload.id, "reasoningEffort");
            compare(sent.payload.value, "low");

            const fast = overflowRow(menu, "composerOverflow:optionToggle:fastMode");
            if (fast !== null) {
                compare(fast.iconName, "check", "an on toggle is checked in the icon column");
                compare(fast.detail, "On", "a folded toggle says whether it is on");
                fast.triggered();
                sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
                compare(sent.action, "composer.option.set");
                compare(sent.payload.value, false);
            }

            if (composer.overflowMenu === null) {
                mouseClick(overflow);
                tryVerify(() => composer.overflowMenu !== null && composer.overflowMenu.opened);
            }
            const again = composer.overflowMenu;
            mouseClick(overflow);
            tryVerify(() => composer.overflowMenu === null, 1000, "pressing the chip again closes its menu");
            compare(overflow.checked, false);
            verify(again !== null);
        }

        // Plan, folded, is a row of the menu that asks for plan mode.
        function test_planFoldedIntoTheMenuSwitchesMode() {
            Shell.state = crowded();
            let composer = createTemporaryObject(composerComponent, root, { width: 240 });
            waitForRendering(composer);
            verify(composer.folded.some(chip => chip.objectName === "planToggle"));
            composer.openOverflow(null);
            const plan = overflowRow(composer.overflowMenu, "composerOverflow:planToggle");
            verify(plan !== null);
            compare(plan.text, "Plan");
            compare(plan.iconName, "", "an off toggle has no check");
            compare(plan.detail, "Off", "a folded toggle says when it is off");
            plan.triggered();
            const sent = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(sent.action, "composer.interactionMode.set");
            compare(sent.payload.mode, "plan");
        }

        // The effort's shortcut still works when the effort has folded: it
        // opens the overflow menu on the effort's row.
        function test_theEffortShortcutReachesAFoldedEffort() {
            Shell.state = crowded();
            let composer = createTemporaryObject(composerComponent, root, { width: 260 });
            waitForRendering(composer);
            verify(composer.folded.some(chip => chip.objectName === "effortPicker"));
            composer.openControl("composer.effort");
            const menu = composer.overflowMenu;
            verify(menu !== null);
            compare(menu.itemAt(menu.currentIndex).subMenu.objectName, "composerOverflow:effortPicker");
            composer.openControl("composer.effort");
            compare(composer.overflowMenu, menu, "a second shortcut keeps the one menu");
        }

        // Send is the accent only with something to send; a turn running
        // with nothing to send makes it Stop.
        function test_sendIsTheAccentOnlyWithSomethingToSend() {
            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), { canSend: false }), workspace: null };
            let composer = createTemporaryObject(composerComponent, root);
            const send = findChild(composer, "primaryAction");
            const accent = send.accent;
            verify(!send.enabled, "an empty prompt cannot send");
            verify(Qt.colorEqual(send.background.color, composer.chipFill));
            verify(!Qt.colorEqual(send.background.color, accent));

            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), { canSend: true, text: "hi" }), workspace: null };
            tryVerify(() => send.enabled && send.sendable);
            compare(send.Accessible.name, "Send");
            verify(Qt.colorEqual(send.background.color, accent));

            Shell.state = { composer: Object.assign({}, Shell.defaultComposer(), { canSend: false, text: "", isRunning: true }), workspace: null };
            tryVerify(() => send.stopMode);
            const input = findChild(composer, "input");
            input.text = "";
            compare(send.Accessible.name, "Stop");
            verify(send.enabled);
            verify(findChild(send, "stopGlyph").visible);
            verify(!Qt.colorEqual(send.background.color, accent), "Stop is not the accent");
            const count = Shell.dispatchedActions.length;
            mouseClick(send);
            verify(Shell.dispatchedActions.slice(count).some(entry => entry.action === "composer.interrupt"));
            verify(Shell.dispatchedActions.slice(count).every(entry => entry.action !== "composer.submit"));
        }

        // The placeholder is one line however long it is, so an empty
        // prompt is no taller for it.
        function test_aLongPlaceholderStaysOneLine() {
            const state = placeholder => ({ composer: Object.assign({}, Shell.defaultComposer(), { placeholder: placeholder }), workspace: null });
            Shell.state = state("Ask");
            let composer = createTemporaryObject(composerComponent, root, { width: 320 });
            const input = findChild(composer, "input");
            waitForRendering(composer);
            const short = input.implicitHeight;
            Shell.state = state("Ask anything, @tag files/folders, $use skills, or / for commands, and keep going well past the edge");
            waitForRendering(composer);
            compare(input.implicitHeight, short);
        }

        // An empty prompt rests at two lines and a long one grows to 40% of
        // the window, then scrolls.
        function test_thePromptGrowsToFortyPercentOfTheWindow() {
            let composer = createTemporaryObject(composerComponent, root);
            const input = findChild(composer, "input");
            const scroll = findChild(composer, "promptScroll");
            waitForRendering(composer);
            const rest = scroll.height;
            input.text = "one";
            waitForRendering(composer);
            compare(scroll.height, rest, "one line keeps the resting height");
            input.text = "line\n".repeat(60);
            waitForRendering(composer);
            verify(scroll.height > rest * 3, "a long prompt grows");
            const card = findChild(composer, "composerCard");
            verify(card.height <= Math.round(composer.Window.height * 0.4) + 1, "the card stays within 40% of the window");
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

        // A two-path glyph's second fill is its own (ProviderIcon renders
        // multi-path glyphs through fill(..., 1)), and a glyph with no
        // paths answers null instead of throwing.
        function test_providerGlyphFillsByPath() {
            compare(ProviderIcons.fill("opencode", false, 0), "#CFCECD");
            compare(ProviderIcons.fill("opencode", false, 1), "#211E1E");
            compare(ProviderIcons.fill("opencode", true, 1), "#F1ECEC");
            compare(ProviderIcons.fill("noSuchDriver", false, 1), null);
            ProviderIcons.glyphs.noPathsEntry = {};
            const missing = ProviderIcons.fill("noPathsEntry", false, 0);
            delete ProviderIcons.glyphs.noPathsEntry;
            compare(missing, null);
        }

        // The bolt is filled; it is Claude's orange on a Claude model and the
        // text colour on any other.
        function test_fastModeBoltIsFilledInTheProvidersColour() {
            const withDriver = driverKind => ({
                composer: Object.assign({}, Shell.defaultComposer(), {
                    selectedInstanceId: "instance",
                    options: [{ id: "fastMode", label: "Fast Mode", type: "boolean", value: true, choices: [] }]
                }),
                modelPicker: Object.assign({}, Shell.defaultModelPicker(), {
                    instances: [{ instanceId: "instance", driverKind: driverKind, displayName: "Instance", models: [] }]
                }),
                workspace: null
            });
            const opaque = color => Qt.rgba(color.r, color.g, color.b, 1);
            const alphaOf = color => Math.round(color.a * 100) / 100;
            Shell.state = withDriver("claudeAgent");
            let composer = createTemporaryObject(composerComponent, root);
            const toggle = findChild(composer, "optionToggle:fastMode");
            const bolt = findChild(toggle, "buttonIcon");
            compare(bolt.filled, true);
            tryVerify(() => Qt.colorEqual(opaque(bolt.color), Qt.color("#d97757")));
            compare(alphaOf(bolt.color), 0.8);
            Shell.state = withDriver("codex");
            tryVerify(() => Qt.colorEqual(opaque(bolt.color), opaque(composer.foreground)));
            compare(bolt.filled, true);
            compare(alphaOf(bolt.color), alphaOf(composer.foreground));
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

            // Editing a queued message saves it: no Steer or Queue cue while it lasts.
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, { editingQueuedRunId: "run-2" })
            });
            compare(primary.followUp, "");
        }

        // Scenario: Page Up and Page Down from the composer scroll the conversation
        function test_pageKeysGoToTheConversation() {
            let composer = createTemporaryObject(composerComponent, root);
            let input = findChild(composer, "input");
            const paged = [];
            Keybindings.commands.add("timeline.pageUp", "", () => paged.push("up"), composer);
            Keybindings.commands.add("timeline.pageDown", "", () => paged.push("down"), composer);
            input.forceActiveFocus();
            input.text = "A short message";
            keyClick(Qt.Key_PageUp);
            keyClick(Qt.Key_PageDown);
            compare(paged, ["up", "down"]);
            verify(input.activeFocus, "the composer keeps the keyboard");
            compare(input.text, "A short message");
            Keybindings.commands.remove("timeline.pageUp");
            Keybindings.commands.remove("timeline.pageDown");
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

        // Removing the chip removes the context; the controller strips the
        // [@title](hal-c2-context://v1/thread/...) link from the draft with it
        // (tst_ComposerRegression's removingAThreadChipStripsItsLinkFromTheDraft).
        function test_threadChipNamesTheThreadAndRemovesIt() {
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    text: "see [@Fix the login](hal-c2-context://v1/thread/thread_th-1) please",
                    threadContexts: [{ id: "th-1", label: "Fix the login" }]
                })
            });
            const composer = createTemporaryObject(composerComponent, root);
            const chip = findChild(composer, "threadContext-th-1");
            verify(!!chip);
            compare(chip.text, "Fix the login");
            // Typed just now (still in the 120 ms debounce): the controller,
            // which strips the link from its draft, gets these words first.
            const input = findChild(composer, "input");
            const typed = "see [@Fix the login](hal-c2-context://v1/thread/thread_th-1) please thanks";
            input.text = typed;
            input.cursorPosition = typed.length;
            const before = Shell.dispatchedActions.length;
            mouseClick(chip);
            const sent = Shell.dispatchedActions.slice(before);
            compare(sent.length, 2);
            compare(sent[0].action, "composer.text.set");
            compare(sent[0].payload.text, typed);
            compare(sent[0].payload.cursor, typed.length);
            compare(sent[1].action, "composer.terminalContext.remove");
            compare(sent[1].payload.id, "th-1");
        }

        // A large paste the controller cannot file is spliced into its
        // draft, so paste hands it the editor's live words and caret first:
        // typing still in the debounce and a caret moved without typing.
        function test_aLargePasteFlushesTheEditorsTextAndCaretFirst() {
            Shell.clipboard = "a very long paste";
            Shell.pasteBecomesFile = true;
            const composer = createTemporaryObject(composerComponent, root);
            const input = findChild(composer, "input");
            input.focus = true;
            const before = Shell.dispatchedActions.length;
            // Typed just now (still in the 120 ms debounce), caret mid-draft.
            input.text = "before after";
            input.cursorPosition = 6;
            verify(Shell.dispatchedActions.slice(before).every(entry => entry.action !== "composer.text.set"), "the typing is unflushed");
            verify(composer.paste(false));
            const sent = Shell.dispatchedActions.slice(before);
            compare(sent.length, 2);
            compare(sent[0].action, "composer.text.set");
            compare(sent[0].payload.text, "before after");
            compare(sent[0].payload.cursor, 6);
            compare(sent[1].action, "composer.attach");
            compare(sent[1].payload.files[0].name, "pasted-text.txt");
            compare(sent[1].payload.files[0].text, "a very long paste");
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
