import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/providers-panel.feature and providers/provider-setup.feature:
// the Providers section draws what ProviderSettingsController publishes.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: settingsComponent
        ProvidersSettings {
            width: 880
            height: 680
        }
    }

    // The shell's body, which the page lives in: scaled by the zoom about its corner, so
    // a popup positioned from the page has its local offsets multiplied by the zoom.
    Component {
        id: zoomedBodyComponent
        Item {
            property real zoom: 1
            property real offsetX: 0
            property real offsetY: 0
            property alias page: inner
            width: root.width / zoom
            height: root.height / zoom
            scale: zoom
            transformOrigin: Item.TopLeft

            ProvidersSettings {
                id: inner
                x: offsetX
                y: offsetY
                width: 880
                height: 680
            }
        }
    }

    function provider(overrides) {
        return Object.assign({
            instanceId: "claudeAgent_work", driver: "claudeAgent", name: "Claude Work", version: "v2.1.0",
            enabled: true, installed: true, status: "ready", headline: "Authenticated", detail: "",
            email: "ada@example.com", models: [{ slug: "claude-opus", name: "Claude Opus" }],
            advisory: null, canUpdate: false, updating: false,
            account: { description: "Signed in.", canSignIn: true, signInLabel: "Change account", canCancel: false,
                       canSignOut: true, url: "", userCode: "", error: "" },
            editable: true, custom: true, resettable: false, pending: false, label: "Claude Work", placeholder: "Claude",
            accentColor: "", fields: [], secrets: [],
            variables: [{ name: "API_TOKEN", value: "", sensitive: true, redacted: true, invalid: false,
                          placeholder: "Stored secret, enter a new value to replace" }]
        }, overrides);
    }

    function settings(overrides) {
        return Object.assign({
            open: true, environmentId: "env-a",
            environments: [{ id: "env-a", label: "This machine", local: true, online: true }],
            status: "ready", title: "", description: "", refreshing: false, wizard: null,
            providers: [root.provider({})]
        }, overrides);
    }

    TestCase {
        name: "ProvidersSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        // The managed runtime shows the MC's download and the actions it allows.
        function test_the_managed_runtime_shows_its_download_and_cancels() {
            const runtime = { status: "Downloading 25.0 MB of 100.0 MB.", message: "", progress: 0.25, installLabel: "",
                              canCancel: true, canRemove: false, busy: false, error: "" };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ instanceId: "antigravity", driver: "antigravity",
                                                                                          name: "Antigravity", runtime: runtime })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_antigravity");
            compare(findChild(card, "runtimeStatus").text, "Downloading 25.0 MB of 100.0 MB.");
            verify(!findChild(card, "runtimeInstall").visible);
            verify(!findChild(card, "runtimeRemove").visible);
            mouseClick(findChild(card, "runtimeCancel"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.runtimeCancel");
            compare(Shell.dispatchedActions[0].payload.instanceId, "antigravity");
        }

        // The header says when the environment last checked its providers.
        function test_the_header_says_when_providers_were_checked() {
            const fiveMinutesAgo = new Date(Date.now() - 5 * 60000 - 1000).toISOString();
            Shell.state = { providerSettings: root.settings({ checkedAt: fiveMinutesAgo }) };
            const page = createTemporaryObject(settingsComponent, root);
            const checked = findChild(page, "checked");
            tryCompare(checked, "text", "Checked 5m ago");
            compare(page.checkedAgo(new Date(Date.now() - 2 * 3600000).toISOString(), Date.now()), "Checked 2h ago");
            compare(page.checkedAgo(new Date().toISOString(), Date.now()), "Checked just now");
            Shell.state = { providerSettings: root.settings({ checkedAt: "" }) };
            verify(!checked.visible);
        }

        // The signed-in account email stays hidden until asked; the signed-in
        // email is hidden until the user reveals it.
        function test_the_account_email_is_scrambled_until_revealed() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            const email = findChild(findChild(page, "provider_claudeAgent_work"), "email");
            verify(email.text !== "ada@example.com");
            compare(email.text.length, "ada@example.com".length);
            compare(email.text.indexOf("@"), 3);
            compare(email.text, page.redacted("ada@example.com"), "the same account scrambles the same way");
            mouseClick(email);
            compare(email.text, "ada@example.com");
            mouseClick(email);
            verify(email.text !== "ada@example.com");
        }

        function test_turning_a_provider_off_asks_the_shell() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            mouseClick(findChild(findChild(page, "provider_claudeAgent_work"), "enabled"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.enable");
            compare(Shell.dispatchedActions[0].payload.instanceId, "claudeAgent_work");
            compare(Shell.dispatchedActions[0].payload.enabled, false);
        }

        function test_without_providers_the_section_says_why() {
            Shell.state = { providerSettings: root.settings({ status: "offline", providers: [], title: "Could not connect to this device",
                                                              description: "Reconnect this device to set up its provider, or select another device." }) };
            const page = createTemporaryObject(settingsComponent, root);
            verify(findChild(page, "placeholder").visible);
            verify(!findChild(page, "refresh").enabled, "an offline environment cannot be refreshed");
        }

        // One environment needs no choice; several do.
        function test_the_environment_choice_shows_with_several_environments() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            verify(!findChild(page, "environments").visible);
            Shell.state = { providerSettings: root.settings({ environments: [
                { id: "env-a", label: "This machine", local: true, online: true },
                { id: "build", label: "Build box", local: false, online: false }] }) };
            verify(findChild(page, "environments").visible);
        }

        function test_an_update_running_cannot_be_started_again() {
            const advisory = { title: "Update available", detail: "Update available: install v0.51.0.", updateCommand: "npm i -g codex",
                               targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, updating: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "advisoryButton"));
            const update = findChild(card, "update");
            verify(update.visible);
            verify(!update.enabled);
        }

        // The card shows an icon; the title, the detail and the actions open from it.
        function test_an_update_advisory_opens_from_an_icon_on_the_card() {
            const advisory = { title: "Update available", detail: "Update available: install v0.51.0.", updateCommand: "npm i -g codex",
                               targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            verify(button.visible);
            verify(button.iconOnly);
            compare(button.Accessible.name, "Claude Work: Update available");
            const popover = findChild(card, "advisory");
            verify(!popover.visible, "the details stay closed until asked for");
            mouseClick(button);
            tryCompare(popover, "opened", true);
            mouseClick(findChild(card, "update"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.update");
        }

        // Escape closes the popover the keyboard opened, and nothing else (it must
        // not reach the page, whose host leaves Settings on it). The icon toggles it.
        function test_the_advisory_popover_closes_on_escape_and_toggles_from_its_icon() {
            const advisory = { title: "Update available", detail: "Update available: install v0.51.0.", updateCommand: "npm i -g codex",
                               targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            const popover = findChild(card, "advisory");
            button.forceActiveFocus();
            keyClick(Qt.Key_Space);
            tryCompare(popover, "opened", true);
            verify(popover.activeFocus, "the popover takes the keyboard");
            let leftThePage = false;
            page.Keys.escapePressed.connect(() => leftThePage = true);
            keyClick(Qt.Key_Escape);
            tryCompare(popover, "opened", false);
            verify(!leftThePage, "Escape stopped at the popover");

            verify(!button.checked, "the icon reads as collapsed while the popover is closed");
            mouseClick(button);
            tryCompare(popover, "opened", true);
            verify(button.checked, "the icon reads as expanded while the popover is open");
            mouseClick(button);
            tryCompare(popover, "opened", false);
            verify(!button.checked, "the icon reads as collapsed again once the popover closes");
            // Closing it with the press must not reopen it with the click that follows.
            tryVerify(() => !popover.opened && !popover.visible);
            verify(!popover.opened, "pressing the icon again closes it rather than reopening it");
        }

        // The popover is placed as it opens and does not follow the icon: the page scrolling,
        // the window resizing or the zoom changing under it closes it instead.
        function test_the_advisory_popover_closes_when_the_icon_moves_under_it() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            const win = root.Window.window;
            const full = { width: win.width, height: win.height };
            const many = [];
            for (let i = 0; i < 12; i++)
                many.push(root.provider({ instanceId: "claudeAgent_" + i, name: "Claude " + i, advisory: i === 0 ? advisory : null }));
            Shell.state = { providerSettings: root.settings({ providers: many }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_0");
            const button = findChild(card, "advisoryButton");
            const popover = findChild(card, "advisory");
            const open = () => {
                mouseClick(button);
                tryCompare(popover, "opened", true);
            };
            try {
                open();
                const flick = findChild(page, "providersScroll");
                verify(flick, "the page's scroll area is found");
                flick.contentY = 40;
                tryCompare(popover, "opened", false);

                open();
                win.height = full.height - 60;
                tryCompare(popover, "opened", false);
                win.height = full.height;

                open();
                win.width = full.width - 60;
                tryCompare(popover, "opened", false);
                win.width = full.width;

                open();
                Shell.state = { layout: { zoom: 1.25 }, providerSettings: root.settings({ providers: many }) };
                tryCompare(popover, "opened", false);
            } finally {
                win.width = full.width;
                win.height = full.height;
            }
        }

        // The keyboard opens it, reaches its actions, and gets the icon back when it closes.
        function test_the_advisory_popover_is_keyboard_reachable_and_returns_focus() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            const popover = findChild(card, "advisory");
            const update = findChild(card, "update");
            button.forceActiveFocus();
            keyClick(Qt.Key_Space);
            tryCompare(popover, "opened", true);
            for (let i = 0; i < 4 && !update.activeFocus; i++)
                keyClick(Qt.Key_Tab);
            verify(update.activeFocus, "Tab reaches Update now from inside the popover");
            keyClick(Qt.Key_Space);
            compare(Shell.dispatchedActions[0].action, "providerSettings.update");
            keyClick(Qt.Key_Escape);
            tryCompare(popover, "opened", false);
            tryVerify(() => button.activeFocus, 1000);
        }

        // Focus leaving the popover (Tab cycles inside it, so this is focus
        // moving to another control) closes it, instead of leaving it open
        // over the page where Escape no longer reaches it.
        function test_the_advisory_popover_closes_when_focus_leaves_it() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            const popover = findChild(card, "advisory");
            button.forceActiveFocus();
            keyClick(Qt.Key_Space);
            tryCompare(popover, "opened", true);
            verify(popover.activeFocus, "the popover holds focus while open");
            findChild(card, "configure").forceActiveFocus();
            tryCompare(popover, "opened", false);
        }

        function test_the_advisory_popover_keeps_the_settings_zoom() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { layout: { zoom: 1.5 }, providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "advisoryButton"));
            const popover = findChild(card, "advisory");
            tryCompare(popover, "opened", true);
            compare(popover.scale, 1.5);
            compare(popover.transformOrigin, Item.TopLeft);
        }

        // Where the popover opens, the drawn card is inside the window, however far
        // down or to the right the icon is, however far the page is zoomed and however
        // small the window is: ShellWindow's minimum is 640x400 and the zoom goes to 5.
        // A long detail at a small window and a high zoom fits neither below nor above
        // the icon, so the card is shorter than its text and scrolls.
        function test_the_advisory_popover_stays_inside_the_window() {
            const short = "Install v0.51.0.";
            const long = "This version of the provider is outside the range HAL-C2 supports. Update it to v0.51.0 or newer " +
                         "so new threads keep working, or keep using the version you have and accept that some features may fail.";
            const win = root.Window.window;
            const full = { width: win.width, height: win.height };
            // [window width, window height, zoom, icon x, icon y, detail]: the icon's
            // centre, as a fraction of the window.
            const cases = [
                [900, 700, 1, 0.1, 0.1, short], [900, 700, 1.5, 0.1, 0.1, short], [900, 700, 1, 0.1, 0.9, short],
                [900, 700, 1.5, 0.1, 0.9, short], [900, 700, 1, 0.9, 0.1, short], [900, 700, 1.5, 0.7, 0.1, short],
                [900, 700, 1.5, 0.7, 0.9, short], [900, 700, 1, 0.9, 0.9, long],
                [640, 400, 1, 0.1, 0.1, long], [640, 400, 2, 0.1, 0.1, long], [640, 400, 2, 0.1, 0.5, long],
                [640, 400, 2, 0.5, 0.3, long], [640, 400, 2, 0.95, 0.5, long], [640, 400, 3, 0.1, 0.1, long],
                [640, 400, 3, 0.6, 0.6, long], [640, 400, 5, 0.2, 0.2, long]];
            let exercised = 0, flipped = 0, shifted = 0, scrolled = 0;
            try {
                for (const [width, height, zoom, fractionX, fractionY, detail] of cases) {
                    win.width = width;
                    win.height = height;
                    const advisory = { title: "Update available", detail: detail, updateCommand: "npm i -g codex", targetVersion: null, strong: false };
                    Shell.state = { layout: { zoom: zoom }, providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
                    const body = createTemporaryObject(zoomedBodyComponent, root, { zoom: zoom });
                    const card = findChild(body.page, "provider_claudeAgent_work");
                    const button = findChild(card, "advisoryButton");
                    const label = `${width}x${height} zoom ${zoom} at ${fractionX},${fractionY}`;
                    // Moves the page so that the icon's centre is where the case asks.
                    const home = button.mapToItem(null, button.width / 2, button.height / 2);
                    body.offsetX = (width * fractionX - home.x) / zoom;
                    body.offsetY = (height * fractionY - home.y) / zoom;
                    const at = button.mapToItem(null, button.width / 2, button.height / 2);
                    verify(at.x > 0 && at.y > 0 && at.x < width && at.y < height, label + ": the icon is in the window");
                    mouseClick(button);
                    const popover = findChild(card, "advisory");
                    tryCompare(popover, "opened", true);
                    const topLeft = popover.background.mapToItem(null, 0, 0);
                    const bottomRight = popover.background.mapToItem(null, popover.background.width, popover.background.height);
                    verify(topLeft.x >= 7 && topLeft.y >= 7, label + ": the popover starts inside the window " + topLeft);
                    verify(bottomRight.x <= width - 7 && bottomRight.y <= height - 7, label + ": the popover ends inside the window " + bottomRight);
                    // Flipped or shifted, it stays against the icon and the window edge, not
                    // a zoom-multiple away from them.
                    const iconTop = button.mapToItem(null, 0, 0).y;
                    if (popover.upward) {
                        flipped++;
                        if (popover.nudge === 0)
                            verify(Math.abs(bottomRight.y - iconTop) <= 4 * zoom + 1, label + ": the flipped popover sits against the icon");
                    }
                    if (popover.shift !== 0) {
                        shifted++;
                        verify(Math.abs(bottomRight.x - (width - 8)) <= 1 || Math.abs(topLeft.x - 8) <= 1, label + ": the shifted popover sits against the window edge");
                    }
                    if (popover.contentItem.contentHeight > popover.contentItem.height + 1)
                        scrolled++;
                    exercised++;
                    popover.close();
                    body.destroy();
                }
            } finally {
                win.width = full.width;
                win.height = full.height;
            }
            compare(exercised, cases.length);
            verify(flipped > 0, "a case opens upward");
            verify(shifted > 0, "a case is shifted left");
            verify(scrolled > 0, "a case is too tall for the window and scrolls");
        }

        // Placement is recomputed while open: taller content (here a larger
        // font scale) cannot grow the popover past the window's edge.
        function test_the_advisory_popover_stays_inside_when_its_content_grows() {
            const advisory = { title: "Update available", detail: "This version is outside the supported range. " +
                "Update to v0.51.0 or newer so new threads keep working.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { layout: { zoom: 1 }, providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const body = createTemporaryObject(zoomedBodyComponent, root, { zoom: 1 });
            const card = findChild(body.page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            const home = button.mapToItem(null, button.width / 2, button.height / 2);
            body.offsetX = (root.width * 0.1 - home.x);
            body.offsetY = (root.height * 0.9 - home.y);
            mouseClick(button);
            const popover = findChild(card, "advisory");
            tryCompare(popover, "opened", true);
            try {
                Theme.fontScale = 2;
                tryVerify(() => popover.opened);
                const topLeft = popover.background.mapToItem(null, 0, 0);
                const bottomRight = popover.background.mapToItem(null, popover.background.width, popover.background.height);
                verify(topLeft.x >= 7 && topLeft.y >= 7, "grown popover starts inside the window " + topLeft);
                verify(bottomRight.x <= root.width - 7 && bottomRight.y <= root.height - 7, "grown popover ends inside the window " + bottomRight);
            } finally {
                Theme.fontScale = 1;
            }
        }

        // A close because the window moved under it does not park keyboard
        // focus on the icon.
        function test_a_moved_close_does_not_return_focus_to_the_icon() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            const popover = findChild(card, "advisory");
            const win = root.Window.window;
            const fullHeight = win.height;
            try {
                mouseClick(button);
                tryCompare(popover, "opened", true);
                win.height = fullHeight - 60;
                tryCompare(popover, "opened", false);
                verify(popover.movedClose, "the resize close is marked as moved");
                verify(!button.activeFocus, "closing does not park focus on the icon");
            } finally {
                win.height = fullHeight;
            }
        }

        // A republish recreates every card: the open popover is reopened on the
        // new delegate (Update flipping to Updating… must not make it vanish).
        function test_the_advisory_popover_survives_a_republish_while_updating() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "advisoryButton"));
            tryCompare(findChild(card, "advisory"), "opened", true);
            const many = [root.provider({ advisory: advisory, updating: true })];
            for (let i = 1; i < 12; i++)
                many.push(root.provider({ instanceId: "claudeAgent_" + i, name: "Claude " + i }));
            Shell.state = { providerSettings: root.settings({ providers: many }) };
            const newCard = findChild(page, "provider_claudeAgent_work");
            const popover = findChild(newCard, "advisory");
            tryCompare(popover, "opened", true);
            const update = findChild(newCard, "update");
            verify(!update.enabled, "the reopened popover shows Updating disabled");
            compare(update.text, "Updating…");
        }

        // At a small window and high zoom the popover scrolls: Tab focus is
        // scrolled into view, never left activatable below the fold.
        function test_the_advisory_popover_scrolls_tab_focus_into_view() {
            const advisory = { title: "Update available", detail: "This version of the provider is outside the range HAL-C2 supports. " +
                "Update it to v0.51.0 or newer so new threads keep working, or keep using the version you have and accept that some features may fail.",
                updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            const win = root.Window.window;
            const full = { width: win.width, height: win.height };
            try {
                win.width = 640;
                win.height = 400;
                Shell.state = { layout: { zoom: 3 }, providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, canUpdate: true })] }) };
                const body = createTemporaryObject(zoomedBodyComponent, root, { zoom: 3 });
                const card = findChild(body.page, "provider_claudeAgent_work");
                const button = findChild(card, "advisoryButton");
                const popover = findChild(card, "advisory");
                button.forceActiveFocus();
                keyClick(Qt.Key_Space);
                tryCompare(popover, "opened", true);
                const update = findChild(card, "update");
                for (let i = 0; i < 6 && !update.activeFocus; i++)
                    keyClick(Qt.Key_Tab);
                verify(update.activeFocus, "Tab reaches Update now");
                const at = update.mapToItem(popover.contentItem, 0, 0);
                verify(at.y >= -1 && at.y + update.height <= popover.contentItem.height + 1,
                       "the focused control is inside the scrolled view " + at.y + "/" + popover.contentItem.height);
                body.destroy();
            } finally {
                win.width = full.width;
                win.height = full.height;
            }
        }

        // A republish without the advisory keeps it closed; this pins that it stays so.
        function test_the_advisory_popover_closes_when_the_advisory_goes_away() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "npm i -g codex", targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "advisoryButton"));
            const popover = findChild(card, "advisory");
            tryCompare(popover, "opened", true);
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: null })] }) };
            tryCompare(popover, "opened", false);
        }

        // A version outside the supported range is told apart on the card itself.
        function test_a_strong_advisory_is_a_warning_icon() {
            const advisory = { title: "Unsupported version", detail: "Update to v0.51.0 or newer.", updateCommand: "npm i -g codex", targetVersion: null, strong: true };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const button = findChild(card, "advisoryButton");
            compare(button.iconName, "triangle-alert");
            compare(button.tint, page.warning);
            compare(button.Accessible.name, "Claude Work: Unsupported version");
        }

        function test_a_provider_without_an_advisory_has_no_icon() {
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({})] }) };
            const page = createTemporaryObject(settingsComponent, root);
            verify(!findChild(findChild(page, "provider_claudeAgent_work"), "advisoryButton").visible);
        }

        // The update command is copied from a button; its path is not printed on the card.
        function test_an_update_advisory_keeps_the_command_off_the_card() {
            const advisory = { title: "Update available", detail: "Install v0.51.0.", updateCommand: "/opt/mise/claude update",
                               targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "advisoryButton"));
            const copy = findChild(card, "copyUpdateCommand");
            verify(copy.visible);
            verify(copy.iconOnly);
            const shown = [];
            const visit = item => {
                if (item.visible && typeof item.text === "string") shown.push(item.text);
                for (const child of item.children) visit(child);
            };
            visit(findChild(card, "advisory").contentItem);
            verify(!shown.some(text => text.includes("/opt/mise")), shown.join("|"));
        }

        function wizard(overrides) {
            return Object.assign({
                step: 1, steps: ["Provider", "Identity", "Config"],
                drivers: [{ id: "codex", label: "Codex", badge: "" }, { id: "claudeAgent", label: "Claude", badge: "" }],
                driver: "claudeAgent", driverLabel: "Claude", label: "Claude", accentColor: "", instanceId: "claudeAgent_2",
                instanceIdError: "", fields: [], saving: false,
                registry: { query: "", searching: false, error: "", agents: [], busy: false, manual: false, selected: null, selectionError: "" }
            }, overrides);
        }

        // A registry agent's native sessions and model providers.
        function test_a_registry_agent_imports_sessions_and_sets_a_model_provider() {
            const acp = {
                canList: true, canImport: true, canDelete: true, canLogout: true, canConfigure: true,
                projects: [{ id: "p1", title: "hal-c2" }], projectId: "p1", more: false, busy: "",
                sessions: [{ sessionId: "s1", title: "Fix the build", updatedAt: "", cwd: "/work", imported: false }],
                providers: [{ providerId: "openai", supported: ["openai"], required: false, configured: false, apiType: "openai", baseUrl: "" }]
            };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ acp: acp })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "configure"));
            const section = findChild(card, "acpSessions");
            verify(section.visible);
            mouseClick(findChild(findChild(section, "acpSession_s1"), "acpImport"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.acpImport");
            compare(Shell.dispatchedActions[0].payload.sessionId, "s1");
            const row = findChild(section, "acpProvider_openai");
            const save = findChild(row, "acpSaveProvider");
            verify(!save.enabled, "a base URL is needed");
            findChild(row, "acpBaseUrl").text = "https://api.example.com";
            findChild(row, "acpHeaders").text = "{\"A\": \"b\"}";
            tryVerify(() => save.enabled);
            mouseClick(save);
            compare(Shell.dispatchedActions[1].action, "providerSettings.acpSetProvider");
            compare(Shell.dispatchedActions[1].payload.baseUrl, "https://api.example.com");
            compare(Shell.dispatchedActions[1].payload.headers, "{\"A\": \"b\"}");
        }

        // The ACP Registry: an agent already added is not offered, another is,
        // and an empty answer suggests a broader search.
        function test_the_wizard_offers_registry_agents() {
            const agent = (id, added) => ({ id: id, name: id, description: "", iconUrl: "", website: "", added: added, preparing: false, progress: "Preparing" });
            const registry = { query: "gem", searching: false, error: "", agents: [agent("gemini-cli", true), agent("goose", false)], busy: false, manual: false, selected: null, selectionError: "" };
            Shell.state = { providerSettings: root.settings({ wizard: wizard({ step: 0, registry: registry }) }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "wizard");
            tryVerify(() => !!card && card.visible);
            const added = findChild(findChild(card, "registryAgent_gemini-cli"), "registryAdd");
            compare(added.text, "Added");
            verify(!added.enabled);
            verify(!findChild(card, "registryEmpty").visible);
            mouseClick(findChild(findChild(card, "registryAgent_goose"), "registryAdd"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.registryAdd");
            compare(Shell.dispatchedActions[0].payload.agentId, "goose");
            Shell.state = { providerSettings: root.settings({ wizard: wizard({ step: 0, registry: Object.assign({}, registry, { agents: [] }) }) }) };
            tryVerify(() => findChild(card, "registryEmpty").visible);
        }

        // Adding an instance: the wizard's own actions, and a taken id said.
        function test_the_wizard_adds_an_instance_and_says_why_an_id_is_refused() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            mouseClick(findChild(page, "addInstance"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.wizardOpen");
            Shell.state = { providerSettings: root.settings({ wizard: wizard({ instanceIdError: "An instance with this id already exists." }) }) };
            const card = findChild(page, "wizard");
            tryVerify(() => !!card && card.visible);
            verify(findChild(card, "instanceIdError").visible);
            verify(!findChild(page, "addInstance").enabled, "one wizard at a time");
            mouseClick(findChild(card, "submit"));
            compare(Shell.dispatchedActions[1].action, "providerSettings.wizardSubmit");
        }

        // The label and id being typed stay on the page until the step moves,
        // even when the panel is republished meanwhile.
        function test_the_wizard_keeps_typing_until_the_step_moves() {
            Shell.state = { providerSettings: root.settings({ wizard: wizard({}) }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "wizard");
            tryVerify(() => !!card && card.visible);
            const label = findChild(card, "label");
            label.forceActiveFocus();
            label.selectAll();
            keySequence("w,o,r,k");
            compare(label.text, "work");
            compare(Shell.dispatchedActions.length, 0);
            Shell.state = { providerSettings: root.settings({ refreshing: true, wizard: wizard({}) }) };
            compare(label.text, "work");
            mouseClick(findChild(card, "next"));
            const step = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(step.action, "providerSettings.wizardStep");
            compare(step.payload.step, 2);
            compare(step.payload.label, "work");
            verify(!("instanceId" in step.payload), "an id not typed is derived by the MC");
        }

        // A stored secret is never shown; its row offers a replacement.
        function test_a_stored_secret_row_offers_a_replacement() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "configure"));
            verify(findChild(card, "editor").visible);
            const value = findChild(findChild(card, "variable_0"), "variableValue");
            compare(value.text, "");
            compare(value.placeholderText, "Stored secret, enter a new value to replace");
            compare(value.echoMode, TextInput.Password);
            mouseClick(findChild(card, "addVariable"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.addVariable");
            compare(Shell.dispatchedActions[0].payload.instanceId, "claudeAgent_work");
            mouseClick(findChild(card, "delete"));
            compare(Shell.dispatchedActions[1].action, "providerSettings.delete");
        }
    
        // A sign-in that asks for credentials sends what the user entered.
        function test_credentials_are_sent_on_connect() {
            const account = { description: "Enter your credentials below.", canSignIn: false, signInLabel: "Sign in", canCancel: true,
                              canSignOut: false, url: "", userCode: "", error: "", methods: [], terminal: null,
                              credentials: [{ name: "GEMINI_API_KEY", label: "API key", secret: true }], acceptsCallback: false, docsUrl: "" };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ account: account })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            const field = findChild(card, "credential_GEMINI_API_KEY");
            verify(findChild(card, "credentials").visible);
            compare(field.echoMode, TextInput.Password);
            field.forceActiveFocus();
            keyClick(Qt.Key_S);
            keyClick(Qt.Key_K);
            mouseClick(findChild(card, "connect"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.signInCredentials");
            compare(Shell.dispatchedActions[0].payload.values.GEMINI_API_KEY, "sk");
        }
    
        // A custom model's options are edited in the controller's draft and
        // saved with Save; a preset adds an option with its usual choices.
        function test_a_custom_model_is_added_and_its_options_edited() {
            const presets = [{ id: "effort", label: "Reasoning", type: "select",
                               choices: [{ id: "low", label: "Low", isDefault: false }, { id: "high", label: "High", isDefault: true }] }];
            const draft = { slug: "my-model", name: "", options: [{ id: "effort", label: "Reasoning", type: "select",
                                                                     choices: [{ id: "low", label: "Low", isDefault: true }] }] };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({
                takesModels: true, customModels: [{ slug: "my-model", name: "", options: draft.options }], modelPresets: presets,
                copyFrom: [], modelDraft: draft, modelError: "Option 1 needs a label." })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "configure"));
            const models = findChild(card, "customModels");
            verify(models.visible);
            compare(findChild(models, "modelError").text, "Option 1 needs a label.");
            const editor = findChild(models, "modelEditor");
            verify(editor.visible);
            // Reasoning is already an option, so it is not offered again.
            compare(findChild(editor, "preset_effort"), null);

            mouseClick(findChild(findChild(editor, "option_0"), "addChoice"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.modelDraft");
            compare(Shell.dispatchedActions[0].payload.options[0].choices.length, 2);
            compare(draft.options[0].choices.length, 1, "the published draft is left as it is");

            mouseClick(findChild(editor, "saveModel"));
            compare(Shell.dispatchedActions[1].action, "providerSettings.saveModel");
            compare(Shell.dispatchedActions[1].payload.slug, "my-model");

            const slug = findChild(models, "newModel");
            slug.forceActiveFocus();
            keyClick(Qt.Key_X);
            mouseClick(findChild(models, "addModel"));
            compare(Shell.dispatchedActions[2].action, "providerSettings.addModel");
            compare(Shell.dispatchedActions[2].payload.slug, "x");
            compare(slug.text, "");
        }

        // settings/usage-limit-sources.feature: a hub needs a URL and a key.
        function test_a_hub_is_added_only_with_a_url_and_key() {
            Shell.state = { providerSettings: root.settings({ hubs: [] }) };
            const page = createTemporaryObject(settingsComponent, root);
            mouseClick(findChild(page, "addHub"));
            const dialog = findChild(page, "addHubDialog");
            tryVerify(() => dialog.opened);
            const url = findChild(dialog, "url");
            url.text = "https://hub.example.ts.net:8318";
            verify(!findChild(dialog, "confirm").enabled, "no key, no hub");
            findChild(dialog, "key").text = "secret";
            verify(findChild(dialog, "confirm").enabled);
            mouseClick(findChild(dialog, "confirm"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.addHub");
            compare(Shell.dispatchedActions[0].payload.url, "https://hub.example.ts.net:8318");
            compare(Shell.dispatchedActions[0].payload.key, "secret");
            compare(Shell.dispatchedActions[0].payload.label, "");
        }

        function test_a_hub_is_removed_after_a_confirm() {
            Shell.state = { providerSettings: root.settings({ hubs: [{ id: "cliproxy-hub.example", label: "Team hub",
                                                                        description: "CLI Proxy · https://hub.example" }] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const row = findChild(page, "hub_cliproxy-hub.example");
            compare(findChild(row, "label").text, "Team hub");
            mouseClick(findChild(row, "remove"));
            const dialog = findChild(page, "removeHubDialog");
            tryVerify(() => dialog.opened);
            compare(dialog.title, "Remove Team hub?");
            mouseClick(findChild(dialog, "cancel"));
            compare(Shell.dispatchedActions.length, 0);
            mouseClick(findChild(row, "remove"));
            tryVerify(() => dialog.opened);
            mouseClick(findChild(dialog, "confirm"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.removeHub");
            compare(Shell.dispatchedActions[0].payload.id, "cliproxy-hub.example");
        }
    }
}
