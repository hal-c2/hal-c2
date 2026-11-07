pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// What the open thread's turn waits on from the user, which the Composer
// stacks on top of its prompt: the pending approval (one at a time, with its position), the
// agent's question, the proposed plan once the turn is over (with its other
// actions: a new thread, copy, download, save to the workspace), and the queued
// follow-ups with the task results waiting behind them. Rendered from
// Shell.state.turn (ComposerController) for the thread the composer shows;
// every answer is a composer.* action the shell sends to the MC.
Item {
    id: requests

    readonly property var turn: Shell.state.turn ?? null
    readonly property var composerModel: Shell.state.composer ?? null
    readonly property bool shown: turn !== null && composerModel !== null && turn.threadKey === composerModel.target
    readonly property var approvals: shown ? turn.approvals : []
    readonly property var questions: shown ? turn.questions : []
    readonly property var plan: shown ? turn.plan ?? null : null
    readonly property var queue: shown ? turn.queue : []
    readonly property var waiting: shown ? turn.waiting ?? [] : []
    // The messages this device keeps until it can send them (the phone's
    // outbox): the route thread's, known or not to a store that has not loaded.
    readonly property var outbox: turn !== null && turn.kind === "thread" ? turn.outbox ?? [] : []
    // The running turn's task list, summed up; `tasksOpen` lists every step.
    // It closes on another thread, and when the list goes (an approval or a
    // question takes its place, or the turn ends).
    readonly property var tasks: shown ? turn.tasks ?? null : null
    property bool tasksOpen: false
    readonly property string tasksThread: shown ? turn.threadKey : ""
    onTasksThreadChanged: tasksOpen = false
    onTasksChanged: if (tasks === null) tasksOpen = false
    // The MC keeps the queue for the user (after a restart or a usage limit)
    // until it is resumed.
    readonly property bool queueHeld: shown && turn.queueHeld === true
    readonly property bool queueResuming: shown && turn.queueResuming === true
    property int approvalIndex: 0
    readonly property var approval: approvals.length > 0 ? approvals[Math.min(approvalIndex, approvals.length - 1)] : null
    readonly property var question: questions.length > 0 ? questions[0] : null
    // The questions of `question`, answered one at a time: `current` is the
    // one shown, and `folded` leaves only its title above the composer.
    readonly property var asked: question?.questions ?? []
    property int questionIndex: 0
    readonly property var current: asked.length > 0 ? asked[Math.min(questionIndex, asked.length - 1)] : null
    property bool folded: false
    // The options picked for each question of `question`, by question id, and
    // what the user typed instead.
    property var picks: ({})
    property var typed: ({})
    property string answering: ""
    property string answeringThread: ""
    // What the user answered to requests still pending on other threads, by
    // request id ({thread, picks, typed}), restored when one is shown again.
    property var kept: ({})
    // Threads the card does not show cannot be checked, so the oldest kept
    // answers go past this many.
    readonly property int keptMost: 50
    readonly property bool answerable: question !== null && question.canRespond && !question.responding

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color warning: Theme.palette.color("warningForeground", "#e0af68")
    readonly property string uiFont: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    readonly property int maximumCardWidth: 768
    readonly property int gutter: 20

    // Whether the turn waits on anything. The height follows this and not
    // `visible`, which a host may bind to more than this.
    readonly property bool pending: approval !== null || question !== null || plan !== null || tasks !== null || queue.length > 0 || waiting.length > 0 || outbox.length > 0

    visible: pending
    implicitHeight: pending ? column.implicitHeight + 8 : 0

    onQuestionChanged: {
        const id = question?.requestId ?? "";
        if (id === answering) return;
        advance.stop();
        const thread = shown ? turn.threadKey : "";
        const pendingHere = questions.map(item => item.requestId);
        const next = {};
        for (const key of Object.keys(kept)) {
            // A request the shown thread no longer waits on was answered or withdrawn.
            if (kept[key].thread === thread && pendingHere.length > 0 && !pendingHere.includes(key)) continue;
            next[key] = kept[key];
        }
        // The request left behind is kept while it may still wait: on a
        // thread no longer shown, or still pending on this one.
        if (answering.length > 0 && (answeringThread !== thread || pendingHere.includes(answering)))
            next[answering] = { thread: answeringThread, picks: picks, typed: typed };
        const restored = next[id] ?? null;
        delete next[id];
        const keys = Object.keys(next);
        for (let index = 0; index < keys.length - keptMost; ++index) delete next[keys[index]];
        kept = next;
        answering = id;
        answeringThread = id.length > 0 ? thread : "";
        picks = restored?.picks ?? {};
        typed = restored?.typed ?? {};
        folded = false;
        questionIndex = firstUnanswered();
    }

    // Moving on after the user picks the one answer a question takes waits a
    // moment, so the pick is seen; moving by hand in that moment cancels it.
    // Past the last question, moving on sends the answers, or goes back to
    // one still unanswered.
    Timer {
        id: advance

        interval: 200
        onTriggered: {
            if (requests.questionIndex < requests.asked.length - 1)
                requests.questionIndex += 1;
            else if (requests.answers() === null)
                requests.questionIndex = requests.firstUnanswered();  // one was skipped
            else
                requests.submit();
        }
    }
    readonly property bool advancing: advance.running

    function moveTo(index) {
        advance.stop();
        questionIndex = Math.max(0, Math.min(index, asked.length - 1));
    }

    function submit() {
        advance.stop();
        const answered = answers();
        if (!answerable || answered === null) return;
        Shell.dispatch("composer.question.answer", {
            requestId: question.requestId,
            answers: answered
        });
    }

    // Files for the answer to one question go to the MC with it.
    function attachTo(questionId, urls) {
        const files = Shell.readAttachmentFiles(urls);
        if (files.length === 0 || question === null) return;
        Shell.dispatch("composer.question.attach", {
            requestId: question.requestId,
            questionId: questionId,
            files: files
        });
    }

    // A pick lets go of what was typed, and a typed answer of the picks.
    function pick(item, label) {
        const next = Object.assign({}, picks);
        let chosen = false;
        if (item.multiSelect) {
            const was = next[item.id] ?? [];
            next[item.id] = was.includes(label) ? was.filter(value => value !== label) : was.concat([label]);
        } else {
            chosen = next[item.id] !== label;
            next[item.id] = chosen ? label : undefined;
        }
        picks = next;
        if ((typed[item.id] ?? "").length > 0) type(item, "");
        if (chosen && item.id === current?.id) advance.restart();
        else advance.stop();
    }

    function type(item, text) {
        typed = Object.assign({}, typed, {
            [item.id]: text
        });
        if (text.trim().length > 0 && picks[item.id] !== undefined) {
            const next = Object.assign({}, picks);
            delete next[item.id];
            picks = next;
        }
    }

    function answerOf(item) {
        const text = (typed[item.id] ?? "").trim();
        const picked = picks[item.id];
        if (text.length > 0) return text;
        if (Array.isArray(picked) ? picked.length > 0 : picked !== undefined) return picked;
        return null;
    }

    // Reads the request itself: `asked` may not have caught up with it yet
    // when a new request arrives.
    function firstUnanswered() {
        const items = question?.questions ?? [];
        for (let index = 0; index < items.length; ++index) {
            if (answerOf(items[index]) === null) return index;
        }
        return Math.max(0, items.length - 1);
    }

    // What the agent receives for each question: typed text wins over picks.
    function answers() {
        const result = {};
        for (const item of question?.questions ?? []) {
            const answer = answerOf(item);
            if (answer === null) return null;
            result[item.id] = answer;
        }
        return result;
    }

    // A number key picks the option in that place while the keyboard is on
    // the card (a click on it puts it there) or on nothing, so the editor, a
    // field or the terminal drawer keeps its digits. Not while folded away.
    readonly property var focused: Window.activeFocusItem
    readonly property bool digitsPick: shown && current !== null && !folded && answerable
                                       && (focused === null || focused === Window.contentItem || isInside(focused, questionCard) && focused.cursorPosition === undefined)

    function isInside(item, ancestor) {
        for (let at = item; at !== null; at = at.parent) {
            if (at === ancestor) return true;
        }
        return false;
    }

    // Each Shortcut sits in an Item so it finds the window it listens to.
    Repeater {
        model: 9

        delegate: Item {
            id: digit

            required property int index

            Shortcut {
                sequence: String(digit.index + 1)
                enabled: requests.digitsPick && digit.index < (requests.current?.options ?? []).length
                onActivated: requests.pick(requests.current, requests.current.options[digit.index].label)
            }
        }
    }

    ColumnLayout {
        id: column

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - requests.gutter * 2, requests.maximumCardWidth)
        spacing: Theme.space.sm

        // The agent's tasks (ComposerTasksBadge): the current step and how
        // many are done, opening to every step with its status and time.
        ShellCard {
            objectName: "tasks"
            Layout.fillWidth: true
            visible: requests.tasks !== null
            implicitHeight: tasksColumn.implicitHeight + 12

            ColumnLayout {
                id: tasksColumn

                anchors.fill: parent
                anchors.margins: 6
                spacing: 2

                ShellButton {
                    id: tasksToggle

                    objectName: "tasksToggle"
                    Layout.fillWidth: true
                    implicitHeight: 28
                    subtle: true
                    Accessible.name: qsTr("%1: %2 of %3 complete. Current task: %4")
                        .arg(requests.tasksOpen ? qsTr("Collapse tasks") : qsTr("Tasks"))
                        .arg(requests.tasks?.completed ?? 0).arg(requests.tasks?.total ?? 0).arg(requests.tasks?.current ?? "")
                    onClicked: requests.tasksOpen = !requests.tasksOpen
                    contentItem: RowLayout {
                        spacing: Theme.space.sm

                        ShellIcon {
                            name: "list-todo"
                            size: Theme.icon.sm
                            color: requests.muted
                        }
                        Text {
                            text: qsTr("Tasks")
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                        Text {
                            objectName: "tasksCurrent"
                            Layout.fillWidth: true
                            text: requests.tasks?.current ?? ""
                            color: requests.foreground
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        Text {
                            objectName: "tasksProgress"
                            text: "%1/%2".arg(requests.tasks?.completed ?? 0).arg(requests.tasks?.total ?? 0)
                            color: (requests.tasks?.completed ?? 0) >= (requests.tasks?.total ?? 1) ? Theme.palette.color("success", "#22c55e") : requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                        ShellIcon {
                            name: requests.tasksOpen ? "chevron-down" : "chevron-up"
                            size: Theme.icon.sm
                            color: requests.muted
                        }
                    }
                }

                Repeater {
                    model: requests.tasksOpen ? requests.tasks?.steps ?? [] : []

                    RowLayout {
                        id: taskStep

                        required property var modelData
                        objectName: "taskStep"
                        readonly property string step: modelData.text
                        readonly property string status: modelData.status
                        readonly property string duration: modelData.duration
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.space.sm
                        Layout.rightMargin: Theme.space.sm
                        spacing: Theme.space.sm
                        Accessible.role: Accessible.ListItem
                        Accessible.name: "%1: %2".arg(status === "completed" ? qsTr("Completed") : status === "running" ? qsTr("Running") : qsTr("Pending")).arg(step)

                        ShellIcon {
                            name: taskStep.status === "completed" ? "check" : taskStep.status === "running" ? "circle-dot" : "circle"
                            size: Theme.icon.sm
                            color: taskStep.status === "completed" ? Theme.palette.color("success", "#22c55e")
                                : taskStep.status === "running" ? Theme.palette.color("accent", "#3b6fe0") : Qt.alpha(requests.muted, 0.5)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: taskStep.step
                            color: taskStep.status === "running" ? requests.foreground : requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                            wrapMode: Text.Wrap
                        }
                        Text {
                            text: taskStep.duration
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                    }
                }
            }
        }

        // The pending approval.
        ShellCard {
            Layout.fillWidth: true
            visible: requests.approval !== null
            implicitHeight: approvalColumn.implicitHeight + 24

            ColumnLayout {
                id: approvalColumn

                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        Layout.fillWidth: true
                        text: requests.approval?.title ?? ""
                        wrapMode: Text.Wrap
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.body.size
                        font.weight: Font.DemiBold
                    }

                    ShellButton {
                        objectName: "approvalPrevious"
                        visible: requests.approvals.length > 1
                        implicitHeight: 22
                        subtle: true
                        iconName: "chevron-left"
                        implicitWidth: implicitHeight
                        enabled: requests.approvalIndex > 0
                        Accessible.name: qsTr("Previous approval")
                        onClicked: requests.approvalIndex -= 1
                    }

                    Text {
                        objectName: "approvalPosition"
                        visible: requests.approvals.length > 1
                        text: qsTr("%1/%2").arg(Math.min(requests.approvalIndex, requests.approvals.length - 1) + 1).arg(requests.approvals.length)
                        color: requests.muted
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.meta.size
                    }

                    ShellButton {
                        objectName: "approvalNext"
                        visible: requests.approvals.length > 1
                        implicitHeight: 22
                        subtle: true
                        iconName: "chevron-right"
                        implicitWidth: implicitHeight
                        enabled: requests.approvalIndex < requests.approvals.length - 1
                        Accessible.name: qsTr("Next approval")
                        onClicked: requests.approvalIndex += 1
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0 && text !== requests.approval?.title
                    text: requests.approval?.detail ?? ""
                    color: requests.foreground
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : requests.uiFont
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 6
                    elide: Text.ElideRight
                }

                Text {
                    objectName: "approvalProblem"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: requests.approval?.problem ?? ""
                    color: requests.warning
                    font.family: requests.uiFont
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.Wrap
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Repeater {
                        model: requests.approval?.options ?? []

                        delegate: ShellButton {
                            required property var modelData
                            required property int index

                            objectName: "approvalOption-" + modelData.decision
                            implicitHeight: 28
                            primary: index === 0
                            text: modelData.label
                            enabled: requests.approval.canRespond && !requests.approval.responding
                            ToolTip.visible: hovered && modelData.warning.length > 0
                            ToolTip.text: modelData.warning
                            onClicked: Shell.dispatch("composer.approval.respond", {
                                requestId: requests.approval.requestId,
                                decision: modelData.decision
                            })
                        }
                    }
                }

                // The provider's warnings, next to the option they apply to.
                Repeater {
                    model: (requests.approval?.options ?? []).filter(option => option.warning.length > 0)

                    delegate: Text {
                        required property var modelData

                        Layout.fillWidth: true
                        text: qsTr("%1: %2").arg(modelData.label).arg(modelData.warning)
                        color: requests.warning
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.meta.size
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // The agent's question, one of its questions at a time.
        ShellCard {
            id: questionCard

            objectName: "questionCard"
            Layout.fillWidth: true
            visible: requests.question !== null
            implicitHeight: questionColumn.implicitHeight + 24

            // A click on the card, off its controls, takes the keyboard to it.
            // Beneath them, so a button or field keeps its own clicks.
            MouseArea {
                anchors.fill: parent
                onPressed: questionCard.forceActiveFocus(Qt.MouseFocusReason)
            }

            ColumnLayout {
                id: questionColumn

                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        objectName: "questionTitle"
                        Layout.fillWidth: true
                        text: requests.current?.question ?? ""
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.body.size
                        font.weight: Font.DemiBold
                        wrapMode: Text.Wrap
                    }

                    ShellButton {
                        objectName: "questionPrevious"
                        visible: requests.asked.length > 1 && !requests.folded
                        implicitHeight: 22
                        subtle: true
                        iconName: "chevron-left"
                        implicitWidth: implicitHeight
                        enabled: requests.questionIndex > 0
                        Accessible.name: qsTr("Previous question")
                        onClicked: requests.moveTo(requests.questionIndex - 1)
                    }

                    Text {
                        objectName: "questionPosition"
                        visible: requests.asked.length > 1
                        text: qsTr("%1/%2").arg(Math.min(requests.questionIndex, requests.asked.length - 1) + 1).arg(requests.asked.length)
                        color: requests.muted
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.meta.size
                    }

                    ShellButton {
                        objectName: "questionNext"
                        visible: requests.asked.length > 1 && !requests.folded
                        implicitHeight: 22
                        subtle: true
                        iconName: "chevron-right"
                        implicitWidth: implicitHeight
                        enabled: requests.questionIndex < requests.asked.length - 1
                        Accessible.name: qsTr("Next question")
                        onClicked: requests.moveTo(requests.questionIndex + 1)
                    }

                    ShellButton {
                        objectName: "questionFold"
                        implicitHeight: 22
                        subtle: true
                        iconName: requests.folded ? "chevron-up" : "chevron-down"
                        implicitWidth: implicitHeight
                        Accessible.name: requests.folded ? qsTr("Show the question") : qsTr("Hide the question")
                        onClicked: requests.folded = !requests.folded
                    }
                }

                Repeater {
                    model: requests.asked

                    delegate: ColumnLayout {
                        id: questionItem

                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        visible: index === Math.min(requests.questionIndex, requests.asked.length - 1) && !requests.folded
                        spacing: Theme.space.sm

                        Text {
                            objectName: "questionHint"
                            Layout.fillWidth: true
                            visible: questionItem.modelData.multiSelect === true
                            text: qsTr("Select one or more options.")
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                            wrapMode: Text.Wrap
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm

                            Repeater {
                                model: questionItem.modelData.options

                                delegate: ShellButton {
                                    required property var modelData
                                    required property int index

                                    readonly property var picked: requests.picks[questionItem.modelData.id]

                                    objectName: "questionOption-" + modelData.label
                                    implicitHeight: 28
                                    checkable: true
                                    enabled: requests.answerable
                                    checked: Array.isArray(picked) ? picked.includes(modelData.label) : picked === modelData.label
                                    primary: checked
                                    // The number key that picks it.
                                    text: index < 9 ? qsTr("%1. %2").arg(index + 1).arg(modelData.label) : modelData.label
                                    Accessible.name: modelData.label
                                    ToolTip.visible: hovered && (modelData.description ?? "").length > 0
                                    ToolTip.text: modelData.description ?? ""
                                    onClicked: requests.pick(questionItem.modelData, modelData.label)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: questionItem.modelData.allowCustomAnswer !== false
                            spacing: Theme.space.sm

                            ShellTextField {
                                objectName: "questionAnswer-" + questionItem.modelData.id
                                Layout.fillWidth: true
                                placeholderText: qsTr("Or type your own answer")
                                enabled: requests.answerable
                                Accessible.name: qsTr("Or type your own answer")
                                text: requests.typed[questionItem.modelData.id] ?? ""
                                onTextEdited: requests.type(questionItem.modelData, text)
                            }

                            ShellButton {
                                objectName: "questionAttach-" + questionItem.modelData.id
                                implicitHeight: 28
                                subtle: true
                                iconName: "paperclip"
                                enabled: requests.answerable
                                Accessible.name: qsTr("Attach files")
                                onClicked: answerFiles.open()

                                FileDialog {
                                    id: answerFiles

                                    title: qsTr("Attach files")
                                    fileMode: FileDialog.OpenFiles
                                    onAccepted: requests.attachTo(questionItem.modelData.id, selectedFiles)
                                }
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            visible: (questionItem.modelData.attachments ?? []).length > 0
                            spacing: Theme.space.sm

                            Repeater {
                                model: questionItem.modelData.attachments ?? []

                                delegate: ComposerAttachment {
                                    required property var modelData

                                    attachment: modelData
                                    // An answer on its way keeps its files.
                                    removable: !(requests.question?.responding ?? false)
                                    onRemoveRequested: Shell.dispatch("composer.question.attachment.remove", {
                                        id: modelData.id
                                    })
                                    onRetryRequested: Shell.dispatch("composer.attachment.retry", {
                                        id: modelData.id
                                    })
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0 && !requests.folded
                    text: requests.question?.problem ?? ""
                    color: requests.warning
                    font.family: requests.uiFont
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: !requests.folded

                    Item {
                        Layout.fillWidth: true
                    }

                    ShellButton {
                        objectName: "questionDismiss"
                        implicitHeight: 28
                        subtle: true
                        text: qsTr("Dismiss")
                        enabled: requests.answerable
                        onClicked: Shell.dispatch("composer.question.dismiss", {
                            requestId: requests.question.requestId
                        })
                    }

                    ShellButton {
                        objectName: "questionSubmit"
                        implicitHeight: 28
                        primary: true
                        text: qsTr("Answer")
                        enabled: requests.answerable && requests.answers() !== null
                        onClicked: requests.submit()
                    }
                }
            }
        }

        // The proposed plan: implement it, or send a message to refine it.
        ShellCard {
            Layout.fillWidth: true
            visible: requests.plan !== null
            implicitHeight: planRow.implicitHeight + 20

            RowLayout {
                id: planRow

                anchors.fill: parent
                anchors.margins: Theme.space.sm
                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    // "Plan ready" and the plan's heading (ComposerPlanFollowUpBanner).
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        Text {
                            objectName: "planReady"
                            text: qsTr("Plan ready")
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.body.size
                            font.weight: Font.DemiBold
                        }
                        Text {
                            objectName: "planHeading"
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: requests.plan?.heading ?? ""
                            color: requests.foreground
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.body.size
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Implement the plan, or send a message to refine it.")
                        color: requests.muted
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.meta.size
                        elide: Text.ElideRight
                    }
                }

                ShellButton {
                    objectName: "planMore"
                    implicitHeight: 28
                    implicitWidth: 28
                    subtle: true
                    iconName: "ellipsis"
                    iconSize: 14
                    Accessible.name: qsTr("More plan actions")
                    onClicked: planMenu.open()

                    ShellMenu {
                        id: planMenu

                        y: -height - 4

                        ShellMenuItem {
                            objectName: "planNewThread"
                            text: qsTr("Implement in a new thread")
                            iconName: "message-square-plus"
                            onTriggered: Shell.dispatch("plan.implementInNewThread", {})
                        }
                        ShellMenuItem {
                            objectName: "planCopy"
                            text: qsTr("Copy plan")
                            iconName: "copy"
                            onTriggered: Shell.dispatch("plan.copy", {})
                        }
                        ShellMenuItem {
                            objectName: "planDownload"
                            text: qsTr("Download as Markdown")
                            iconName: "download"
                            onTriggered: Shell.dispatch("plan.download", {})
                        }
                        ShellMenuItem {
                            objectName: "planSave"
                            text: qsTr("Save to workspace…")
                            iconName: "save"
                            // Without a workspace the save only says so.
                            onTriggered: (requests.plan?.workspaceRoot ?? "").length > 0 ? planSaveDialog.open() : Shell.dispatch("plan.save", {})
                        }
                    }
                }

                // Implements the plan, or refines it once feedback is typed.
                ShellButton {
                    objectName: "planImplement"
                    readonly property bool refine: requests.composerModel?.planAction === "refine"
                    implicitHeight: 28
                    primary: true
                    text: refine ? qsTr("Refine") : qsTr("Implement")
                    onClicked: refine ? Shell.dispatch("composer.submit", {}) : Shell.dispatch("composer.plan.implement", {})
                }
            }
        }

        // The messages written with no connection, in the order they go once
        // it returns. One still waiting can be pulled back into the composer.
        ShellCard {
            objectName: "outboxCard"
            visible: requests.outbox.length > 0
            Layout.fillWidth: true
            implicitHeight: outboxColumn.implicitHeight

            ColumnLayout {
                id: outboxColumn

                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 0

                Repeater {
                    model: requests.outbox

                    delegate: RowLayout {
                        id: waitingRow

                        required property var modelData
                        readonly property var attachments: modelData.attachments ?? []

                        Layout.fillWidth: true
                        Layout.preferredHeight: 32
                        Layout.leftMargin: 12
                        Layout.rightMargin: Theme.space.sm
                        spacing: Theme.space.sm

                        ShellIcon {
                            name: "clock"
                            size: 13
                            color: requests.muted
                        }
                        Text {
                            objectName: "outboxText-" + waitingRow.modelData.messageId
                            Layout.fillWidth: true
                            text: waitingRow.modelData.text.length > 0 || waitingRow.attachments.length === 0 ? waitingRow.modelData.text : qsTr("%n attachment(s)", "", waitingRow.attachments.length)
                            textFormat: Text.PlainText
                            color: requests.foreground
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            objectName: "outboxStatus-" + waitingRow.modelData.messageId
                            text: waitingRow.modelData.sending ? qsTr("Sending…") : qsTr("Waiting to send")
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                        ShellButton {
                            objectName: "outboxEdit-" + waitingRow.modelData.messageId
                            implicitHeight: 24
                            subtle: true
                            text: qsTr("Edit")
                            // On its way, the environment may already have it.
                            enabled: !waitingRow.modelData.sending
                            onClicked: Shell.dispatch("composer.outbox.edit", {
                                messageId: waitingRow.modelData.messageId
                            })
                        }
                        ShellButton {
                            objectName: "outboxDelete-" + waitingRow.modelData.messageId
                            implicitHeight: 24
                            subtle: true
                            text: qsTr("Delete")
                            // On its way, the environment may already have it.
                            enabled: !waitingRow.modelData.sending
                            onClicked: Shell.dispatch("composer.outbox.delete", {
                                messageId: waitingRow.modelData.messageId
                            })
                        }
                    }
                }
            }
        }

        // What waits behind the running turn, stacked as one card: the user's
        // follow-ups in the order they run, then what the MC queued for the
        // agent (a delegated task's result), named by what it stands for. It
        // folds to its header, and scrolls past a few rows.
        ShellCard {
            id: queueCard

            property bool expanded: true
            readonly property int count: requests.queue.length + requests.waiting.length

            objectName: "queueCard"
            visible: count > 0
            Layout.fillWidth: true
            implicitHeight: queueColumn.implicitHeight

            ColumnLayout {
                id: queueColumn

                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 0

                ShellButton {
                    objectName: "queueToggle"
                    Layout.fillWidth: true
                    implicitHeight: 32
                    subtle: true
                    Accessible.name: queueCard.expanded ? qsTr("Collapse queued messages") : qsTr("Expand queued messages")
                    onClicked: queueCard.expanded = !queueCard.expanded

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: Theme.space.sm
                        spacing: Theme.space.sm

                        ShellIcon {
                            name: "clock"
                            size: 13
                            color: requests.muted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: requests.queueHeld ? qsTr("Queue held") : qsTr("Queued")
                            elide: Text.ElideRight
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                        Text {
                            objectName: "queueCount"
                            text: queueCard.count
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Theme.type.meta.size
                        }
                        ShellChevron {
                            direction: queueCard.expanded ? "down" : "right"
                            size: Theme.icon.sm
                            color: requests.muted
                        }
                    }
                }

                // A held queue says its messages are safe and offers the way on.
                RowLayout {
                    objectName: "queueHeld"
                    visible: requests.queueHeld
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    Layout.leftMargin: 12
                    Layout.rightMargin: Theme.space.sm
                    spacing: Theme.space.sm

                    ShellIcon {
                        name: "pause"
                        size: 13
                        color: requests.muted
                    }
                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Messages stay saved until you resume.")
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: Theme.type.meta.size
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                    ShellButton {
                        objectName: "queueResume"
                        implicitHeight: 24
                        subtle: true
                        text: requests.queueResuming ? qsTr("Resuming…") : qsTr("Resume queue")
                        enabled: !requests.queueResuming
                        onClicked: Shell.dispatch("composer.queue.resume", {})
                    }
                }

                Flickable {
                    id: queueList

                    // Tab can reach a row scrolled out of view: it scrolls in.
                    readonly property Item focusedItem: Window.activeFocusItem

                    objectName: "queueList"
                    visible: queueCard.expanded
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 200)
                    contentHeight: queueRows.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                        Accessible.name: qsTr("Scroll queued messages")
                    }
                    onFocusedItemChanged: {
                        let row = focusedItem;
                        while (row && row.parent !== queueRows)
                            row = row.parent;
                        if (!row)
                            return;
                        if (row.y < contentY)
                            contentY = row.y;
                        else if (row.y + row.height > contentY + height)
                            contentY = row.y + row.height - height;
                    }

                    ColumnLayout {
                        id: queueRows

                        width: parent.width
                        spacing: 0

                        Repeater {
                            model: requests.queue

                            delegate: ColumnLayout {
                                id: queued

                                required property var modelData
                                readonly property var attachments: modelData.attachments ?? []

                                Layout.fillWidth: true
                                spacing: 0

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 32
                                    Layout.leftMargin: 12
                                    Layout.rightMargin: Theme.space.sm
                                    spacing: Theme.space.sm

                                    Text {
                                        objectName: "queueText-" + queued.modelData.runId
                                        Layout.fillWidth: true
                                        // An attachment-only message says what it carries.
                                        text: queued.modelData.text.length > 0 || queued.attachments.length === 0 ? queued.modelData.text : qsTr("%n attachment(s)", "", queued.attachments.length)
                                        textFormat: Text.PlainText
                                        color: queued.modelData.text.length > 0 ? requests.foreground : requests.muted
                                        font.family: requests.uiFont
                                        font.pixelSize: Theme.type.meta.size
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }

                                    // Editing puts the message in the composer; sending saves it.
                                    ShellButton {
                                        objectName: "queueEdit-" + queued.modelData.runId
                                        implicitHeight: 24
                                        subtle: true
                                        text: requests.composerModel?.editingQueuedRunId === queued.modelData.runId ? qsTr("Editing") : qsTr("Edit")
                                        enabled: requests.composerModel?.editingQueuedRunId !== queued.modelData.runId
                                        onClicked: Shell.dispatch("composer.queue.edit", {
                                            runId: queued.modelData.runId
                                        })
                                    }

                                    ShellButton {
                                        objectName: "queueSteer-" + queued.modelData.runId
                                        implicitHeight: 24
                                        subtle: true
                                        text: qsTr("Steer")
                                        onClicked: Shell.dispatch("composer.queue.steer", {
                                            runId: queued.modelData.runId
                                        })
                                    }

                                    ShellButton {
                                        objectName: "queueRemove-" + queued.modelData.runId
                                        implicitHeight: 24
                                        subtle: true
                                        iconName: "x"
                                        implicitWidth: implicitHeight
                                        Accessible.name: qsTr("Remove from the queue")
                                        onClicked: Shell.dispatch("composer.queue.remove", {
                                            runId: queued.modelData.runId
                                        })
                                    }
                                }

                                // What it carries: an image's thumbnail, a file by name;
                                // either opens large in the attachment viewer.
                                Flow {
                                    objectName: "queueAttachments-" + queued.modelData.runId
                                    visible: queued.attachments.length > 0
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 12
                                    Layout.rightMargin: Theme.space.sm
                                    Layout.bottomMargin: Theme.space.sm
                                    spacing: Theme.space.sm

                                    Repeater {
                                        model: queued.attachments

                                        delegate: Rectangle {
                                            id: carried

                                            required property var modelData
                                            readonly property bool image: modelData.kind === "image"
                                            readonly property bool pictured: thumbnail.status === Image.Ready

                                            function open() {
                                                Shell.dispatch("attachment.sent.view", {
                                                    id: modelData.id,
                                                    name: modelData.name,
                                                    mimeType: modelData.mimeType ?? ""
                                                });
                                            }

                                            objectName: "queueAttachment-" + modelData.id
                                            Accessible.role: Accessible.Button
                                            Accessible.name: qsTr("Open %1").arg(modelData.name)
                                            Accessible.onPressAction: open()
                                            activeFocusOnTab: true
                                            Keys.onReturnPressed: open()
                                            Keys.onEnterPressed: open()
                                            Keys.onSpacePressed: open()
                                            width: image ? 48 : Math.min(220, fileLabel.implicitWidth + 30)
                                            height: image ? 48 : 24
                                            radius: 2
                                            color: Qt.alpha(requests.foreground, 0.04)
                                            border.color: activeFocus ? requests.foreground : Qt.alpha(requests.foreground, 0.12)

                                            Image {
                                                id: thumbnail
                                                visible: carried.image
                                                anchors.fill: parent
                                                anchors.margins: 1
                                                source: carried.image ? carried.modelData.url ?? "" : ""
                                                sourceSize.height: 96
                                                fillMode: Image.PreserveAspectCrop
                                                clip: true
                                            }
                                            ShellIcon {
                                                visible: carried.image ? !carried.pictured : true
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.horizontalCenter: carried.image ? parent.horizontalCenter : undefined
                                                x: 6
                                                name: carried.image ? "image" : "file-text"
                                                size: carried.image ? 18 : 12
                                                color: requests.muted
                                            }
                                            Text {
                                                id: fileLabel
                                                visible: !carried.image
                                                anchors.verticalCenter: parent.verticalCenter
                                                x: 22
                                                width: parent.width - 28
                                                text: carried.modelData.name
                                                textFormat: Text.PlainText
                                                color: requests.foreground
                                                font.family: requests.uiFont
                                                font.pixelSize: Theme.type.caption.size
                                                elide: Text.ElideMiddle
                                            }
                                            HoverHandler {
                                                id: carriedHover
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                onTapped: carried.open()
                                            }
                                            ToolTip.visible: carriedHover.hovered && carried.image
                                            ToolTip.delay: 500
                                            ToolTip.text: carried.modelData.name
                                        }
                                    }
                                }
                            }
                        }

                        // The agent's own: nothing to edit, steer with or remove.
                        Repeater {
                            model: requests.waiting

                            // Indented, without an icon: a Shape is not clipped
                            // by the list's scroll.
                            delegate: Text {
                                id: notice

                                required property var modelData

                                // The worker whose result this waits to deliver; its thread opens.
                                readonly property string worker: modelData.workerThreadId ?? ""

                                objectName: "queueWaiting-" + modelData.runId
                                Accessible.role: notice.worker.length > 0 ? Accessible.Link : Accessible.StaticText
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                Layout.leftMargin: 24
                                Layout.rightMargin: 12
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.summary
                                textFormat: Text.PlainText
                                color: modelData.outcome === "failed" ? requests.warning : requests.muted
                                font.family: requests.uiFont
                                font.pixelSize: Theme.type.meta.size
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.underline: notice.worker.length > 0 && waitingHover.hovered

                                HoverHandler {
                                    id: waitingHover
                                    enabled: notice.worker.length > 0
                                    cursorShape: Qt.PointingHandCursor
                                }
                                TapHandler {
                                    enabled: notice.worker.length > 0
                                    onTapped: Shell.dispatch("rightPanel.openThread", {
                                        threadKey: Threads.activeThread.slice(0, Threads.activeThread.indexOf(":") + 1) + notice.worker
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Where in the workspace the plan is saved, starting from its file name.
    // It closes once the plan is written and stays open when the write fails
    // or no path is given, so another can be tried.
    Popup {
        id: planSaveDialog
        objectName: "planSaveDialog"

        readonly property int saved: Shell.state.planSave?.saved ?? 0
        readonly property bool saving: Shell.state.planSave?.saving === true
        onSavedChanged: close()

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: 380
        modal: true
        padding: 16
        onAboutToShow: planSavePath.text = requests.plan?.fileName ?? ""
        onOpened: {
            planSavePath.forceActiveFocus();
            planSavePath.selectAll();
        }

        Overlay.modal: ShellScrim {}
        background: ShellPopoverSurface {}

        contentItem: ColumnLayout {
            spacing: Theme.space.sm

            Text {
                text: qsTr("Save plan to workspace")
                color: requests.foreground
                font.family: requests.uiFont
                font.pixelSize: Theme.type.title.size
                font.weight: Font.DemiBold
            }
            Text {
                objectName: "planSaveHint"
                Layout.fillWidth: true
                text: qsTr("Enter a path relative to %1.").arg(requests.plan?.workspaceRoot ?? "")
                color: requests.muted
                font.family: requests.uiFont
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
            ShellTextField {
                id: planSavePath

                objectName: "planSavePath"
                Layout.fillWidth: true
                placeholderText: qsTr("Path in the workspace, e.g. docs/plan.md")
                Accessible.name: qsTr("Workspace path")
                onAccepted: planSaveConfirm.clicked()
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                Item {
                    Layout.fillWidth: true
                }
                ShellButton {
                    text: qsTr("Cancel")
                    onClicked: planSaveDialog.close()
                }
                ShellButton {
                    id: planSaveConfirm

                    objectName: "planSaveConfirm"
                    primary: true
                    enabled: !planSaveDialog.saving
                    text: planSaveDialog.saving ? qsTr("Saving...") : qsTr("Save")
                    onClicked: Shell.dispatch("plan.save", {
                        path: planSavePath.text.trim()
                    })
                }
            }
        }
    }
}
