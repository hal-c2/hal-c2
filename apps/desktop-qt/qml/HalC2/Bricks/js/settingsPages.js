.pragma library

// The settings sections, in the page's order (apps/web SettingsSidebarNav).
// A section with a `brick` is a native page, loaded from <brick>.qml in this
// module; one without is still the embedded page's, which the shell falls
// back to. Moving a section to QML is giving its line a brick.
//
//   action     dispatched instead of settings.navigate (the page never shows it)
//   requires   shell state the section needs before it is listed
//   keywords   what the native search matches, beside the label
var sections = [
    { to: "/settings/general", label: "General", brick: "GeneralSettings",
      keywords: "project grouping auto-resume snooze limited threads auto-settle merged inactive notifications time format response streaming whitespace diff layout proactive panels skills slash rich text composer collapse send shortcut follow-up provider update checks continue restarts origin worktree add project unpin archive delete confirmation quit text generation model legacy plan context window sidebar" },
    { to: "/settings/appearance", label: "Appearance", brick: "AppearanceSettings",
      keywords: "appearance theme themes light dark system color scheme contrast glass opacity environment identification diff colors composer context panel animations font size family smoothing word wrap custom editor" },
    { to: "/settings/projects", label: "Project" },
    { to: "/settings/keybindings", label: "Keybindings", brick: "KeybindingsSettings", action: "keybindings.open",
      detail: "Shortcuts and when they apply", keywords: "keybindings shortcuts keys hotkeys conditions when recorder" },
    { to: "/settings/snap-shot", label: "SnapShots" },
    { to: "/settings/providers", label: "Providers" },
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

// The native sections matching `query` (lower case) by label or keywords.
function searchRows(query, state) {
    return navRows([], state).filter(function (section) {
        return section.label.toLowerCase().indexOf(query) >= 0 || (section.keywords || "").indexOf(query) >= 0;
    });
}
