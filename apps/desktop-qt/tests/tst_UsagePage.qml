import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import "../qml/HalC2/Bricks/js/usageChart.js" as UsageChartMath
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

        // Codex and Claude over three days, the middle one quiet for Codex.
        function charted(overrides) {
            const summary = Object.assign({}, root.usage({}).summary, {
                providers: [{ id: "codex", label: "Codex", costUsd: 30, totalTokens: 300, sessions: 2 },
                            { id: "claude", label: "Claude Code", costUsd: 12, totalTokens: 1200, sessions: 1 }],
                chart: [{ key: "2026-09-21", label: "Sep 21", heading: "Sep 21", costUsd: [10, 4], totalTokens: [100, 400] },
                        { key: "2026-09-22", label: "Sep 22", heading: "Sep 22", costUsd: [0, 8], totalTokens: [0, 800] },
                        { key: "2026-09-23", label: "Sep 23", heading: "Sep 23", costUsd: [20, 0], totalTokens: [200, 0] }]
            });
            Shell.state = { usage: root.usage(Object.assign({ summary: summary }, overrides)) };
            return createTemporaryObject(usageComponent, root);
        }

        function test_the_chart_draws_a_line_for_each_provider() {
            const page = charted({});
            const chart = findChild(page, "usageChart");
            verify(chart.visible);
            compare(chart.description, "Daily cost");
            compare(chart.lines.length, 2);
            // Codex spent the most, so it is painted first, under Claude.
            compare(chart.lines[0].total, 30);
            verify(chart.lines[0].line.startsWith("M0.00,"));
            // The scale ends on a round step at or above the busiest provider-day.
            compare(chart.axis.max, 20);
            verify(!findChild(chart, "usageChartReadout").visible);
        }

        function test_hovering_the_chart_reads_out_that_period() {
            const page = charted({});
            const chart = findChild(page, "usageChart");
            const readout = findChild(chart, "usageChartReadout");
            // The plot starts after the axis labels; its middle is the second day.
            mouseMove(chart, 64 + (chart.width - 64) / 2, 100);
            tryCompare(chart, "hoveredIndex", 1);
            verify(readout.visible);
            compare(findChild(readout, "usageChartHeading").text, "Sep 22");
            compare(findChild(readout, "usageChartValue_0").text, "$0.00");
            compare(findChild(readout, "usageChartValue_1").text, "$8.00");
            compare(findChild(readout, "usageChartTotal").text, "$8.00");
            mouseMove(chart, chart.width - 1, 100);
            tryCompare(chart, "hoveredIndex", 2);
            compare(findChild(readout, "usageChartValue_0").text, "$20.00");
            // Leaving the chart puts the readout away.
            mouseMove(root, 2, 2);
            tryCompare(readout, "visible", false);
        }

        function test_the_chart_follows_the_metric() {
            const page = charted({ metric: "tokens" });
            const chart = findChild(page, "usageChart");
            compare(chart.description, "Daily processed tokens");
            compare(chart.axis.max, 800);
            mouseMove(chart, 64 + (chart.width - 64) / 2, 100);
            tryCompare(chart, "hoveredIndex", 1);
            compare(findChild(chart, "usageChartValue_1").text, "800");
        }

        function test_without_a_provider_there_is_no_chart() {
            Shell.state = { usage: root.usage({}) };
            const page = createTemporaryObject(usageComponent, root);
            verify(!findChild(page, "usageChart").visible, "an older summary brings no chart");
        }

        // The tallest period is never drawn past the top of the plot.
        function test_the_scale_ends_at_or_above_the_peak() {
            for (const peak of [0.004, 1, 7.3, 19.9, 20, 87, 1234.5, 2.5e9]) {
                const scale = UsageChartMath.niceScale(peak, 4);
                verify(scale.max >= peak, "peak " + peak + " fits under " + scale.max);
                compare(scale.ticks[0], 0);
                fuzzyCompare(scale.ticks[scale.ticks.length - 1], scale.max, scale.max * 1e-6);
                verify(scale.ticks.length <= 6, "peak " + peak + " has " + scale.ticks.length + " ticks");
            }
            compare(UsageChartMath.niceScale(0, 4).ticks, [0]);
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
