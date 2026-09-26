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
        if (scrollRequest.to === "top") scroller.scrollToTop()
        else if (scrollRequest.to === "bottom") scroller.scrollToBottom()
        else scroller.scrollBy(scrollRequest.by)
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
