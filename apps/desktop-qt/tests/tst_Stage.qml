import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The stage (features/desktop/stage.feature): right-panel tabs in the
// thread's centre, in one to four panes. Its strip, pane headers and empty
// panes ask RightPanelController for every change; a tab drags between the
// side panel and the stage; a body moves between them and is never remade;
// and the layout puts the timeline away under a line of the latest activity,
// or, in a narrow window, shows the conversation or the stage, one at a time.
Item {
    id: root
    width: 1200
    height: 760

    // The side panel and the stage, sharing their bodies as DefaultLayout has them.
    Component {
        id: pairComponent
        Item {
            property alias bodies: bodies
            property alias stage: stage
            property alias panel: panel
            width: 1100
            height: 600

            PanelBodies {
                id: bodies
            }

            Stage {
                id: stage
                bodies: bodies
                width: 560
                height: 600
            }

            RightPanel {
                id: panel
                bodies: bodies
                x: 600
                width: 500
                height: 600
            }
        }
    }

    // The thread's centre as DefaultLayout has it, on a thread.
    Component {
        id: areaComponent
        Item {
            property alias area: area
            width: 1000
            height: 700

            PanelBodies {
                id: bodies
            }

            ThreadArea {
                id: area
                anchors.fill: parent
                routeKind: "thread"
                bodies: bodies
            }
        }
    }

    // The thread's centre with the side panel beside it, as DefaultLayout has them.
    Component {
        id: centreComponent
        Item {
            property alias bodies: bodies
            property alias area: area
            property alias panel: panel
            width: 1200
            height: 700

            PanelBodies {
                id: bodies
            }

            ThreadArea {
                id: area
                width: 760
                height: 700
                routeKind: "thread"
                bodies: bodies
            }

            RightPanel {
                id: panel
                bodies: bodies
                x: 760
                width: 440
                height: 700
            }
        }
    }

    // A DiffSelection with nothing in it.
    Component {
        id: fakeDiff
        QtObject {
            property var choices: [{ value: -1, label: "Latest turn" }]
            property int selection: -1
            property int latestTurn: 3
            property string status: "empty"
            property string message: "No net changes in this selection."
            property bool wrap: false
            property bool ignoreWhitespace: false
            property bool canRevert: false
            property bool reverting: false
            property int revertTurn: 0
            property var model: null
        }
    }

    // The thread's timeline, as far as the stage's activity line reads it.
    Component {
        id: fakeTimeline
        ListModel {
            property string latest: "Ran the cart tests: 12 passed"
            property bool working: true
        }
    }

    // RightPanelController's state: `staged` tabs on the stage in `panes`,
    // the rest in the side panel.
    function panelState(options) {
        const staged = options.staged ?? [];
        const tabs = [
            { id: "diff", kind: "diff", title: "Diff" },
            { id: "files", kind: "files", title: "Files" }
        ].map(tab => Object.assign({}, tab, { dock: staged.includes(tab.id) ? "stage" : "panel" }));
        const docked = tabs.filter(tab => tab.dock === "panel").map(tab => tab.id);
        const panes = options.panes ?? (staged.length > 0 ? [staged[0]] : []);
        const open = options.open ?? docked.length > 0;
        const activeId = options.activeId ?? (docked[0] ?? "");
        return {
            threadKey: "env-a:thread-1",
            isOpen: open,
            activeId: activeId,
            width: 480,
            canAdd: { diff: true, files: true, agents: true, terminal: true },
            tabs: tabs,
            shownTabs: panes.filter(id => id.length > 0).concat(open && activeId.length > 0 ? [activeId] : []),
            stage: {
                tabs: tabs.filter(tab => tab.dock === "stage"),
                panes: panes,
                layout: options.layout ?? "single",
                focusedPane: options.focusedPane ?? 0,
                focus: options.focus ?? false,
                timeline: options.timeline ?? false,
                chatWidth: 0
            }
        };
    }

    function show(options) {
        Shell.state = Object.assign({}, Shell.state, { panel: panelState(options) });
    }

    TestCase {
        id: test
        name: "StageTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
            Panel.diff = null;
            Threads.reset();
        }

        function within(item, ancestor) {
            for (let at = item; at; at = at.parent) {
                if (at === ancestor)
                    return true;
            }
            return false;
        }

        // Moves a pressed pointer from `from` to `to` over `item` in steps,
        // letting each move's drag events through before the next.
        function drag(item, from, to) {
            for (let step = 1; step <= 10; ++step) {
                mouseMove(item, from.x + (to.x - from.x) * step / 10, from.y + (to.y - from.y) * step / 10);
                wait(0);
            }
        }

        function lastAction() {
            return Shell.dispatchedActions[Shell.dispatchedActions.length - 1] ?? null;
        }

        function test_theStripSwitchesTheLayout() {
            show({ staged: ["diff", "files"], panes: ["diff", "files"], layout: "columns" });
            const pair = createTemporaryObject(pairComponent, root);
            const columns = findChild(pair.stage, "stageLayout-columns");
            const grid = findChild(pair.stage, "stageLayout-grid");
            verify(columns.Accessible.checked);
            verify(!grid.Accessible.checked);
            mouseClick(grid);
            compare(lastAction().action, "stage.layout");
            compare(lastAction().payload.layout, "grid");
            verify(findChild(pair.stage, "stageColumnDivider").visible);
            verify(!findChild(pair.stage, "stageRowDivider").visible);
        }

        function test_aPaneHeaderDocksItsTabBackOrClosesIt() {
            show({ staged: ["diff"] });
            const pair = createTemporaryObject(pairComponent, root);
            mouseClick(findChild(pair.stage, "stagePaneDock-0"));
            compare(lastAction().action, "rightPanel.dock");
            compare(lastAction().payload.id, "diff");
            compare(lastAction().payload.dock, "panel");
            mouseClick(findChild(pair.stage, "stagePaneClose-0"));
            compare(lastAction().action, "rightPanel.close");
            compare(lastAction().payload.id, "diff");
            compare(findChild(pair.stage, "stageDismiss").Accessible.name, "Move every tab to the side panel");
        }

        function test_theFocusedPaneIsOutlinedOnlyAmongOthers() {
            show({ staged: ["diff", "files"], panes: ["diff", "files"], layout: "columns", focusedPane: 1 });
            const pair = createTemporaryObject(pairComponent, root);
            verify(findChild(pair.stage, "stagePaneOutline-1").visible);
            verify(!findChild(pair.stage, "stagePaneOutline-0").visible);
            const first = findChild(pair.stage, "stagePane-0");
            mouseClick(first, first.width / 2, first.height / 2);
            compare(lastAction().action, "stage.focusPane");
            compare(lastAction().payload.pane, 0);

            show({ staged: ["diff"] });
            verify(!findChild(pair.stage, "stagePaneOutline-0").visible, "one pane needs no outline");
        }

        // Scenario: An empty pane offers the stage's tabs.
        function test_anEmptyPaneOffersTheStagesTabs() {
            show({ staged: ["diff"], panes: ["diff", "", "", ""], layout: "grid" });
            const pair = createTemporaryObject(pairComponent, root);
            for (let pane = 1; pane < 4; ++pane) {
                const pick = findChild(pair.stage, "stagePanePick-" + pane + "-files");
                verify(pick && pick.visible, "pane " + pane + " offers Files");
                verify(!findChild(pair.stage, "stagePanePick-" + pane + "-diff"), "a tab a pane shows is not offered");
            }
            mouseClick(findChild(pair.stage, "stagePanePick-2-files"));
            compare(lastAction().action, "rightPanel.dock");
            compare(lastAction().payload.id, "files");
            compare(lastAction().payload.dock, "stage");
            compare(lastAction().payload.pane, 2);
        }

        // Scenario: A tab keeps what it shows when it moves. The body is the
        // same object in the side panel, on the stage and back.
        function test_aBodyMovesWithoutBeingRemade() {
            Panel.diff = createTemporaryObject(fakeDiff, root);
            show({ activeId: "diff" });
            const pair = createTemporaryObject(pairComponent, root);
            const body = findChild(pair.bodies, "panelBody-diff") ?? findChild(pair.panel, "panelBody-diff");
            verify(body);
            tryCompare(body, "status", Loader.Ready);
            const item = body.item;
            verify(within(body, pair.panel), "the side panel shows it");

            show({ staged: ["diff"], activeId: "files" });
            compare(body.parent, findChild(pair.stage, "stageBodySlot-0"));
            verify(!within(body, pair.panel));
            verify(body.visible);
            compare(body.item, item, "the stage borrows the same body");

            show({ activeId: "diff" });
            verify(within(body, pair.panel));
            verify(body.visible);
            compare(body.item, item, "and gives it back");
        }

        // A tab that drags still clicks: in the side panel's strip and the stage's.
        function test_aClickedTabShows() {
            show({ staged: ["diff"], activeId: "files" });
            const pair = createTemporaryObject(pairComponent, root);
            show({ staged: [], activeId: "diff" });
            const panelTab = findChild(pair.panel, "panelTab-files");
            tryVerify(() => panelTab.width > 0, 1000, "the side panel's tabs are laid out");
            mouseClick(panelTab);
            compare(lastAction().action, "rightPanel.activate");
            compare(lastAction().payload.id, "files");

            show({ staged: ["diff", "files"], panes: ["diff"], open: false });
            const stageTab = findChild(pair.stage, "stageTab-files");
            tryVerify(() => stageTab.width > 0, 1000, "the stage's tabs are laid out");
            mouseClick(stageTab);
            compare(lastAction().action, "stage.show");
            compare(lastAction().payload.id, "files");
        }

        // Scenario: Tabs drag between the side panel and the stage.
        function test_aTabDragsBetweenThePanelAndTheStage() {
            show({ staged: ["diff"], activeId: "files" });
            const pair = createTemporaryObject(pairComponent, root);
            const tab = findChild(pair.panel, "panelTab-files");
            const pane = findChild(pair.stage, "stagePane-0");
            verify(tab && pane);
            const from = tab.mapToItem(pair, tab.width / 2, tab.height / 2);
            const to = pane.mapToItem(pair, pane.width - 20, pane.height / 2);
            mousePress(pair, from.x, from.y);
            drag(pair, from, to);
            compare(pair.bodies.dragging, "files");
            verify(findChild(pair.stage, "stagePaneZone-0").visible, "the pane shows where the tab lands");
            mouseRelease(pair, to.x, to.y);
            compare(pair.bodies.dragging, "");
            tryVerify(() => lastAction()?.action === "rightPanel.dock");
            compare(lastAction().payload.id, "files");
            compare(lastAction().payload.dock, "stage");
            compare(lastAction().payload.pane, 0);
            compare(lastAction().payload.zone, "right", "the pane's right edge splits it");

            // The controller docks it; dragged by its pane's header, it goes back.
            show({ staged: ["diff", "files"], panes: ["diff", "files"], layout: "columns", open: true, activeId: "" });
            const header = findChild(pair.stage, "stagePaneDock-1").parent;
            tryVerify(() => header.width > 0, 5000, "the new pane is laid out");
            const start = header.mapToItem(pair, 40, header.height / 2);
            const panelAt = pair.panel.mapToItem(pair, pair.panel.width / 2, pair.panel.height / 2);
            mousePress(pair, start.x, start.y);
            drag(pair, start, panelAt);
            compare(pair.bodies.dragging, "files");
            mouseRelease(pair, panelAt.x, panelAt.y);
            tryVerify(() => lastAction()?.action === "rightPanel.dock" && lastAction().payload.dock === "panel");
            compare(lastAction().payload.id, "files");
        }

        // With nothing in the centre yet, a tab dragged onto the conversation
        // goes there.
        function test_aTabDragsIntoAnEmptyCentre() {
            show({ staged: [], activeId: "files" });
            const holder = createTemporaryObject(centreComponent, root);
            const drop = findChild(holder.area, "centreDrop");
            const tab = findChild(holder.panel, "panelTab-files");
            verify(drop && tab);
            verify(!drop.enabled, "the centre takes nothing until a tab drags");
            const from = tab.mapToItem(holder, tab.width / 2, tab.height / 2);
            const to = holder.area.mapToItem(holder, holder.area.width * 0.75, 200);
            mousePress(holder, from.x, from.y);
            drag(holder, from, to);
            compare(holder.bodies.dragging, "files");
            verify(drop.enabled && drop.containsDrag, "the centre shows it takes the tab");
            mouseRelease(holder, to.x, to.y);
            tryVerify(() => lastAction()?.action === "rightPanel.dock");
            compare(lastAction().payload.id, "files");
            compare(lastAction().payload.dock, "stage");
            verify(!drop.enabled);

            // Once the stage shows, its panes take drops instead.
            show({ staged: ["files"], activeId: "diff" });
            verify(findChild(holder.area, "stage").visible);
            const other = findChild(holder.panel, "panelTab-diff");
            const start = other.mapToItem(holder, other.width / 2, other.height / 2);
            mousePress(holder, start.x, start.y);
            drag(holder, start, to);
            compare(holder.bodies.dragging, "diff");
            verify(!drop.enabled);
            mouseRelease(holder, to.x, to.y);
        }

        // Scenario: The latest activity shows over the composer while the
        // timeline is away.
        function test_focusModeKeepsTheComposerUnderTheLatestActivity() {
            Threads.timeline = createTemporaryObject(fakeTimeline, root);
            Shell.state = Object.assign({}, Shell.state, {
                panel: panelState({ staged: ["diff"], focus: true, open: false })
            });
            const holder = createTemporaryObject(areaComponent, root);
            const area = holder.area;
            verify(!area.narrow);
            const centre = findChild(area, "routeView");
            const stage = findChild(area, "stage");
            const strip = findChild(area, "stageActivity");
            verify(!centre.visible, "the timeline is put away");
            verify(stage.visible);
            verify(strip.visible);
            compare(findChild(area, "stageActivityText").text, "Ran the cart tests: 12 passed");
            const stripAt = strip.mapToItem(area, 0, 0);
            const stageAt = stage.mapToItem(area, 0, 0);
            verify(stageAt.y + stage.height <= stripAt.y + 1, "the stage sits above the line");
            verify(stripAt.y + strip.height < area.height, "and the composer's room below it");

            Threads.timeline.latest = "Wrote src/cart.ts";
            compare(findChild(area, "stageActivityText").text, "Wrote src/cart.ts");

            mouseClick(strip);
            compare(lastAction().action, "stage.showTimeline");
            show({ staged: ["diff"], focus: true, timeline: true, open: false });
            verify(centre.visible, "the timeline shows again");
            verify(stage.visible, "under the stage's strip");
            verify(!strip.visible);
            verify(!findChild(area, "stageSplitter").visible);
        }

        // Scenario: The Timeline tab switches quickly between the timeline
        // and a tab (and the strip stays over the timeline).
        function test_theTimelineTabShowsTheTimelineUnderTheStrip() {
            Threads.timeline = createTemporaryObject(fakeTimeline, root);
            show({ staged: ["diff", "files"], panes: ["diff"], focus: true, open: false });
            const holder = createTemporaryObject(areaComponent, root);
            const area = holder.area;
            const centre = findChild(area, "routeView");
            const stage = findChild(area, "stage");
            const timelineTab = findChild(stage, "stageTimelineTab");
            const diffTab = findChild(stage, "stageTab-diff");
            const pane = findChild(stage, "stagePane-0");
            verify(!centre.visible);
            verify(!timelineTab.Accessible.selected);
            tryVerify(() => timelineTab.width > 0 && diffTab.width > 0, 1000, "the strip is laid out");
            verify(timelineTab.mapToItem(stage, 0, 0).x < diffTab.mapToItem(stage, 0, 0).x, "the strip starts with the Timeline");

            mouseClick(timelineTab);
            compare(lastAction().action, "stage.showTimeline");
            show({ staged: ["diff", "files"], panes: ["diff"], focus: true, timeline: true, open: false });
            verify(timelineTab.Accessible.selected);
            verify(centre.visible, "the timeline shows");
            verify(!pane.visible, "in place of the panes");
            compare(stage.width, area.width);
            tryCompare(stage, "height", stage.stripHeight);
            tryVerify(() => centre.mapToItem(area, 0, 0).y >= stage.height, 1000, "under the strip");
            verify(!findChild(area, "stageActivity").visible, "no line of the latest activity over the timeline");

            mouseClick(diffTab);
            compare(lastAction().action, "stage.show");
            compare(lastAction().payload.id, "diff");
            compare(lastAction().payload.focus, true, "across the centre, in place of the timeline");

            // Beside the conversation, a tab shows in the stage.
            show({ staged: ["diff", "files"], panes: ["diff"], open: false });
            verify(centre.visible && stage.visible);
            verify(!timelineTab.Accessible.selected);
            mouseClick(findChild(stage, "stageTab-files"));
            compare(lastAction().payload.id, "files");
            compare(lastAction().payload.focus, false);
        }

        // A layout that rounds the centre rounds the stage's corners on its
        // edge, and the panes stay clear of them.
        function test_aRoundedCentreRoundsTheStagesOuterCorners() {
            Threads.timeline = createTemporaryObject(fakeTimeline, root);
            Shell.state = Object.assign({}, Shell.state, {
                panel: panelState({ staged: ["diff"], open: false })
            });
            const holder = createTemporaryObject(areaComponent, root);
            const area = holder.area;
            area.radius = 12;
            const stage = findChild(area, "stage");
            verify(stage.visible);
            compare(stage.topLeftRadius, 0, "beside the conversation, its left edge is inside");
            compare(stage.topRightRadius, 12);
            compare(stage.bottomRightRadius, 12);
            const pane = findChild(stage, "stagePane-0");
            tryVerify(() => pane.height > 0, 1000, "the panes are laid out");
            const paneBottom = pane.mapToItem(stage, 0, pane.height).y;
            verify(paneBottom <= stage.height - 12, "the pane ends above the rounded corner");

            Shell.state = Object.assign({}, Shell.state, {
                panel: panelState({ staged: ["diff"], focus: true, open: false })
            });
            compare(stage.topLeftRadius, 12, "over the conversation, its top edge is the centre's");
            compare(stage.topRightRadius, 12);
            compare(stage.bottomRightRadius, 0);
        }

        // Scenario: A narrow window shows the conversation or the stage, one at a time.
        function test_aNarrowWindowShowsOneAtATime() {
            Threads.timeline = createTemporaryObject(fakeTimeline, root);
            Shell.state = Object.assign({}, Shell.state, {
                panel: panelState({ staged: ["diff"], open: false })
            });
            const holder = createTemporaryObject(areaComponent, root, { width: 700 });
            const area = holder.area;
            verify(area.narrow);
            const centre = findChild(area, "routeView");
            const stage = findChild(area, "stage");
            const strip = findChild(area, "stageActivity");
            verify(centre.visible);
            verify(stage.visible, "no room beside the conversation: the strip over it");
            compare(stage.width, area.width);
            compare(stage.height, stage.stripHeight);
            verify(findChild(stage, "stageTimelineTab").Accessible.selected);
            verify(!findChild(stage, "stageToggleBeside").visible, "nothing offers what does not fit");
            verify(!strip.visible);
            verify(!findChild(area, "stageSplitter").visible);

            const diffTab = findChild(stage, "stageTab-diff");
            tryVerify(() => diffTab.width > 0, 1000, "the strip is laid out");
            mouseClick(diffTab);
            compare(lastAction().action, "stage.show");
            compare(lastAction().payload.focus, true);
            show({ staged: ["diff"], focus: true, open: false });
            verify(!centre.visible);
            tryVerify(() => stage.height > stage.stripHeight, 1000, "the stage shows above the composer");
            compare(stage.width, area.width);
            verify(strip.visible, "and the line offers the timeline back");
        }
    }
}
