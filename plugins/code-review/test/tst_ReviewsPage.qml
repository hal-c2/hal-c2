// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/code-review/test
import QtQuick
import QtTest

Item {
    id: test

    width: 1200
    height: 800

    // The plugin object the page gets, with the MC part faked: `reviews` is what the
    // topic last said, and each call is recorded.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var calls: []
        property var listener: null

        function watch(topic, callback, environment) {
            listener = callback;
            return 1;
        }

        function unwatch(id) {
        }

        function call(method, input, callback, environment) {
            calls = calls.concat([{
                    method: method,
                    input: input
                }]);
            callback({}, null);
        }

        function openThread(id, environment) {
        }

        // The MC's `reviews` topic says #13 by stranger is ready at `head`.
        function publish(head) {
            listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [{
                        key: "acme/api#13",
                        number: 13,
                        title: "Limits",
                        repository: "acme/api",
                        author: "stranger",
                        status: "ready",
                        headSha: head,
                        approved: null,
                        untrusted: "Opened by stranger, who is not a member or collaborator of the repository."
                    }]
            });
        }
    }

    Loader {
        id: loader

        anchors.fill: parent
    }

    TestCase {
        name: "ReviewsPage"
        when: windowShown

        readonly property string first: "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        readonly property string second: "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            plugin.calls = [];
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/ReviewsPage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.listener !== null);
            plugin.publish(first);
            tryVerify(() => find("codeReviewApprove")?.visible === true);
        }

        // Clicks the approve button once the layout has made room for it.
        function clickApprove() {
            const detail = find("codeReviewDetail");
            const button = find("codeReviewApprove");
            tryVerify(() => button.mapToItem(detail.contentItem, 0, button.height).y <= detail.contentHeight);
            mouseClick(button);
        }

        function approvals() {
            return plugin.calls.filter(each => each.method === "approve");
        }

        function test_approves_the_commit_shown() {
            compare(find("codeReviewApproveCommit").text, "At commit 1111111");
            clickApprove();
            compare(approvals().length, 1);
            compare(approvals()[0].input.headSha, first);
        }

        // A push while the page is open is shown, and taken in before it is approved.
        function test_a_push_since_the_page_opened_is_not_approved_unseen() {
            plugin.publish(second);
            tryCompare(find("codeReviewApproveCommit"), "text", "Pushed since you opened it: now at 2222222, not 1111111");
            clickApprove();
            compare(approvals().length, 0, "a click on the moved head approved it unseen");

            tryCompare(find("codeReviewApproveCommit"), "text", "At commit 2222222");
            clickApprove();
            compare(approvals().length, 1);
            compare(approvals()[0].input.headSha, second);
        }
    }
}
