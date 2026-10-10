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
    readonly property string uiFont: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    readonly property int maximumCardWidth: 768
    readonly property int gutter: 20

    // Whether the turn waits on anything. The height follows this and not
    // `visible`, which a host may bind to more than this.
    readonly property bool pending: approval !== null || question !== null || plan !== null || queue.length > 0 || waiting.length > 0

    visible: pending
    implicitHeight: pending ? column.implicitHeight + 8 : 0

    onQuestionChanged: {
        const id = question?.requestId ?? "";
        if (id === answering) return;
        answering = id;
        picks = {};
        typed = {};
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
                        font.pixelSize: Math.round(13 * Theme.fontScale)
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
                        font.pixelSize: Math.round(12 * Theme.fontScale)
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
                    font.pixelSize: Math.round(12 * Theme.fontScale)
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
                    font.pixelSize: Math.round(12 * Theme.fontScale)
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
                        font.pixelSize: Math.round(12 * Theme.fontScale)
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
                            font.pixelSize: Math.round(13 * Theme.fontScale)
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

                        RowLayout {
                            Layout.fillWidth: true
                            visible: questionItem.modelData.allowCustomAnswer !== false
                            spacing: 6

                            ShellTextField {
                                objectName: "questionAnswer-" + questionItem.modelData.id
                                Layout.fillWidth: true
                                placeholderText: qsTr("Or type your own answer")
                                text: requests.typed[questionItem.modelData.id] ?? ""
                                onTextEdited: requests.type(questionItem.modelData, text)
                            }

                            ShellButton {
                                objectName: "questionAttach-" + questionItem.modelData.id
                                implicitHeight: 28
                                subtle: true
                                iconName: "paperclip"
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
                            spacing: 6

                            Repeater {
                                model: questionItem.modelData.attachments ?? []

                                delegate: ComposerAttachment {
                                    required property var modelData

                                    attachment: modelData
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
                    visible: text.length > 0
                    text: requests.question?.problem ?? ""
                    color: requests.warning
                    font.family: requests.uiFont
                    font.pixelSize: Math.round(12 * Theme.fontScale)
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
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Implement the plan, or send a message to refine it.")
                        color: requests.muted
                        font.family: requests.uiFont
                        font.pixelSize: Math.round(12 * Theme.fontScale)
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
                            onTriggered: planSaveDialog.open()
                        }
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

        // What waits behind the running turn, stacked as one card: the user's
        // follow-ups in the order they run, then what the MC queued for the
        // agent (a delegated task's result), named by what it stands for. It
        // folds to its header, and scrolls past a few rows, as the web's
        // QueuedRunsControl does.
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
                        anchors.rightMargin: 10
                        spacing: 6

                        ShellIcon {
                            name: "clock"
                            size: 13
                            color: requests.muted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Queued")
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                        Text {
                            objectName: "queueCount"
                            text: queueCard.count
                            color: requests.muted
                            font.family: requests.uiFont
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                        ShellIcon {
                            name: queueCard.expanded ? "chevron-down" : "chevron-right"
                            size: 13
                            color: requests.muted
                        }
                    }
                }

                Flickable {
                    objectName: "queueList"
                    visible: queueCard.expanded
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 128)
                    contentHeight: queueRows.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                    }

                    ColumnLayout {
                        id: queueRows

                        width: parent.width
                        spacing: 0

                        Repeater {
                            model: requests.queue

                            delegate: RowLayout {
                                id: queued

                                required property var modelData

                                Layout.fillWidth: true
                                Layout.preferredHeight: 32
                                Layout.leftMargin: 12
                                Layout.rightMargin: 6
                                spacing: 6

                                Text {
                                    Layout.fillWidth: true
                                    text: queued.modelData.text
                                    textFormat: Text.PlainText
                                    color: requests.foreground
                                    font.family: requests.uiFont
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
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
                        }

                        // The agent's own: nothing to edit, steer with or remove.
                        Repeater {
                            model: requests.waiting

                            delegate: RowLayout {
                                id: notice

                                required property var modelData

                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                Layout.leftMargin: 12
                                Layout.rightMargin: 12
                                spacing: 6

                                ShellIcon {
                                    name: "corner-down-right"
                                    size: 12
                                    color: notice.modelData.outcome === "failed" ? requests.warning : requests.muted
                                }
                                Text {
                                    objectName: "queueWaiting-" + notice.modelData.runId
                                    Layout.fillWidth: true
                                    text: notice.modelData.summary
                                    textFormat: Text.PlainText
                                    color: requests.muted
                                    font.family: requests.uiFont
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Where in the workspace the plan is saved; empty takes the
    // plan's own file name.
    Popup {
        id: planSaveDialog
        objectName: "planSaveDialog"

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: 380
        modal: true
        padding: 16
        onOpened: {
            planSavePath.text = "";
            planSavePath.forceActiveFocus();
        }

        background: Rectangle {
            radius: Theme.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 10

            Text {
                text: qsTr("Save plan to workspace")
                color: requests.foreground
                font.family: requests.uiFont
                font.pixelSize: Math.round(15 * Theme.fontScale)
                font.bold: true
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
                spacing: 6

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
                    text: qsTr("Save")
                    onClicked: {
                        Shell.dispatch("plan.save", {
                            path: planSavePath.text.trim()
                        });
                        planSaveDialog.close();
                    }
                }
            }
        }
    }
}
