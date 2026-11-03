import QtQuick
import QtTest
import "../qml/HalC2/Bricks"

// What the user sees of an agent in a browser tab (AgentCue.qml): a badge
// while it acts, its pointer at the page point it acted on, and a click's
// ripple only when motion is allowed.
Item {
    width: 800
    height: 600

    AgentCue {
        id: cue

        anchors.fill: parent
    }

    TestCase {
        name: "AgentCue"
        when: windowShown

        function find(name) {
            return findChild(cue, name);
        }

        function init() {
            cue.entry = null;
            cue.pageScale = 1;
            cue.reduceMotion = false;
        }

        function test_quietWithoutAnAgent() {
            verify(!find("agentCueBadge").visible);
            verify(!find("agentCuePointer").visible);
        }

        function test_badgeWhileActing() {
            cue.entry = { label: "Agent is using this tab", operation: "click", pointer: { x: 100, y: 40 } };
            verify(find("agentCueBadge").visible);
            cue.entry = { operation: "click", pointer: { x: 100, y: 40 } };
            verify(!find("agentCueBadge").visible);
            verify(find("agentCuePointer").visible);
        }

        function test_pointerAtThePagePoint() {
            cue.reduceMotion = true;
            cue.pageScale = 2;
            cue.entry = { label: "Clicking", operation: "click", pointer: { x: 100, y: 40 } };
            const pointer = find("agentCuePointer");
            compare(pointer.x + pointer.width / 2, 200);
            compare(pointer.y + pointer.height / 2, 80);
        }

        function test_userInControlDimsThePointer() {
            cue.reduceMotion = true;
            cue.entry = { operation: "click", pointer: { x: 10, y: 10 }, userInControl: true };
            compare(find("agentCuePointer").opacity, 0.25);
        }

        function test_rippleOnlyWithMotion() {
            tryCompare(find("agentCueRipple"), "opacity", 0, 1000);
            cue.reduceMotion = true;
            cue.entry = { label: "Clicking", operation: "click", pointer: { x: 10, y: 10 } };
            compare(find("agentCueRipple").opacity, 0);
            cue.reduceMotion = false;
            cue.entry = { label: "Clicking", operation: "click", pointer: { x: 50, y: 50 } };
            tryVerify(() => find("agentCueRipple").opacity > 0, 200);
        }
    }
}
