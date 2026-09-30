pragma Singleton
import QtQuick

QtObject {
    id: shell

    property var state: ({
            composer: defaultComposer(),
            modelPicker: defaultModelPicker(),
            workspace: null,
            turn: null
        })
    property var dispatchedActions: []
    property int dispatchCount: 0
    property bool echoTextEdits: true
    property bool localFolderImportEnabled: false

    signal actionRequested(string action, var payload)
    signal windowCommandRequested(string command)

    function windowCommand(command) {
        windowCommandRequested(command);
    }

    function defaultComposer() {
        return {
            target: "thread-a",
            edit: null,
            text: "",
            cursor: 0,
            suggestions: [],
            triggerKind: null,
            suggestionsEmptyText: null,
            options: [],
            attachments: [],
            terminalContexts: [],
            placeholder: qsTr("Send a message"),
            editorDisabled: false,
            canSend: true,
            selectedInstanceId: null,
            selectedModel: null,
            runtimeMode: "approval-required",
            runtimeModes: [],
            showInteractionModeToggle: false,
            interactionMode: "default",
            pendingApprovalCount: 0,
            showPlanFollowUpPrompt: false,
            isRunning: false,
            followUpBehavior: "steer",
            enterIntents: {
                singleLine: { "": "foreground", "ctrl+alt": "background" },
                multiline: { "": "foreground", "ctrl+alt": "background" }
            }
        };
    }

    function defaultModelPicker() {
        return {
            instances: [],
            locked: false,
            shortcut: null,
            previousProvider: null,
            nextProvider: null,
            jump: []
        };
    }

    function reset() {
        echoTextEdits = true;
        localFolderImportEnabled = false;
        dispatchedActions = [];
        dispatchCount = 0;
        state = {
            composer: defaultComposer(),
            modelPicker: defaultModelPicker(),
            workspace: null,
            turn: null
        };
    }

    function publishComposerText(text, cursor, edit = state.composer.edit) {
        state = Object.assign({}, state, {
            composer: Object.assign({}, state.composer, {
                text: text,
                edit: edit,
                cursor: cursor
            })
        });
    }

    // The shell's own turn for the composer's target (ComposerController).
    function publishTurn(fields) {
        state = Object.assign({}, state, {
            turn: Object.assign({
                threadKey: state.composer.target,
                running: false,
                approvals: [],
                questions: [],
                plan: null,
                queue: []
            }, fields)
        });
    }

    function publishComposerTarget(target, text, cursor) {
        state = Object.assign({}, state, {
            composer: Object.assign({}, state.composer, {
                target: target,
                edit: null,
                text: text,
                cursor: cursor
            })
        });
    }

    function dispatch(action, payload) {
        dispatchedActions = dispatchedActions.concat([
            {
                action: action,
                payload: payload
            }
        ]);
        dispatchCount += 1;
        if (echoTextEdits && action === "composer.text.set" && payload.target === state.composer.target) {
            publishComposerText(payload.text, payload.cursor, payload.edit);
        } else if (action === "composer.submit") {
            publishComposerText(payload.text, state.composer.cursor, payload.edit);
        }
        actionRequested(action, payload);
    }

    function localDirectoryPath(url) {
        return String(url).replace(/^file:\/\//, "");
    }

    function readImageFiles(urls) {
        return [];
    }
}
