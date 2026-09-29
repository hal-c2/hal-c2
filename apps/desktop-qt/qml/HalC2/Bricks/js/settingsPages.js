.pragma library
.import "settingsRows.js" as Rows

// The settings sections, in the page's order (apps/web SettingsSidebarNav).
// A section with a `brick` is a native page, loaded from <brick>.qml in this
// module; one without is still the embedded page's, which the shell falls
// back to. Moving a section to QML is giving its line a brick.
//
//   action     dispatched instead of settings.navigate (the page never shows it)
//   requires   shell state the section needs before it is listed
//   keywords   what the native search matches, beside the label
//   rows       the page's settingsRows.js rows, each found by its title and description
//   settings   other settings on the page the search finds: {title, targetId, keywords}
var sections = [
    { to: "/settings/general", label: "General", brick: "GeneralSettings", rows: Rows.general,
      keywords: "project grouping auto-resume snooze limited threads auto-settle merged inactive notifications time format response streaming whitespace diff layout proactive panels skills slash rich text composer collapse send shortcut follow-up provider update checks continue restarts origin worktree add project unpin archive delete confirmation quit text generation model legacy plan context window sidebar" },
    { to: "/settings/appearance", label: "Appearance", brick: "AppearanceSettings", rows: Rows.appearance,
      settings: [{ title: "Theme", targetId: "themes", keywords: "theme themes light dark system color scheme mode" }],
      keywords: "appearance theme themes light dark system color scheme contrast glass opacity environment identification diff colors composer context panel animations font size family smoothing word wrap custom editor" },
    { to: "/settings/projects", label: "Project" },
    { to: "/settings/keybindings", label: "Keybindings", brick: "KeybindingsSettings", action: "keybindings.open",
      detail: "Shortcuts and when they apply", keywords: "keybindings shortcuts keys hotkeys conditions when recorder" },
    { to: "/settings/snap-shot", label: "SnapShots" },
    { to: "/settings/providers", label: "Providers", brick: "ProvidersSettings", requires: "providerSettings",
      detail: "Install, sign-in, versions and models",
      keywords: "providers provider codex claude cursor grok opencode antigravity acp agents sign in sign out login logout account email enable disable update version models refresh" },
    { to: "/settings/integrations", label: "Integrations" },
    { to: "/settings/scheduled-tasks", label: "Scheduled Tasks" },
    { to: "/settings/source-control", label: "Source Control" },
    { to: "/settings/storage", label: "Storage" },
    { to: "/settings/connections", label: "Connections", brick: "ConnectionsSettings", action: "connections.open",
      requires: "connections", detail: "Environments, pairing links and clients",
      keywords: "connections environments pairing link code clients revoke access remote" },
    { to: "/settings/archived", label: "Archive" },
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

// The native brick for a section, or "" when the page renders it.
function brickFor(section) {
    var found = find(section);
    return found !== null && found.brick ? found.brick : "";
}

// The navigation rows: native sections always (once their state is there),
// the page's only while the page lists them. `pageSections` is the page's
// `settings.sections`, `state` the shell's state.
function navRows(pageSections, state) {
    var listed = {};
    for (var i = 0; i < pageSections.length; ++i) listed[pageSections[i].to] = true;
    return sections.filter(function (section) {
        if (section.requires) return state[section.requires] !== undefined && state[section.requires] !== null;
        return section.brick ? true : listed[section.to] === true;
    });
}

// The page's search results in the sections it still renders: a result in a
// native section would open that section at nothing.
function pageResults(results) {
    return results.filter(function (result) {
        return brickFor(result.to) === "";
    });
}

// What the native search finds for `query` (lower case): sections by label or
// keywords, and the settings on their pages, each {label, detail (its
// section), to, action, targetId (the setting's objectName on the page)}.
// Every word must match; titles that match come first.
function searchRows(query, state) {
    var words = query.split(/\s+/).filter(function (word) { return word.length > 0; });
    var matches = function (text) {
        return words.every(function (word) { return text.indexOf(word) >= 0; });
    };
    var titled = [];
    var others = [];
    var add = function (row, title) {
        (matches(title.toLowerCase()) ? titled : others).push(row);
    };
    navRows([], state).forEach(function (section) {
        var text = (section.label + " " + (section.keywords || "")).toLowerCase();
        if (matches(text)) add(section, section.label);
        // Rows this platform does not show are not found.
        var settings = Rows.visible(section.rows || [], Qt.platform.os).filter(function (row) { return row.key !== undefined; }).map(function (row) {
            return { title: row.title, targetId: "settingsRow:" + row.key, keywords: row.description || "" };
        }).concat(section.settings || []);
        settings.forEach(function (setting) {
            var haystack = (setting.title + " " + setting.keywords).toLowerCase();
            if (!matches(haystack)) return;
            add({ label: setting.title, detail: section.label, to: section.to, targetId: setting.targetId }, setting.title);
        });
    });
    return titled.concat(others);
}
