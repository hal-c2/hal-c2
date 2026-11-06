import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/connections/connection-health.feature: Settings > Connections pairs
// with other MCs by a pasted link, says why one is not connected, and offers
// to retry or remove it; a pairing that fails says why.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: groupComponent
        SavedEnvironmentsGroup {
            width: 880
        }
    }

    function entry(id, state, message) {
        return { id: id, label: id === "studio" ? "Studio" : id, origin: "http://" + id + ".local:3773", state: state, message: message };
    }

    function everyText(item, out) {
        if (item.visible === false) return out;
        if (item.text !== undefined) out.push(String(item.text));
        for (let i = 0; i < item.children.length; ++i) everyText(item.children[i], out);
        return out;
    }

    TestCase {
        name: "SavedEnvironmentsGroupTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_pasted_link_pairs_and_the_field_clears() {
            Shell.state = { savedEnvironments: { environments: [], pairing: false, error: "", damaged: "" } };
            const group = createTemporaryObject(groupComponent, root);
            const link = findChild(group, "savedEnvironmentsLink");
            const pair = findChild(group, "savedEnvironmentsPair");
            verify(!pair.enabled, "nothing to pair with yet");
            link.text = "  http://studio.local:3773/pair#token=abc  ";
            verify(pair.enabled);
            mouseClick(pair);
            compare(Shell.dispatchedActions.length, 1);
            compare(Shell.dispatchedActions[0].action, "savedEnvironments.pair");
            compare(Shell.dispatchedActions[0].payload.link, "http://studio.local:3773/pair#token=abc");
            compare(link.text, "");
        }

        function test_a_failed_pairing_says_why() {
            Shell.state = { savedEnvironments: { environments: [], pairing: false, error: "Studio could not be saved: The system's secure storage is not available.", damaged: "" } };
            const group = createTemporaryObject(groupComponent, root);
            const error = findChild(group, "savedEnvironmentsError");
            verify(error.visible);
            compare(error.text, "Studio could not be saved: The system's secure storage is not available.");
        }

        function test_an_environment_that_is_not_connected_says_why_and_can_be_retried_or_removed() {
            Shell.state = { savedEnvironments: { environments: [entry("studio", "blocked", "Connection credential studio is unavailable.")], pairing: false, error: "", damaged: "" } };
            const group = createTemporaryObject(groupComponent, root);
            const texts = everyText(group, []);
            verify(texts.indexOf("Studio") >= 0, texts.join(" | "));
            verify(texts.indexOf("Connection credential studio is unavailable.") >= 0, texts.join(" | "));
            verify(texts.indexOf("Retry") >= 0, texts.join(" | "));
            verify(texts.indexOf("Remove") >= 0, texts.join(" | "));
        }

        function test_a_connected_environment_offers_remove_only() {
            Shell.state = { savedEnvironments: { environments: [entry("studio", "connected", "")], pairing: false, error: "", damaged: "" } };
            const group = createTemporaryObject(groupComponent, root);
            const texts = everyText(group, []);
            verify(texts.indexOf("Connected") >= 0, texts.join(" | "));
            verify(texts.indexOf("Retry") < 0, texts.join(" | "));
            verify(texts.indexOf("Remove") >= 0, texts.join(" | "));
        }
    }
}
