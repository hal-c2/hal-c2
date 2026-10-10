import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/connections/cluster.feature: the Cluster section draws what
// ClusterController publishes; a session without administrative access is
// told so, and cannot invite or join.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: clusterComponent
        ClusterSettings {
            width: 880
            height: 680
        }
    }

    function everyText(item, out) {
        if (item.text !== undefined) out.push(String(item.text));
        for (let i = 0; i < item.children.length; ++i) everyText(item.children[i], out);
        return out;
    }

    TestCase {
        name: "ClusterSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_session_without_admin_access_is_told_and_cannot_invite_or_join() {
            Shell.state = { cluster: { busy: false, status: null, error: null, needsAdmin: true, invite: null, notice: null } };
            const page = createTemporaryObject(clusterComponent, root);
            compare(findChild(page, "settingsBreadcrumb").text, "Settings / Cluster");
            verify(findChild(page, "clusterNeedsAdmin").visible);
            verify(!findChild(page, "clusterInvite").enabled);
            verify(!findChild(page, "clusterInviteTailscale").enabled);
            verify(!findChild(page, "clusterJoin").enabled);
            verify(!findChild(page, "clusterJoinLink").enabled);
            verify(!everyText(page, []).some(text => /access:\w+ is required/.test(text)));
        }

        function test_an_administrator_can_invite_and_join() {
            Shell.state = { cluster: { busy: false, status: null, error: null, needsAdmin: false, invite: null, notice: null } };
            const page = createTemporaryObject(clusterComponent, root);
            verify(!findChild(page, "clusterNeedsAdmin").visible);
            verify(findChild(page, "clusterInvite").enabled);
            verify(findChild(page, "clusterJoin").enabled);
        }
    }
}
