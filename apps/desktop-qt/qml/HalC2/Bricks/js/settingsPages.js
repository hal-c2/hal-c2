.pragma library
.import "settingsRows.js" as Rows

// The settings sections, in the web's order (apps/web SettingsSidebarNav).
// Each section's page is <brick>.qml in this module.
//
//   action     dispatched instead of settings.navigate
//   under      the section it opens from, which stays current; it is not listed itself
//   requires   shell state the section needs before it is listed
//   keywords   what the native search matches, beside the label
//   rows       the section's settingsRows.js rows, each found by its title and description
//   settings   other settings on the page the search finds: {title, targetId, keywords}
var sections = [
    { to: "/settings/general", label: "General", brick: "GeneralSettings", rows: Rows.general,
      keywords: "project grouping auto-resume snooze limited threads auto-settle merged inactive notifications time format response streaming whitespace diff layout proactive panels skills slash rich text composer collapse send shortcut follow-up provider update checks continue restarts origin worktree add project unpin archive delete confirmation quit text generation model legacy plan context window sidebar" },
    { to: "/settings/diagnostics", label: "Diagnostics", brick: "DiagnosticsSettings", under: "/settings/general",
      keywords: "diagnostics processes cpu memory kill signal sigint sigkill resource history traces spans failures logs folder" },
    { to: "/settings/open-source-licenses", label: "Open source licenses", brick: "OpenSourceLicenses", under: "/settings/general",
      keywords: "open source licenses licences notices third party attribution dependencies" },
    { to: "/settings/appearance", label: "Appearance", brick: "AppearanceSettings", rows: Rows.appearance,
      settings: [{ title: "Theme", targetId: "themes", keywords: "theme themes light dark system color scheme mode" }],
      keywords: "appearance theme themes light dark system color scheme contrast glass opacity environment identification diff colors composer context panel animations font size family smoothing word wrap custom editor" },
    { to: "/settings/projects", label: "Project", brick: "ProjectSettings", requires: "projectSettings",
      detail: "Name, icon, checkouts and how new threads start",
      settings: [{ title: "Default model", targetId: "model", keywords: "model provider new threads automatic" }],
      keywords: "project projects name rename title icon emoji favicon checkout checkouts remove delete default model permissions runtime mode workspace worktree submodules new threads" },
    { to: "/settings/keybindings", label: "Keybindings", brick: "KeybindingsSettings", action: "keybindings.open",
      detail: "Shortcuts and when they apply", keywords: "keybindings shortcuts keys hotkeys conditions when recorder" },
    { to: "/settings/snap-shot", label: "SnapShots", brick: "SnapShotSettings",
      detail: "Capture a window into your draft",
      keywords: "snapshot snapshots snap shot capture screenshot window shortcut sound flash animation portal accessibility" },
    { to: "/settings/providers", label: "Providers", brick: "ProvidersSettings", requires: "providerSettings",
      detail: "Install, sign-in, versions and models",
      keywords: "providers provider codex claude cursor grok opencode antigravity acp agents sign in sign out login logout account email enable disable update version models refresh" },
    { to: "/settings/integrations", label: "Integrations", brick: "IntegrationsSettings", requires: "deviceSettings",
      detail: "Simulators, emulators and agent device access",
      keywords: "integrations devices device hub simulator emulator ios android xcode agent device access tools version update" },
    { to: "/settings/scheduled-tasks", label: "Scheduled Tasks", brick: "ScheduledTasksSettings", requires: "scheduledTasks",
      detail: "Prompts sent to a project on a timer",
      keywords: "scheduled tasks schedule cron timer recurring daily weekdays interval prompt run now pause resume automation" },
    { to: "/settings/source-control", label: "Source Control", brick: "SourceControlSettings", requires: "sourceControlSettings",
      detail: "Git, hosts, fetching and writing style",
      keywords: "source control git jujutsu github gitlab forgejo azure bitbucket authenticated account fetch interval pull merge method squash rebase writing style conventional commits instructions templates writer model" },
    { to: "/settings/storage", label: "Storage", brick: "StorageSettings", requires: "storageSettings",
      detail: "Worktree, artifact and log cleanup",
      keywords: "storage cleanup disk worktrees delete inactive merged unchanged browser artifacts captures rotated logs retention days" },
    { to: "/settings/connections", label: "Connections", brick: "ConnectionsSettings", action: "connections.open",
      requires: "connections", detail: "Environments, pairing links and clients",
      keywords: "connections environments pairing link code clients revoke access remote" },
    { to: "/settings/archived", label: "Archive", brick: "ArchivedThreads", requires: "archivedThreads",
      detail: "Archived threads, unarchived or deleted", keywords: "archive archived threads unarchive restore delete" },
    { to: "/settings/cluster", label: "Cluster", brick: "ClusterSettings", action: "cluster.open", requires: "cluster",
      detail: "Machines, invites and joining", keywords: "cluster machines invite join remove tailscale" },
];

// The section a settings route shows: bare /settings opens General.
function resolve(section) {
    return !section || section === "/settings" ? "/settings/general" : section;
}

function find(section) {
    var to = resolve(section);
    for (var i = 0; i < sections.length; ++i) {
        if (sections[i].to === to) return sections[i];
    }
    return null;
}

// The section the navigation marks for `section`: the one it opens from, if any.
function current(section) {
    var found = find(section);
    return found !== null && found.under ? found.under : resolve(section);
}

// The brick that draws a section, or "" for one there is not.
function brickFor(section) {
    var found = find(section);
    return found !== null && found.brick ? found.brick : "";
}

// The sections there are: the ones that need shell state once it is there.
// `state` is the shell's state.
function available(state) {
    return sections.filter(function (section) {
        return !section.requires || (state[section.requires] !== undefined && state[section.requires] !== null);
    });
}

// The navigation rows: the sections there are, less those opened from another.
function navRows(state) {
    return available(state).filter(function (section) { return !section.under; });
}

// How well a title matches `query`, as the web ranks settings: the whole
// title, its start, anywhere in it, every word in it, the phrase in its other
// words, or only the words scattered.
function rank(title, query, words, others) {
    if (title === query) return 5;
    if (title.indexOf(query) === 0) return 4;
    if (title.indexOf(query) >= 0) return 3;
    if (words.every(function (word) { return title.indexOf(word) >= 0; })) return 2;
    return others.indexOf(query) >= 0 ? 1 : 0;
}

// What the native search finds for `query` (lower case): sections by label or
// keywords, the settings in their sections, and the commands in `bindings`
// (Keybindings.bindings), each {label, detail (its section), to, action,
// targetId (the setting's objectName in its section)}. Every word must match;
// the best matching titles come first, commands after every setting.
function searchRows(query, state, bindings) {
    query = query.trim().replace(/\s+/g, " ");
    var words = query.split(" ").filter(function (word) { return word.length > 0; });
    var found = [];
    var add = function (row, title, others, secondary) {
        title = title.toLowerCase();
        others = others.toLowerCase();
        var text = title + "\n" + others;
        if (!words.every(function (word) { return text.indexOf(word) >= 0; })) return;
        found.push({ row: row, rank: rank(title, query, words, others), secondary: secondary, index: found.length });
    };
    available(state).forEach(function (section) {
        add(section, section.label, section.keywords || "", false);
        // Rows this platform does not show are not found.
        var settings = Rows.visible(section.rows || [], Qt.platform.os).filter(function (row) { return row.key !== undefined || row.link !== undefined; }).map(function (row) {
            return { title: row.title, targetId: "settingsRow:" + (row.key ?? row.id), keywords: row.description || "" };
        }).concat(section.settings || []);
        settings.forEach(function (setting) {
            add({ label: setting.title, detail: section.label, to: section.to, targetId: setting.targetId }, setting.title, setting.keywords, false);
        });
    });
    // One result per command, found by its id and keys too, as the web's.
    var commands = {};
    (bindings || []).forEach(function (binding) {
        var command = commands[binding.command];
        if (command === undefined) {
            command = commands[binding.command] = { label: binding.label, terms: [binding.command] };
        }
        command.terms.push(binding.key);
        if (binding.defaultKey) command.terms.push(binding.defaultKey);
    });
    Object.keys(commands).sort(function (left, right) {
        return commands[left].label.localeCompare(commands[right].label);
    }).forEach(function (id) {
        add({ label: commands[id].label, detail: "Keybindings", to: "/settings/keybindings" }, commands[id].label, commands[id].terms.join(" "), true);
    });
    return found.sort(function (left, right) {
        return (left.secondary - right.secondary) || (right.rank - left.rank) || (left.index - right.index);
    }).map(function (entry) { return entry.row; });
}
