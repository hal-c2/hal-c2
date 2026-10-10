.pragma library

// The rows of the native General and Appearance pages, with their titles
// and descriptions. A row's
// `key` is a Settings row key (SettingsController rows()): Settings knows its
// store and default. `descriptions` words a row by its value. Kinds: switch, select (`options`), number (`min`, `max`,
// `step`, `unit`), text (`placeholder`).
//
// Rows that need logic beyond reading and writing the key:
// A section with `folded` starts closed: its rows are listed once it is opened.
//
// Rows of the MC's follow the settings scope (Settings.mixed, Settings.disabledReason):
//   component         a row of its own drawing (`id` names it): textGeneration, backgroundActivity
//   requires          a capability every selected environment must have for the row to be listed
//   needs             one they must have for it to be changed; `unsupported` says so otherwise
//   mixedDescription  the description while the selected environments disagree
//
//   grouping   a switch over sidebarProjectGroupingMode ("separate" is off)
//   settleDays a switch plus a number: null days is off

function option(value, label) {
    return { value: value, label: label };
}

var general = [
    { section: "Organization" },
    { key: "sidebarProjectGroupingMode", kind: "grouping", title: "Project grouping",
      description: "Combine matching repositories across environments." },
    { key: "autoResumeLimitedThreads", kind: "switch", title: "Auto-resume limited threads",
      description: "Resume usage-limit stops at the reported reset time. Each thread can cancel its scheduled continuation." },
    { key: "snoozeLimitedThreads", kind: "switch", title: "Snooze limited threads",
      description: "Snooze usage-limit stops until the reported reset time. Combine with auto-resume to continue when they wake." },
    { key: "sidebarAutoSettleOnMerge", kind: "switch", title: "Auto-settle merged threads", requires: "threadAutoSettlement",
      description: "Settle a thread when its pull request merges. Closed pull requests still settle automatically." },
    { key: "sidebarAutoSettleAfterDays", kind: "settleDays", title: "Auto-settle inactive threads", requires: "threadAutoSettlement",
      description: "Sidebar threads with no activity for this long settle automatically.",
      daysTitle: "Days of inactivity before auto-settle",
      daysDescription: "Any new activity un-settles a thread automatically.", min: 1, max: 90 },

    { section: "Behavior" },
    { key: "notificationMode", kind: "select", title: "Thread notifications",
      description: "System alerts when a thread finishes, fails, or needs input or approval. Applies to this device while HAL-C2 is open.",
      options: [option("off", "Off"), option("notifications", "Notifications only"), option("sound", "Sound only"),
                option("notifications-and-sound", "Notifications with sound")] },
    { key: "inAppNotificationsEnabled", kind: "switch", title: "In-app notifications",
      description: "Show a toast when another thread finishes, fails, or needs input or approval while this app has focus." },
    { key: "timestampFormat", kind: "select", title: "Time format",
      description: "System default follows your system's clock and region settings.",
      options: [option("locale", "System default"), option("12-hour", "12-hour"), option("24-hour", "24-hour")] },
    { key: "responseStreamingMode", kind: "select", title: "Response streaming",
      mixedDescription: "The selected targets use different streaming modes.",
      descriptions: { turn: "Text appears once the agent finishes its turn.",
                      paragraph: "Each paragraph or code block appears as soon as it is complete." },
      options: [option("paragraph", "Show finished paragraphs"), option("turn", "Wait for the full response")] },
    { key: "diffIgnoreWhitespace", kind: "switch", title: "Hide whitespace changes",
      description: "Set whether the diff panel ignores whitespace-only edits by default." },
    { key: "diffFilesCollapsed", kind: "select", title: "Default diff file state",
      description: "Start with files expanded or collapsed when opening diffs or a pull request's Code tab.",
      options: [option(true, "Collapsed"), option(false, "Expanded")] },
    { key: "diffLayout", kind: "select", title: "Diff layout",
      description: "Show diffs stacked or side by side. The toggle in the diff toolbar changes this too.",
      options: [option("stacked", "Stacked"), option("split", "Split")] },
    { key: "proactivePanelsEnabled", kind: "switch", title: "Proactive panels",
      description: "Open linked pull requests first. Otherwise, open the working tree diff for changes to at least 3 files or 50 lines." },
    { key: "showSkillsInSlashMenu", kind: "switch", title: "Show skills in slash menu",
      description: "Also include skills in the / command menu. Skills always appear when you type $." },
    { key: "composerRichTextEnabled", kind: "switch", title: "Rich text composer",
      description: "Show formatted Markdown as you type." },
    { key: "composerCollapseOnScroll", kind: "switch", title: "Collapse composer on scroll",
      description: "Rest the composer of an existing thread into a single line when you scroll the conversation. Focus the composer or start typing to expand it again." },
    { key: "composerVimKeys", kind: "switch", title: "Vim keys in the composer",
      description: "Escape leaves insert mode; h, j, k, l, w, b, 0, $, x and u move and edit, and i, a, I and A insert again." },
    { key: "sendShortcut", kind: "select", title: "Send shortcut",
      description: "Choose when Enter sends a prompt or inserts a new line",
      options: [option("enter", "Enter"), option("mod-enter-multiline", "Ctrl + Enter for multiline prompts"),
                option("mod-enter", "Ctrl + Enter always")] },
    { key: "followUpBehavior", kind: "select", title: "Follow-up behavior",
      description: "Queue follow-ups while the agent runs or steer the current run. Press Ctrl + Enter to do the opposite for one message.",
      options: [option("queue", "Queue"), option("steer", "Steer")] },
    { key: "enableProviderUpdateChecks", kind: "switch", title: "Provider update checks",
      description: "Check installed provider CLIs for newer available versions." },
    { key: "continueThreadsAfterServerUpdate", kind: "switch", title: "Continue threads after restarts",
      needs: "threadRestartContinuation", unsupported: "All selected connected environments must support restart continuation.",
      description: "Automatically resume interrupted threads after an update, crash, or machine restart on the selected environments. Update older servers first." },

    { id: "background-activity", component: "backgroundActivity", title: "Background activity",
      description: "Gates background work such as Git refreshes and provider health probes on the selected environments. Advanced sets its own intervals." },

    { section: "Projects & threads" },
    { key: "newWorktreesStartFromOrigin", kind: "switch", title: "Start from origin",
      description: "Creates the worktree from the latest matching branch on origin instead of your local branch." },
    { key: "addProjectBaseDirectory", kind: "text", title: "Add project starts in",
      description: "Leave empty to use \"~/\" when the Add Project browser opens.", placeholder: "~/" },

    { section: "Confirmations" },
    { key: "confirmThreadUnpin", kind: "switch", title: "Unpin confirmation",
      description: "Ask before unpinning a thread from the pinned section." },
    { key: "confirmThreadArchive", kind: "switch", title: "Archive confirmation",
      description: "Require a second click on the inline archive action before a thread is archived." },
    { key: "confirmThreadDelete", kind: "switch", title: "Delete confirmation",
      description: "Ask before deleting a thread and its chat history." },
    { key: "confirmQuit", kind: "select", title: "Quit shortcut",
      description: "Hold mode also quits on two quick presses.",
      options: [option("direct", "Direct"), option("hold", "Hold"), option("double-click", "Double press")] },

    { section: "Text generation" },
    { id: "text-generation-model", component: "textGeneration", title: "Text generation model",
      description: "Used for thread titles and other generated text on connected devices with this provider. Source control can override it." },

    { section: "Diagnostics" },
    { id: "diagnostics", link: "/settings/diagnostics", button: "View diagnostics", title: "Diagnostics",
      description: "Inspect processes, resource use, and logs on this environment." },
    { id: "open-source-licenses", link: "/settings/open-source-licenses", button: "View licenses", title: "Open source licenses",
      description: "Notices for dependencies, assets, and optional tools used by HAL-C2." },
    { section: "Legacy features", folded: true },
    { key: "planModeEnabled", kind: "switch", title: "Plan mode",
      description: "Restore Build/Plan, /plan, /default, and Shift+Tab. Off uses build mode." },
    { key: "contextWindowMeterEnabled", kind: "switch", title: "Context window indicator",
      description: "Shows context window usage as a circular indicator in the composer." },
    { key: "legacySidebarEnabled", kind: "switch", title: "Sidebar",
      description: "Restore per-project thread trees instead of the default flat sidebar." },
];

var appearance = [
    { section: "Interface" },
    { key: "appearanceContrast", kind: "number", title: "Contrast", min: 50, max: 200, step: 10, unit: "%",
      description: "Adjust the contrast of colors and borders across the interface." },
    { key: "glassOpacity", kind: "number", title: "Glass opacity", min: 40, max: 100, step: 5, unit: "%",
      description: "Higher values make menus, dialogs, and the composer more solid." },
    { key: "environmentIdentificationMode", kind: "select", title: "Environment identification",
      description: "Choose how Dev and Nightly environments are identified.",
      options: [option("artwork", "Artwork"), option("pill", "Version pill"), option("none", "None")] },
    { key: "diffColorScheme", kind: "select", title: "Diff colors",
      description: "Choose colors for additions and deletions, including change counts.",
      options: [option("red-green", "Red & green"), option("blue-orange", "Blue & orange")] },
    { key: "persistComposerContextStrip", kind: "switch", title: "Composer context",
      description: "Keep branch and worktree controls below the composer after a thread starts." },
    { key: "wordWrap", kind: "switch", title: "Word wrap",
      description: "Wrap long lines in code blocks, tables, diffs, and file previews by default." },
    { key: "fontSmoothing", kind: "switch", title: "Font smoothing", macOnly: true,
      description: "Use thinner grayscale text smoothing instead of the macOS default." },

    { section: "Fonts" },
    { key: "fontSizeInterface", kind: "number", title: "Interface font size", min: 12, max: 20, step: 1, unit: "px",
      description: "Everything outside code blocks and the terminal." },
    { key: "fontFamilySans", kind: "text", title: "Interface font", placeholder: "System default",
      description: "Everything outside code blocks and the terminal." },
    { key: "fontSizePrompt", kind: "number", title: "Prompt font size", min: 12, max: 20, step: 1, unit: "px",
      description: "Only the box you write prompts in. Mono works well here." },
    { key: "fontFamilyComposer", kind: "text", title: "Prompt font", placeholder: "Same as interface",
      description: "Only the box you write prompts in. Mono works well here." },
    { key: "fontSizeCode", kind: "number", title: "Code font size", min: 10, max: 18, step: 1, unit: "px",
      description: "Code blocks, diffs, and file previews." },
    { key: "fontFamilyCode", kind: "text", title: "Code font", placeholder: "System monospace",
      description: "Code blocks, diffs, and file previews." },
    { key: "fontSizeTerminal", kind: "number", title: "Terminal font size", min: 8, max: 20, step: 1, unit: "px",
      description: "Terminal output, independent from code blocks and diffs." },
    { key: "fontFamilyTerminal", kind: "text", title: "Terminal font", placeholder: "Same as code",
      description: "Terminal output, independent from code blocks and diffs." },

    { section: "Motion" },
    { key: "panelAnimationDurationMs", kind: "number", title: "Panel animations", min: 0, max: 400, step: 50, unit: "ms",
      description: "Set how fast panels open and close." },
    { key: "reduceMotion", kind: "switch", title: "Reduce motion",
      description: "Open and close panels at once, whatever the animation speed." },
];

function describe(row, value) {
    return row.descriptions ? row.descriptions[value] || "" : row.description || "";
}

// Rows this platform shows.
function visible(rows, platform) {
    return rows.filter(function (row) {
        return !row.macOnly || platform === "osx";
    });
}

// The rows a page lists: a folded section's only once it is open (`open`, by
// section title).
function listed(rows, platform, open) {
    var hidden = false;
    return visible(rows, platform).filter(function (row) {
        if (row.section === undefined) return !hidden;
        hidden = row.folded === true && !open[row.section];
        return true;
    });
}

// The folded section holding the row named `target` ("settingsRow:<key>"), or "".
function foldOf(rows, target) {
    var fold = "";
    for (var i = 0; i < rows.length; ++i) {
        var row = rows[i];
        if (row.section !== undefined) fold = row.folded === true ? row.section : "";
        else if ("settingsRow:" + (row.key ?? row.id) === target) return fold;
    }
    return "";
}

// The General and Appearance rows restoring defaults resets: each one off its
// default (`isDefault(key)`), once, as {key, title}.
function changed(isDefault, platform) {
    var seen = {};
    return visible(general.concat(appearance), platform).filter(function (row) {
        if (row.key === undefined || seen[row.key] || isDefault(row.key)) return false;
        seen[row.key] = true;
        return true;
    });
}

// Project grouping is a switch: off is "separate", and turning it back on
// restores the mode used before (`last`), else the default.
function groupingOn(mode) {
    return mode !== "separate";
}

function groupingFromToggle(on, last) {
    return on ? (last && last !== "separate" ? last : "repository") : "separate";
}

// Inactive settling: null days is off; turning it on starts from the default.
function settleOn(days) {
    return days !== null && days !== undefined;
}

function settleFromToggle(on, fallback) {
    return on ? fallback : null;
}

// Keeps a typed number within the row's range; NaN keeps `current`.
function clamp(row, value, current) {
    var number = Number(value);
    if (isNaN(number)) return current;
    return Math.min(row.max, Math.max(row.min, Math.round(number)));
}

// The index of `value` among a select row's options, -1 when none.
function optionIndex(row, value) {
    for (var i = 0; i < row.options.length; ++i) {
        if (row.options[i].value === value) return i;
    }
    return -1;
}
