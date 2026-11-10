import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 900
    height: 700

    Component {
        id: requestsComponent

        TurnRequests {
            width: 800
        }
    }

    Component {
        id: composerComponent

        Composer {
            width: 800
            height: 400
        }
    }

    TestCase {
        name: "TurnRequestsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function approval(requestId, fields) {
            return Object.assign({
                requestId: requestId,
                title: "Command approval",
                appName: "",
                detail: "npm test",
                options: [
                    { decision: "accept", label: "Approve", warning: "" },
                    { decision: "decline", label: "Deny", warning: "" }
                ],
                canRespond: true,
                responding: false,
                problem: ""
            }, fields ?? {});
        }

        function question(multiSelect) {
            return {
                requestId: "request-q",
                questions: [{
                        id: "database",
                        header: "Database",
                        question: "Which database?",
                        options: [
                            { label: "Postgres", description: "" },
                            { label: "SQLite", description: "" },
                            { label: "MySQL", description: "" }
                        ],
                        multiSelect: multiSelect,
                        allowCustomAnswer: true
                    }],
                canRespond: true,
                responding: false,
                problem: ""
            };
        }

        function lastAction() {
            return Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
        }

        function test_hiddenWithNothingPending() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({});
            waitForRendering(root);
            verify(!requests.pending);
            compare(requests.implicitHeight, 0);
        }

        function test_anotherThreadsTurnIsNotShown() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({
                threadKey: "thread-b",
                approvals: [approval("request-1")]
            });
            verify(!requests.pending);
            compare(requests.implicitHeight, 0);
        }

        function test_approvalOptionAnswersTheRequest() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ approvals: [approval("request-1")] });
            waitForRendering(root);
            verify(requests.pending);
            mouseClick(findChild(requests, "approvalOption-decline"));
            compare(lastAction().action, "composer.approval.respond");
            compare(lastAction().payload.requestId, "request-1");
            compare(lastAction().payload.decision, "decline");
        }

        function test_approvalBeingAnsweredOrGoneCannotBeAnsweredAgain() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ approvals: [approval("request-1", { responding: true })] });
            waitForRendering(root);
            verify(!findChild(requests, "approvalOption-accept").enabled);
            Shell.publishTurn({ approvals: [approval("request-1", { canRespond: false, problem: "Provider process is gone" })] });
            waitForRendering(root);
            verify(!findChild(requests, "approvalOption-accept").enabled);
            compare(findChild(requests, "approvalProblem").text, "Provider process is gone");
        }

        function test_severalApprovalsAreAnsweredOneAtATime() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ approvals: [approval("request-1"), approval("request-2"), approval("request-3")] });
            waitForRendering(root);
            const position = findChild(requests, "approvalPosition");
            compare(position.text, "1/3");
            mouseClick(findChild(requests, "approvalNext"));
            compare(position.text, "2/3");
            mouseClick(findChild(requests, "approvalOption-accept"));
            compare(lastAction().payload.requestId, "request-2");
            mouseClick(findChild(requests, "approvalPrevious"));
            compare(position.text, "1/3");
        }

        function test_pickedOptionAnswersTheQuestion() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(false)] });
            waitForRendering(root);
            const submit = findChild(requests, "questionSubmit");
            verify(!submit.enabled, "nothing picked yet");
            mouseClick(findChild(requests, "questionOption-Postgres"));
            mouseClick(findChild(requests, "questionOption-SQLite"));
            mouseClick(submit);
            compare(lastAction().action, "composer.question.answer");
            compare(lastAction().payload.answers.database, "SQLite");
        }

        function test_severalAnswersAreSentTogether() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(true)] });
            waitForRendering(root);
            mouseClick(findChild(requests, "questionOption-Postgres"));
            mouseClick(findChild(requests, "questionOption-MySQL"));
            mouseClick(findChild(requests, "questionSubmit"));
            compare(lastAction().payload.answers.database, ["Postgres", "MySQL"]);
        }

        function test_typedAnswerWinsOverPickedOption() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(false)] });
            waitForRendering(root);
            mouseClick(findChild(requests, "questionOption-SQLite"));
            const field = findChild(requests, "questionAnswer-database");
            field.forceActiveFocus();
            keyClick(Qt.Key_D);
            keyClick(Qt.Key_B);
            mouseClick(findChild(requests, "questionSubmit"));
            compare(lastAction().payload.answers.database, "db");
        }

        // The shape Claude's AskUserQuestion arrives in: several questions, each
        // keyed by its own text.
        function test_severalQuestionsAreAnsweredTogether() {
            const requests = createTemporaryObject(requestsComponent, root);
            const ids = ["What should the prose say where it now says \"the MC\" / \"two MCs\"?", "Which short form (tags, env vars, `mise` tasks)?", "How deep should the rename go?"];
            Shell.publishTurn({
                questions: [{
                        requestId: "request-q",
                        questions: ids.map((id, index) => ({
                                    id: id,
                                    header: "Question " + (index + 1),
                                    question: id,
                                    options: [
                                        { label: "First " + index + " (Recommended)", description: "The first choice." },
                                        { label: "Second " + index, description: "The second choice." }
                                    ],
                                    multiSelect: false
                                })),
                        canRespond: true,
                        responding: false,
                        problem: ""
                    }]
            });
            waitForRendering(root);
            verify(requests.pending, "the card shows");
            const submit = findChild(requests, "questionSubmit");
            verify(submit.mapToItem(root, 0, submit.height).y <= root.height, "the answer button is inside the window");
            const position = findChild(requests, "questionPosition");
            compare(position.text, "1/3");
            // A pick moves on to the next question by itself.
            mouseClick(findChild(requests, "questionOption-First 0 (Recommended)"));
            tryCompare(position, "text", "2/3");
            mouseClick(findChild(requests, "questionOption-Second 1"));
            tryCompare(position, "text", "3/3");
            verify(!submit.enabled, "one question is still open");
            // The last pick sends every answer.
            mouseClick(findChild(requests, "questionOption-First 2 (Recommended)"));
            tryVerify(() => lastAction()?.action === "composer.question.answer");
            compare(lastAction().payload.answers[ids[0]], "First 0 (Recommended)");
            compare(lastAction().payload.answers[ids[1]], "Second 1");
            compare(lastAction().payload.answers[ids[2]], "First 2 (Recommended)");
        }

        // The terminal drawer handles its own keys and has no cursor: its
        // digits are the shell's.
        function test_digitsTypedElsewhereAreNotPicks() {
            const requests = createTemporaryObject(requestsComponent, root);
            const terminal = createTemporaryQmlObject("import QtQuick; Item { property string got: \"\"; focus: true; Keys.onPressed: event => { got += event.text; event.accepted = true; } }", root);
            Shell.publishTurn({ questions: [question(false)] });
            waitForRendering(root);
            terminal.forceActiveFocus();
            keyClick(Qt.Key_2);
            verify(!findChild(requests, "questionOption-SQLite").checked, "the terminal's 2 picked an option");
            verify(!requests.advancing, "the terminal's 2 is about to send an answer");
            compare(terminal.got, "2");
        }

        // A pick on the last question goes back to one skipped, not nowhere.
        function test_lastPickGoesBackToASkippedQuestion() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [twoQuestions()] });
            waitForRendering(root);
            const title = findChild(requests, "questionTitle");
            mouseClick(findChild(requests, "questionNext"));
            compare(title.text, "Which cache?");
            mouseClick(findChild(requests, "questionOption-Redis"));
            tryVerify(() => !requests.advancing);
            compare(title.text, "Which database?");
            verify(lastAction()?.action !== "composer.question.answer", "half the answers were sent");
        }

        // Answers are kept while their request may still be pending, and no longer.
        function test_keptAnswersGoOnceTheirRequestIsAnswered() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(false)] });
            waitForRendering(root);
            requests.type(requests.current, "DuckDB");
            // Off to another thread and back: kept, then restored.
            Shell.publishComposerTarget("thread-b", "", 0);
            Shell.publishTurn({});
            verify(requests.kept["request-q"] !== undefined, "the answer left behind is not kept");
            Shell.publishComposerTarget("thread-a", "", 0);
            Shell.publishTurn({ questions: [question(false)] });
            compare(findChild(requests, "questionAnswer-database").text, "DuckDB");
            compare(Object.keys(requests.kept).length, 0);
            // Left again, and answered elsewhere meanwhile: the next request on
            // its thread drops it.
            Shell.publishComposerTarget("thread-b", "", 0);
            Shell.publishTurn({});
            Shell.publishComposerTarget("thread-a", "", 0);
            Shell.publishTurn({ questions: [twoQuestions()] });
            compare(Object.keys(requests.kept).length, 0, "an answered request is still kept");
            // Replaced on the thread shown: the one answered is not kept.
            requests.type(requests.current, "Postgres");
            Shell.publishTurn({ questions: [question(false)] });
            compare(Object.keys(requests.kept).length, 0, "the request replaced is kept");
            compare(findChild(requests, "questionAnswer-database").text, "");
        }

        function twoQuestions() {
            const asked = (id, text, labels) => ({
                    id: id,
                    header: id,
                    question: text,
                    options: labels.map(label => ({ label: label, description: "" })),
                    multiSelect: false,
                    allowCustomAnswer: true
                });
            return {
                requestId: "request-two",
                questions: [asked("database", "Which database?", ["Postgres", "SQLite"]), asked("cache", "Which cache?", ["Redis", "Memcached"])],
                canRespond: true,
                responding: false,
                problem: ""
            };
        }

        // Moving by hand right after a pick is not moved again (upstream #17364).
        function test_movingByHandCancelsTheMoveAfterAPick() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [twoQuestions()] });
            waitForRendering(root);
            const title = findChild(requests, "questionTitle");
            compare(title.text, "Which database?");
            verify(!findChild(requests, "questionPrevious").enabled, "the first question has none before it");
            mouseClick(findChild(requests, "questionOption-Postgres"));
            verify(requests.advancing);
            mouseClick(findChild(requests, "questionNext"));
            verify(!requests.advancing, "the move by hand cancels the one after the pick");
            compare(title.text, "Which cache?");
            mouseClick(findChild(requests, "questionPrevious"));
            compare(title.text, "Which database?");
            verify(findChild(requests, "questionOption-Postgres").checked, "the first answer is kept");
        }

        function test_foldedQuestionShowsOnlyItsTitle() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [twoQuestions()] });
            waitForRendering(root);
            mouseClick(findChild(requests, "questionFold"));
            verify(findChild(requests, "questionTitle").visible);
            for (const name of ["questionOption-Postgres", "questionAnswer-database", "questionSubmit", "questionNext"])
                verify(!findChild(requests, name).visible, name + " is folded away");
            mouseClick(findChild(requests, "questionFold"));
            verify(findChild(requests, "questionOption-Postgres").visible);
        }

        function test_numberKeyPicksUnlessTyping() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(true)] });
            waitForRendering(root);
            // A click on the card takes the keyboard to it.
            mouseClick(findChild(requests, "questionTitle"));
            keyClick(Qt.Key_2);
            verify(findChild(requests, "questionOption-SQLite").checked, "2 picks the second option");
            const field = findChild(requests, "questionAnswer-database");
            field.forceActiveFocus();
            keyClick(Qt.Key_3);
            compare(field.text, "3");
            verify(!findChild(requests, "questionOption-MySQL").checked, "typing picks nothing");
            verify(!findChild(requests, "questionOption-SQLite").checked, "typing lets go of the pick");
        }

        function test_questionCanBeDismissed() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ questions: [question(false)] });
            waitForRendering(root);
            mouseClick(findChild(requests, "questionDismiss"));
            compare(lastAction().action, "composer.question.dismiss");
            compare(lastAction().payload.requestId, "request-q");
        }

        function test_planIsImplemented() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ plan: { id: "plan-1", title: "Add a tax line", markdown: "# Add a tax line" } });
            waitForRendering(root);
            mouseClick(findChild(requests, "planImplement"));
            compare(lastAction().action, "composer.plan.implement");
        }

        function test_queuedMessageIsSentNowOrRemoved() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "check the logs" }, { runId: "run-3", text: "update the docs" }] });
            waitForRendering(root);
            mouseClick(findChild(requests, "queueSendNow-run-3"));
            compare(lastAction().action, "composer.queue.steer");
            compare(lastAction().payload.runId, "run-3");
            mouseClick(findChild(requests, "queueRemove-run-2"));
            compare(lastAction().action, "composer.queue.remove");
            compare(lastAction().payload.runId, "run-2");
            mouseClick(findChild(requests, "queueEdit-run-3"));
            compare(lastAction().action, "composer.queue.edit");
            compare(lastAction().payload.runId, "run-3");
        }

        // A queued message shows its attachments, and selecting one opens it
        // large in the attachment viewer, as in the timeline.
        function test_queuedAttachmentsShowAndOpen() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "", attachments: [
                { id: "shot", name: "shot.png", mimeType: "image/png", kind: "image", url: "" },
                { id: "notes", name: "notes.md", mimeType: "text/markdown", kind: "file" }] }] });
            waitForRendering(root);
            verify(findChild(requests, "queueAttachment-shot").visible);
            verify(findChild(requests, "queueAttachment-notes").visible);
            mouseClick(findChild(requests, "queueAttachment-notes"));
            compare(lastAction().action, "attachment.sent.view");
            compare(lastAction().payload.id, "notes");
            compare(lastAction().payload.name, "notes.md");
            mouseClick(findChild(requests, "queueAttachment-shot"));
            compare(lastAction().payload.id, "shot");
            compare(lastAction().payload.mimeType, "image/png");
        }

        // The MC keeps a queue after a restart; the card says so and offers
        // to resume it, once at a time.
        function test_aHeldQueueCanBeResumed() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "later" }] });
            waitForRendering(root);
            verify(!findChild(requests, "queueHeld").visible);
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "later" }], queueHeld: true, queueResuming: false });
            waitForRendering(root);
            verify(findChild(requests, "queueHeld").visible);
            mouseClick(findChild(requests, "queueResume"));
            compare(lastAction().action, "composer.queue.resume");
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "later" }], queueHeld: true, queueResuming: true });
            waitForRendering(root);
            verify(!findChild(requests, "queueResume").enabled);
            compare(findChild(requests, "queueResume").text, "Resuming…");
            // Folded, the held notice stays.
            mouseClick(findChild(requests, "queueToggle"));
            verify(!findChild(requests, "queueList").visible);
            verify(findChild(requests, "queueHeld").visible);
        }

        // A delegated task's result waits its turn under its title, with
        // nothing for the user to act on, in the same folding card.
        function test_waitingResultsStackUnderTheirTitles() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({
                queue: [{ runId: "run-2", text: "check the logs" }],
                waiting: [{ runId: "run-3", summary: "Ledger dedupe: timeline-composer-files failed", outcome: "failed" }]
            });
            waitForRendering(root);
            compare(findChild(requests, "queueCount").text, "2");
            compare(findChild(requests, "queueWaiting-run-3").text, "Ledger dedupe: timeline-composer-files failed");
            verify(findChild(requests, "queueEdit-run-3") === null);
            verify(findChild(requests, "queueList").visible);
            mouseClick(findChild(requests, "queueToggle"));
            verify(!findChild(requests, "queueList").visible);
            verify(requests.pending);
        }

        // A result that names its worker opens the worker's thread; one that does not
        // is not a link.
        function test_waitingResultOpensItsWorkersThread() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({
                waiting: [
                    { runId: "run-3", summary: "Tax tests finished", outcome: "completed", workerThreadId: "worker" },
                    { runId: "run-4", summary: "Old task finished", outcome: "completed", workerThreadId: "" }
                ]
            });
            waitForRendering(root);
            const linked = findChild(requests, "queueWaiting-run-3");
            compare(linked.Accessible.role, Accessible.Link);
            mouseClick(linked);
            compare(lastAction().action, "rightPanel.openThread");
            compare(lastAction().payload.threadKey.slice(-6), "worker");
            verify(findChild(requests, "queueWaiting-run-4").Accessible.role !== Accessible.Link);
        }

        function test_tabbingToAQueuedRowOutOfViewScrollsItIn() {
            const requests = createTemporaryObject(requestsComponent, root);
            const queue = [];
            for (let i = 1; i <= 8; ++i)
                queue.push({ runId: "run-" + i, text: "follow-up " + i });
            Shell.publishTurn({ queue: queue });
            waitForRendering(root);
            const list = findChild(requests, "queueList");
            compare(list.contentY, 0);
            findChild(requests, "queueRemove-run-8").forceActiveFocus(Qt.TabFocusReason);
            // The queued message's delegate: its text row, then its attachments.
            const row = findChild(requests, "queueText-run-8").parent.parent;
            verify(row.y + row.height <= list.contentY + list.height);
            verify(row.y >= list.contentY);
            findChild(requests, "queueEdit-run-1").forceActiveFocus(Qt.BacktabFocusReason);
            compare(list.contentY, 0);
        }

        function test_composerSendsImagesWithoutText() {
            const composer = createTemporaryObject(composerComponent, root);
            Shell.state = Object.assign({}, Shell.state, {
                composer: Object.assign({}, Shell.state.composer, {
                    canSend: false,
                    attachments: [{ id: "attachment-1", name: "cart.png" }]
                })
            });
            waitForRendering(root);
            const send = findChild(composer, "primaryAction");
            verify(send.enabled);
            mouseClick(send);
            compare(lastAction().action, "composer.submit");
        }
    }
}
