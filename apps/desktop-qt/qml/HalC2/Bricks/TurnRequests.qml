import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What the open thread's turn waits on from the user, which the Composer
// stacks on top of its prompt: the pending approval (one at a time, with its position), the
// agent's question, the proposed plan once the turn is over, and the queued
// follow-ups. Rendered from Shell.state.turn (ComposerController) for the
// thread the composer shows; every answer is a composer.* action the shell
// sends to the MC.
Item {
    id: requests

    readonly property var turn: Shell.state.turn ?? null
    readonly property var composerModel: Shell.state.composer ?? null
    readonly property bool shown: turn !== null && composerModel !== null && turn.threadKey === composerModel.target
    readonly property var approvals: shown ? turn.approvals : []
    readonly property var questions: shown ? turn.questions : []
    readonly property var plan: shown ? turn.plan ?? null : null
    readonly property var queue: shown ? turn.queue : []
    property int approvalIndex: 0
    readonly property var approval: approvals.length > 0 ? approvals[Math.min(approvalIndex, approvals.length - 1)] : null
    readonly property var question: questions.length > 0 ? questions[0] : null
    // The options picked for each question of `question`, by question id, and
    // what the user typed instead.
    property var picks: ({})
    property var typed: ({})
    property string answering: ""

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color warning: Theme.palette.color("warning", "#e0af68")
    readonly property string uiFont: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
    readonly property int maximumCardWidth: 768
    readonly property int gutter: 20

    // Whether the turn waits on anything. The height follows this and not
    // `visible`, which a host may bind to more than this.
    readonly property bool pending: approval !== null || question !== null || plan !== null || queue.length > 0

    visible: pending
    implicitHeight: pending ? column.implicitHeight + 8 : 0

    onQuestionChanged: {
        const id = question?.requestId ?? "";
        if (id === answering) return;
        answering = id;
        picks = {};
        typed = {};
    }

    function pick(item, label) {
        const next = Object.assign({}, picks);
        if (item.multiSelect) {
            const chosen = next[item.id] ?? [];
            next[item.id] = chosen.includes(label) ? chosen.filter(value => value !== label) : chosen.concat([label]);
        } else {
            next[item.id] = next[item.id] === label ? undefined : label;
        }
        picks = next;
    }

    function type(item, text) {
        typed = Object.assign({}, typed, {
            [item.id]: text
        });
    }

    // What the agent receives for each question: typed text wins over picks.
    function answers() {
        const result = {};
        for (const item of question?.questions ?? []) {
            const text = (typed[item.id] ?? "").trim();
            const picked = picks[item.id];
            if (text.length > 0) {
                result[item.id] = text;
            } else if (Array.isArray(picked) ? picked.length > 0 : picked !== undefined) {
                result[item.id] = picked;
            } else {
                return null;
            }
        }
        return result;
    }

    ColumnLayout {
        id: column

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - requests.gutter * 2, requests.maximumCardWidth)
        spacing: 6

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
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: 13
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
                        font.pixelSize: 12
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
                    font.pixelSize: 12
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
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 6

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
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // The agent's question.
        ShellCard {
            Layout.fillWidth: true
            visible: requests.question !== null
            implicitHeight: questionColumn.implicitHeight + 24

            ColumnLayout {
                id: questionColumn

                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Repeater {
                    model: requests.question?.questions ?? []

                    delegate: ColumnLayout {
                        id: questionItem

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                            Layout.fillWidth: true
                            text: questionItem.modelData.question
                            color: requests.foreground
                            font.family: requests.uiFont
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            wrapMode: Text.Wrap
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Repeater {
                                model: questionItem.modelData.options

                                delegate: ShellButton {
                                    required property var modelData

                                    readonly property var picked: requests.picks[questionItem.modelData.id]

                                    objectName: "questionOption-" + modelData.label
                                    implicitHeight: 28
                                    checkable: true
                                    checked: Array.isArray(picked) ? picked.includes(modelData.label) : picked === modelData.label
                                    primary: checked
                                    text: modelData.label
                                    ToolTip.visible: hovered && (modelData.description ?? "").length > 0
                                    ToolTip.text: modelData.description ?? ""
                                    onClicked: requests.pick(questionItem.modelData, modelData.label)
                                }
                            }
                        }

                        ShellTextField {
                            objectName: "questionAnswer-" + questionItem.modelData.id
                            Layout.fillWidth: true
                            visible: questionItem.modelData.allowCustomAnswer !== false
                            placeholderText: qsTr("Or type your own answer")
                            text: requests.typed[questionItem.modelData.id] ?? ""
                            onTextEdited: requests.type(questionItem.modelData, text)
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: requests.question?.problem ?? ""
                    color: requests.warning
                    font.family: requests.uiFont
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    Layout.fillWidth: true

                    Item {
                        Layout.fillWidth: true
                    }

                    ShellButton {
                        objectName: "questionDismiss"
                        implicitHeight: 28
                        subtle: true
                        text: qsTr("Dismiss")
                        enabled: requests.question !== null && requests.question.canRespond && !requests.question.responding
                        onClicked: Shell.dispatch("composer.question.dismiss", {
                            requestId: requests.question.requestId
                        })
                    }

                    ShellButton {
                        objectName: "questionSubmit"
                        implicitHeight: 28
                        primary: true
                        text: qsTr("Answer")
                        enabled: requests.question !== null && requests.question.canRespond && !requests.question.responding && requests.answers() !== null
                        onClicked: Shell.dispatch("composer.question.answer", {
                            requestId: requests.question.requestId,
                            answers: requests.answers()
                        })
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
                anchors.margins: 10
                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        Layout.fillWidth: true
                        text: requests.plan?.title ?? ""
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Implement the plan, or send a message to refine it.")
                        color: requests.muted
                        font.family: requests.uiFont
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                }

                ShellButton {
                    objectName: "planImplement"
                    implicitHeight: 28
                    primary: true
                    text: qsTr("Implement")
                    onClicked: Shell.dispatch("composer.plan.implement", {})
                }
            }
        }

        // Follow-ups waiting behind the running turn, in the order they run.
        Repeater {
            model: requests.queue

            delegate: ShellCard {
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: 36

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 6
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        text: modelData.text
                        color: requests.foreground
                        font.family: requests.uiFont
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    // Editing puts the message in the composer; sending saves it.
                    ShellButton {
                        objectName: "queueEdit-" + modelData.runId
                        implicitHeight: 24
                        subtle: true
                        text: requests.composerModel?.editingQueuedRunId === modelData.runId ? qsTr("Editing") : qsTr("Edit")
                        enabled: requests.composerModel?.editingQueuedRunId !== modelData.runId
                        onClicked: Shell.dispatch("composer.queue.edit", {
                            runId: modelData.runId
                        })
                    }

                    ShellButton {
                        objectName: "queueSteer-" + modelData.runId
                        implicitHeight: 24
                        subtle: true
                        text: qsTr("Steer")
                        onClicked: Shell.dispatch("composer.queue.steer", {
                            runId: modelData.runId
                        })
                    }

                    ShellButton {
                        objectName: "queueRemove-" + modelData.runId
                        implicitHeight: 24
                        subtle: true
                        iconName: "x"
                        implicitWidth: implicitHeight
                        Accessible.name: qsTr("Remove from the queue")
                        onClicked: Shell.dispatch("composer.queue.remove", {
                            runId: modelData.runId
                        })
                    }
                }
            }
        }
    }
}
