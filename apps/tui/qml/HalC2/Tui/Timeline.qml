import OpenTUI

// The conversation's rows (Shell.state.timeline): pre-styled lines, each with
// the action a click dispatches. User messages sit in an accent bubble on the
// right; a collapsed one clips its body to a fixed number of rows. The view
// sticks to the newest row while the latest page is mounted; the host asks for
// jumps through `timelineScroll`.
ScrollView {
    id: scroller
    objectName: "timeline"
    readonly property var timeline: Shell.state.timeline
    readonly property var scrollRequest: Shell.state.timelineScroll ?? null
    readonly property int scrollSeq: scrollRequest ? scrollRequest.seq : 0
    onScrollSeqChanged: {
        // A jump the host asked for wins over keeping the row being read in place.
        heightBefore = -1
        if (scrollRequest.to === "top") scroller.scrollToTop()
        else if (scrollRequest.to === "bottom") scroller.scrollToBottom()
        else scroller.scrollBy(scrollRequest.by)
    }

    // Where the user is, for the "Scroll to end" offer under the timeline.
    readonly property bool awayFromEnd: timeline.kind === "thread"
        && (!timeline.showingLatest || contentHeight - layoutHeight - contentY > 1)

    // A thread opened (or another one chosen) shows its newest output once its rows
    // arrive, however far the last one was scrolled; the page key says which thread.
    readonly property var pageKey: Shell.state.page.key ?? null
    property bool opening: true
    onPageKeyChanged: opening = true
    onTimelineChanged: if (opening && timeline.items.length > 0) settleOpening()

    // Rows mount over a few frames: every height change while opening goes to the
    // bottom again, and the opening ends one loop turn after the last of them.
    function settleOpening() {
        heightBefore = -1
        scrollToBottom()
        Qt.callLater(function () { scroller.opening = false })
    }

    // Earlier turns that land above the row being read push it down; the view
    // follows by the height they added, so that row stays where it was.
    property string firstKey: ""
    property real heightBefore: -1
    readonly property string headKey: {
        const items = timeline.items
        for (let i = 0; i < items.length; i++) {
            if (!items[i].key.startsWith("pager:")) return items[i].key
        }
        return ""
    }
    onHeadKeyChanged: {
        // Earlier rows arrived only if the old head is still in the list: when the
        // window slides along a growing thread the old head has left it.
        heightBefore = -1 // a pending offset belongs to the previous head
        const prepended = firstKey !== "" && headKey !== "" && headKey !== firstKey && !opening
            && timeline.items.some(item => item.key === firstKey)
        firstKey = headKey
        if (prepended && contentHeight - layoutHeight - contentY > 1) {
            heightBefore = contentHeight
        }
    }

    onContentHeightChanged: {
        if (opening && timeline.items.length > 0) {
            settleOpening()
        } else if (heightBefore >= 0) {
            const added = contentHeight - heightBefore
            heightBefore = -1
            if (added > 0) scrollBy(added)
        }
        askForEarlier()
    }
    onLayoutHeightChanged: askForEarlier()

    // A timeline that leaves room in the view loads the turns before it by itself.
    function askForEarlier() {
        if (timeline.canLoadEarlier && contentHeight <= layoutHeight) {
            Qt.callLater(Shell.dispatch, "timeline.showOlder")
        }
    }

    stickyScroll: timeline.showingLatest
    stickyStart: "bottom"
    // Like the OpenTUI client's fixed body height: the timeline takes what the
    // composer leaves. A content-sized basis keeps a resize's old height and
    // pushes the composer off screen.
    flexGrow: 1
    flexShrink: 1
    flexBasis: 0

    Item {
        id: column
        objectName: "timelineColumn"
        flexDirection: "column"
        flexShrink: 0
        alignSelf: "center"
        width: scroller.timeline.width

        Repeater {
            model: scroller.timeline.items
            delegate: Item {
                id: entry
                readonly property var entryData: modelData
                objectName: "timelineItem-" + entryData.key
                flexDirection: "row"
                flexShrink: 0
                justifyContent: entryData.align === "right" ? "flex-end" : "flex-start"
                marginTop: entryData.marginTop
                marginBottom: entryData.marginBottom

                // A Rectangle's border turns on with its style, so only boxed
                // items get one; each side mounts lines only when it is used.
                Rectangle {
                    id: bubble
                    visible: entry.entryData.boxed
                    width: entry.entryData.width
                    flexDirection: "column"
                    flexShrink: 0
                    border.width: 1
                    border.style: "rounded"
                    border.color: Theme.colors.accent
                    paddingX: 1

                    readonly property var clip: entry.entryData.boxed ? entry.entryData.clip : null
                    readonly property var lines: entry.entryData.boxed ? entry.entryData.lines : []

                    Repeater {
                        model: bubble.clip ? bubble.lines.slice(0, bubble.clip.from) : bubble.lines
                        delegate: TimelineLine { line: modelData }
                    }
                    Item {
                        visible: bubble.clip !== null
                        flexDirection: "column"
                        flexShrink: 0
                        height: bubble.clip ? bubble.clip.rows : 0
                        overflow: "hidden"
                        Repeater {
                            model: bubble.clip ? bubble.lines.slice(bubble.clip.from, bubble.clip.to) : []
                            delegate: TimelineLine { line: modelData }
                        }
                    }
                    Repeater {
                        model: bubble.clip ? bubble.lines.slice(bubble.clip.to) : []
                        delegate: TimelineLine { line: modelData }
                    }
                }
                Item {
                    visible: !entry.entryData.boxed
                    width: entry.entryData.width
                    flexDirection: "column"
                    flexShrink: 0

                    Repeater {
                        model: entry.entryData.boxed ? [] : entry.entryData.lines
                        delegate: TimelineLine { line: modelData }
                    }
                }
            }
        }

        Rectangle {
            id: planCard
            objectName: "planCard"
            readonly property var plan: scroller.timeline.plan
            visible: plan !== null
            flexDirection: "column"
            flexShrink: 0
            marginBottom: 1
            border.width: 1
            border.style: "rounded"
            border.color: Theme.colors.accent
            paddingX: 1

            Text { text: planCard.plan ? planCard.plan.title : "" }
            Repeater {
                model: planCard.plan ? planCard.plan.lines : []
                delegate: Text { wrapMode: "word"; text: modelData }
            }
            Text {
                text: planCard.plan ? planCard.plan.hint : ""
                color: Theme.colors.dim
            }
        }

        WorkingIndicator {}
    }
}
