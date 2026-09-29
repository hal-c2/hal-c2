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

        // The shell moves on to the most recent project's draft; home says nothing meanwhile.
        function test_with_projects_home_shows_nothing_while_the_draft_opens() {
            Shell.state = { sidebar: { projects: [{ key: "env:shop" }], localEnvironmentId: null }, landing: { failed: false } };
            const home = createTemporaryObject(homeComponent, root);
            verify(!findChild(home, "homeTitle").visible);
            verify(!findChild(home, "homeDetail").visible);
            verify(!findChild(home, "homeAction").visible);
        }

        // Starting the draft failed: the user is told and can try again.
        function test_a_draft_that_could_not_start_offers_to_try_again() {
            Shell.state = { sidebar: { projects: [{ key: "env:shop" }], localEnvironmentId: null }, landing: { failed: true } };
            const home = createTemporaryObject(homeComponent, root);
            compare(findChild(home, "homeTitle").text, "Couldn’t start a new thread");
            compare(findChild(home, "homeDetail").text, "The project is still available. Try opening the draft again.");
            const action = findChild(home, "homeAction");
            compare(action.text, "Try again");
            mouseClick(action);
            compare(Shell.dispatchedActions[0].action, "landing.retry");
        }

        function test_before_the_node_answers_home_waits() {
            const home = createTemporaryObject(homeComponent, root);
            compare(findChild(home, "homeTitle").text, "Waiting for the app…");
            verify(!findChild(home, "homeAction").visible);
        }
    }
}
