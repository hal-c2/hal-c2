.pragma library
.import "settingsRows.js" as Rows

// The settings sections, in order.
// Each section's page is <brick>.qml in this module.
//
//   action     dispatched instead of settings.navigate
//   prefix     the section is every route under `to` (one MC plugin's settings
//              at /settings/plugin/<environment>/<id>); not searched or offered
//   under      the section it opens from, which stays current; it is not listed itself
//   requires   shell state the section needs before it is listed
//   keywords   what the native search matches, beside the label
//   rows       the section's settingsRows.js rows, each found by its title, description
//              and keywords
//   settings   other settings on the page the search finds: {title, targetId, keywords,
//              requires (shell state the setting needs before it is found), connected
//              (found while an environment is connected), project (found while editing
//              a project), scope ("environment": set for all projects, not one), within
//              (what opening it shows while the setting itself is hidden)}
//   project    the section of the project being edited: listed first while a project
//              is, and as `others` {label, detail} while every project is
var sections = [
    { to: "/settings/general", label: "General", brick: "GeneralSettings", rows: Rows.general,
      keywords: "project grouping auto-resume snooze limited threads auto-settle merged inactive notifications time format response streaming whitespace diff layout proactive panels skills slash rich text composer collapse send shortcut follow-up provider update checks continue restarts origin worktree add project unpin archive delete confirmation quit text generation model legacy plan context window sidebar" },
    { to: "/settings/diagnostics", label: "Diagnostics", brick: "DiagnosticsSettings", under: "/settings/general",
      keywords: "diagnostics processes cpu memory kill signal sigint sigkill resource history traces spans failures logs folder" },
    { to: "/settings/open-source-licenses", label: "Open source licenses", brick: "OpenSourceLicenses", under: "/settings/general",
      keywords: "open source licenses licences notices third party attribution dependencies" },
    { to: "/settings/appearance", label: "Appearance", brick: "AppearanceSettings", rows: Rows.appearance,
      settings: [{ title: "Theme", targetId: "themes", keywords: "theme themes light dark system color scheme mode" }],
      keywords: "appearance theme themes light dark system color scheme contrast glass opacity environment identification diff colors composer context panel animations font size family smoothing custom editor" },
    { to: "/settings/projects", label: "Project", brick: "ProjectSettings", requires: "projectSettings",
      detail: "Name, icon, checkouts and how new threads start",
      project: { label: "New threads", detail: "How new threads start on the selected environments" },
      settings: [{ title: "Project overview", targetId: "identity", project: true, keywords: "name rename title icon emoji favicon checkouts remove" },
                 { title: "Default model", targetId: "model", keywords: "model provider new threads automatic" },
                 { title: "Project environment", targetId: "environment", keywords: "environment variables env dotenv .env mise direnv envrc mcp" },
                 { title: "Actions", targetId: "projectActions", keywords: "actions scripts commands setup dev test run hal-c2.json import" }],
      keywords: "project projects name rename title icon emoji favicon checkout checkouts remove delete default model permissions runtime mode workspace worktree submodules environment variables dotenv mise direnv new threads" },
    { to: "/settings/keybindings", label: "Keybindings", brick: "KeybindingsSettings", action: "keybindings.open",
      detail: "Shortcuts and when they apply", keywords: "keybindings shortcuts keys hotkeys conditions when recorder" },
    { to: "/settings/plugins", label: "Plugins", brick: "PluginsSettings", requires: "plugins",
      detail: "Add-ons for the sidebar, composer and status bar",
      keywords: "plugins plugin extensions add-ons addons installed disable enable remove load url unsigned errors failed slots" },
    { to: "/settings/plugin", label: "Plugin", brick: "PluginSettings", under: "/settings/plugins", prefix: true },
    { to: "/settings/snap-shot", label: "SnapShots", brick: "SnapShotSettings",
      detail: "Capture a window into your draft",
      // The capture options show while capture is on; until then a result opens at its switch.
      settings: [{ title: "Capture sound", targetId: "snapShot:sound", within: "snapShot:enabled", keywords: "sound audio play starts" },
                 { title: "Capture flash", targetId: "snapShot:flash", within: "snapShot:enabled", keywords: "flash cue captured window" },
                 { title: "Capture animations", targetId: "snapShot:animations", within: "snapShot:enabled", keywords: "animations animate draft" },
                 { title: "Include app text", targetId: "snapShot:accessibility", within: "snapShot:enabled", keywords: "accessibility text controls" }],
      keywords: "snapshot snapshots snap shot capture screenshot window shortcut sound flash animation portal accessibility" },
    { to: "/settings/providers", label: "Providers", brick: "ProvidersSettings", requires: "providerSettings",
      detail: "Install, sign-in, versions and models",
      settings: [{ title: "Provider health check interval", targetId: "healthInterval", connected: true, keywords: "health check probe background refresh interval seconds" },
                 { title: "Usage providers", targetId: "hubs", connected: true, keywords: "usage limits cliproxyapi cli proxy hub accounts" }],
      keywords: "providers provider codex claude cursor grok opencode antigravity pi muse acp agents sign in sign out login logout account email enable disable update version models refresh binary path executable install" },
    { to: "/settings/integrations", label: "Integrations", brick: "IntegrationsSettings", requires: "deviceSettings",
      detail: "Simulators, emulators, agent device access and Slack",
      keywords: "integrations devices device hub simulator emulator ios android xcode agent device access tools version update slack bot token socket mode manifest" },
    { to: "/settings/scheduled-tasks", label: "Scheduled Tasks", brick: "ScheduledTasksSettings", requires: "scheduledTasks",
      detail: "Prompts sent to a project on a timer",
      keywords: "scheduled tasks schedule cron timer recurring daily weekdays interval prompt run now pause resume automation" },
    { to: "/settings/source-control", label: "Source Control", brick: "SourceControlSettings", requires: "sourceControlSettings",
      detail: "Git, hosts, fetching and writing style",
      settings: [{ title: "Automatic Git fetch interval", targetId: "fetchInterval", scope: "environment", keywords: "git fetch background refresh remote branches interval" },
                 { title: "Writing style", targetId: "writingStyle", keywords: "commit messages pull request descriptions conventional commits" },
                 { title: "Follow change request templates", targetId: "templates", keywords: "pull request merge request template templates" }],
      keywords: "source control git jujutsu github gitlab forgejo azure bitbucket authenticated account fetch interval pull merge method squash rebase writing style conventional commits instructions templates writer model" },
    { to: "/settings/storage", label: "Storage", brick: "StorageSettings", requires: "storageSettings",
      detail: "Worktree, artifact and log cleanup",
      keywords: "storage cleanup disk worktrees delete inactive merged unchanged browser artifacts captures rotated logs retention days temporary files tmp tmpdir folder" },
    { to: "/settings/connections", label: "Connections", brick: "ConnectionsSettings", action: "connections.open",
      requires: "connections", detail: "Pairing links and clients",
      settings: [{ title: "Load balancing", targetId: "load-balancing", requires: "loadBalancing",
                   keywords: "automatic machine environment resources cpu memory capacity preference weight shared projects" }],
      keywords: "connections pairing link code clients revoke access remote" },
    // Only a client that receives its MC's pushes (apps/mobile-qt) publishes `notifications`.
    { to: "/settings/notifications", label: "Notifications", brick: "NotificationsSettings", requires: "notifications",
      detail: "Alerts, ongoing agent activity and quiet hours",
      keywords: "notifications notification alerts push unifiedpush ntfy distributor live activity ongoing card lock screen live update quiet hours do not disturb permission" },
    // Only a client that paired itself (apps/mobile-qt) publishes `pairing`.
    { to: "/settings/pairing", label: "Pairing", brick: "PairingSettings", requires: "pairing",
      detail: "The environment this device is paired with",
      keywords: "pairing paired environment machine address connection forget unpair sign out disconnect this device" },
    // Only a client that maintains its environments itself (apps/mobile-qt) publishes `maintenance`.
    { to: "/settings/maintenance", label: "Maintenance", brick: "MaintenanceSettings", requires: "maintenance",
      detail: "Environment and provider updates",
      keywords: "maintenance update updates upgrade version release channel server environment provider providers refresh codex claude" },
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
        if (sections[i].to === to || (sections[i].prefix && to.indexOf(sections[i].to + "/") === 0)) return sections[i];
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

function present(state, key) {
    return state[key] !== undefined && state[key] !== null;
}

function projectScope(state) {
    return (state.settingsScope?.kind ?? "all") === "project";
}

// The sections there are: the ones that need shell state once it is there.
// `state` is the shell's state. The project's section leads while a project
// is being edited, and goes by its `project` names while every project is.
function available(state) {
    var listed = [];
    sections.forEach(function (section) {
        if (section.prefix || (section.requires && !present(state, section.requires))) return;
        if (!section.project) listed.push(section);
        else if (projectScope(state)) listed.unshift(section);
        else listed.push(Object.assign({}, section, section.project));
    });
    return listed;
}

// The navigation rows: the sections there are, less those opened from another.
function navRows(state) {
    return available(state).filter(function (section) { return !section.under; });
}

// The settings a section's page holds, each {title, targetId (its objectName
// on the page), keywords, capability (one every selected environment must
// have for the row to show)}: its rows this platform shows, then its others.
function settingsOf(section, os) {
    return Rows.visible(section.rows || [], os).filter(function (row) { return row.key !== undefined || row.link !== undefined || row.component !== undefined; }).map(function (row) {
        return { title: row.title, targetId: "settingsRow:" + (row.key ?? row.id), keywords: (row.description || "") + " " + (row.keywords || ""),
                 capability: row.requires };
    }).concat(section.settings || []);
}

// The setting a section's page names `targetId`, or null.
function targetOf(section, targetId, os) {
    var found = find(section);
    if (found === null || !targetId) return null;
    return settingsOf(found, os).find(function (setting) { return setting.targetId === targetId; }) ?? null;
}

// What the command palette offers (PaletteModel.setSettingsSections): every
// section, and each setting on its page with its `targetId` and `detail` (its
// section's label).
function paletteEntries(os) {
    var entries = [];
    sections.filter(function (section) { return !section.prefix; }).forEach(function (section) {
        entries.push({ to: section.to, label: section.label, keywords: section.keywords || "", requires: section.requires || "" });
        settingsOf(section, os).forEach(function (setting) {
            entries.push({ to: section.to, label: setting.title, keywords: setting.keywords || "", requires: setting.requires || section.requires || "",
                           targetId: setting.targetId, detail: section.label });
        });
    });
    return entries;
}

// Search text as it is compared: lower case, without accents, its spaces
// single and trimmed.
function normalize(text) {
    return text.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
}

// How well a title matches `query`: the whole
// title, its start, anywhere in it, every word in it, the phrase in its other
// words, or only the words scattered.
function rank(title, query, words, others) {
    if (title === query) return 5;
    if (title.indexOf(query) === 0) return 4;
    if (title.indexOf(query) >= 0) return 3;
    if (words.every(function (word) { return title.indexOf(word) >= 0; })) return 2;
    return others.indexOf(query) >= 0 ? 1 : 0;
}

// Whether an environment of the settings scope's is connected.
function connected(state) {
    return (state.settingsScope?.environments ?? []).some(function (environment) { return environment.online; });
}

// What the native search finds for `query`: sections by label or keywords,
// the settings in their sections, and the keyboard commands, from `bindings`
// (Keybindings.bindings) and `commands` ([{command, label}], every command
// there is), each {label, detail (its section), to, action, targetId (the
// setting's objectName in its section)}. Every word must match. The best
// matching titles come first; of titles matching alike in different sections,
// the one the query covers more of, and within a section in page order; a
// section found only by its keywords after the settings in it; commands after
// every setting.
function searchRows(query, state, bindings, commands) {
    query = normalize(query);
    var words = query.split(" ").filter(function (word) { return word.length > 0; });
    var found = [];
    var add = function (row, title, others, kind, group) {
        title = normalize(title);
        others = normalize(others);
        var text = title + "\n" + others;
        if (!words.every(function (word) { return text.indexOf(word) >= 0; })) return;
        found.push({ row: row, rank: rank(title, query, words, others), kind: kind, group: group, length: title.length, index: found.length });
    };
    var isConnected = connected(state);
    var inProject = projectScope(state);
    available(state).forEach(function (section) {
        add(section, section.label, section.keywords || "", 0, section.to);
        // Rows this platform does not show are not found.
        settingsOf(section, Qt.platform.os).filter(function (setting) {
            return (!setting.requires || present(state, setting.requires)) && (!setting.connected || isConnected) && (!setting.project || inProject);
        }).forEach(function (setting) {
            add({ label: setting.title, detail: section.label, to: section.to, targetId: setting.targetId }, setting.title, setting.keywords || "", 0, section.to);
        });
    });
    // One result per command, found by its id and keys too. A command opens
    // Keybindings at its rows, or, with none, at a new one for it.
    var byCommand = {};
    (commands || []).forEach(function (entry) {
        byCommand[entry.command] = { label: entry.label, terms: [entry.command] };
    });
    (bindings || []).forEach(function (binding) {
        var command = byCommand[binding.command];
        if (command === undefined) command = byCommand[binding.command] = { label: binding.label, terms: [binding.command] };
        command.terms.push(binding.key);
        if (binding.defaultKey) command.terms.push(binding.defaultKey);
    });
    Object.keys(byCommand).sort(function (left, right) {
        return byCommand[left].label.localeCompare(byCommand[right].label);
    }).forEach(function (id) {
        add({ label: byCommand[id].label, detail: "Keybindings", to: "/settings/keybindings", targetId: "keybinding:" + id },
            byCommand[id].label, byCommand[id].terms.join(" "), 1, "");
    });
    // A section's closeness is its closest title among those matching alike.
    var closest = {};
    found.forEach(function (entry) {
        if (entry.rank < 3) return;
        var key = entry.group + "\n" + entry.rank;
        if (closest[key] === undefined || entry.length < closest[key]) closest[key] = entry.length;
    });
    var closeness = function (entry) {
        return entry.rank >= 3 && entry.group ? closest[entry.group + "\n" + entry.rank] : 0;
    };
    var keywordOnly = function (entry) {
        return entry.row.targetId === undefined && entry.kind === 0 && entry.rank < 3 ? 1 : 0;
    };
    return found.sort(function (left, right) {
        return (left.kind - right.kind) || (right.rank - left.rank) || (closeness(left) - closeness(right))
            || (keywordOnly(left) - keywordOnly(right)) || (left.index - right.index);
    }).map(function (entry) { return entry.row; });
}

// Where every settings page lays out: one centred column, at most `columnMaxWidth`
// wide, with `margin` on either side when the pane is narrower.
var columnMaxWidth = 720;

// Not clamped at 0: a pane not laid out yet gives a negative width, which the
// layouts skip, where 0 would wrap every label a letter a line for a frame.
function columnWidth(available, margin) {
    return Math.min(columnMaxWidth, available - 2 * margin);
}

function columnX(available, margin) {
    return Math.max(margin, Math.round((available - columnWidth(available, margin)) / 2));
}
