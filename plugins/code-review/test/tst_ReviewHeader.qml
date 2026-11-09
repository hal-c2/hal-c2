// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/code-review/test
import QtQuick
import QtTest

Item {
    id: test

    width: 900
    height: 700

    // The plugin object a review thread's header gets, with the MC part faked: the
    // thread's review waits to be published, and `preview` says what would be posted.
    QtObject {
        id: plugin

        function watch(topic, callback, environment) {
            callback({
                "thread-1": {
                    key: "acme/api#13",
                    number: 13,
                    title: "Limits",
                    repository: "acme/api",
                    status: "waiting",
                    verdict: "comment",
                    version: "v1"
                }
            });
            return 1;
        }

        function unwatch(id) {
        }

        function call(method, input, callback, environment) {
            callback({
                version: "v1",
                verdict: "comment",
                body: "Two findings.",
                comments: []
            }, null);
        }
    }

    Loader {
        id: loader

        width: test.width
    }

    TestCase {
        name: "ReviewHeader"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/ReviewHeader.qml"), {
                plugin: plugin,
                thread: {
                    id: "thread-1",
                    environmentId: "local"
                }
            });
            tryVerify(() => loader.status === Loader.Ready && find("codeReviewPublish")?.visible === true);
        }

        // The confirmation takes the keyboard: Escape closes it, and focus goes back
        // to what opened it.
        function test_the_confirmation_takes_the_keyboard_and_escape_closes_it() {
            const publish = find("codeReviewPublish");
            publish.forceActiveFocus();
            mouseClick(publish);
            const confirmation = find("codeReviewConfirmPublish");
            tryVerify(() => confirmation.opened);
            tryVerify(() => confirmation.activeFocus, 1000, "the confirmation has no keyboard focus");

            keyClick(Qt.Key_Escape);
            tryVerify(() => !confirmation.visible, 1000, "Escape did not close the confirmation");
            tryVerify(() => publish.activeFocus, 1000, "focus did not go back to the publish button");
        }
    }
}
