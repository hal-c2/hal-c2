pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The usage page (UsageController publishes `usage`): cost or tokens over a
// window, merged across the chosen environments, or how much of each
// provider's limits is left.
Rectangle {
    id: page

    // Whether the page heads itself; a host with its own bar says it.
    property bool titled: true
    readonly property var model: Shell.state.usage ?? null
    readonly property string metric: model ? model.metric : "limits"
    readonly property bool limitsShown: metric === "limits"
    readonly property var summary: model ? model.summary : null
    readonly property var limits: model && model.limits ? model.limits : ({ pools: [], notices: [] })
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warningForeground", "#f59e0b")

    function usd(value) {
        return "$" + Number(value).toLocaleString(Qt.locale("en_US"), "f", 2);
    }

    // K, M, B and T with three significant figures.
    function tokens(value) {
        const units = ["", "K", "M", "B", "T"];
        let scaled = Number(value);
        let unit = 0;
        while (Math.abs(scaled) >= 1000 && unit < units.length - 1) {
            scaled /= 1000;
            ++unit;
        }
        return (unit === 0 ? String(Math.round(scaled)) : String(Number(scaled.toPrecision(3)))) + units[unit];
    }

    function amount(row) {
        return page.metric === "tokens" ? page.tokens(row.totalTokens) : page.usd(row.costUsd);
    }

    // The colour a provider's line is drawn in:
    // Codex in the text colour, Grok between it and the chart's muted chrome.
    function providerColor(id) {
        if (id === "claude")
            return "#d97757";
        return id === "grok" ? Qt.tint(page.color, Qt.alpha(page.foreground, 0.72)) : page.foreground;
    }

    function driverKind(id) {
        return id === "claude" ? "claudeAgent" : id;
    }

    function sessions(count) {
        return count === 1 ? qsTr("1 session") : qsTr("%1 sessions").arg(Math.round(count));
    }

    // How long until `iso`: `2d 3h`, `3h 20m` or `5m`; "" once it has passed.
    function until(iso) {
        const minutes = Math.max(0, Math.round((Date.parse(iso) - Date.now()) / 60000));
        if (minutes === 0)
            return "";
        const days = Math.floor(minutes / 1440);
        const hours = Math.floor((minutes % 1440) / 60);
        if (days > 0)
            return qsTr("%1d %2h").arg(days).arg(hours);
        if (hours > 0)
            return qsTr("%1h %2m").arg(hours).arg(minutes % 60);
        return qsTr("%1m").arg(minutes);
    }

    function resetsIn(iso) {
        if (!iso)
            return "";
        const left = page.until(iso);
        return left ? qsTr("resets in %1").arg(left) : qsTr("resets now");
    }

    // `2 reset credits banked · next expires in 27d 23h` (resetCreditsSummary).
    function credits(row) {
        if (row.available === 0)
            return qsTr("No reset credits banked");
        const banked = row.available === 1 ? qsTr("1 reset credit banked") : qsTr("%1 reset credits banked").arg(row.available);
        const left = row.nextExpiresAt ? page.until(row.nextExpiresAt) : "";
        return left ? qsTr("%1 · next expires in %2").arg(banked).arg(left) : banked;
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    // The one chosen: a raised fill and the accent's ink, as every settings
    // choice is; the accent's fill is the primary action's.
    component Toggle: ShellButton {
        required property bool selected

        subtle: true
        checked: selected
        hoverFill: selected ? Theme.palette.color("surfaceRaised", "#1f1f24") : accentSurface
        tint: selected ? Theme.palette.color("accentText", "#60a5fa") : Theme.palette.color("text", "#e4e4e7")
    }

    component Section: Label {
        Layout.topMargin: Theme.space.md
        color: page.muted
        font.pixelSize: Theme.type.meta.size
        font.weight: Font.DemiBold
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                visible: page.titled
                text: qsTr("Usage")
                color: page.foreground
                font.pixelSize: Theme.type.title.size
                font.weight: Font.DemiBold
            }

            Label {
                objectName: "usageWindowLabel"
                // Its own width where there is room for it, and the first to give
                // way where the centre is narrow.
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                // Whole pixels: a width rounded down from the text's would elide it.
                Layout.maximumWidth: Math.ceil(implicitWidth)
                visible: !page.limitsShown
                text: page.model ? page.model.windowLabel : ""
                color: page.muted
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideRight
            }

            Item {
                Layout.fillWidth: true
            }

            ShellComboBox {
                id: environmentBox

                readonly property var choices: [{ id: "", label: qsTr("All environments") }].concat((page.model ? page.model.environments : []).map(environment => ({
                    id: environment.id,
                    label: page.limitsShown || environment.status === "ready" ? environment.label : environment.status === "scanning" ? qsTr("%1 · Scanning…").arg(environment.label) : environment.status === "outdated" ? qsTr("%1 · Update required").arg(environment.label) : qsTr("%1 · Unavailable").arg(environment.label)
                })))

                objectName: "usageEnvironment"
                visible: page.model !== null && page.model.environments.length > 1
                outline: true
                textRole: "label"
                valueRole: "id"
                model: choices
                currentIndex: Math.max(0, choices.findIndex(choice => choice.id === (page.model ? page.model.environmentId : "")))
                onActivated: index => Shell.dispatch("usage.environment", { id: choices[index].id })
            }

            ShellButton {
                objectName: "usagePrices"
                text: qsTr("Model prices")
                onClicked: Shell.dispatch("usagePrices.open")
            }

            ShellButton {
                objectName: "usageRefresh"
                iconName: "refresh-cw"
                enabled: page.model !== null && !page.model.refreshing
                Accessible.name: page.limitsShown ? qsTr("Refresh limits") : qsTr("Refresh usage")
                onClicked: Shell.dispatch("usage.refresh")
            }
        }

        // Wraps where the centre is narrow, so the page never runs wider than it.
        Flow {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: [["cost", qsTr("Cost")], ["tokens", qsTr("Tokens")], ["limits", qsTr("Limits")]]

                delegate: Toggle {
                    required property var modelData

                    objectName: "usageMetric_" + modelData[0]
                    text: modelData[1]
                    selected: page.metric === modelData[0]
                    onClicked: Shell.dispatch("usage.metric", { metric: modelData[0] })
                }
            }

            Item {
                width: 12
                height: 1
            }

            Repeater {
                model: [[1, qsTr("Past 24h")], [7, qsTr("7 days")], [30, qsTr("30 days")], [90, qsTr("90 days")]]

                delegate: Toggle {
                    required property var modelData

                    text: modelData[1]
                    enabled: !page.limitsShown
                    selected: page.model !== null && page.model.windowDays === modelData[0]
                    onClicked: Shell.dispatch("usage.window", { days: modelData[0] })
                }
            }
        }

        Repeater {
            model: page.limitsShown ? page.limits.notices : (page.model ? page.model.notices : [])

            delegate: Label {
                required property string modelData

                Layout.fillWidth: true
                text: modelData
                color: page.warning
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
        }

        // Why there is nothing to show, or that history is still being read.
        ShellEmptyState {
            id: usageMessage

            objectName: "usageMessage"
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space.xxl
            visible: title.length > 0
            status: page.model && page.model.scanning && !page.limitsShown ? "loading" : "empty"
            iconName: "chart-no-axes-column"
            title: page.model ? page.model.message : ""
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: Theme.space.sm

                // Limits: one section per provider, one line per window.
                Repeater {
                    model: page.limitsShown ? page.limits.pools : []

                    delegate: ColumnLayout {
                        id: pool

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        RowLayout {
                            Layout.topMargin: 8
                            spacing: Theme.space.sm

                            ProviderIcon {
                                driverKind: pool.modelData.driver
                            }

                            Label {
                                text: pool.modelData.label
                                color: page.foreground
                                font.pixelSize: Theme.type.body.size
                                font.weight: Font.DemiBold
                            }
                        }

                        Repeater {
                            model: pool.modelData.windows

                            delegate: ShellCard {
                                id: card

                                required property var modelData

                                Layout.fillWidth: true
                                implicitHeight: cardColumn.implicitHeight + 20

                                ColumnLayout {
                                    id: cardColumn

                                    anchors.fill: parent
                                    anchors.margins: Theme.space.sm
                                    spacing: Theme.space.sm

                                    RowLayout {
                                        Layout.fillWidth: true

                                        Label {
                                            Layout.fillWidth: true
                                            text: card.modelData.label
                                            wrapMode: Text.Wrap
                                            color: page.muted
                                            font.pixelSize: Theme.type.meta.size
                                        }

                                        Label {
                                            text: page.resetsIn(card.modelData.resetsAt)
                                            color: page.muted
                                            font.pixelSize: Theme.type.caption.size
                                        }
                                    }

                                    Label {
                                        text: qsTr("%1% left").arg(card.modelData.remainingPercent)
                                        color: page.foreground
                                        font.pixelSize: Theme.type.display.size
                                        font.weight: Font.DemiBold
                                    }

                                    // One share per account, the soonest reset first.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Repeater {
                                            model: card.modelData.accounts

                                            delegate: ColumnLayout {
                                                id: account

                                                required property var modelData

                                                Layout.fillWidth: true
                                                Layout.preferredWidth: 1
                                                spacing: 2

                                                Rectangle {
                                                    Layout.fillWidth: true
                                                    implicitHeight: 6
                                                    radius: Theme.radiusPill
                                                    color: Theme.palette.color("surfaceRaised", "#1f1f24")

                                                    // The accent, then a warning at a quarter left
                                                    // and an error at a tenth.
                                                    Rectangle {
                                                        readonly property real remaining: Math.max(0, 100 - account.modelData.usedPercent)

                                                        objectName: "limitLeft"
                                                        width: parent.width * remaining / 100
                                                        height: parent.height
                                                        radius: Theme.radiusPill
                                                        color: remaining <= 10 ? Theme.palette.color("error", "#ef4444") : remaining <= 25 ? Theme.palette.color("warning", "#f59e0b") : Theme.palette.color("accent", "#3b82f6")
                                                    }
                                                }

                                                Label {
                                                    Layout.fillWidth: true
                                                    text: qsTr("%1 · %2%").arg(account.modelData.name).arg(Math.round(100 - account.modelData.usedPercent))
                                                    color: page.muted
                                                    font.pixelSize: Theme.type.caption.size
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Banked reset credits, spent only once the user confirms.
                        Repeater {
                            model: pool.modelData.credits ?? []

                            delegate: RowLayout {
                                id: credit

                                required property var modelData

                                objectName: "usageCredits_" + credit.modelData.key
                                Layout.fillWidth: true
                                spacing: 8

                                Label {
                                    text: pool.modelData.credits.length > 1 ? qsTr("%1: %2").arg(credit.modelData.name).arg(page.credits(credit.modelData)) : page.credits(credit.modelData)
                                    color: page.muted
                                    font.pixelSize: Theme.type.meta.size
                                }

                                ShellButton {
                                    objectName: "useReset"
                                    visible: credit.modelData.available > 0
                                    enabled: !credit.modelData.busy
                                    subtle: true
                                    text: credit.modelData.busy ? qsTr("Using…") : qsTr("Use reset")
                                    onClicked: {
                                        resetDialog.key = credit.modelData.key;
                                        resetDialog.open();
                                    }
                                }

                                Label {
                                    objectName: "resetStatus"
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: credit.modelData.status
                                    color: page.foreground
                                    font.pixelSize: Theme.type.meta.size
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
                }

                // Usage: the total, each provider's part, then the breakdowns.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !page.limitsShown && !!page.summary
                    spacing: 4

                    Label {
                        objectName: "usageTotal"
                        text: page.summary ? page.amount(page.summary) : ""
                        color: page.foreground
                        font.pixelSize: Theme.type.display.size
                        font.weight: Font.DemiBold
                    }

                    Label {
                        text: {
                            if (!page.summary)
                                return "";
                            const count = page.sessions(page.summary.sessions);
                            if (page.metric === "tokens")
                                return count;
                            if (page.summary.unpricedShare > 0)
                                return qsTr("%1 · API estimate excludes %2% unpriced records").arg(count).arg((page.summary.unpricedShare * 100).toFixed(1));
                            return qsTr("%1 · API estimate").arg(count);
                        }
                        color: page.muted
                        font.pixelSize: Theme.type.meta.size
                    }

                    Repeater {
                        model: page.summary ? page.summary.providers : []

                        delegate: RowLayout {
                            id: providerRow

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Theme.space.sm

                            // The provider's colour in the chart.
                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: Theme.radiusPill
                                color: page.providerColor(providerRow.modelData.id)
                                Accessible.ignored: true
                            }

                            ProviderIcon {
                                driverKind: page.driverKind(providerRow.modelData.id)
                            }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("%1  %2").arg(providerRow.modelData.label).arg(page.sessions(providerRow.modelData.sessions))
                                color: page.foreground
                                font.pixelSize: Theme.type.body.size
                                elide: Text.ElideRight
                            }

                            Label {
                                text: page.amount(providerRow.modelData)
                                color: page.foreground
                                font.pixelSize: Theme.type.body.size
                            }
                        }
                    }

                    Section {
                        visible: usageChart.visible
                        text: usageChart.description
                    }

                    UsageChart {
                        id: usageChart

                        readonly property bool hourly: page.model !== null && page.model.windowDays === 1

                        objectName: "usageChart"
                        Layout.fillWidth: true
                        visible: series.length > 0 && columns.length > 0
                        description: page.metric === "tokens" ? (hourly ? qsTr("Hourly processed tokens") : qsTr("Daily processed tokens")) : (hourly ? qsTr("Hourly cost") : qsTr("Daily cost"))
                        series: (page.summary?.providers ?? []).map(provider => ({
                            label: provider.label,
                            color: page.providerColor(provider.id),
                            driverKind: page.driverKind(provider.id)
                        }))
                        columns: (page.summary?.chart ?? []).map(period => ({
                            label: period.label,
                            heading: period.heading,
                            values: page.metric === "tokens" ? period.totalTokens : period.costUsd
                        }))
                        format: page.metric === "tokens" ? page.tokens : page.usd
                    }

                    Section {
                        text: qsTr("Totals")
                    }

                    Repeater {
                        model: page.summary ? [[qsTr("Processed tokens"), page.tokens(page.summary.totalTokens)], [qsTr("Cached input"), page.tokens(page.summary.cachedInputTokens)], [qsTr("Uncached input"), page.tokens(page.summary.uncachedInputTokens)], [qsTr("Output"), page.tokens(page.summary.outputTokens)], [qsTr("Cache savings"), page.usd(page.summary.cacheSavingsUsd)]] : []

                        delegate: RowLayout {
                            id: total

                            required property var modelData

                            Layout.fillWidth: true

                            Label {
                                Layout.fillWidth: true
                                text: total.modelData[0]
                                wrapMode: Text.Wrap
                                color: page.muted
                                font.pixelSize: Theme.type.meta.size
                            }

                            Label {
                                text: total.modelData[1]
                                color: page.foreground
                                font.pixelSize: Theme.type.meta.size
                            }
                        }
                    }

                    Section {
                        text: qsTr("Models")
                    }

                    Repeater {
                        model: page.summary ? page.summary.models : []

                        delegate: RowLayout {
                            id: modelRow

                            required property var modelData

                            Layout.fillWidth: true

                            Label {
                                Layout.fillWidth: true
                                text: modelRow.modelData.model
                                color: page.foreground
                                font.pixelSize: Theme.type.meta.size
                                elide: Text.ElideRight
                            }

                            Label {
                                text: page.metric === "cost" && modelRow.modelData.unpriced ? qsTr("Unpriced") : page.amount(modelRow.modelData)
                                color: page.foreground
                                font.pixelSize: Theme.type.meta.size
                            }
                        }
                    }

                    Section {
                        text: page.model && page.model.windowDays === 1 ? qsTr("Hourly") : qsTr("Daily")
                    }

                    // Newest first, each a bar against the busiest period.
                    Repeater {
                        id: periods

                        readonly property real peak: {
                            let most = 0;
                            for (const period of (page.summary ? page.summary.periods : []))
                                most = Math.max(most, page.metric === "tokens" ? period.totalTokens : period.costUsd);
                            return most;
                        }

                        model: page.summary ? page.summary.periods : []

                        delegate: RowLayout {
                            id: periodRow

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: 8

                            Label {
                                Layout.preferredWidth: 64
                                text: periodRow.modelData.label
                                elide: Text.ElideRight
                                color: page.muted
                                font.pixelSize: Theme.type.caption.size
                            }

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 8

                                Rectangle {
                                    objectName: "periodBar"
                                    height: parent.height
                                    radius: 2
                                    width: periods.peak > 0 ? parent.width * (page.metric === "tokens" ? periodRow.modelData.totalTokens : periodRow.modelData.costUsd) / periods.peak : 0
                                    color: Theme.palette.color("accent", "#3b82f6")
                                }
                            }

                            Label {
                                Layout.preferredWidth: 72
                                horizontalAlignment: Text.AlignRight
                                text: page.amount(periodRow.modelData)
                                elide: Text.ElideRight
                                color: page.foreground
                                font.pixelSize: Theme.type.caption.size
                            }
                        }
                    }
                }
            }
        }
    }
    UsageModelPrices {
        anchors.fill: parent
    }

    Dialog {
        id: resetDialog

        property string key

        objectName: "resetDialog"
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        width: Math.min(440, (parent?.width ?? 472) / scale - 32)
        padding: Theme.space.xl
        title: qsTr("Use a reset credit?")
        onAccepted: Shell.dispatch("usage.resetCredit", { key: key })

        Overlay.modal: ShellScrim {}
        background: ShellPopoverSurface {}
        header: Label {
            text: resetDialog.title
            padding: Theme.space.xl
            bottomPadding: Theme.space.xs
            font.pixelSize: Theme.type.title.size
            font.weight: Font.DemiBold
            color: page.foreground
        }
        contentItem: ColumnLayout {
            spacing: Theme.space.md

            Label {
                Layout.fillWidth: true
                text: qsTr("This redeems one credit on your account and clears the current rate-limit windows. It cannot be undone.")
                color: page.muted
                font.pixelSize: Theme.type.body.size
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "cancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: resetDialog.reject()
                }

                ShellButton {
                    objectName: "confirm"
                    primary: true
                    text: qsTr("Use credit")
                    onClicked: resetDialog.accept()
                }
            }
        }
    }
}
