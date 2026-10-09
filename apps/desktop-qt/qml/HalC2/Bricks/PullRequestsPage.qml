pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The pull requests page (PullRequestListController publishes
// `pullRequestList`): every project's pull requests in the web's groups, the
// filters, and each row opening the thread that works on it.
Rectangle {
    id: page

    readonly property var model: Shell.state.pullRequestList ?? null
    readonly property var filters: model ? model.filters : ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // Group headers and rows in one list, so only what shows is drawn.
    readonly property var items: {
        const flat = [];
        for (const group of (model ? model.groups : [])) {
            flat.push({ header: true, label: group.label, count: group.rows.length });
            for (const row of group.rows)
                flat.push(Object.assign({ header: false }, row));
        }
        return flat;
    }

    function filter(name, value) {
        Shell.dispatch("pullRequestList.filter", { name: name, value: value });
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    component FilterBox: ShellComboBox {
        id: box

        required property string name
        // [label, value] pairs.
        required property var choices

        outline: true
        textRole: "label"
        valueRole: "value"
        model: choices.map(choice => ({ label: choice[0], value: choice[1] }))
        currentIndex: Math.max(0, choices.findIndex(choice => choice[1] === (page.filters[box.name] ?? "")))
        onActivated: index => page.filter(box.name, choices[index][1])
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                text: qsTr("Pull Requests")
                color: page.foreground
                font.pixelSize: Math.round(18 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Item {
                Layout.fillWidth: true
            }

            ShellTextField {
                id: search

                objectName: "pullRequestSearch"
                Layout.preferredWidth: 280
                placeholderText: qsTr("Search pull requests, or label:bug")
                text: page.filters.query ?? ""
                Accessible.name: qsTr("Search pull requests")
                // Every host is searched; wait for the user to pause.
                onTextEdited: searchDelay.restart()
                onAccepted: {
                    searchDelay.stop();
                    page.filter("query", text);
                }

                Timer {
                    id: searchDelay

                    interval: 250
                    onTriggered: page.filter("query", search.text)
                }
            }

            ShellButton {
                iconName: "refresh-cw"
                enabled: page.model !== null && !page.model.loading
                Accessible.name: qsTr("Refresh pull requests")
                onClicked: Shell.dispatch("pullRequestList.refresh")
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            FilterBox {
                name: "state"
                choices: [[qsTr("Open"), "open"], [qsTr("Closed"), "closed"], [qsTr("Merged"), "merged"], [qsTr("All states"), "all"]]
            }

            FilterBox {
                name: "involvement"
                choices: [[qsTr("Everyone's"), "all"], [qsTr("Reviewing"), "reviewing"], [qsTr("Authored"), "authored"]]
            }

            FilterBox {
                name: "draft"
                choices: [[qsTr("Drafts too"), ""], [qsTr("Drafts only"), "only"], [qsTr("Hide drafts"), "hide"]]
            }

            FilterBox {
                name: "review"
                choices: [[qsTr("Any review"), ""], [qsTr("Approved"), "approved"], [qsTr("Changes requested"), "changes-requested"], [qsTr("Review required"), "review-required"], [qsTr("No reviews"), "none"]]
            }

            FilterBox {
                name: "checks"
                choices: [[qsTr("Any checks"), ""], [qsTr("Passing"), "passing"], [qsTr("Failing"), "failing"]]
            }

            FilterBox {
                name: "projectKey"
                choices: [[qsTr("All projects"), ""]].concat((page.model ? page.model.projects : []).map(project => [project.label, project.key]))
            }

            FilterBox {
                visible: page.model !== null && page.model.environmentChoices.length > 1
                name: "environmentId"
                choices: [[qsTr("All servers"), ""]].concat((page.model ? page.model.environmentChoices : []).map(environment => [environment.label, environment.id]))
            }
        }

        Repeater {
            model: page.model ? page.model.problems : []

            delegate: Label {
                required property string modelData

                Layout.fillWidth: true
                text: modelData
                color: Theme.palette.color("warning", "#f59e0b")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        // The rows that did load stay; this reads the failed projects again.
        ShellButton {
            objectName: "pullRequestProblemsRetry"
            visible: page.items.length > 0 && page.model !== null && page.model.problems.length > 0
            text: qsTr("Retry")
            onClicked: Shell.dispatch("pullRequestList.refresh")
        }

        Label {
            Layout.fillWidth: true
            visible: page.model !== null && page.model.notice !== null
            text: page.model && page.model.notice ? page.model.notice.text : ""
            color: page.model && page.model.notice && page.model.notice.kind === "error" ? Theme.palette.color("error", "#f87171") : page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ColumnLayout {
            readonly property var message: page.model ? (page.model.error ?? page.model.empty) : null

            Layout.fillWidth: true
            Layout.topMargin: 48
            visible: page.items.length === 0
            spacing: 8

            Label {
                objectName: "pullRequestMessageTitle"
                Layout.alignment: Qt.AlignHCenter
                text: parent.message ? parent.message.title : (page.model && page.model.loading ? qsTr("Loading pull requests…") : "")
                color: page.foreground
                font.pixelSize: Math.round(15 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: 420
                visible: text.length > 0
                text: parent.message ? (parent.message.body ?? parent.message.message ?? "") : ""
                color: page.muted
                font.pixelSize: Math.round(13 * Theme.fontScale)
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
            }

            ShellButton {
                objectName: "pullRequestMessageAction"
                Layout.alignment: Qt.AlignHCenter
                visible: parent.message !== null
                text: parent.message && parent.message.action === "project.add" ? qsTr("Add project") : page.model && page.model.error ? qsTr("Retry") : qsTr("Check again")
                onClicked: parent.message.action === "project.add" ? Shell.dispatch("project.add") : Shell.dispatch("pullRequestList.refresh")
            }
        }

        // Takes the spare height while there are no rows, as the list does
        // once there are, so the header and filters stay at the top.
        Item {
            Layout.fillHeight: true
            visible: page.items.length === 0
        }

        ListView {
            id: list

            objectName: "pullRequestRows"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.items.length > 0
            clip: true
            model: page.items
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true

            delegate: Item {
                id: entry

                required property var modelData

                width: list.width
                height: modelData.header ? 32 : 52

                Label {
                    visible: entry.modelData.header
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    text: entry.modelData.header ? qsTr("%1  %2").arg(entry.modelData.label).arg(entry.modelData.count) : ""
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                Rectangle {
                    visible: !entry.modelData.header
                    anchors.fill: parent
                    radius: Math.min(Theme.radius, 6)
                    color: rowMouse.containsMouse ? Qt.alpha(Theme.palette.color("accentSurface", "#27272a"), 0.6) : "transparent"

                    MouseArea {
                        id: rowMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Shell.dispatch("pullRequestList.open", { key: entry.modelData.key })
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Label {
                                text: {
                                    const row = entry.modelData;
                                    if (row.header) return "";
                                    if (row.state === "merged") return qsTr("Merged");
                                    if (row.state === "closed") return qsTr("Closed");
                                    return row.isDraft ? qsTr("Draft") : qsTr("Open");
                                }
                                color: entry.modelData.state === "merged" ? Theme.palette.color("merged", "#a855f7") : entry.modelData.state === "closed" ? Theme.palette.color("error", "#f87171") : Theme.palette.color("success", "#22c55e")
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            Label {
                                text: entry.modelData.header ? "" : "#" + entry.modelData.number
                                color: page.muted
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                            }

                            Label {
                                Layout.fillWidth: true
                                text: entry.modelData.title ?? ""
                                color: page.foreground
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                                elide: Text.ElideRight
                            }

                            Label {
                                visible: !entry.modelData.header && entry.modelData.conflicting && entry.modelData.state === "open"
                                text: qsTr("Has conflicts")
                                color: Theme.palette.color("warning", "#f59e0b")
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            Label {
                                visible: !entry.modelData.header && (entry.modelData.additions > 0 || entry.modelData.deletions > 0)
                                text: visible ? "+%1 −%2".arg(entry.modelData.additions).arg(entry.modelData.deletions) : ""
                                color: page.muted
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            ShellButton {
                                subtle: true
                                iconName: "external-link"
                                Accessible.name: qsTr("Open on the host")
                                onClicked: Shell.dispatch("pullRequestList.openOnHost", { key: entry.modelData.key })
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            text: {
                                const row = entry.modelData;
                                if (row.header) return "";
                                const parts = [row.author, row.repository];
                                if (row.environmentLabel) parts.push(row.environmentLabel);
                                if (row.reviewDecision === "approved") parts.push(qsTr("Approved"));
                                else if (row.reviewDecision === "changes-requested") parts.push(qsTr("Changes requested"));
                                else if (row.reviewDecision === "review-required") parts.push(qsTr("Awaiting review"));
                                if (row.checksState === "failing") parts.push(qsTr("Checks failing"));
                                else if (row.checksState === "passing") parts.push(qsTr("Checks passing"));
                                return parts.concat(row.labels.slice(0, 3)).join(" · ");
                            }
                            color: page.muted
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
