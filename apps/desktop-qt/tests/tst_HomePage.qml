import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/files/adding-projects.feature: home, with no thread chosen.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: homeComponent
        HomePage {
            width: 880
            height: 680
        }
    }

    TestCase {
        name: "HomePageTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        // A user with no projects is invited to add one.
        function test_a_user_with_no_projects_is_invited_to_add_one() {
            Shell.state = { sidebar: { projects: [], localEnvironmentId: null } };
            const home = createTemporaryObject(homeComponent, root);
            compare(findChild(home, "homeTitle").text, "What should we work on?");
            verify(findChild(home, "homeDetail").visible);
            const action = findChild(home, "homeAction");
            compare(action.text, "Add project");
            mouseClick(action);
            compare(Shell.dispatchedActions[0].action, "project.add");
        }

        function test_with_projects_home_offers_a_new_thread() {
            Shell.state = { sidebar: { projects: [{ key: "env:shop" }], localEnvironmentId: null } };
            const home = createTemporaryObject(homeComponent, root);
            verify(!findChild(home, "homeDetail").visible);
            const action = findChild(home, "homeAction");
            compare(action.text, "New thread");
            mouseClick(action);
            compare(Shell.dispatchedActions[0].action, "thread.new");
        }

        function test_before_the_node_answers_home_waits() {
            const home = createTemporaryObject(homeComponent, root);
            compare(findChild(home, "homeTitle").text, "Waiting for the app…");
            verify(!findChild(home, "homeAction").visible);
        }
    }
}
