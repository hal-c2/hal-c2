pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// TokenEconomizer's page, for one MC at a time: what the loop guard did lately,
// one project's micro-skills (its facts with their evidence, drop and restore,
// its import from history with a Forget), and tool pruning's tools per project
// and provider (apply, restore) with whatever holds pruning off and the way out.
// Follows `loopGuard`, `toolPrune` and the one project's `microSkills:<id>`;
// the plugin publishes them only on a change, so each is asked for once too.
Item {
    id: page

    property var plugin
    property string environment: ""
    property var loopGuard: null
    property var toolPrune: null
    // The micro-skills listing (`microSkills` call) and the shown project's entry.
    property var microSkills: null
    property string projectId: ""
    property var skills: null
    property var watches: []
    property var skillsWatch: null
    property string refusal: ""

    readonly property var skillProjects: (microSkills?.projects ?? []).map(entry => entry.projectId)
    readonly property var prunes: toolPrune?.projects ?? []
    // The call's answer has no top-level list; each project says whether it is held.
    readonly property var unreadable: toolPrune?.unreadable ?? [...new Set(prunes.filter(each => each.unreadable).map(each => each.provider))]
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")

    function follow() {
        if (!page.plugin.environments.includes(page.environment))
            page.environment = page.plugin.environments[0] ?? "";
    }

    // Everything one MC shows: its two topics, once asked and then followed.
    function load() {
        for (const watch of page.watches)
            page.plugin.unwatch(watch);
        page.watches = [];
        page.loopGuard = null;
        page.toolPrune = null;
        page.microSkills = null;
        page.showProject("");
        if (page.environment.length === 0)
            return;
        const environment = page.environment;
        page.plugin.call("status", {}, result => {
            if (result && page.environment === environment && page.loopGuard === null)
                page.loopGuard = result;
        }, environment);
        page.plugin.call("toolPrune", {}, result => {
            if (result && page.environment === environment && page.toolPrune === null)
                page.toolPrune = result;
        }, environment);
        page.plugin.call("microSkills", {}, result => {
            if (!result || page.environment !== environment)
                return;
            page.microSkills = result;
            const ids = result.projects.map(entry => entry.projectId);
            if (!ids.includes(page.projectId))
                page.showProject(ids[0] ?? "");
        }, environment);
        page.watches = [page.plugin.watch("loopGuard", value => page.loopGuard = value, environment), page.plugin.watch("toolPrune", value => page.toolPrune = value, environment)];
    }

    function showProject(projectId) {
        if (page.skillsWatch !== null)
            page.plugin.unwatch(page.skillsWatch);
        page.skillsWatch = null;
        page.projectId = projectId;
        page.skills = (page.microSkills?.projects ?? []).find(entry => entry.projectId === projectId) ?? null;
        if (projectId.length > 0)
            page.skillsWatch = page.plugin.watch("microSkills:" + projectId, value => page.skills = value, page.environment);
    }

    function start(method, input, done) {
        page.refusal = "";
        page.plugin.call(method, input, (result, error) => {
            if (error)
                page.refusal = error;
            else if (done)
                done(result);
        }, page.environment);
    }

    // Drop, restore and forget answer the project's entry.
    function skillsCall(method, input) {
        page.start(method, Object.assign({
            projectId: page.projectId
        }, input), result => {
            const entry = result?.projects?.[0];
            if (entry && entry.projectId === page.projectId)
                page.skills = entry;
        });
    }

    function projectName(projectId) {
        const sidebar = Shell.state.sidebar ?? {};
        const known = (sidebar.projects ?? []).concat(sidebar.localProjects ?? []).find(each => each.projectId === projectId && each.environmentId === page.environment);
        return known?.displayName ?? projectId;
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    function percent(rate) {
        return rate === null || rate === undefined ? qsTr("not yet exercised") : qsTr("fires %1%").arg(Math.round(rate * 100));
    }

    function factState(state) {
        switch (state) {
        case "ACTIVE":
            return qsTr("active");
        case "CANDIDATE":
            return qsTr("forming");
        case "RETIRED":
            return qsTr("retired");
        default:
            return String(state).toLowerCase();
        }
    }

    function importLine(history) {
        const read = qsTr("read %1 of %2 thread(s)").arg(history.threadsRead ?? 0).arg(history.threads ?? 0);
        switch (history?.state ?? "none") {
        case "running":
            return history.threads === undefined ? qsTr("Import from earlier threads: planning") : qsTr("Import from earlier threads: running, %1").arg(read);
        case "done":
            return qsTr("Import from earlier threads: done, %1, %n turn(s) learned from", "", history.turns ?? 0).arg(read);
        case "stopped":
            return qsTr("Import from earlier threads: stopped (%1), %2").arg(history.reason ?? "").arg(read);
        case "skipped":
            return qsTr("Import from earlier threads: skipped, %1").arg(history.reason ?? "");
        default:
            return qsTr("Not imported from earlier threads");
        }
    }

    function leftOut(history) {
        const skipped = history?.skipped ?? {};
        return Object.keys(skipped).sort().map(reason => qsTr("%1: %2").arg(reason).arg(skipped[reason])).join(", ");
    }

    function toolLine(tool) {
        return qsTr("unused for the last %1 conversation(s) and %2 prompt(s); loaded in %3").arg(tool.unusedSessions ?? 0).arg(tool.unusedPrompts ?? 0).arg(tool.loadedSessions ?? 0);
    }

    function toolStateLabel(state) {
        switch (state) {
        case "off":
            return qsTr("Off");
        case "proposed":
            return qsTr("Proposed");
        case "kept":
            return qsTr("Given back");
        default:
            return state;
        }
    }

    objectName: "tokenEconomizerPage"
    implicitWidth: 900
    implicitHeight: 600
    onEnvironmentChanged: load()
    Component.onCompleted: {
        follow();
        if (page.watches.length === 0)
            load();
    }

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    component Heading: Text {
        Layout.fillWidth: true
        Layout.topMargin: 8
        color: page.foreground
        font.pixelSize: Math.round(14 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    component Line: Text {
        Layout.fillWidth: true
        visible: text.length > 0
        color: page.muted
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    component Rule: Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: page.border
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
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                visible: page.plugin.environments.length > 1
                spacing: 8

                Item {
                    Layout.fillWidth: true
                }

                ShellComboBox {
                    outline: true
                    implicitWidth: 180
                    model: page.plugin.environments.map(environment => page.environmentLabel(environment))
                    currentIndex: page.plugin.environments.indexOf(page.environment)
                    Accessible.name: qsTr("Machine")
                    onActivated: index => page.environment = page.plugin.environments[index]
                }
            }

            Line {
                objectName: "tokenEconomizerProblem"
                text: page.refusal
                color: page.warningColor
            }

            // --- loop guard ---------------------------------------------------------
            Heading {
                text: qsTr("Loop guard")
            }

            Line {
                objectName: "tokenEconomizerLoopGuard"
                text: {
                    const guard = page.loopGuard;
                    if (guard === null)
                        return qsTr("Waiting for TokenEconomizer…");
                    const mode = {
                        "nudge": qsTr("Redirects stuck agents"),
                        "watch": qsTr("Only watching"),
                        "off": qsTr("Off")
                    }[guard.mode] ?? guard.mode;
                    return [mode, qsTr("%n turn(s) watched now", "", guard.watching ?? 0), qsTr("%n redirect(s)", "", guard.nudges ?? 0), qsTr("%n stop(s) offered", "", guard.aborts ?? 0)].join(" · ");
                }
            }

            Repeater {
                model: (page.loopGuard?.recent ?? []).slice(-5).reverse()

                delegate: RowLayout {
                    id: recent

                    required property var modelData

                    objectName: "tokenEconomizerRecent:" + modelData.runId
                    Layout.fillWidth: true
                    spacing: 8

                    Line {
                        text: qsTr("%1 · %2 · %3").arg(Format.dateTime(recent.modelData.at)).arg(recent.modelData.action === "stop" ? qsTr("offered to stop") : qsTr("redirected")).arg(recent.modelData.reason ?? "")
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                    }

                    ShellButton {
                        subtle: true
                        text: qsTr("Open thread")
                        onClicked: page.plugin.openThread(recent.modelData.threadId, page.environment)
                    }
                }
            }

            Rule {}

            // --- micro-skills -------------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Heading {
                    text: qsTr("Micro-skills")
                }

                ShellComboBox {
                    objectName: "tokenEconomizerProject"
                    visible: page.skillProjects.length > 1
                    outline: true
                    implicitWidth: 220
                    model: page.skillProjects.map(id => page.projectName(id))
                    currentIndex: page.skillProjects.indexOf(page.projectId)
                    Accessible.name: qsTr("Project")
                    onActivated: index => page.showProject(page.skillProjects[index])
                }
            }

            Line {
                text: {
                    if (page.microSkills === null)
                        return "";
                    if (page.microSkills.mode === "off")
                        return qsTr("Off. Turn them on in the plugin's settings.");
                    if (page.skillProjects.length === 0)
                        return qsTr("Nothing learned yet.");
                    return page.skillProjects.length === 1 ? page.projectName(page.projectId) : "";
                }
            }

            Line {
                objectName: "tokenEconomizerHeld"
                text: page.skills?.held ? qsTr("Held: %1 Nothing is learned, staged, dropped or forgotten on this project until its saved file reads again; fix or remove the file and it is read again at its next use.").arg(page.skills.held) : ""
                color: page.warningColor
            }

            RowLayout {
                Layout.fillWidth: true
                visible: page.skills !== null
                spacing: 8

                Line {
                    objectName: "tokenEconomizerImport"
                    text: {
                        const history = page.skills?.history ?? {};
                        const left = page.leftOut(history);
                        return left.length > 0 ? qsTr("%1; left out %2").arg(page.importLine(history)).arg(left) : page.importLine(history);
                    }
                }

                ShellButton {
                    objectName: "tokenEconomizerForget"
                    subtle: true
                    enabled: !page.skills?.held
                    text: qsTr("Forget")
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Forget every fact learned here and import again; dropped facts stay dropped.")
                    onClicked: page.skillsCall("microSkills.forget", {})
                }
            }

            Repeater {
                model: page.skills?.skills ?? []

                delegate: RowLayout {
                    id: fact

                    required property var modelData
                    readonly property var evidence: modelData.evidence ?? {}

                    objectName: "tokenEconomizerFact:" + modelData.id
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: fact.modelData.claim
                            color: page.foreground
                            wrapMode: Text.Wrap
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                        }

                        Line {
                            objectName: "tokenEconomizerEvidence:" + fact.modelData.id
                            text: [fact.modelData.source === "proposer" ? qsTr("proposed by the model") : qsTr("learned from turns"), page.factState(fact.modelData.state) + (fact.modelData.staged ? qsTr(", staged") : ""), qsTr("confirmed by %n turn(s)", "", fact.evidence.confirms ?? 0) + (fact.evidence.contradicts > 0 ? qsTr(", contradicted by %n", "", fact.evidence.contradicts) : ""), page.percent(fact.evidence.firingRate)].join(" · ")
                        }
                    }

                    ShellButton {
                        objectName: "tokenEconomizerDrop:" + fact.modelData.id
                        subtle: true
                        enabled: !page.skills?.held
                        text: qsTr("Drop")
                        onClicked: page.skillsCall("microSkills.drop", {
                            id: fact.modelData.id
                        })
                    }
                }
            }

            Repeater {
                model: page.skills?.dropped ?? []

                delegate: RowLayout {
                    id: dropped

                    required property string modelData

                    objectName: "tokenEconomizerDropped:" + modelData
                    Layout.fillWidth: true
                    spacing: 8

                    Line {
                        text: qsTr("Dropped: %1, never staged or learned again").arg(dropped.modelData)
                    }

                    ShellButton {
                        objectName: "tokenEconomizerRestore:" + dropped.modelData
                        subtle: true
                        enabled: !page.skills?.held
                        text: qsTr("Restore")
                        onClicked: page.skillsCall("microSkills.restore", {
                            id: dropped.modelData
                        })
                    }
                }
            }

            Rule {}

            // --- tool pruning -------------------------------------------------------
            Heading {
                text: qsTr("Tool pruning")
            }

            Line {
                text: {
                    if (page.toolPrune === null)
                        return "";
                    const mode = {
                        "auto": qsTr("Turns unused tools off once a project is quiet"),
                        "propose": qsTr("Proposes unused tools; you apply them"),
                        "off": qsTr("Off")
                    }[page.toolPrune.mode] ?? page.toolPrune.mode;
                    return page.prunes.length === 0 ? qsTr("%1. No evidence yet.").arg(mode) : mode;
                }
            }

            Line {
                objectName: "tokenEconomizerUnreadable"
                text: page.unreadable.length > 0 ? qsTr("Held for %1: uses saved earlier could not be read, so nothing is turned off. Apply or restore that provider's tools below, or change the mode in the plugin's settings, to go on without them.").arg(page.unreadable.join(", ")) : ""
                color: page.warningColor
            }

            Repeater {
                model: page.prunes

                delegate: ColumnLayout {
                    id: prune

                    required property var modelData
                    readonly property string key: modelData.projectId + ":" + modelData.provider
                    readonly property var shown: Object.keys(modelData.tools ?? {}).filter(name => ["off", "proposed", "kept"].includes(modelData.tools[name].state)).sort()

                    objectName: "tokenEconomizerPrune:" + key
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                text: qsTr("%1, %2").arg(page.projectName(prune.modelData.projectId)).arg(prune.modelData.provider)
                                color: page.foreground
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                                font.weight: Font.Medium
                            }

                            Line {
                                text: [qsTr("%n conversation(s)", "", prune.modelData.sessions ?? 0), qsTr("%n off", "", (prune.modelData.off ?? []).length), qsTr("%n proposed", "", (prune.modelData.proposed ?? []).length)].join(" · ")
                            }
                        }

                        ShellButton {
                            objectName: "tokenEconomizerApplyAll:" + prune.key
                            visible: (prune.modelData.proposed ?? []).length > 0
                            primary: true
                            text: qsTr("Apply proposal")
                            onClicked: page.start("toolPruneApply", {
                                projectId: prune.modelData.projectId,
                                provider: prune.modelData.provider
                            })
                        }

                        ShellButton {
                            objectName: "tokenEconomizerRestoreAll:" + prune.key
                            visible: (prune.modelData.off ?? []).length > 0
                            subtle: true
                            text: qsTr("Give all back")
                            onClicked: page.start("toolPruneRestore", {
                                projectId: prune.modelData.projectId,
                                provider: prune.modelData.provider
                            })
                        }
                    }

                    Line {
                        objectName: "tokenEconomizerUnresolved:" + prune.key
                        text: (prune.modelData.unresolved ?? []).length > 0 ? qsTr("Nothing is turned off for this project's new conversations until %n thread(s) are read back: turns of them were heard only in part. Each new conversation here tries again; a deleted thread stops holding it.", "", prune.modelData.unresolved.length) : ""
                        color: page.warningColor
                    }

                    Repeater {
                        model: [...(prune.modelData.unresolved ?? []).map(thread => ({
                                    thread,
                                    away: false
                                })), ...(prune.modelData.away ?? []).map(thread => ({
                                    thread,
                                    away: true
                                }))]

                        delegate: RowLayout {
                            id: held

                            required property var modelData

                            objectName: (modelData.away ? "tokenEconomizerAway:" : "tokenEconomizerHolding:") + prune.key + ":" + modelData.thread
                            Layout.fillWidth: true
                            spacing: 8

                            Line {
                                text: held.modelData.away ? qsTr("Away on another machine, holding nothing off until it comes back: %1").arg(held.modelData.thread) : qsTr("Holding pruning off: %1").arg(held.modelData.thread)
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }

                            ShellButton {
                                visible: !held.modelData.away
                                subtle: true
                                text: qsTr("Open thread")
                                onClicked: page.plugin.openThread(held.modelData.thread, page.environment)
                            }
                        }
                    }

                    Line {
                        visible: (prune.modelData.pending ?? []).length > 0
                        text: qsTr("Waiting for the project to be quiet to turn off: %1").arg((prune.modelData.pending ?? []).join(", "))
                    }

                    Repeater {
                        model: prune.shown

                        delegate: RowLayout {
                            id: tool

                            required property string modelData
                            readonly property var evidence: prune.modelData.tools[modelData]

                            objectName: "tokenEconomizerTool:" + prune.key + ":" + modelData
                            Layout.fillWidth: true
                            spacing: 8

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Text {
                                    Layout.fillWidth: true
                                    text: qsTr("%1 · %2").arg(tool.modelData).arg(page.toolStateLabel(tool.evidence.state))
                                    color: page.foreground
                                    elide: Text.ElideRight
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                Line {
                                    text: page.toolLine(tool.evidence)
                                }
                            }

                            ShellButton {
                                objectName: "tokenEconomizerApply:" + prune.key + ":" + tool.modelData
                                visible: tool.evidence.state !== "off"
                                subtle: true
                                text: qsTr("Turn off")
                                onClicked: page.start("toolPruneApply", {
                                    projectId: prune.modelData.projectId,
                                    provider: prune.modelData.provider,
                                    tools: [tool.modelData]
                                })
                            }

                            ShellButton {
                                objectName: "tokenEconomizerGiveBack:" + prune.key + ":" + tool.modelData
                                visible: tool.evidence.state === "off"
                                subtle: true
                                text: qsTr("Give back")
                                onClicked: page.start("toolPruneRestore", {
                                    projectId: prune.modelData.projectId,
                                    provider: prune.modelData.provider,
                                    tools: [tool.modelData]
                                })
                            }
                        }
                    }
                }
            }
        }
    }
}
