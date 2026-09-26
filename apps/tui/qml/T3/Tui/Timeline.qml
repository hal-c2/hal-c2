import OpenTUI

// The conversation's rows (Shell.state.timeline): pre-styled lines, each with
// the action a click dispatches. User messages sit boxed on the right. The view
// sticks to the newest row while the latest page is mounted; the host asks for
// jumps through `timelineScroll`.
ScrollView {
    id: scroller
    objectName: "timeline"
    readonly property var timeline: Shell.state.timeline
    readonly property var scrollRequest: Shell.state.timelineScroll ?? null
    readonly property int scrollSeq: scrollRequest ? scrollRequest.seq : 0
    onScrollSeqChanged: {
        if (scrollRequest.to === "top") scroller.scrollToTop()
        else if (scrollRequest.to === "bottom") scroller.scrollToBottom()
        else scroller.scrollBy(scrollRequest.by)
    }

    stickyScroll: timeline.showingLatest
    stickyStart: "bottom"
    flexGrow: 1
    flexShrink: 1

    Item {
        id: column
        objectName: "timelineColumn"
        flexDirection: "column"
        flexShrink: 0
        alignSelf: "center"
        width: scroller.timeline.width

        Text {
            visible: scroller.timeline.kind === "none"
            text: scroller.timeline.emptyHint
            color: Theme.colors.faint
        }

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

                // A Rectangle's border turns on with its style, so only boxed
                // items get one; each side mounts lines only when it is used.
                Rectangle {
                    visible: entry.entryData.boxed
                    width: entry.entryData.width
                    flexDirection: "column"
                    flexShrink: 0
                    border.width: 1
                    border.style: "rounded"
                    border.color: Theme.colors.faint
                    paddingX: 1

                    Repeater {
                        model: entry.entryData.boxed ? entry.entryData.lines : []
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
            marginTop: 1
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
                onMouseDown: Shell.dispatch("plan.implement")
            }
        }

        WorkingIndicator {}
    }
}
