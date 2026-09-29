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
            verify(!requests.visible);
            compare(requests.implicitHeight, 0);
        }

        function test_anotherThreadsTurnIsNotShown() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({
                threadKey: "thread-b",
                approvals: [approval("request-1")]
            });
            verify(!requests.visible);
        }

        function test_approvalOptionAnswersTheRequest() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ approvals: [approval("request-1")] });
            waitForRendering(root);
            verify(requests.visible);
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

        function test_queuedMessageIsSteeredOrRemoved() {
            const requests = createTemporaryObject(requestsComponent, root);
            Shell.publishTurn({ queue: [{ runId: "run-2", text: "check the logs" }, { runId: "run-3", text: "update the docs" }] });
            waitForRendering(root);
            mouseClick(findChild(requests, "queueSteer-run-3"));
            compare(lastAction().action, "composer.queue.steer");
            compare(lastAction().payload.runId, "run-3");
            mouseClick(findChild(requests, "queueRemove-run-2"));
            compare(lastAction().action, "composer.queue.remove");
            compare(lastAction().payload.runId, "run-2");
            mouseClick(findChild(requests, "queueEdit-run-3"));
            compare(lastAction().action, "composer.queue.edit");
            compare(lastAction().payload.runId, "run-3");
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
