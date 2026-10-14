pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import HalC2.Shell
import HalC2.Bricks

// The Planner page: each MC's plan in the view the user picked, as a Gantt chart, a
// board or a list, the task picked in any of them, and the runs of the plan's
// actions with what they propose. Follows each MC's `plan` and `runs` topics; a
// view belongs to the MC that saved it and shows that MC's plan.
Item {
    id: page

    property var plugin
    // environment → the last value of its `plan` and `runs` topics, and its watches.
    property var plans: ({})
    property var runsBy: ({})
    property var watches: ({})
    readonly property bool several: plugin.environments.length > 1
    readonly property var statuses: ["todo", "doing", "blocked", "done", "dropped"]
    readonly property var allFields: ["status", "owner", "start", "due", "progress", "labels", "project", "links"]
    readonly property var groupings: ["none", "status", "project", "label", "owner", "parent", "milestone"]
    readonly property var sortings: ["manual", "start", "due", "title", "status", "progress"]
    readonly property var zooms: ["day", "week", "month", "quarter"]
    readonly property var layouts: ["gantt", "board", "list"]

    // Every MC's saved views, the one picked, and the user's unsaved edits of it.
    readonly property var views: {
        const all = [];
        for (const environment of plugin.environments) {
            for (const view of plans[environment]?.views ?? [])
                all.push(Object.assign({}, view, { environment: environment, key: environment + "|" + view.id }));
        }
        return all;
    }
    property string viewKey: ""
    readonly property var saved: views.find(view => view.key === viewKey) ?? views[0] ?? null
    property var working: null
    property var base: null
    readonly property bool changed: working !== null && base !== null && JSON.stringify(working) !== JSON.stringify(base)

    // The plan of the picked view's MC, with dates being dragged in place.
    readonly property string environment: working?.environment ?? plugin.environments[0] ?? ""
    readonly property var plan: plans[environment] ?? null
    // "environment|id" → {start, due} sent to an MC and not yet published back.
    property var pending: ({})
    readonly property var items: (plan?.items ?? []).map(item => {
        const keyed = Object.assign({}, item, { environment: page.environment, key: page.environment + "|" + item.id });
        return page.pending[keyed.key] ? Object.assign(keyed, page.pending[keyed.key]) : keyed;
    })
    readonly property var byId: {
        const map = {};
        for (const item of items)
            map[item.id] = item;
        return map;
    }
    readonly property string today: plan?.today ?? new Date().toISOString().slice(0, 10)
    readonly property var actions: plan?.actions ?? []
    readonly property var projects: plan?.projects ?? []
    readonly property var latest: (plan?.updates ?? [])[0] ?? null

    // What the view shows: its filter, sorting and grouping applied.
    readonly property var shown: working === null ? [] : items.filter(item => page.matches(item, page.working.filter))
    // Group key → collapsed, and the rows of the chart and the list.
    property var collapsed: ({})
    readonly property var rows: buildRows(shown, working)
    readonly property var rowIndex: {
        const index = {};
        rows.forEach((row, at) => {
            if (row.kind === "item" && index[row.item.id] === undefined)
                index[row.item.id] = at;
        });
        return index;
    }

    // The item picked in any view, and the run picked in the runs panel.
    property string selectedKey: ""
    // The row the keyboard was on when the rows were last made again.
    property string keyRow: ""
    readonly property var selected: items.find(item => item.key === selectedKey) ?? null
    property bool runsOpen: false
    property string pickedRun: ""
    readonly property var runs: {
        const all = [];
        for (const environment of plugin.environments) {
            for (const run of runsBy[environment]?.runs ?? [])
                all.push(Object.assign({}, run, { environment: environment, key: environment + "|" + run.id }));
        }
        const order = ["proposed", "running", "queued", "failed", "applied", "done"];
        return all.sort((a, b) => order.indexOf(a.status) - order.indexOf(b.status));
    }
    readonly property var run: runs.find(run => run.key === pickedRun) ?? null
    readonly property int waiting: runs.filter(run => run.status === "proposed").length
    // Item id → the dates the picked run's proposal would give it.
    readonly property var ghosts: {
        const ghosts = {};
        if (run === null || run.status !== "proposed" || run.environment !== environment)
            return ghosts;
        for (const change of run.changes ?? []) {
            const fields = change.fields ?? {};
            const item = byId[change.itemId];
            if (change.op !== "update" || change.dismissed || change.outcome || !item || (fields.start === undefined && fields.due === undefined))
                continue;
            ghosts[item.id] = { start: fields.start ?? item.start, due: fields.due ?? item.due };
        }
        return ghosts;
    }

    // Why the last call from this page failed, until the next one.
    property string refusal: ""
    property int busy: 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color surface: Theme.palette.color("surface", "#18181b")
    readonly property color raised: Theme.palette.color("surfaceRaised", "#1f1f23")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")
    readonly property color infoColor: Theme.palette.color("info", "#3b82f6")
    readonly property int rowHeight: 34
    readonly property int labelWidth: 220

    function follow() {
        const watches = {};
        for (const environment of page.plugin.environments) {
            watches[environment] = page.watches[environment] ?? [page.plugin.watch("plan", value => {
                    const next = Object.assign({}, page.plans);
                    next[environment] = value;
                    page.plans = next;
                    const pending = {};
                    for (const key in page.pending)
                        if (!key.startsWith(environment + "|"))
                            pending[key] = page.pending[key];
                    page.pending = pending;
                }, environment), page.plugin.watch("runs", value => {
                    const next = Object.assign({}, page.runsBy);
                    next[environment] = value;
                    page.runsBy = next;
                }, environment)];
        }
        for (const environment of Object.keys(page.watches)) {
            if (watches[environment] === undefined) {
                for (const id of page.watches[environment])
                    page.plugin.unwatch(id);
            }
        }
        page.watches = watches;
    }

    // Calls the MC part of `environment`; what it refuses is shown under the bar.
    function ask(method, input, environment, done) {
        page.refusal = "";
        page.busy += 1;
        page.plugin.call(method, input, (result, error) => {
            page.busy -= 1;
            if (error)
                page.refusal = error;
            if (done)
                done(result, error);
        }, environment);
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    // A view as the page compares and edits it, every field present.
    function normal(view) {
        if (!view)
            return null;
        const filter = view.filter ?? {};
        return {
            id: view.id,
            environment: view.environment,
            key: view.key,
            name: view.name ?? "",
            layout: view.layout ?? "gantt",
            filter: {
                text: filter.text ?? "",
                statuses: filter.statuses ?? [],
                labels: filter.labels ?? [],
                projects: filter.projects ?? [],
                owners: filter.owners ?? [],
                hideDone: filter.hideDone === true
            },
            groupBy: view.groupBy ?? "none",
            sortBy: view.sortBy ?? "manual",
            zoom: view.zoom ?? "week",
            fields: view.fields ?? [],
            showDependencies: view.showDependencies !== false,
            showBaseline: view.showBaseline === true
        };
    }

    // The view as the MC keeps it.
    function stored(view) {
        const copy = Object.assign({}, view);
        delete copy.environment;
        delete copy.key;
        return copy;
    }

    // Takes the saved view again, keeping the user's edits of the same view.
    function adopt() {
        const fresh = page.normal(page.saved);
        if (page.working === null || fresh === null || page.working.key !== fresh.key || !page.changed || JSON.stringify(page.working) === JSON.stringify(fresh))
            page.working = fresh;
        page.base = fresh;
    }

    function edit(changes) {
        page.working = Object.assign({}, page.working, changes);
    }

    function editFilter(changes) {
        page.edit({ filter: Object.assign({}, page.working.filter, changes) });
    }

    function toggled(list, value) {
        return list.includes(value) ? list.filter(each => each !== value) : list.concat([value]);
    }

    function saveView() {
        page.ask("saveView", { view: page.stored(page.working) }, page.environment);
    }

    function revert() {
        page.working = page.normal(page.saved);
    }

    // A new view: `mode` "new" from scratch, "copy" of the working view, or "rename".
    function nameView(mode, name) {
        if (mode === "rename") {
            page.edit({ name: name });
            page.ask("saveView", { view: Object.assign(page.stored(page.normal(page.saved)), { name: name }) }, page.environment);
            return;
        }
        const view = mode === "copy" ? page.stored(page.working) : {
            layout: "gantt",
            filter: page.normal({}).filter,
            groupBy: "none",
            sortBy: "manual",
            zoom: "week",
            fields: ["status", "owner", "due"],
            showDependencies: true,
            showBaseline: false
        };
        delete view.id;
        view.name = name;
        const environment = page.environment;
        page.ask("saveView", { view: view }, environment, (result, error) => {
            if (!error && result?.view?.id)
                page.viewKey = environment + "|" + result.view.id;
        });
    }

    function day(iso) {
        if (!iso)
            return NaN;
        const parts = iso.split("-");
        return Math.round(Date.UTC(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])) / 86400000);
    }

    function iso(day) {
        return new Date(day * 86400000).toISOString().slice(0, 10);
    }

    function statusLabel(status) {
        switch (status) {
        case "todo":
            return qsTr("To do");
        case "doing":
            return qsTr("In progress");
        case "blocked":
            return qsTr("Blocked");
        case "done":
            return qsTr("Done");
        case "dropped":
            return qsTr("Dropped");
        default:
            return status ?? "";
        }
    }

    function statusColor(status) {
        switch (status) {
        case "doing":
            return page.infoColor;
        case "blocked":
            return page.errorColor;
        case "done":
            return page.successColor;
        default:
            return page.muted;
        }
    }

    function healthLabel(health) {
        if (health === "on-track")
            return qsTr("On track");
        if (health === "at-risk")
            return qsTr("At risk");
        if (health === "off-track")
            return qsTr("Off track");
        return "";
    }

    function healthColor(health) {
        if (health === "on-track")
            return page.successColor;
        if (health === "at-risk")
            return page.warningColor;
        if (health === "off-track")
            return page.errorColor;
        return page.muted;
    }

    // A run in the run list: what a proposal still holds once dismissed changes are left
    // out, as its thread's header says it, or where it is.
    function runLabel(run) {
        if (run.status !== "proposed")
            return page.runStatusLabel(run.status);
        const kept = (run.changes ?? []).filter(change => !change.dismissed).length;
        if (kept === 0 && run.health)
            return qsTr("Status update");
        return kept === 1 ? qsTr("1 change") : qsTr("%1 changes").arg(kept);
    }

    function runStatusLabel(status) {
        switch (status) {
        case "queued":
            return qsTr("Queued");
        case "running":
            return qsTr("Running");
        case "failed":
            return qsTr("Failed");
        case "proposed":
            return qsTr("Waiting for you");
        case "applied":
            return qsTr("Applied");
        case "done":
            return qsTr("Done");
        default:
            return status;
        }
    }

    function fieldLabel(field) {
        switch (field) {
        case "title":
            return qsTr("Task");
        case "status":
            return qsTr("Status");
        case "owner":
            return qsTr("Owner");
        case "start":
            return qsTr("Start");
        case "due":
            return qsTr("Due");
        case "progress":
            return qsTr("Progress");
        case "labels":
            return qsTr("Labels");
        case "project":
            return qsTr("Project");
        case "links":
            return qsTr("Links");
        default:
            return field;
        }
    }

    function projectTitle(id) {
        return page.projects.find(project => project.id === id)?.title ?? id ?? "";
    }

    // A field of `item` as stored, and as a list or a card shows it.
    function fieldValue(item, field) {
        switch (field) {
        case "progress":
            return item.derivedProgress ?? item.progress ?? 0;
        case "project":
            return item.projectId ?? null;
        case "labels":
            return item.labels ?? [];
        case "links":
            return (item.issue ? 1 : 0) + (item.pullRequests ?? []).length + (item.threads ?? []).length;
        default:
            return item[field] ?? null;
        }
    }

    function fieldText(item, field) {
        const value = page.fieldValue(item, field);
        switch (field) {
        case "status":
            return page.statusLabel(value);
        case "progress":
            return value + "%";
        case "project":
            return value ? page.projectTitle(value) : "";
        case "labels":
            return value.join(", ");
        case "links":
            {
                const parts = [];
                if (item.issue)
                    parts.push("#" + item.issue.number);
                for (const pull of item.pullRequests ?? [])
                    parts.push("PR #" + pull.number);
                if ((item.threads ?? []).length > 0)
                    parts.push(item.threads.length === 1 ? qsTr("1 thread") : qsTr("%1 threads").arg(item.threads.length));
                return parts.join(" · ");
            }
        default:
            return value ?? "";
        }
    }

    function matches(item, filter) {
        const text = filter.text.trim().toLowerCase();
        if (text.length > 0) {
            const words = [item.title, item.notes ?? "", item.owner ?? "", (item.labels ?? []).join(" ")].join(" ").toLowerCase();
            if (!words.includes(text))
                return false;
        }
        if (filter.statuses.length > 0 && !filter.statuses.includes(item.status))
            return false;
        if (filter.hideDone && (item.status === "done" || item.status === "dropped"))
            return false;
        if (filter.labels.length > 0 && !(item.labels ?? []).some(label => filter.labels.includes(label)))
            return false;
        if (filter.projects.length > 0 && !filter.projects.includes(item.projectId))
            return false;
        if (filter.owners.length > 0 && !filter.owners.includes(item.owner))
            return false;
        return true;
    }

    function compare(a, b, sortBy) {
        const text = (x, y) => (x ?? "￿").localeCompare(y ?? "￿");
        switch (sortBy) {
        case "start":
            return text(a.start ?? a.due, b.start ?? b.due);
        case "due":
            return text(a.due, b.due);
        case "title":
            return a.title.localeCompare(b.title);
        case "status":
            return page.statuses.indexOf(a.status) - page.statuses.indexOf(b.status);
        case "progress":
            return page.fieldValue(b, "progress") - page.fieldValue(a, "progress");
        default:
            return (a.order ?? 0) - (b.order ?? 0);
        }
    }

    // The groups `item` is shown in under `groupBy`, each {key, label, rank}.
    function groupsOf(item, groupBy) {
        const none = label => [{ key: "", label: label, rank: 99 }];
        switch (groupBy) {
        case "status":
            return [{ key: item.status, label: page.statusLabel(item.status), rank: page.statuses.indexOf(item.status) }];
        case "project":
            return item.projectId ? [{ key: item.projectId, label: page.projectTitle(item.projectId), rank: 0 }] : none(qsTr("No project"));
        case "label":
            return (item.labels ?? []).length > 0 ? item.labels.map(label => ({ key: label, label: label, rank: 0 })) : none(qsTr("No label"));
        case "owner":
            return item.owner ? [{ key: item.owner, label: item.owner, rank: 0 }] : none(qsTr("No owner"));
        case "parent":
            {
                const parent = page.byId[item.parent];
                return parent ? [{ key: parent.id, label: parent.title, rank: 0 }] : none(qsTr("No parent"));
            }
        case "milestone":
            {
                const milestone = item.kind === "milestone" ? item : page.items.find(each => each.kind === "milestone" && (each.after ?? []).includes(item.id));
                return milestone ? [{ key: milestone.id, label: milestone.title, rank: 0 }] : none(qsTr("No milestone"));
            }
        default:
            return none("");
        }
    }

    // The rows of the chart and the list: a tree of subtasks, or groups.
    function buildRows(shown, view) {
        if (view === null)
            return [];
        const sorted = shown.slice().sort((a, b) => page.compare(a, b, view.sortBy));
        const rows = [];
        if (view.groupBy === "none") {
            const ids = new Set(sorted.map(item => item.id));
            const children = {};
            const roots = [];
            for (const item of sorted) {
                if (item.parent && ids.has(item.parent))
                    (children[item.parent] = children[item.parent] ?? []).push(item);
                else
                    roots.push(item);
            }
            const walk = (item, depth) => {
                const kids = children[item.id] ?? [];
                rows.push({ kind: "item", key: item.key, item: item, depth: depth, children: kids.length > 0 });
                if (!page.collapsed[item.key] && depth < 32) {
                    for (const kid of kids)
                        walk(kid, depth + 1);
                }
            };
            for (const root of roots)
                walk(root, 0);
            return rows;
        }
        const groups = new Map();
        for (const item of sorted) {
            for (const group of page.groupsOf(item, view.groupBy)) {
                if (!groups.has(group.key))
                    groups.set(group.key, { label: group.label, rank: group.rank, items: [] });
                groups.get(group.key).items.push(item);
            }
        }
        const ordered = Array.from(groups.entries()).sort((a, b) => a[1].rank - b[1].rank || a[1].label.localeCompare(b[1].label));
        for (const [key, group] of ordered) {
            const groupKey = "group:" + key;
            rows.push({ kind: "group", key: groupKey, label: group.label, count: group.items.length, depth: 0, children: true });
            if (!page.collapsed[groupKey]) {
                for (const item of group.items)
                    rows.push({ kind: "item", key: item.key, item: item, depth: 1, children: false });
            }
        }
        return rows;
    }

    function collapse(key) {
        const next = Object.assign({}, page.collapsed);
        next[key] = !next[key];
        page.collapsed = next;
    }

    function select(item) {
        page.selectedKey = item ? item.key : "";
    }

    // A row of the timeline or the list pressed: its task opens, its group folds.
    function press(row) {
        if (row.item)
            page.select(row.item);
        else
            page.collapse(row.key);
    }

    // Enter or Space presses a row; Left and Right fold and unfold one with subtasks.
    // Folding makes the rows again, so the row's remade self takes the keyboard back.
    function rowKey(event, row) {
        const pressing = event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space;
        const folding = (event.key === Qt.Key_Left || event.key === Qt.Key_Right) && row.children && (event.key === Qt.Key_Left) !== !!page.collapsed[row.key];
        if (!pressing && !folding)
            return;
        if (folding || !row.item)
            page.keyRow = row.key;
        if (pressing)
            page.press(row);
        else
            page.collapse(row.key);
        event.accepted = true;
    }

    // A row made while it is `keyRow` takes the keyboard.
    function takeKeys(row, key) {
        if (key !== page.keyRow)
            return;
        page.keyRow = "";
        row.forceActiveFocus(Qt.TabFocusReason);
    }

    function update(item, fields) {
        page.ask("updateItem", { id: item.id, fields: fields }, item.environment);
    }

    // Moves `item` by `shift` days, or its end only by `grow`; shown at once, then as the MC has it.
    function reschedule(item, shift, grow) {
        const fields = {};
        if (item.kind === "milestone") {
            fields.due = page.iso(page.day(item.due) + shift);
        } else {
            if (item.start)
                fields.start = page.iso(page.day(item.start) + shift);
            if (item.due)
                fields.due = page.iso(page.day(item.due) + shift + grow);
        }
        const next = Object.assign({}, page.pending);
        next[item.key] = fields;
        page.pending = next;
        page.ask("updateItem", { id: item.id, fields: fields }, item.environment, (result, error) => {
            if (error) {
                const back = Object.assign({}, page.pending);
                delete back[item.key];
                page.pending = back;
            }
        });
    }

    function add(kind) {
        const today = page.day(page.today);
        const fields = kind === "milestone" ? { title: qsTr("New milestone"), kind: "milestone", due: page.iso(today + 14) } : { title: qsTr("New task"), kind: "task", start: page.iso(today), due: page.iso(today + 4) };
        if (page.projects.length === 1)
            fields.projectId = page.projects[0].id;
        const environment = page.environment;
        page.ask("addItem", { fields: fields }, environment, (result, error) => {
            if (!error && result?.item?.id)
                page.selectedKey = environment + "|" + result.item.id;
        });
    }

    function runAction(action, itemIds) {
        const environment = page.environment;
        page.ask("run", { action: action, itemIds: itemIds }, environment, (result, error) => {
            if (!error && result?.run?.id) {
                page.pickedRun = environment + "|" + result.run.id;
                page.runsOpen = true;
            }
        });
    }

    // A task of `environment`'s plan; the runs panel lists runs from every MC.
    function itemIn(environment, id) {
        return environment === page.environment ? page.byId[id] : (page.plans[environment]?.items ?? []).find(item => item.id === id);
    }

    // What a change the picked run proposes does, in a line.
    function changeText(change) {
        const environment = page.run?.environment;
        const item = page.itemIn(environment, change.itemId);
        const title = item?.title ?? change.itemId ?? "";
        const fields = change.fields ?? {};
        switch (change.op) {
        case "add":
            return qsTr("Add %1").arg(fields.title ?? "");
        case "remove":
            return qsTr("Remove %1").arg(title);
        case "link":
            {
                const ref = fields.pullRequest ?? fields.issue ?? {};
                return qsTr("Link %1 to %2#%3").arg(title).arg(ref.repository ?? "").arg(ref.number ?? "");
            }
        default:
            {
                const parts = [];
                for (const key of Object.keys(fields)) {
                    const was = item ? item[key] : undefined;
                    const show = value => Array.isArray(value) ? value.map(id => page.itemIn(environment, id)?.title ?? id).join(", ") : String(value ?? "—");
                    parts.push(qsTr("%1 %2 → %3").arg(key).arg(show(was)).arg(show(fields[key])));
                }
                return title + ": " + parts.join(", ");
            }
        }
    }

    function time(value) {
        return value ? Qt.formatDateTime(new Date(value), Qt.locale().dateTimeFormat(Locale.ShortFormat)) : "";
    }

    objectName: "plannerPage"
    implicitWidth: 1000
    implicitHeight: 640
    onSavedChanged: adopt()
    Component.onCompleted: follow()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    // A small coloured label.
    component Chip: Rectangle {
        id: chip

        property string text
        property color tone: page.muted

        implicitWidth: chipText.implicitWidth + 12
        implicitHeight: chipText.implicitHeight + 4
        radius: height / 2
        color: Qt.alpha(tone, 0.14)
        border.color: Qt.alpha(tone, 0.4)

        Text {
            id: chipText

            anchors.centerIn: parent
            text: chip.text
            color: chip.tone
            font.pixelSize: Math.round(11 * Theme.fontScale)
            font.weight: Font.Medium
        }
    }

    component Caption: Text {
        Layout.fillWidth: true
        color: page.muted
        font.pixelSize: Math.round(11 * Theme.fontScale)
        font.weight: Font.Medium
        font.capitalization: Font.AllUppercase
    }

    component Line: Text {
        Layout.fillWidth: true
        color: page.foreground
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    // A text field of the picked item, kept as the MC has it until the user edits it.
    component ItemField: ShellTextField {
        id: itemField

        property string current
        signal commit(string text)

        Layout.fillWidth: true
        text: current
        onCurrentChanged: text = current
        onEditingFinished: if (text !== current)
            commit(text.trim())
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // The views, adding to the plan, its actions and the runs.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: bar.implicitHeight + 16
            color: page.surface

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: page.border
            }

            ColumnLayout {
                id: bar

                anchors.fill: parent
                anchors.margins: 8
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Flow {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: page.views

                            delegate: AbstractButton {
                                id: tab

                                required property var modelData
                                readonly property bool current: page.working?.key === modelData.key

                                objectName: "plannerView:" + modelData.name
                                implicitWidth: tabText.implicitWidth + 24
                                implicitHeight: 28
                                hoverEnabled: true
                                Accessible.role: Accessible.PageTab
                                Accessible.name: tabText.text
                                Keys.onReturnPressed: clicked()
                                Keys.onEnterPressed: clicked()
                                onClicked: page.viewKey = tab.modelData.key
                                background: Rectangle {
                                    radius: Math.min(Theme.radius, 8)
                                    color: tab.current ? Theme.palette.color("accentSurface", "#27272a") : tab.hovered || tab.visualFocus ? Theme.palette.color("sidebarRowHover", "#1f1f23") : "transparent"
                                    border.color: tab.current || tab.visualFocus ? Theme.palette.color("focus", "#3b82f6") : "transparent"
                                }

                                HoverHandler {
                                    cursorShape: Qt.PointingHandCursor
                                }

                                Text {
                                    id: tabText

                                    anchors.centerIn: parent
                                    text: (tab.current && page.changed ? "• " : "") + tab.modelData.name + (page.several ? " (" + page.environmentLabel(tab.modelData.environment) + ")" : "")
                                    color: page.foreground
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    font.weight: tab.current ? Font.DemiBold : Font.Normal
                                }
                            }
                        }

                        ShellButton {
                            objectName: "plannerNewView"
                            subtle: true
                            iconName: "plus"
                            toolTip: qsTr("New view")
                            Accessible.name: qsTr("New view")
                            enabled: page.plan !== null
                            onClicked: namer.ask("new", "")
                        }
                    }

                    ShellButton {
                        objectName: "plannerAddTask"
                        enabled: page.plan !== null
                        iconName: "plus"
                        text: qsTr("Task")
                        Accessible.name: qsTr("Add task")
                        onClicked: page.add("task")
                    }

                    ShellButton {
                        objectName: "plannerAddMilestone"
                        enabled: page.plan !== null
                        iconName: "plus"
                        text: qsTr("Milestone")
                        Accessible.name: qsTr("Add milestone")
                        onClicked: page.add("milestone")
                    }

                    ShellButton {
                        id: actionsButton

                        objectName: "plannerActions"
                        enabled: page.actions.some(action => action.scope === "plan")
                        chevron: true
                        text: qsTr("Actions")
                        onClicked: actionsMenu.open()

                        ShellMenu {
                            id: actionsMenu

                            y: parent.height + 4

                            Instantiator {
                                model: page.actions.filter(action => action.scope === "plan")

                                delegate: ShellMenuItem {
                                    required property var modelData

                                    objectName: "plannerAction:" + modelData.id
                                    text: modelData.label
                                    detail: modelData.apply === "apply" ? qsTr("applies its changes") : ""
                                    onTriggered: page.runAction(modelData.id, [])
                                }

                                onObjectAdded: (index, object) => actionsMenu.insertItem(index, object)
                                onObjectRemoved: (index, object) => actionsMenu.removeItem(object)
                            }
                        }
                    }

                    ShellButton {
                        objectName: "plannerSync"
                        subtle: true
                        visible: (page.plan?.sync?.repositories ?? []).length > 0 || (page.plan?.sync?.board ?? "").length > 0
                        enabled: page.busy === 0
                        text: qsTr("Look now")
                        toolTip: qsTr("Look at GitHub now")
                        onClicked: page.ask("sync", {}, page.environment)
                    }

                    ShellButton {
                        objectName: "plannerRunsToggle"
                        subtle: !page.runsOpen
                        text: page.waiting > 0 ? qsTr("Runs (%1 waiting)").arg(page.waiting) : qsTr("Runs")
                        onClicked: page.runsOpen = !page.runsOpen
                    }
                }

                // How the view lays out, groups, sorts and filters the plan; wraps when narrow.
                Flow {
                    Layout.fillWidth: true
                    visible: page.working !== null
                    spacing: 6

                    ShellComboBox {
                        readonly property var values: page.layouts

                        objectName: "plannerLayout"
                        outline: true
                        implicitWidth: 120
                        model: [qsTr("Gantt"), qsTr("Board"), qsTr("List")]
                        currentIndex: values.indexOf(page.working?.layout ?? "gantt")
                        Accessible.name: qsTr("Layout")
                        onActivated: index => page.edit({ layout: values[index] })
                    }

                    ShellComboBox {
                        readonly property var values: page.groupings

                        objectName: "plannerGroupBy"
                        outline: true
                        implicitWidth: 150
                        model: [qsTr("No grouping"), qsTr("By status"), qsTr("By project"), qsTr("By label"), qsTr("By owner"), qsTr("By parent"), qsTr("By milestone")]
                        currentIndex: values.indexOf(page.working?.groupBy ?? "none")
                        Accessible.name: qsTr("Group by")
                        onActivated: index => page.edit({ groupBy: values[index] })
                    }

                    ShellComboBox {
                        readonly property var values: page.sortings

                        objectName: "plannerSortBy"
                        outline: true
                        implicitWidth: 140
                        model: [qsTr("Manual order"), qsTr("By start"), qsTr("By due date"), qsTr("By title"), qsTr("By status"), qsTr("By progress")]
                        currentIndex: values.indexOf(page.working?.sortBy ?? "manual")
                        Accessible.name: qsTr("Sort by")
                        onActivated: index => page.edit({ sortBy: values[index] })
                    }

                    Row {
                        visible: page.working?.layout === "gantt"
                        spacing: 0

                        Repeater {
                            model: [
                                { value: "day", label: qsTr("Days") },
                                { value: "week", label: qsTr("Weeks") },
                                { value: "month", label: qsTr("Months") },
                                { value: "quarter", label: qsTr("Quarters") }
                            ]

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "plannerZoom:" + modelData.value
                                subtle: page.working?.zoom !== modelData.value
                                text: modelData.label
                                onClicked: page.edit({ zoom: modelData.value })
                            }
                        }
                    }

                    ShellButton {
                        objectName: "plannerFields"
                        subtle: true
                        chevron: true
                        text: qsTr("Show")
                        onClicked: fieldsMenu.open()

                        ShellMenu {
                            id: fieldsMenu

                            y: parent.height + 4

                            Instantiator {
                                model: page.allFields

                                delegate: ShellMenuItem {
                                    required property string modelData

                                    objectName: "plannerField:" + modelData
                                    text: page.fieldLabel(modelData)
                                    checkable: true
                                    checked: (page.working?.fields ?? []).includes(modelData)
                                    current: checked
                                    onTriggered: page.edit({ fields: page.allFields.filter(field => field === modelData ? !(page.working.fields.includes(field)) : page.working.fields.includes(field)) })
                                }

                                onObjectAdded: (index, object) => fieldsMenu.insertItem(index, object)
                                onObjectRemoved: (index, object) => fieldsMenu.removeItem(object)
                            }

                            ShellMenuSeparator {}

                            ShellMenuItem {
                                objectName: "plannerShowDependencies"
                                text: qsTr("Dependencies")
                                checkable: true
                                checked: page.working?.showDependencies === true
                                current: checked
                                onTriggered: page.edit({ showDependencies: !page.working.showDependencies })
                            }

                            ShellMenuItem {
                                objectName: "plannerShowBaseline"
                                text: qsTr("Baseline")
                                checkable: true
                                checked: page.working?.showBaseline === true
                                current: checked
                                onTriggered: page.edit({ showBaseline: !page.working.showBaseline })
                            }
                        }
                    }

                    ShellButton {
                        readonly property var filter: page.working?.filter ?? null
                        readonly property int count: filter ? filter.statuses.length + filter.labels.length + filter.projects.length + filter.owners.length + (filter.hideDone ? 1 : 0) : 0

                        objectName: "plannerFilters"
                        subtle: count === 0
                        chevron: true
                        text: count > 0 ? qsTr("Filters (%1)").arg(count) : qsTr("Filters")
                        onClicked: filtersMenu.open()

                        ShellMenu {
                            id: filtersMenu

                            y: parent.height + 4

                            ShellMenuItem {
                                objectName: "plannerHideDone"
                                text: qsTr("Hide done")
                                checkable: true
                                checked: page.working?.filter.hideDone === true
                                current: checked
                                onTriggered: page.editFilter({ hideDone: !page.working.filter.hideDone })
                            }

                            ShellMenu {
                                id: statusMenu

                                title: qsTr("Status")

                                Instantiator {
                                    model: page.statuses

                                    delegate: ShellMenuItem {
                                        required property string modelData

                                        objectName: "plannerFilterStatus:" + modelData
                                        text: page.statusLabel(modelData)
                                        checkable: true
                                        checked: (page.working?.filter.statuses ?? []).includes(modelData)
                                        current: checked
                                        onTriggered: page.editFilter({ statuses: page.toggled(page.working.filter.statuses, modelData) })
                                    }

                                    onObjectAdded: (index, object) => statusMenu.insertItem(index, object)
                                    onObjectRemoved: (index, object) => statusMenu.removeItem(object)
                                }
                            }

                            ShellMenu {
                                id: ownerMenu

                                title: qsTr("Owner")

                                Instantiator {
                                    model: Array.from(new Set(page.items.map(item => item.owner).filter(owner => owner))).sort()

                                    delegate: ShellMenuItem {
                                        required property string modelData

                                        text: modelData
                                        checkable: true
                                        checked: (page.working?.filter.owners ?? []).includes(modelData)
                                        current: checked
                                        onTriggered: page.editFilter({ owners: page.toggled(page.working.filter.owners, modelData) })
                                    }

                                    onObjectAdded: (index, object) => ownerMenu.insertItem(index, object)
                                    onObjectRemoved: (index, object) => ownerMenu.removeItem(object)
                                }
                            }

                            ShellMenu {
                                id: labelMenu

                                title: qsTr("Label")

                                Instantiator {
                                    model: Array.from(new Set([].concat(...page.items.map(item => item.labels ?? [])))).sort()

                                    delegate: ShellMenuItem {
                                        required property string modelData

                                        text: modelData
                                        checkable: true
                                        checked: (page.working?.filter.labels ?? []).includes(modelData)
                                        current: checked
                                        onTriggered: page.editFilter({ labels: page.toggled(page.working.filter.labels, modelData) })
                                    }

                                    onObjectAdded: (index, object) => labelMenu.insertItem(index, object)
                                    onObjectRemoved: (index, object) => labelMenu.removeItem(object)
                                }
                            }

                            ShellMenu {
                                id: projectMenu

                                title: qsTr("Project")

                                Instantiator {
                                    model: page.projects

                                    delegate: ShellMenuItem {
                                        required property var modelData

                                        text: modelData.title
                                        checkable: true
                                        checked: (page.working?.filter.projects ?? []).includes(modelData.id)
                                        current: checked
                                        onTriggered: page.editFilter({ projects: page.toggled(page.working.filter.projects, modelData.id) })
                                    }

                                    onObjectAdded: (index, object) => projectMenu.insertItem(index, object)
                                    onObjectRemoved: (index, object) => projectMenu.removeItem(object)
                                }
                            }

                            ShellMenuSeparator {}

                            ShellMenuItem {
                                text: qsTr("Clear filters")
                                onTriggered: page.editFilter({ statuses: [], labels: [], projects: [], owners: [], hideDone: false })
                            }
                        }
                    }

                    ShellTextField {
                        id: filterField

                        readonly property string current: page.working?.filter.text ?? ""

                        objectName: "plannerFilter"
                        width: 180
                        placeholderText: qsTr("Filter")
                        Accessible.name: qsTr("Filter tasks")
                        onCurrentChanged: if (text !== current)
                            text = current
                        onTextChanged: if (page.working !== null && text !== current)
                            page.editFilter({ text: text })
                    }

                    Chip {
                        objectName: "plannerViewChanged"
                        visible: page.changed
                        text: qsTr("Changed")
                        tone: page.warningColor
                    }

                    ShellButton {
                        objectName: "plannerViewSave"
                        visible: page.changed
                        primary: true
                        enabled: page.busy === 0
                        text: qsTr("Save")
                        onClicked: page.saveView()
                    }

                    ShellButton {
                        objectName: "plannerViewSaveAs"
                        visible: page.changed
                        subtle: true
                        text: qsTr("Save as new")
                        onClicked: namer.ask("copy", page.working.name)
                    }

                    ShellButton {
                        objectName: "plannerViewRevert"
                        visible: page.changed
                        subtle: true
                        text: qsTr("Revert")
                        onClicked: page.revert()
                    }

                    ShellButton {
                        objectName: "plannerViewMenu"
                        subtle: true
                        iconName: "ellipsis"
                        toolTip: qsTr("View and baseline")
                        Accessible.name: qsTr("View and baseline")
                        onClicked: viewMenu.open()

                        ShellMenu {
                            id: viewMenu

                            y: parent.height + 4
                            x: parent.width - width

                            ShellMenuItem {
                                objectName: "plannerViewRename"
                                text: qsTr("Rename view…")
                                onTriggered: namer.ask("rename", page.working.name)
                            }

                            ShellMenuItem {
                                objectName: "plannerViewDuplicate"
                                text: qsTr("Save as new view…")
                                onTriggered: namer.ask("copy", page.working.name)
                            }

                            ShellMenuItem {
                                objectName: "plannerViewRemove"
                                text: qsTr("Remove view")
                                destructive: true
                                enabled: page.views.filter(view => view.environment === page.environment).length > 1
                                onTriggered: {
                                    page.ask("removeView", { id: page.working.id }, page.environment);
                                    page.viewKey = "";
                                }
                            }

                            ShellMenuSeparator {}

                            ShellMenuItem {
                                objectName: "plannerSetBaseline"
                                text: qsTr("Save baseline")
                                detail: qsTr("today's dates, to compare against")
                                onTriggered: page.ask("setBaseline", {}, page.environment)
                            }

                            ShellMenuItem {
                                objectName: "plannerClearBaseline"
                                text: qsTr("Clear baseline")
                                enabled: page.items.some(item => item.baseline)
                                onTriggered: page.ask("clearBaseline", {}, page.environment)
                            }
                        }
                    }
                }

                // How the plan is going, GitHub and Slack.
                RowLayout {
                    Layout.fillWidth: true
                    visible: page.plan !== null
                    spacing: 8

                    Chip {
                        objectName: "plannerHealth"
                        visible: page.latest !== null
                        text: page.healthLabel(page.latest?.health)
                        tone: page.healthColor(page.latest?.health)
                    }

                    Text {
                        objectName: "plannerUpdate"
                        Layout.fillWidth: true
                        text: page.latest ? page.latest.text + "  ·  " + page.time(page.latest.at) : qsTr("No status update yet")
                        color: page.latest ? page.foreground : page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Chip {
                        objectName: "plannerUpdateSlack"
                        visible: page.latest?.slack !== undefined && page.latest?.slack !== null
                        text: qsTr("Slack")
                    }

                    ShellButton {
                        objectName: "plannerPostUpdate"
                        subtle: true
                        text: qsTr("Post update")
                        onClicked: poster.open()
                    }
                }

                Text {
                    objectName: "plannerSyncLine"
                    Layout.fillWidth: true
                    readonly property var sync: page.plan?.sync ?? null
                    visible: text.length > 0
                    text: {
                        if (sync === null || ((sync.repositories ?? []).length === 0 && !sync.board))
                            return "";
                        const parts = [qsTr("GitHub: %1").arg((sync.repositories ?? []).join(", "))];
                        if (sync.board)
                            parts.push(qsTr("board %1").arg(sync.board));
                        if (sync.mode === "twoWay")
                            parts.push(qsTr("both ways"));
                        if (sync.checkedAt)
                            parts.push(qsTr("looked %1").arg(page.time(sync.checkedAt)));
                        return parts.join("  ·  ");
                    }
                    color: page.muted
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }

                Text {
                    objectName: "plannerSyncProblem"
                    Layout.fillWidth: true
                    readonly property var sync: page.plan?.sync ?? null
                    visible: text.length > 0
                    text: {
                        if (sync === null)
                            return "";
                        const unwatched = (sync.unwatched ?? []).map(each => each.includes(" ") ? each : qsTr("No project on this MC has the repository %1.").arg(each));
                        return [sync.problem ?? ""].concat(unwatched).filter(part => part.length > 0).join(" ");
                    }
                    color: page.warningColor
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Text {
                    objectName: "plannerSlackProblem"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: page.plan?.sync?.slack?.problem ?? ""
                    color: page.warningColor
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                // What agents and Slack said about the plan as a whole.
                Repeater {
                    model: (page.plan?.planFeedback ?? []).slice(0, 3)

                    delegate: RowLayout {
                        id: note

                        required property var modelData

                        objectName: "plannerPlanFeedback:" + modelData.id
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: note.modelData.text + (note.modelData.by ? "  — " + String(note.modelData.by).replace(/^slack:/, "") + (String(note.modelData.by).startsWith("slack:") ? qsTr(" in Slack") : "") : "")
                            color: page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellButton {
                            subtle: true
                            text: qsTr("Dismiss")
                            onClicked: page.ask("dismissFeedback", { itemId: null, feedbackId: note.modelData.id }, page.environment)
                        }
                    }
                }

                Text {
                    objectName: "plannerRefusal"
                    Layout.fillWidth: true
                    visible: page.refusal.length > 0
                    text: page.refusal
                    color: page.errorColor
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Loader {
                    anchors.fill: parent
                    active: page.working !== null
                    sourceComponent: page.working?.layout === "board" ? boardView : page.working?.layout === "list" ? listView : ganttView
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 48
                    visible: page.working === null || page.rows.length === 0
                    text: page.plan === null ? qsTr("Loading the plan…") : page.items.length === 0 ? qsTr("No tasks yet. Add a task or a milestone, or follow a repository's issues in the plugin's settings.") : qsTr("No task matches this view.")
                    color: page.muted
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                visible: itemPanel.visible
                color: page.border
            }

            // The picked task, from any view.
            Flickable {
                id: itemPanel

                readonly property var item: page.selected

                objectName: "plannerItem"
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                visible: item !== null
                clip: true
                contentHeight: itemColumn.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: itemColumn

                    readonly property var item: itemPanel.item
                    readonly property var others: page.items.filter(each => each.id !== itemColumn.item?.id)

                    x: 16
                    y: 16
                    width: itemPanel.width - 32
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        ItemField {
                            objectName: "plannerItemTitle"
                            current: itemColumn.item?.title ?? ""
                            font.pixelSize: Math.round(15 * Theme.fontScale)
                            Accessible.name: qsTr("Title")
                            onCommit: text => {
                                if (text.length > 0)
                                    page.update(itemColumn.item, { title: text });
                            }
                        }

                        ShellButton {
                            subtle: true
                            iconName: "x"
                            toolTip: qsTr("Close")
                            Accessible.name: qsTr("Close")
                            onClicked: page.select(null)
                        }
                    }

                    Text {
                        objectName: "plannerItemNotices"
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: {
                            const item = itemColumn.item;
                            if (!item)
                                return "";
                            const parts = [];
                            if (item.late)
                                parts.push(qsTr("Late"));
                            for (const id of item.early ?? [])
                                parts.push(qsTr("Starts before %1 ends").arg(page.byId[id]?.title ?? id));
                            if (item.slip > 0)
                                parts.push(item.slip === 1 ? qsTr("Ends 1 day after its baseline") : qsTr("Ends %1 days after its baseline").arg(item.slip));
                            else if (item.slip < 0)
                                parts.push(item.slip === -1 ? qsTr("Ends 1 day before its baseline") : qsTr("Ends %1 days before its baseline").arg(-item.slip));
                            return parts.join(" · ");
                        }
                        color: page.warningColor
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 10
                        rowSpacing: 6

                        Text {
                            text: qsTr("Kind")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellComboBox {
                            objectName: "plannerItemKind"
                            Layout.fillWidth: true
                            outline: true
                            model: [qsTr("Task"), qsTr("Milestone")]
                            currentIndex: itemColumn.item?.kind === "milestone" ? 1 : 0
                            Accessible.name: qsTr("Kind")
                            onActivated: index => page.update(itemColumn.item, index === 1 ? { kind: "milestone", start: null } : { kind: "task" })
                        }

                        Text {
                            text: qsTr("Status")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellComboBox {
                            objectName: "plannerItemStatus"
                            Layout.fillWidth: true
                            outline: true
                            model: page.statuses.map(status => page.statusLabel(status))
                            currentIndex: page.statuses.indexOf(itemColumn.item?.status ?? "todo")
                            Accessible.name: qsTr("Status")
                            onActivated: index => page.update(itemColumn.item, { status: page.statuses[index] })
                        }

                        Text {
                            visible: itemColumn.item?.kind !== "milestone"
                            text: qsTr("Start")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ItemField {
                            objectName: "plannerItemStart"
                            visible: itemColumn.item?.kind !== "milestone"
                            current: itemColumn.item?.start ?? ""
                            placeholderText: qsTr("YYYY-MM-DD")
                            Accessible.name: qsTr("Start")
                            onCommit: text => page.update(itemColumn.item, { start: text.length > 0 ? text : null })
                        }

                        Text {
                            text: itemColumn.item?.kind === "milestone" ? qsTr("On") : qsTr("Due")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ItemField {
                            objectName: "plannerItemDue"
                            current: itemColumn.item?.due ?? ""
                            placeholderText: qsTr("YYYY-MM-DD")
                            Accessible.name: qsTr("Due")
                            onCommit: text => page.update(itemColumn.item, { due: text.length > 0 ? text : null })
                        }

                        Text {
                            text: qsTr("Progress")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ItemField {
                            objectName: "plannerItemProgress"
                            current: itemColumn.item?.progress === null || itemColumn.item?.progress === undefined ? "" : String(itemColumn.item.progress)
                            placeholderText: qsTr("%1% from its subtasks and pull requests").arg(itemColumn.item?.derivedProgress ?? 0)
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator {
                                bottom: 0
                                top: 100
                            }
                            Accessible.name: qsTr("Progress")
                            onCommit: text => page.update(itemColumn.item, { progress: text.length > 0 ? Number(text) : null })
                        }

                        Text {
                            text: qsTr("Owner")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ItemField {
                            objectName: "plannerItemOwner"
                            current: itemColumn.item?.owner ?? ""
                            placeholderText: qsTr("Nobody")
                            Accessible.name: qsTr("Owner")
                            onCommit: text => page.update(itemColumn.item, { owner: text.length > 0 ? text : null })
                        }

                        Text {
                            text: qsTr("Labels")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ItemField {
                            objectName: "plannerItemLabels"
                            current: (itemColumn.item?.labels ?? []).join(", ")
                            placeholderText: qsTr("comma separated")
                            Accessible.name: qsTr("Labels")
                            onCommit: text => page.update(itemColumn.item, { labels: text.split(",").map(label => label.trim()).filter(label => label.length > 0) })
                        }

                        Text {
                            text: qsTr("Project")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellComboBox {
                            objectName: "plannerItemProject"
                            Layout.fillWidth: true
                            outline: true
                            model: [qsTr("No project")].concat(page.projects.map(project => project.title))
                            // A project the MC no longer offers is shown by its id, not as none.
                            currentIndex: {
                                const id = itemColumn.item?.projectId ?? "";
                                const at = page.projects.findIndex(project => project.id === id);
                                return id === "" ? 0 : at < 0 ? -1 : at + 1;
                            }
                            displayText: currentIndex >= 0 ? currentText : itemColumn.item?.projectId ?? ""
                            Accessible.name: qsTr("Project")
                            onActivated: index => page.update(itemColumn.item, { projectId: index === 0 ? null : page.projects[index - 1].id })
                        }

                        Text {
                            text: qsTr("Under")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellComboBox {
                            objectName: "plannerItemParent"
                            Layout.fillWidth: true
                            outline: true
                            model: [qsTr("Nothing")].concat(itemColumn.others.map(each => each.title))
                            currentIndex: itemColumn.others.findIndex(each => each.id === itemColumn.item?.parent) + 1
                            Accessible.name: qsTr("Subtask of")
                            onActivated: index => page.update(itemColumn.item, { parent: index === 0 ? null : itemColumn.others[index - 1].id })
                        }

                        Text {
                            Layout.alignment: Qt.AlignTop
                            text: qsTr("Waits for")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            Repeater {
                                model: itemColumn.item?.after ?? []

                                delegate: RowLayout {
                                    id: dependency

                                    required property string modelData

                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        Layout.fillWidth: true
                                        text: page.byId[dependency.modelData]?.title ?? dependency.modelData
                                        color: (itemColumn.item?.early ?? []).includes(dependency.modelData) ? page.errorColor : page.foreground
                                        elide: Text.ElideRight
                                        font.pixelSize: Math.round(12 * Theme.fontScale)
                                    }

                                    ShellButton {
                                        subtle: true
                                        iconName: "x"
                                        Accessible.name: qsTr("Stop waiting for %1").arg(page.byId[dependency.modelData]?.title ?? "")
                                        onClicked: page.update(itemColumn.item, { after: itemColumn.item.after.filter(id => id !== dependency.modelData) })
                                    }
                                }
                            }

                            ShellComboBox {
                                readonly property var choices: itemColumn.others.filter(each => !(itemColumn.item?.after ?? []).includes(each.id))

                                objectName: "plannerItemAfter"
                                Layout.fillWidth: true
                                outline: true
                                markCurrent: false
                                visible: choices.length > 0
                                model: choices.map(each => each.title)
                                currentIndex: -1
                                displayText: qsTr("Add a task to wait for")
                                Accessible.name: qsTr("Add a task to wait for")
                                onActivated: index => page.update(itemColumn.item, { after: (itemColumn.item.after ?? []).concat([choices[index].id]) })
                            }
                        }
                    }

                    Caption {
                        text: qsTr("Notes")
                    }

                    TextArea {
                        id: notes

                        readonly property string current: itemColumn.item?.notes ?? ""

                        objectName: "plannerItemNotes"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(80, implicitHeight)
                        text: current
                        placeholderText: qsTr("Markdown")
                        wrapMode: TextEdit.Wrap
                        color: page.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        Accessible.name: qsTr("Notes")
                        onCurrentChanged: text = current
                        onEditingFinished: if (text !== current)
                            page.update(itemColumn.item, { notes: text })
                        background: Rectangle {
                            radius: Math.min(Theme.radius, 8)
                            color: Theme.palette.color("input", "#18181b")
                            border.color: notes.activeFocus ? Theme.palette.color("focus", "#3b82f6") : page.border
                        }
                    }

                    Line {
                        visible: (itemColumn.item?.note ?? "").length > 0
                        text: qsTr("Last progress note: %1").arg(itemColumn.item?.note ?? "")
                        color: page.muted
                    }

                    Line {
                        objectName: "plannerItemSyncError"
                        visible: (itemColumn.item?.syncError ?? "").length > 0
                        text: qsTr("Not synced to GitHub: %1").arg(itemColumn.item?.syncError ?? "")
                        color: page.errorColor
                    }

                    Caption {
                        text: qsTr("Links")
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: itemColumn.item?.issue !== null && itemColumn.item?.issue !== undefined
                        spacing: 6

                        Line {
                            objectName: "plannerItemIssue"
                            text: itemColumn.item?.issue ? qsTr("Issue %1#%2 · %3").arg(itemColumn.item.issue.repository).arg(itemColumn.item.issue.number).arg(itemColumn.item.issue.state ?? "") : ""
                        }

                        ShellButton {
                            subtle: true
                            text: qsTr("Open")
                            onClicked: Qt.openUrlExternally(itemColumn.item.issue.url)
                        }

                        ShellButton {
                            subtle: true
                            text: qsTr("Unlink")
                            onClicked: page.ask("unlink", { itemId: itemColumn.item.id, kind: "issue", ref: { repository: itemColumn.item.issue.repository, number: itemColumn.item.issue.number } }, itemColumn.item.environment)
                        }
                    }

                    Repeater {
                        model: itemColumn.item?.pullRequests ?? []

                        delegate: RowLayout {
                            id: pull

                            required property var modelData

                            objectName: "plannerItemPullRequest:" + modelData.number
                            Layout.fillWidth: true
                            spacing: 6

                            Line {
                                text: qsTr("PR %1#%2 %3 · %4").arg(pull.modelData.repository).arg(pull.modelData.number).arg(pull.modelData.title ?? "").arg(pull.modelData.state ?? "")
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }

                            ShellButton {
                                subtle: true
                                text: qsTr("Open")
                                onClicked: Qt.openUrlExternally(pull.modelData.url)
                            }

                            ShellButton {
                                subtle: true
                                text: qsTr("Unlink")
                                onClicked: page.ask("unlink", { itemId: itemColumn.item.id, kind: "pullRequest", ref: { repository: pull.modelData.repository, number: pull.modelData.number } }, itemColumn.item.environment)
                            }
                        }
                    }

                    Repeater {
                        model: itemColumn.item?.threads ?? []

                        delegate: RowLayout {
                            id: linked

                            required property string modelData

                            Layout.fillWidth: true
                            spacing: 6

                            Line {
                                text: {
                                    const run = page.runs.find(run => run.threadId === linked.modelData);
                                    return run ? qsTr("%1 thread · %2").arg(run.label).arg(page.runStatusLabel(run.status)) : qsTr("Thread");
                                }
                            }

                            ShellButton {
                                objectName: "plannerItemOpenThread"
                                subtle: true
                                text: qsTr("Open thread")
                                onClicked: page.plugin.openThread(linked.modelData, itemColumn.item.environment)
                            }

                            ShellButton {
                                subtle: true
                                text: qsTr("Unlink")
                                onClicked: page.ask("unlink", { itemId: itemColumn.item.id, kind: "thread", threadId: linked.modelData }, itemColumn.item.environment)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        ShellTextField {
                            id: linkField

                            objectName: "plannerItemLink"
                            Layout.fillWidth: true
                            placeholderText: qsTr("owner/name#12")
                            Accessible.name: qsTr("Pull request to link")
                            onAccepted: linkButton.clicked()
                        }

                        ShellButton {
                            id: linkButton

                            readonly property var ref: {
                                const found = /^\s*([\w.-]+\/[\w.-]+)#(\d+)\s*$/.exec(linkField.text);
                                return found ? { repository: found[1], number: Number(found[2]) } : null;
                            }

                            subtle: true
                            enabled: ref !== null
                            text: qsTr("Link PR")
                            onClicked: {
                                page.ask("link", { itemId: itemColumn.item.id, pullRequest: ref }, itemColumn.item.environment);
                                linkField.text = "";
                            }
                        }
                    }

                    Caption {
                        visible: (itemColumn.item?.feedback ?? []).length > 0
                        text: qsTr("Feedback")
                    }

                    Repeater {
                        model: itemColumn.item?.feedback ?? []

                        delegate: RowLayout {
                            id: feedback

                            required property var modelData

                            objectName: "plannerItemFeedback:" + modelData.id
                            Layout.fillWidth: true
                            spacing: 6

                            Line {
                                text: feedback.modelData.text + (feedback.modelData.by ? "  — " + String(feedback.modelData.by).replace(/^slack:/, "") : "")
                            }

                            ShellButton {
                                subtle: true
                                text: qsTr("Dismiss")
                                onClicked: page.ask("dismissFeedback", { itemId: itemColumn.item.id, feedbackId: feedback.modelData.id }, itemColumn.item.environment)
                            }
                        }
                    }

                    Caption {
                        text: qsTr("Actions")
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: page.actions.filter(action => action.scope === "item")

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "plannerItemAction:" + modelData.id
                                text: modelData.label
                                enabled: page.busy === 0
                                onClicked: page.runAction(modelData.id, [itemColumn.item.id])
                            }
                        }

                        ShellButton {
                            readonly property string repository: page.projects.find(project => project.id === itemColumn.item?.projectId)?.repository ?? (page.plan?.sync?.repositories ?? [])[0] ?? ""

                            objectName: "plannerCreateIssue"
                            visible: !itemColumn.item?.issue
                            enabled: repository.length > 0 && page.busy === 0
                            text: qsTr("Create issue")
                            toolTip: repository.length > 0 ? qsTr("In %1").arg(repository) : qsTr("Give the task a project with a GitHub remote")
                            onClicked: page.ask("createIssue", { itemId: itemColumn.item.id, repository: repository }, itemColumn.item.environment)
                        }

                        ShellButton {
                            objectName: "plannerRemove"
                            subtle: true
                            text: qsTr("Remove")
                            onClicked: {
                                const item = itemColumn.item;
                                page.select(null);
                                page.ask("removeItem", { id: item.id }, item.environment);
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                visible: runsPanel.visible
                color: page.border
            }

            // The runs of the plan's actions, and the one picked with what it proposes.
            Flickable {
                id: runsPanel

                objectName: "plannerRuns"
                Layout.preferredWidth: 360
                Layout.fillHeight: true
                visible: page.runsOpen
                clip: true
                contentHeight: runsColumn.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: runsColumn

                    readonly property var run: page.run
                    readonly property bool open: run?.status === "proposed"

                    x: 16
                    y: 12
                    width: runsPanel.width - 32
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true

                        Caption {
                            text: qsTr("Runs")
                        }

                        ShellButton {
                            subtle: true
                            iconName: "x"
                            toolTip: qsTr("Close")
                            Accessible.name: qsTr("Close runs")
                            onClicked: page.runsOpen = false
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: page.runs.length === 0
                        text: qsTr("No runs yet. Run an action on the plan or on a task.")
                        color: page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Repeater {
                        model: page.runs

                        delegate: ItemDelegate {
                            id: entry

                            required property var modelData
                            required property int index

                            objectName: "plannerRun:" + modelData.label
                            Layout.fillWidth: true
                            leftPadding: 8
                            rightPadding: 8
                            topPadding: 5
                            bottomPadding: 5
                            highlighted: modelData.key === page.pickedRun
                            Accessible.name: qsTr("%1, %2").arg(modelData.label).arg(page.runLabel(modelData))
                            onClicked: page.pickedRun = modelData.key

                            background: Rectangle {
                                radius: Math.min(Theme.radius, 6)
                                color: entry.highlighted ? Theme.palette.color("sidebarRowSelected", "#27272a") : entry.hovered ? Theme.palette.color("sidebarRowHover", "#1f1f23") : "transparent"
                            }

                            contentItem: RowLayout {
                                spacing: 6

                                Text {
                                    objectName: "plannerRunTitle"
                                    Layout.fillWidth: true
                                    text: {
                                        const titles = (entry.modelData.itemIds ?? []).map(id => page.itemIn(entry.modelData.environment, id)?.title).filter(title => title);
                                        const where = page.several ? " (" + page.environmentLabel(entry.modelData.environment) + ")" : "";
                                        return entry.modelData.label + where + (titles.length > 0 ? " · " + titles.join(", ") : "");
                                    }
                                    color: page.foreground
                                    elide: Text.ElideRight
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                Text {
                                    objectName: "plannerRunState"
                                    text: page.runLabel(entry.modelData)
                                    color: entry.modelData.status === "failed" ? page.errorColor : entry.modelData.status === "proposed" ? page.warningColor : page.muted
                                    font.pixelSize: Math.round(11 * Theme.fontScale)
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        visible: runsColumn.run !== null
                        implicitHeight: 1
                        color: page.border
                    }

                    ColumnLayout {
                        objectName: "plannerRunDetail"
                        Layout.fillWidth: true
                        visible: runsColumn.run !== null
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                Layout.fillWidth: true
                                text: runsColumn.run?.label ?? ""
                                color: page.foreground
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(14 * Theme.fontScale)
                                font.weight: Font.DemiBold
                            }

                            Chip {
                                visible: (runsColumn.run?.health ?? "").length > 0
                                text: page.healthLabel(runsColumn.run?.health)
                                tone: page.healthColor(runsColumn.run?.health)
                            }
                        }

                        Line {
                            objectName: "plannerRunStatus"
                            text: page.runStatusLabel(runsColumn.run?.status) + (runsColumn.run?.startedAt ? " · " + page.time(runsColumn.run.startedAt) : "")
                            color: page.muted
                        }

                        Line {
                            visible: (runsColumn.run?.error ?? "").length > 0
                            text: runsColumn.run?.error ?? ""
                            color: page.errorColor
                        }

                        TextEdit {
                            objectName: "plannerRunSummary"
                            Layout.fillWidth: true
                            visible: (runsColumn.run?.summary ?? "").length > 0
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.MarkdownText
                            text: runsColumn.run?.summary ?? ""
                            color: page.foreground
                            wrapMode: TextEdit.Wrap
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }

                        Repeater {
                            model: runsColumn.run?.changes ?? []

                            delegate: Rectangle {
                                id: change

                                required property var modelData
                                readonly property bool dismissed: modelData.dismissed === true

                                objectName: "plannerChange:" + modelData.id
                                Layout.fillWidth: true
                                implicitHeight: changeColumn.implicitHeight + 16
                                radius: Math.min(Theme.radius, 8)
                                color: page.raised
                                border.color: page.border
                                opacity: dismissed ? 0.55 : 1

                                ColumnLayout {
                                    id: changeColumn

                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 4

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        Text {
                                            objectName: "plannerChangeText"
                                            Layout.fillWidth: true
                                            text: page.changeText(change.modelData)
                                            color: page.foreground
                                            wrapMode: Text.Wrap
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
                                            font.strikeout: change.dismissed
                                        }

                                        ShellButton {
                                            objectName: "plannerChangeDismiss"
                                            visible: runsColumn.open && !change.modelData.outcome
                                            subtle: true
                                            enabled: page.busy === 0
                                            text: change.dismissed ? qsTr("Keep") : qsTr("Dismiss")
                                            onClicked: page.ask("dismissChange", { runId: runsColumn.run.id, changeId: change.modelData.id, dismissed: !change.dismissed }, runsColumn.run.environment)
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: text.length > 0
                                        text: change.modelData.outcome === "stale" ? qsTr("Not applied: %1").arg(change.modelData.staleReason ?? "") : (change.modelData.reason ?? "")
                                        color: change.modelData.outcome === "stale" ? page.warningColor : page.muted
                                        wrapMode: Text.Wrap
                                        font.pixelSize: Math.round(11 * Theme.fontScale)
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: runsColumn.run?.feedback ?? []

                            delegate: Line {
                                required property var modelData

                                text: (modelData.itemId ? (page.itemIn(runsColumn.run.environment, modelData.itemId)?.title ?? modelData.itemId) + ": " : "") + modelData.text
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            ShellButton {
                                objectName: "plannerApply"
                                visible: runsColumn.open
                                primary: true
                                enabled: page.busy === 0
                                text: qsTr("Apply")
                                onClicked: page.ask("apply", { runId: runsColumn.run.id }, runsColumn.run.environment)
                            }

                            ShellButton {
                                objectName: "plannerRetry"
                                visible: runsColumn.run?.status === "failed"
                                primary: true
                                enabled: page.busy === 0
                                text: qsTr("Try again")
                                onClicked: page.ask("retry", { runId: runsColumn.run.id }, runsColumn.run.environment)
                            }

                            ShellButton {
                                objectName: "plannerRunThread"
                                visible: (runsColumn.run?.threadId ?? "").length > 0
                                text: qsTr("Open thread")
                                onClicked: page.plugin.openThread(runsColumn.run.threadId, runsColumn.run.environment)
                            }

                            ShellButton {
                                objectName: "plannerDiscard"
                                visible: runsColumn.run !== null && runsColumn.run.status !== "running" && runsColumn.run.status !== "queued"
                                subtle: true
                                enabled: page.busy === 0
                                text: qsTr("Discard")
                                onClicked: {
                                    page.ask("discard", { runId: runsColumn.run.id }, runsColumn.run.environment);
                                    page.pickedRun = "";
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The Gantt chart: a row per task or group, its name pinned on the left, and a
    // timeline that scrolls under it. Only the visible rows' dependencies are drawn.
    Component {
        id: ganttView

        ListView {
            id: gantt

            readonly property string zoom: page.working?.zoom ?? "week"
            readonly property real dayWidth: zoom === "day" ? 36 : zoom === "month" ? 4 : zoom === "quarter" ? 1.5 : 14
            readonly property int headerHeight: 28
            // The first day drawn, a Monday, and the last.
            readonly property int rangeStart: {
                let first = page.day(page.today);
                for (const item of page.items) {
                    for (const date of [item.start, item.due, item.baseline?.start, item.baseline?.due]) {
                        if (date)
                            first = Math.min(first, page.day(date));
                    }
                }
                first -= 14;
                return first - ((first + 3) % 7 + 7) % 7;
            }
            readonly property int rangeEnd: {
                let last = page.day(page.today);
                for (const item of page.items) {
                    for (const date of [item.start, item.due, item.baseline?.start, item.baseline?.due]) {
                        if (date)
                            last = Math.max(last, page.day(date));
                    }
                }
                return last + 42;
            }
            readonly property real visibleWidth: width - page.labelWidth
            readonly property int firstRow: Math.max(0, Math.floor((contentY - originY) / page.rowHeight) - 1)
            readonly property int lastRow: Math.ceil((contentY - originY + height) / page.rowHeight) + 1
            // The dependencies with an end in a visible row.
            readonly property var links: {
                if (!page.working?.showDependencies)
                    return [];
                const links = [];
                page.rows.forEach((row, to) => {
                    if (row.kind !== "item")
                        return;
                    for (const id of row.item.after ?? []) {
                        const from = page.rowIndex[id];
                        if (from === undefined || Math.max(from, to) < firstRow || Math.min(from, to) > lastRow)
                            continue;
                        links.push({ from: from, to: to, name: page.rows[from].item.title + "->" + row.item.title, violated: (row.item.early ?? []).includes(id) });
                    }
                });
                return links;
            }
            // The day at the left edge, kept when the zoom or the range changes.
            property real leftDay: NaN
            property bool placing: false

            // Where `item`'s bar starts and ends, in the content's x.
            function edges(item) {
                const x = day => page.labelWidth + (day - rangeStart) * dayWidth;
                if (item.kind === "milestone") {
                    // A milestone whose date was cleared is undated, like a task without dates.
                    if (isNaN(page.day(item.due)))
                        return null;
                    const centre = x(page.day(item.due)) + dayWidth / 2;
                    return { start: centre - 7, end: centre + 7 };
                }
                const start = page.day(item.start ?? item.due);
                const end = page.day(item.due ?? item.start);
                if (isNaN(start))
                    return null;
                return { start: x(start), end: x(end + 1) };
            }

            function rowY(index) {
                return originY + headerHeight + index * page.rowHeight + page.rowHeight / 2;
            }

            function keep() {
                if (isNaN(leftDay))
                    return;
                placing = true;
                contentX = Math.max(0, Math.min(contentWidth - width, (leftDay - rangeStart) * dayWidth));
                placing = false;
            }

            // Shows the week before today, or before the first task when it starts later.
            function place() {
                if (!isNaN(leftDay) || width <= 0 || page.rows.length === 0)
                    return;
                let first = page.day(page.today);
                for (const item of page.items) {
                    if (item.start || item.due)
                        first = Math.min(first, page.day(item.start ?? item.due));
                }
                leftDay = Math.max(first, page.day(page.today) - 28) - 7;
                keep();
            }

            // The day at the start of tick `n` of the zoom.
            function tickDay(n) {
                if (zoom === "day")
                    return rangeStart + n;
                if (zoom === "week")
                    return rangeStart + 7 * n;
                const start = new Date(rangeStart * 86400000);
                const months = start.getUTCFullYear() * 12 + start.getUTCMonth();
                const month = zoom === "quarter" ? (Math.floor(months / 3) + n) * 3 : months + n;
                return Math.round(Date.UTC(Math.floor(month / 12), month % 12, 1) / 86400000);
            }

            function tickLabel(day) {
                const date = new Date(day * 86400000);
                const locale = Qt.locale();
                if (zoom === "day")
                    return date.getUTCDate() === 1 ? locale.monthName(date.getUTCMonth(), Locale.ShortFormat) + " 1" : String(date.getUTCDate());
                if (zoom === "week")
                    return locale.monthName(date.getUTCMonth(), Locale.ShortFormat) + " " + date.getUTCDate();
                if (zoom === "month")
                    return locale.monthName(date.getUTCMonth(), Locale.ShortFormat) + (date.getUTCMonth() === 0 ? " " + date.getUTCFullYear() : "");
                return "Q" + (Math.floor(date.getUTCMonth() / 3) + 1) + " " + date.getUTCFullYear();
            }

            objectName: "plannerGantt"
            clip: true
            model: page.rows
            contentWidth: page.labelWidth + (rangeEnd - rangeStart + 1) * dayWidth
            flickableDirection: Flickable.HorizontalAndVerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            headerPositioning: ListView.OverlayHeader
            onContentXChanged: if (!placing && !isNaN(leftDay))
                leftDay = rangeStart + contentX / dayWidth
            onDayWidthChanged: keep()
            onRangeStartChanged: keep()
            onWidthChanged: place()
            onCountChanged: place()
            Component.onCompleted: place()

            ScrollBar.vertical: ScrollBar {}
            ScrollBar.horizontal: ScrollBar {}

            header: Rectangle {
                z: 5
                width: gantt.contentWidth
                height: gantt.headerHeight
                color: page.surface

                Repeater {
                    // Ticks for what is in view only; they move as it scrolls.
                    readonly property real tickWidth: gantt.zoom === "day" ? gantt.dayWidth : gantt.zoom === "week" ? 7 * gantt.dayWidth : gantt.zoom === "month" ? 28 * gantt.dayWidth : 89 * gantt.dayWidth
                    readonly property int firstTick: Math.max(0, Math.floor(gantt.contentX / (gantt.zoom === "month" ? 30.44 * gantt.dayWidth : gantt.zoom === "quarter" ? 91.3 * gantt.dayWidth : tickWidth)) - 1)

                    id: ticks

                    model: Math.ceil(gantt.visibleWidth / tickWidth) + 3

                    delegate: Item {
                        id: tick

                        required property int index
                        readonly property int day: gantt.tickDay(ticks.firstTick + index)

                        x: page.labelWidth + (day - gantt.rangeStart) * gantt.dayWidth
                        width: 1
                        height: gantt.headerHeight

                        Rectangle {
                            width: 1
                            height: parent.height
                            color: page.border
                        }

                        Text {
                            x: 4
                            anchors.verticalCenter: parent.verticalCenter
                            text: gantt.tickLabel(tick.day)
                            color: page.muted
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                    }
                }

                Rectangle {
                    x: gantt.contentX
                    width: page.labelWidth
                    height: parent.height
                    color: page.surface

                    Text {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.fieldLabel("title")
                        color: page.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.Medium
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.border
                }
            }

            // Weekends at days and weeks, behind the bars.
            Item {
                parent: gantt.contentItem
                z: 0
                x: gantt.contentX + page.labelWidth
                y: gantt.contentY + gantt.headerHeight
                width: Math.max(0, gantt.visibleWidth)
                height: gantt.height - gantt.headerHeight
                clip: true
                visible: gantt.zoom === "day" || gantt.zoom === "week"

                Repeater {
                    id: weekends

                    readonly property int firstWeek: Math.max(0, Math.floor(gantt.contentX / (7 * gantt.dayWidth)) - 1)

                    model: parent.visible ? Math.ceil(gantt.visibleWidth / (7 * gantt.dayWidth)) + 3 : 0

                    delegate: Rectangle {
                        required property int index

                        x: ((weekends.firstWeek + index) * 7 + 5) * gantt.dayWidth - gantt.contentX
                        width: 2 * gantt.dayWidth
                        height: parent.height
                        color: Qt.alpha(page.foreground, 0.035)
                    }
                }
            }

            // Dependencies and today, over the bars.
            Item {
                id: overlay

                parent: gantt.contentItem
                z: 2
                x: gantt.contentX + page.labelWidth
                y: gantt.contentY + gantt.headerHeight
                width: Math.max(0, gantt.visibleWidth)
                height: gantt.height - gantt.headerHeight
                clip: true

                Rectangle {
                    objectName: "plannerToday"
                    x: page.labelWidth + (page.day(page.today) - gantt.rangeStart + 0.5) * gantt.dayWidth - 1 - overlay.x
                    width: 2
                    height: overlay.height
                    color: page.errorColor
                    opacity: 0.8
                    Accessible.role: Accessible.Indicator
                    Accessible.name: qsTr("Today, %1").arg(page.today)
                }

                Repeater {
                    model: gantt.links

                    delegate: Shape {
                        id: arrow

                        required property var modelData
                        readonly property var from: gantt.edges(page.rows[modelData.from].item)
                        readonly property var to: gantt.edges(page.rows[modelData.to].item)
                        readonly property real x1: (from?.end ?? 0) - overlay.x
                        readonly property real y1: gantt.rowY(modelData.from) - overlay.y
                        readonly property real x2: (to?.start ?? 0) - overlay.x
                        readonly property real y2: gantt.rowY(modelData.to) - overlay.y
                        readonly property real gap: 6
                        readonly property color tone: modelData.violated ? page.errorColor : page.muted

                        objectName: "plannerArrow:" + modelData.name
                        visible: from !== null && to !== null
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            strokeColor: arrow.tone
                            strokeWidth: 1.25
                            fillColor: "transparent"

                            PathPolyline {
                                path: arrow.x2 - arrow.gap >= arrow.x1 + arrow.gap ? [Qt.point(arrow.x1, arrow.y1), Qt.point(arrow.x1 + arrow.gap, arrow.y1), Qt.point(arrow.x1 + arrow.gap, arrow.y2), Qt.point(arrow.x2, arrow.y2)] : [Qt.point(arrow.x1, arrow.y1), Qt.point(arrow.x1 + arrow.gap, arrow.y1), Qt.point(arrow.x1 + arrow.gap, arrow.y2 - Math.sign(arrow.y2 - arrow.y1) * page.rowHeight / 2), Qt.point(arrow.x2 - arrow.gap, arrow.y2 - Math.sign(arrow.y2 - arrow.y1) * page.rowHeight / 2), Qt.point(arrow.x2 - arrow.gap, arrow.y2), Qt.point(arrow.x2, arrow.y2)]
                            }
                        }

                        ShapePath {
                            strokeColor: "transparent"
                            fillColor: arrow.tone

                            PathPolyline {
                                path: [Qt.point(arrow.x2, arrow.y2), Qt.point(arrow.x2 - 5, arrow.y2 - 3.5), Qt.point(arrow.x2 - 5, arrow.y2 + 3.5), Qt.point(arrow.x2, arrow.y2)]
                            }
                        }
                    }
                }
            }

            delegate: Item {
                id: lane

                required property var modelData
                required property int index
                readonly property var item: modelData.item ?? null
                readonly property bool picked: item !== null && item.key === page.selectedKey
                readonly property var bar: item ? gantt.edges(item) : null
                readonly property var ghost: item ? page.ghosts[item.id] ?? null : null
                readonly property var ghostEdges: ghost ? gantt.edges(Object.assign({}, item, ghost)) : null
                readonly property var planned: item?.baseline && page.working?.showBaseline ? gantt.edges(Object.assign({}, item, item.baseline)) : null
                readonly property color tone: item?.late ? page.warningColor : page.statusColor(item?.status)
                // Whole days the bar is being dragged by, and its end.
                property int shift: 0
                property int grow: 0

                z: 1
                width: gantt.contentWidth
                height: page.rowHeight

                Rectangle {
                    x: gantt.contentX
                    width: gantt.width
                    height: parent.height
                    color: lane.picked ? Qt.alpha(Theme.palette.color("sidebarRowSelected", "#27272a"), 0.6) : "transparent"
                }

                Rectangle {
                    visible: lane.planned !== null
                    x: lane.planned?.start ?? 0
                    y: parent.height - 7
                    width: Math.max(2, (lane.planned?.end ?? 0) - (lane.planned?.start ?? 0))
                    height: 3
                    radius: 1.5
                    color: Qt.alpha(page.muted, 0.6)
                }

                // Where the picked run's proposal would put the bar.
                Shape {
                    id: ghostShape

                    objectName: lane.item ? "plannerGhost:" + lane.item.title : ""
                    visible: lane.ghostEdges !== null
                    x: lane.ghostEdges?.start ?? 0
                    y: 6
                    width: Math.max(4, (lane.ghostEdges?.end ?? 0) - (lane.ghostEdges?.start ?? 0))
                    height: parent.height - 12
                    Accessible.role: Accessible.Graphic
                    Accessible.name: qsTr("Proposed: %1 to %2").arg(lane.ghost?.start ?? "").arg(lane.ghost?.due ?? "")

                    ShapePath {
                        strokeColor: page.warningColor
                        strokeWidth: 1.5
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [3, 2]
                        fillColor: Qt.alpha(page.warningColor, 0.08)

                        PathRectangle {
                            x: 0.75
                            y: 0.75
                            width: ghostShape.width - 1.5
                            height: ghostShape.height - 1.5
                            radius: 4
                        }
                    }
                }

                // A task's bar, its progress filled in; dragged to move it, its end to change when it ends.
                Rectangle {
                    id: taskBar

                    objectName: lane.item ? "plannerBar:" + lane.item.title : ""
                    visible: lane.bar !== null && lane.item?.kind !== "milestone"
                    x: (lane.bar?.start ?? 0) + lane.shift * gantt.dayWidth
                    y: 8
                    width: Math.max(4, (lane.bar?.end ?? 0) - (lane.bar?.start ?? 0) + lane.grow * gantt.dayWidth)
                    height: parent.height - 16
                    radius: 4
                    color: Qt.alpha(lane.tone, 0.3)
                    border.color: (lane.item?.early ?? []).length > 0 ? page.errorColor : Qt.alpha(lane.tone, 0.8)
                    border.width: (lane.item?.early ?? []).length > 0 || lane.item?.late ? 2 : 1
                    opacity: lane.item?.status === "dropped" ? 0.4 : 1
                    Accessible.role: Accessible.Graphic
                    Accessible.name: lane.item ? qsTr("%1, %2 to %3, %4% done").arg(lane.item.title).arg(lane.item.start ?? "").arg(lane.item.due ?? "").arg(lane.item.derivedProgress ?? 0) : ""

                    Rectangle {
                        width: parent.width * Math.min(100, lane.item?.derivedProgress ?? 0) / 100
                        height: parent.height
                        radius: parent.radius
                        color: Qt.alpha(lane.tone, 0.75)
                    }

                    MouseArea {
                        property real from: 0
                        property bool moved: false

                        anchors.fill: parent
                        preventStealing: true
                        cursorShape: moved ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        onPressed: mouse => {
                            from = mapToItem(null, mouse.x, 0).x;
                            moved = false;
                        }
                        onPositionChanged: mouse => {
                            const dx = mapToItem(null, mouse.x, 0).x - from;
                            if (Math.abs(dx) > 4)
                                moved = true;
                            lane.shift = moved ? Math.round(dx / gantt.dayWidth) : 0;
                        }
                        onReleased: {
                            if (moved && lane.shift !== 0)
                                page.reschedule(lane.item, lane.shift, 0);
                            else if (!moved)
                                page.select(lane.item);
                            lane.shift = 0;
                            moved = false;
                        }
                        onCanceled: {
                            lane.shift = 0;
                            moved = false;
                        }
                    }

                    MouseArea {
                        property real from: 0

                        objectName: lane.item ? "plannerBarEnd:" + lane.item.title : ""
                        anchors.right: parent.right
                        width: 8
                        height: parent.height
                        visible: lane.item?.start !== null && lane.item?.start !== undefined && lane.item?.due !== null && lane.item?.due !== undefined
                        preventStealing: true
                        cursorShape: Qt.SizeHorCursor
                        onPressed: mouse => from = mapToItem(null, mouse.x, 0).x
                        onPositionChanged: mouse => {
                            const days = Math.round((mapToItem(null, mouse.x, 0).x - from) / gantt.dayWidth);
                            lane.grow = Math.max(page.day(lane.item.start) - page.day(lane.item.due), days);
                        }
                        onReleased: {
                            if (lane.grow !== 0)
                                page.reschedule(lane.item, 0, lane.grow);
                            lane.grow = 0;
                        }
                        onCanceled: lane.grow = 0
                    }
                }

                // A milestone's diamond, dragged to move its date.
                Rectangle {
                    objectName: lane.item ? "plannerMilestone:" + lane.item.title : ""
                    visible: lane.bar !== null && lane.item?.kind === "milestone"
                    x: (lane.bar?.start ?? 0) + 2 + lane.shift * gantt.dayWidth
                    y: (parent.height - height) / 2
                    width: 10
                    height: 10
                    rotation: 45
                    color: lane.item?.late ? page.warningColor : lane.item?.status === "done" ? page.successColor : Theme.palette.color("accent", "#a78bfa")
                    Accessible.role: Accessible.Graphic
                    Accessible.name: lane.item ? qsTr("Milestone %1 on %2").arg(lane.item.title).arg(lane.item.due ?? "") : ""

                    MouseArea {
                        property real from: 0
                        property bool moved: false

                        anchors.fill: parent
                        anchors.margins: -4
                        preventStealing: true
                        onPressed: mouse => {
                            from = mapToItem(null, mouse.x, 0).x;
                            moved = false;
                        }
                        onPositionChanged: mouse => {
                            const dx = mapToItem(null, mouse.x, 0).x - from;
                            if (Math.abs(dx) > 4)
                                moved = true;
                            lane.shift = moved ? Math.round(dx / gantt.dayWidth) : 0;
                        }
                        onReleased: {
                            if (moved && lane.shift !== 0)
                                page.reschedule(lane.item, lane.shift, 0);
                            else if (!moved)
                                page.select(lane.item);
                            lane.shift = 0;
                        }
                        onCanceled: lane.shift = 0
                    }
                }

                Text {
                    visible: lane.bar !== null
                    x: (lane.item?.kind === "milestone" ? (lane.bar?.end ?? 0) + 4 : taskBar.x + taskBar.width + 6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: (lane.item?.title ?? "") + (lane.item?.owner ? "  · " + lane.item.owner : "")
                    color: page.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }

                // The row's name, pinned while the timeline scrolls.
                Rectangle {
                    id: label

                    objectName: lane.item ? "plannerTask:" + lane.item.title : "plannerGroup:" + (lane.modelData.label ?? "")
                    x: gantt.contentX
                    width: page.labelWidth
                    height: parent.height
                    color: lane.picked ? Theme.palette.color("sidebarRowSelected", "#27272a") : labelMouse.containsMouse ? Theme.palette.color("sidebarRowHover", "#1f1f23") : page.surface
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.palette.color("focus", "#3b82f6")
                    activeFocusOnTab: true
                    Accessible.role: Accessible.ListItem
                    Accessible.name: labelText.text
                    Accessible.onPressAction: page.press(lane.modelData)
                    Keys.onPressed: event => page.rowKey(event, lane.modelData)
                    Component.onCompleted: page.takeKeys(label, lane.modelData.key)

                    Rectangle {
                        anchors.right: parent.right
                        width: 1
                        height: parent.height
                        color: page.border
                    }

                    Text {
                        id: chevron

                        x: 8 + lane.modelData.depth * 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        visible: lane.modelData.children
                        text: page.collapsed[lane.modelData.key] ? "▸" : "▾"
                        color: page.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }

                    Text {
                        id: labelText

                        x: chevron.x + 14
                        width: parent.width - x - 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: lane.item ? lane.item.title : (lane.modelData.label ?? "") + "  " + (lane.modelData.count ?? "")
                        color: lane.item ? page.foreground : page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: lane.item ? (lane.item.kind === "milestone" ? Font.DemiBold : Font.Normal) : Font.DemiBold
                    }

                    MouseArea {
                        id: labelMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            label.forceActiveFocus(Qt.MouseFocusReason);
                            if (lane.modelData.children && (lane.item === null || mouse.x < chevron.x + 16))
                                page.collapse(lane.modelData.key);
                            else
                                page.select(lane.item);
                        }
                    }
                }
            }
        }
    }

    // The board: a column per state, or per owner, label or project; a card dragged
    // to another column is changed to it.
    Component {
        id: boardView

        Flickable {
            id: board

            readonly property string groupBy: page.working?.groupBy ?? "status"
            readonly property var columns: {
                const view = page.working;
                if (view === null)
                    return [];
                const sorted = page.shown.slice().sort((a, b) => page.compare(a, b, view.sortBy));
                if (groupBy !== "status" && groupBy !== "none") {
                    const groups = new Map();
                    for (const item of sorted) {
                        for (const group of page.groupsOf(item, groupBy)) {
                            if (!groups.has(group.key))
                                groups.set(group.key, { value: group.key, label: group.label, rank: group.rank, items: [] });
                            groups.get(group.key).items.push(item);
                        }
                    }
                    return Array.from(groups.values()).sort((a, b) => a.rank - b.rank || a.label.localeCompare(b.label));
                }
                // Dropped work has a column whenever the filter lets it through.
                const statuses = view.filter.statuses.length === 0 || view.filter.statuses.includes("dropped") ? page.statuses : page.statuses.slice(0, 4);
                return statuses.map(status => ({ value: status, label: page.statusLabel(status), items: sorted.filter(item => item.status === status) }));
            }
            // The card being dragged, its column, and where the pointer is.
            property var dragged: null
            property var draggedFrom: null
            property point pointer

            // Changes `item` from column `from` to column `to`.
            function drop(item, from, to) {
                if (to === null || from === null || to.value === from.value)
                    return;
                if (groupBy === "owner")
                    page.update(item, { owner: to.value || null });
                else if (groupBy === "project")
                    page.update(item, { projectId: to.value || null });
                else if (groupBy === "label")
                    page.update(item, { labels: (item.labels ?? []).filter(label => label !== from.value).concat(to.value && !(item.labels ?? []).includes(to.value) ? [to.value] : []) });
                else if (groupBy === "parent")
                    page.update(item, { parent: to.value || null });
                else if (groupBy === "milestone") {
                    // A milestone is its own column; a task stops holding up one and holds up the other.
                    if (item.kind === "milestone")
                        return;
                    page.ask("moveToMilestone", { id: item.id, from: from.value || null, to: to.value || null }, item.environment);
                } else
                    page.update(item, { status: to.value });
            }

            function columnAt(scene) {
                for (let i = 0; i < lanes.count; ++i) {
                    const column = lanes.itemAt(i);
                    const local = column.mapFromItem(null, scene.x, scene.y);
                    if (local.x >= 0 && local.x < column.width && local.y >= 0 && local.y < column.height)
                        return columns[i];
                }
                return null;
            }

            objectName: "plannerBoard"
            clip: true
            contentWidth: columnsRow.implicitWidth + 32
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.horizontal: ScrollBar {}

            Row {
                id: columnsRow

                x: 16
                y: 12
                height: board.height - 24
                spacing: 12

                Repeater {
                    id: lanes

                    model: board.columns

                    delegate: Rectangle {
                        id: column

                        required property var modelData

                        objectName: "plannerBoardColumn:" + modelData.label
                        width: 260
                        height: columnsRow.height
                        radius: Math.min(Theme.radius, 10)
                        color: board.dragged !== null && board.columnAt(board.pointer) === modelData ? Theme.palette.color("accentSurface", "#27272a") : page.raised
                        border.color: page.border

                        Text {
                            id: columnTitle

                            x: 12
                            y: 10
                            text: column.modelData.label + "  " + column.modelData.items.length
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.DemiBold
                        }

                        ListView {
                            anchors.fill: parent
                            anchors.topMargin: 36
                            anchors.margins: 8
                            clip: true
                            spacing: 6
                            model: column.modelData.items
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: card

                                required property var modelData

                                objectName: "plannerCard:" + modelData.title
                                width: ListView.view.width
                                implicitHeight: cardColumn.implicitHeight + 16
                                radius: Math.min(Theme.radius, 8)
                                color: modelData.key === page.selectedKey ? Theme.palette.color("sidebarRowSelected", "#27272a") : page.surface
                                border.color: activeFocus ? Theme.palette.color("focus", "#3b82f6") : modelData.late ? page.warningColor : page.border
                                opacity: board.dragged?.key === modelData.key ? 0.4 : 1
                                activeFocusOnTab: true
                                Accessible.role: Accessible.ListItem
                                Accessible.name: modelData.title
                                Accessible.onPressAction: page.select(modelData)
                                Keys.onPressed: event => {
                                    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space)
                                        return;
                                    page.select(card.modelData);
                                    event.accepted = true;
                                }

                                ColumnLayout {
                                    id: cardColumn

                                    x: 10
                                    y: 8
                                    width: card.width - 20
                                    spacing: 4

                                    Text {
                                        Layout.fillWidth: true
                                        text: (card.modelData.kind === "milestone" ? "◆ " : "") + card.modelData.title
                                        color: page.foreground
                                        wrapMode: Text.Wrap
                                        font.pixelSize: Math.round(13 * Theme.fontScale)
                                    }

                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        Repeater {
                                            model: (page.working?.fields ?? []).filter(field => String(page.fieldText(card.modelData, field)).length > 0 && !(board.groupBy === "status" && field === "status"))

                                            delegate: Text {
                                                required property string modelData

                                                text: page.fieldText(card.modelData, modelData)
                                                color: modelData === "due" && card.modelData.late ? page.warningColor : page.muted
                                                font.pixelSize: Math.round(11 * Theme.fontScale)
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    property point from

                                    anchors.fill: parent
                                    preventStealing: true
                                    cursorShape: board.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                    onPressed: mouse => from = mapToItem(null, mouse.x, mouse.y)
                                    onPositionChanged: mouse => {
                                        const scene = mapToItem(null, mouse.x, mouse.y);
                                        if (board.dragged === null && Math.abs(scene.x - from.x) + Math.abs(scene.y - from.y) > 6) {
                                            board.dragged = card.modelData;
                                            board.draggedFrom = column.modelData;
                                        }
                                        board.pointer = scene;
                                    }
                                    onReleased: mouse => {
                                        if (board.dragged !== null)
                                            board.drop(board.dragged, board.draggedFrom, board.columnAt(mapToItem(null, mouse.x, mouse.y)));
                                        else
                                            page.select(card.modelData);
                                        board.dragged = null;
                                        board.draggedFrom = null;
                                    }
                                    onCanceled: {
                                        board.dragged = null;
                                        board.draggedFrom = null;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // The card under the pointer while it is dragged.
            Rectangle {
                readonly property point at: board.mapFromItem(null, board.pointer.x, board.pointer.y)

                parent: board
                visible: board.dragged !== null
                x: at.x - 20
                y: at.y - 14
                z: 10
                width: 220
                height: 30
                radius: Math.min(Theme.radius, 8)
                color: page.surface
                border.color: Theme.palette.color("focus", "#3b82f6")

                Text {
                    x: 10
                    width: parent.width - 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: board.dragged?.title ?? ""
                    color: page.foreground
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }
    }

    // The list: a row per task with the view's fields, sorted by a column's header.
    Component {
        id: listView

        ListView {
            id: list

            readonly property var fields: page.working?.fields ?? []
            readonly property real cellWidth: 120
            readonly property real titleWidth: Math.max(220, width - fields.length * cellWidth - 24)
            // Every column the view picks, wider than the list when it has many.
            readonly property real rowWidth: titleWidth + fields.length * cellWidth + 24

            objectName: "plannerList"
            clip: true
            model: page.rows
            contentWidth: rowWidth
            flickableDirection: Flickable.AutoFlickIfNeeded
            boundsBehavior: Flickable.StopAtBounds
            headerPositioning: ListView.OverlayHeader

            ScrollBar.vertical: ScrollBar {}
            ScrollBar.horizontal: ScrollBar { objectName: "plannerListScroll" }

            header: Rectangle {
                z: 5
                width: list.rowWidth
                height: 30
                color: page.surface

                Row {
                    x: 12
                    height: parent.height

                    Repeater {
                        model: ["title"].concat(list.fields)

                        delegate: Item {
                            id: heading

                            required property string modelData
                            readonly property string sorts: modelData === "owner" || modelData === "labels" || modelData === "project" || modelData === "links" ? "" : modelData

                            objectName: "plannerColumn:" + modelData
                            width: modelData === "title" ? list.titleWidth : list.cellWidth
                            height: parent.height

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.fieldLabel(heading.modelData) + (page.working?.sortBy === heading.sorts ? " ↓" : "")
                                color: page.muted
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                                font.weight: Font.Medium
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: heading.sorts.length > 0
                                cursorShape: Qt.PointingHandCursor
                                onClicked: page.edit({ sortBy: page.working.sortBy === heading.sorts ? "manual" : heading.sorts })
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.border
                }
            }

            delegate: Rectangle {
                id: row

                required property var modelData
                readonly property var item: modelData.item ?? null

                objectName: item ? "plannerRow:" + item.title : "plannerGroup:" + (modelData.label ?? "")
                width: list.rowWidth
                height: page.rowHeight
                color: item !== null && item.key === page.selectedKey ? Theme.palette.color("sidebarRowSelected", "#27272a") : rowMouse.containsMouse ? Theme.palette.color("sidebarRowHover", "#1f1f23") : "transparent"
                border.width: activeFocus ? 1 : 0
                border.color: Theme.palette.color("focus", "#3b82f6")
                activeFocusOnTab: true
                Accessible.role: Accessible.ListItem
                Accessible.name: rowTitle.text
                Accessible.onPressAction: page.press(row.modelData)
                Keys.onPressed: event => page.rowKey(event, row.modelData)
                Component.onCompleted: page.takeKeys(row, row.modelData.key)

                MouseArea {
                    id: rowMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        row.forceActiveFocus(Qt.MouseFocusReason);
                        page.press(row.modelData);
                    }
                }

                Row {
                    id: cells

                    x: 12
                    height: parent.height

                    Text {
                        id: rowTitle

                        width: list.titleWidth
                        anchors.verticalCenter: parent.verticalCenter
                        leftPadding: row.modelData.depth * 14
                        text: row.item ? (row.item.kind === "milestone" ? "◆ " : "") + row.item.title : (row.modelData.label ?? "") + "  " + (row.modelData.count ?? "")
                        color: row.item ? page.foreground : page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: row.item ? Font.Normal : Font.DemiBold
                    }

                    Repeater {
                        model: row.item ? list.fields : []

                        delegate: Text {
                            required property string modelData
                            readonly property var value: page.fieldValue(row.item, modelData)

                            objectName: "plannerCell:" + modelData
                            width: list.cellWidth
                            anchors.verticalCenter: cells.verticalCenter
                            rightPadding: 8
                            text: page.fieldText(row.item, modelData)
                            color: modelData === "status" ? page.statusColor(row.item.status) : modelData === "due" && row.item.late ? page.warningColor : page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                    }
                }
            }
        }
    }

    // Names a new, copied or renamed view.
    Popup {
        id: namer

        property string mode: "new"

        function ask(mode, name) {
            namer.mode = mode;
            nameField.text = mode === "copy" ? qsTr("%1 copy").arg(name) : name;
            namer.open();
            nameField.forceActiveFocus();
            nameField.selectAll();
        }

        anchors.centerIn: Overlay.overlay
        modal: true
        padding: 16
        width: 320
        background: Rectangle {
            radius: Math.min(Theme.radius, 10)
            color: page.surface
            border.color: page.border
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            Text {
                text: namer.mode === "rename" ? qsTr("Rename the view") : namer.mode === "copy" ? qsTr("Save as a new view") : qsTr("New view")
                color: page.foreground
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            ShellTextField {
                id: nameField

                objectName: "plannerViewName"
                Layout.fillWidth: true
                placeholderText: qsTr("Name")
                Accessible.name: qsTr("Name of the view")
                onAccepted: nameSave.clicked()
            }

            RowLayout {
                Layout.fillWidth: true

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: namer.close()
                }

                ShellButton {
                    id: nameSave

                    objectName: "plannerViewNameSave"
                    primary: true
                    enabled: nameField.text.trim().length > 0
                    text: qsTr("Save")
                    onClicked: {
                        page.nameView(namer.mode, nameField.text.trim());
                        namer.close();
                    }
                }
            }
        }
    }

    // Posts how the plan is going, kept in its history and sent to Slack when set up.
    Popup {
        id: poster

        property string health: "on-track"

        anchors.centerIn: Overlay.overlay
        modal: true
        padding: 16
        width: 380
        onOpened: {
            poster.health = page.latest?.health ?? "on-track";
            updateText.text = "";
            updateText.forceActiveFocus();
        }
        background: Rectangle {
            radius: Math.min(Theme.radius, 10)
            color: page.surface
            border.color: page.border
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            Text {
                text: qsTr("Post a status update")
                color: page.foreground
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Row {
                spacing: 6

                Repeater {
                    model: ["on-track", "at-risk", "off-track"]

                    delegate: ShellButton {
                        required property string modelData

                        objectName: "plannerUpdateHealth:" + modelData
                        subtle: poster.health !== modelData
                        text: page.healthLabel(modelData)
                        onClicked: poster.health = modelData
                    }
                }
            }

            TextArea {
                id: updateText

                objectName: "plannerUpdateText"
                Layout.fillWidth: true
                Layout.preferredHeight: 100
                placeholderText: qsTr("How the plan is going")
                wrapMode: TextEdit.Wrap
                color: page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                background: Rectangle {
                    radius: Math.min(Theme.radius, 8)
                    color: Theme.palette.color("input", "#18181b")
                    border.color: page.border
                }
            }

            RowLayout {
                Layout.fillWidth: true

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: poster.close()
                }

                ShellButton {
                    objectName: "plannerUpdatePost"
                    primary: true
                    enabled: updateText.text.trim().length > 0 && page.busy === 0
                    text: qsTr("Post")
                    onClicked: page.ask("postUpdate", { health: poster.health, text: updateText.text.trim() }, page.environment, (result, error) => {
                        if (!error)
                            poster.close();
                    })
                }
            }
        }
    }
}
