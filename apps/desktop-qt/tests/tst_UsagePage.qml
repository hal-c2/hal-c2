import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/usage.feature: the usage page draws what UsageController publishes.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: usageComponent
        UsagePage {
            width: 880
            height: 680
        }
    }

    function usage(overrides) {
        return Object.assign({
            open: true,
            metric: "cost",
            windowDays: 30,
            windowLabel: "Aug 25 to Sep 23",
            environmentId: "",
            environments: [{ id: "local", label: "Local", status: "ready" }],
            scanning: false,
            refreshing: false,
            notices: [],
            message: "",
            summary: {
                costUsd: 1234.5, totalTokens: 2500000, sessions: 3, unpricedShare: 0,
                cacheSavingsUsd: 0, cachedInputTokens: 0, uncachedInputTokens: 0, cacheCreationTokens: 0, outputTokens: 0,
                providers: [{ id: "codex", label: "Codex", costUsd: 1234.5, totalTokens: 2500000, sessions: 3 }],
                models: [], periods: [{ key: "2026-09-23", label: "Sep 23", costUsd: 1234.5, totalTokens: 2500000 }]
            },
            limits: null
        }, overrides);
    }

    TestCase {
        name: "UsagePageTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_cost_and_tokens_show_the_total_in_their_units() {
            Shell.state = { usage: root.usage({}) };
            const page = createTemporaryObject(usageComponent, root);
            compare(findChild(page, "usageTotal").text, "$1,234.50");
            Shell.state = { usage: root.usage({ metric: "tokens" }) };
            compare(findChild(page, "usageTotal").text, "2.5M");
        }

        function test_choosing_a_metric_asks_the_shell() {
            Shell.state = { usage: root.usage({}) };
            const page = createTemporaryObject(usageComponent, root);
            mouseClick(findChild(page, "usageMetric_tokens"));
            compare(Shell.dispatchedActions[0].action, "usage.metric");
            compare(Shell.dispatchedActions[0].payload.metric, "tokens");
        }

        // One environment needs no choice; several do.
        function test_the_environment_choice_shows_with_several_environments() {
            Shell.state = { usage: root.usage({}) };
            const page = createTemporaryObject(usageComponent, root);
            verify(!findChild(page, "usageEnvironment").visible);
            Shell.state = { usage: root.usage({ environments: [{ id: "local", label: "Local", status: "ready" }, { id: "server", label: "Server", status: "scanning" }] }) };
            verify(findChild(page, "usageEnvironment").visible);
        }

        function test_without_anything_to_show_the_page_says_why() {
            Shell.state = { usage: root.usage({ metric: "limits", summary: null, limits: { pools: [], notices: [] }, message: "No provider on the selected environments reports subscription limits." }) };
            const page = createTemporaryObject(usageComponent, root);
            const message = findChild(page, "usageMessage");
            verify(message.visible);
            compare(message.text, "No provider on the selected environments reports subscription limits.");
            verify(!findChild(page, "usageWindowLabel").visible);
        }

        function test_a_refresh_running_cannot_be_started_again() {
            Shell.state = { usage: root.usage({ refreshing: true }) };
            const page = createTemporaryObject(usageComponent, root);
            verify(!findChild(page, "usageRefresh").enabled);
        }
        function creditsPage(credit) {
            Shell.state = { usage: root.usage({ metric: "limits", summary: null, limits: { notices: [], pools: [{
                driver: "codex", label: "Codex",
                windows: [{ key: "session:five-hour", label: "5-hour", remainingPercent: 60, resetsAt: "",
                            accounts: [{ name: "Codex", usedPercent: 40, resetsAt: "" }] }],
                credits: [Object.assign({ key: "codex:sam@example.com", name: "Codex", available: 1,
                                          nextExpiresAt: "", busy: false, status: "" }, credit)] }] } }) };
            return createTemporaryObject(usageComponent, root);
        }

        // A reset credit is spent only after the user confirms.
        function test_a_reset_credit_is_spent_after_confirming() {
            const page = creditsPage({});
            const row = findChild(page, "usageCredits_codex:sam@example.com");
            verify(row.visible);
            mouseClick(findChild(row, "useReset"));
            const dialog = findChild(page, "resetDialog");
            tryCompare(dialog, "opened", true);
            compare(Shell.dispatchedActions.length, 0, "nothing is spent before confirming");
            mouseClick(findChild(dialog.contentItem, "confirm"));
            compare(Shell.dispatchedActions[0].action, "usage.resetCredit");
            compare(Shell.dispatchedActions[0].payload.key, "codex:sam@example.com");
        }

        // The user backs out of spending a reset credit.
        function test_backing_out_keeps_the_credit() {
            const page = creditsPage({});
            mouseClick(findChild(findChild(page, "usageCredits_codex:sam@example.com"), "useReset"));
            const dialog = findChild(page, "resetDialog");
            tryCompare(dialog, "opened", true);
            mouseClick(findChild(dialog.contentItem, "cancel"));
            tryCompare(dialog, "visible", false);
            compare(Shell.dispatchedActions.length, 0);
        }

        function test_the_credits_say_how_many_are_banked_and_what_came_of_a_spend() {
            const expires = new Date(Date.now() + (27 * 24 + 23) * 3600000 + 30000).toISOString();
            let page = creditsPage({ available: 2, nextExpiresAt: expires });
            compare(page.credits({ available: 2, nextExpiresAt: expires }), "2 reset credits banked · next expires in 27d 23h");
            page = creditsPage({ available: 0, status: "No reset credit left." });
            const row = findChild(page, "usageCredits_codex:sam@example.com");
            verify(!findChild(row, "useReset").visible, "nothing is left to spend");
            compare(findChild(row, "resetStatus").text, "No reset credit left.");
        }
    }
}
