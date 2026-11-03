pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Maintenance page: the repositories the plugin maintains, when each runs
// next with a Run now, and its runs, newest first, each with what its agent
// applied and deferred. From a run: open its thread, open its pull request (or
// the one it opened), cancel it while it runs, dismiss it once it ended, or run
// its repository again. Follows the `maintenance` topic of each MC that runs
// the plugin, one MC at a time.
Item {
    id: page

    property var plugin
    // environment → the last value of its `maintenance` topic.
    property var byEnvironment: ({})
    // environment → its watch.
    property var watches: ({})
    property string environment: ""
    readonly property var maintenance: byEnvironment[environment] ?? null
    readonly property var repositories: maintenance?.repositories ?? []
    readonly property var runs: (maintenance?.runs ?? []).slice().sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0))
    property string refusal: ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")

    function follow() {
        const watches = {};
        for (const environment of page.plugin.environments) {
            watches[environment] = page.watches[environment] ?? page.plugin.watch("maintenance", value => {
                const next = Object.assign({}, page.byEnvironment);
                next[environment] = value;
                page.byEnvironment = next;
            }, environment);
        }
        for (const environment of Object.keys(page.watches)) {
            if (watches[environment] === undefined)
                page.plugin.unwatch(page.watches[environment]);
        }
        page.watches = watches;
        if (!page.plugin.environments.includes(page.environment))
            page.environment = page.plugin.environments[0] ?? "";
    }

    function start(method, input) {
        page.refusal = "";
        page.plugin.call(method, input, (result, error) => {
            if (error)
                page.refusal = error;
        }, page.environment);
    }

    // Whether a run's repository has a run that keeps a new one from starting.
    function held(repository) {
        return page.runs.some(run => run.repository === repository && (run.status === "running" || run.status === "waiting" || run.status === "publishing"));
    }

    function runStatus(run) {
        switch (run.status) {
        case "running":
            return qsTr("Running");
        case "waiting":
            return qsTr("Waiting for you to open its pull request");
        case "publishing":
            return qsTr("Opening its pull request…");
        case "kept":
            return qsTr("Kept in HAL-C2");
        case "published":
            return qsTr("Pull request open");
        case "done":
            return run.mode === "report" ? qsTr("Reported") : qsTr("Nothing to change");
        case "skipped":
            return qsTr("Skipped");
        case "cancelled":
            return qsTr("Cancelled");
        case "failed":
            return qsTr("Failed");
        default:
            return run.status;
        }
    }

    // What each category came to, such as "Dependencies: 2 applied, 1 deferred".
    function categoryLines(run) {
        const titles = {
            "deps": qsTr("Dependencies"),
            "security-alerts": qsTr("Security alerts"),
            "docs-drift": qsTr("Docs drift"),
            "coverage-gaps": qsTr("Coverage gaps")
        };
        return (run.report?.categories ?? []).map(entry => {
            const parts = [];
            if ((entry.applied ?? []).length > 0)
                parts.push(qsTr("%n applied", "", entry.applied.length));
            if ((entry.deferred ?? []).length > 0)
                parts.push(qsTr("%n deferred", "", entry.deferred.length));
            if ((entry.findings ?? []).length > 0)
                parts.push(qsTr("%n to discuss", "", entry.findings.length));
            return qsTr("%1: %2").arg(titles[entry.category] ?? entry.category).arg(parts.length > 0 ? parts.join(", ") : qsTr("nothing to do"));
        });
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    function when(value) {
        return value ? Qt.formatDateTime(new Date(value), Qt.locale().dateTimeFormat(Locale.ShortFormat)) : "";
    }

    objectName: "maintenancePage"
    implicitWidth: 900
    implicitHeight: 600
    Component.onCompleted: follow()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    Flickable {
        anchors.fill: parent
        clip: true
        contentHeight: content.implicitHeight + 32
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {}

        ColumnLayout {
            id: content

            x: 16
            y: 16
            width: page.width - 32
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    objectName: "maintenanceFollowing"
                    Layout.fillWidth: true
                    text: page.maintenance === null ? qsTr("Waiting for the maintenance plugin…") : qsTr("%n repository(ies) maintained", "", page.repositories.length)
                    color: page.muted
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                ShellComboBox {
                    visible: page.plugin.environments.length > 1
                    outline: true
                    implicitWidth: 180
                    model: page.plugin.environments.map(environment => page.environmentLabel(environment))
                    currentIndex: page.plugin.environments.indexOf(page.environment)
                    Accessible.name: qsTr("Machine")
                    onActivated: index => page.environment = page.plugin.environments[index]
                }
            }

            Text {
                objectName: "maintenanceProblem"
                Layout.fillWidth: true
                visible: text.length > 0
                text: page.refusal
                color: page.warningColor
                wrapMode: Text.Wrap
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Text {
                Layout.fillWidth: true
                visible: page.maintenance !== null && page.repositories.length === 0
                text: qsTr("No repositories yet. Pick them in the plugin's settings from this machine's GitHub projects.")
                color: page.muted
                wrapMode: Text.Wrap
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            Repeater {
                model: page.repositories

                delegate: RowLayout {
                    id: repository

                    required property var modelData

                    objectName: "maintenanceRepository:" + modelData.repository
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: repository.modelData.repository
                            color: page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            font.weight: Font.Medium
                        }

                        Text {
                            objectName: "maintenanceNext:" + repository.modelData.repository
                            Layout.fillWidth: true
                            text: {
                                const parts = [];
                                if (!repository.modelData.project)
                                    parts.push(qsTr("no project has it as its remote"));
                                if (repository.modelData.nextRunAt)
                                    parts.push(qsTr("next run %1").arg(page.when(repository.modelData.nextRunAt)));
                                else
                                    parts.push(qsTr("runs when you ask"));
                                return parts.join(" · ");
                            }
                            color: page.muted
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                    }

                    ShellButton {
                        objectName: "maintenanceRunNow:" + repository.modelData.repository
                        enabled: !page.held(repository.modelData.repository)
                        text: qsTr("Run now")
                        onClicked: page.start("run", {
                            repository: repository.modelData.repository
                        })
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                visible: page.runs.length > 0
                color: page.border
            }

            Repeater {
                objectName: "maintenanceRuns"
                model: page.runs

                delegate: ColumnLayout {
                    id: run

                    required property var modelData
                    readonly property string status: modelData.status
                    readonly property string problem: modelData.publishError || ((status === "failed" || status === "skipped") ? (modelData.error ?? "") : "")

                    objectName: "maintenanceRun:" + modelData.id
                    Layout.fillWidth: true
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("%1, %2").arg(run.modelData.repository).arg(run.modelData.date)
                            color: page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            font.weight: Font.Medium
                        }

                        ShellButton {
                            objectName: "maintenancePublish:" + run.modelData.id
                            visible: run.status === "waiting" || run.status === "kept" || run.status === "publishing"
                            primary: true
                            enabled: run.status !== "publishing"
                            text: enabled ? qsTr("Open pull request") : qsTr("Opening…")
                            onClicked: page.start("publish", {
                                runId: run.modelData.id
                            })
                        }

                        ShellButton {
                            objectName: "maintenanceOpenPullRequest:" + run.modelData.id
                            subtle: true
                            visible: (run.modelData.prUrl ?? "").length > 0
                            text: qsTr("Open on GitHub")
                            onClicked: Qt.openUrlExternally(run.modelData.prUrl)
                        }

                        ShellButton {
                            objectName: "maintenanceThread:" + run.modelData.id
                            subtle: true
                            visible: (run.modelData.threadId ?? "").length > 0 && run.status !== "skipped"
                            text: qsTr("Open thread")
                            onClicked: page.plugin.openThread(run.modelData.threadId, page.environment)
                        }

                        ShellButton {
                            objectName: "maintenanceCancel:" + run.modelData.id
                            subtle: true
                            visible: run.status === "running"
                            text: qsTr("Cancel")
                            onClicked: page.start("cancel", {
                                runId: run.modelData.id
                            })
                        }

                        ShellButton {
                            objectName: "maintenanceRerun:" + run.modelData.id
                            subtle: true
                            visible: run.status !== "running" && run.status !== "publishing"
                            enabled: !page.held(run.modelData.repository)
                            text: qsTr("Run again")
                            onClicked: page.start("run", {
                                repository: run.modelData.repository
                            })
                        }

                        ShellButton {
                            objectName: "maintenanceDismiss:" + run.modelData.id
                            subtle: true
                            visible: run.status !== "running" && run.status !== "publishing"
                            text: qsTr("Dismiss")
                            onClicked: page.start("dismiss", {
                                runId: run.modelData.id
                            })
                        }
                    }

                    Text {
                        objectName: "maintenanceStatus:" + run.modelData.id
                        Layout.fillWidth: true
                        text: {
                            const parts = [page.runStatus(run.modelData), run.modelData.mode === "report" ? qsTr("report only") : run.modelData.branch ?? ""];
                            if (run.modelData.trigger === "scheduled")
                                parts.push(qsTr("scheduled"));
                            return parts.filter(part => part.length > 0).join(" · ");
                        }
                        color: page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Text {
                        objectName: "maintenanceSummary:" + run.modelData.id
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: run.modelData.report?.summary ?? ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Text {
                        objectName: "maintenanceCategories:" + run.modelData.id
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: page.categoryLines(run.modelData).join("\n")
                        color: page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Text {
                        objectName: "maintenanceRunProblem:" + run.modelData.id
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: run.problem
                        color: run.status === "skipped" ? page.muted : page.errorColor
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }
            }
        }
    }
}
