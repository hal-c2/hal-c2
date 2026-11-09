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
        // What `preview` answers: the post publishing would make.
        property var preview: ({})

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
            callback(method === "preview" ? preview : {}, null);
        }

        function openThread(id, environment) {
        }

        // The MC's `reviews` topic says #13 by stranger is ready at `head`, held back
        // as `limited` says if it is.
        function publish(head, limited) {
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
                        approved: limited ? head : null,
                        limited: limited ?? null,
                        untrusted: "Opened by stranger, who is not a member or collaborator of the repository."
                    }]
            });
        }

        // #13 by stranger, `status` at `head`, with the user's approval of `approved`.
        function publishApproved(status, head, approved) {
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
                        status: status,
                        headSha: head,
                        approved: approved,
                        untrusted: "Opened by stranger, who is not a member or collaborator of the repository."
                    }]
            });
        }

        // #13 waiting to be published at findings `version`, with the agent's verdict.
        function publishWaiting(version) {
            listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [{
                        key: "acme/api#13",
                        number: 13,
                        title: "Limits",
                        repository: "acme/api",
                        author: "octocat",
                        status: "waiting",
                        headSha: "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        verdict: "approve",
                        version: version,
                        comments: []
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
            plugin.preview = {};
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

        // A review held for a machine out of reach waits for the machine, not a time.
        function test_a_review_held_for_a_machine_out_of_reach_names_no_time() {
            plugin.publish(first, {
                reason: "laptop did not hear of this review starting.",
                until: null,
                apart: ["hal_c2@laptop.hal-c2"]
            });
            tryCompare(find("codeReviewProblem"), "text", "Held back: laptop did not hear of this review starting.");
        }

        function asked(method) {
            return plugin.calls.filter(each => each.method === method);
        }

        // Clicks `name` once the layout has made room for it.
        function clickShown(name) {
            const detail = find("codeReviewDetail");
            tryVerify(() => find(name)?.visible === true);
            const button = find(name);
            // The row places a button shown just now once it is polished.
            waitForItemPolished(button.parent);
            tryVerify(() => button.mapToItem(detail.contentItem, 0, button.height).y <= detail.contentHeight);
            mouseClick(button);
        }

        // What is posted is what the user confirmed: the post the MC read, its verdict
        // too, which the settings may have made a comment where the agent approved.
        function test_publishing_shows_and_sends_the_verdict_it_posts_with() {
            plugin.preview = {
                version: "v1",
                verdict: "comment",
                body: "Looks right.",
                comments: []
            };
            plugin.publishWaiting("v1");
            clickShown("codeReviewPublish");
            compare(asked("preview").length, 1);
            compare(asked("publish").length, 0, "published before the user confirmed");
            tryCompare(find("codeReviewPublishVerdict"), "text", "Posted as: Comment");

            clickShown("codeReviewPublishConfirm");
            compare(asked("publish").length, 1);
            compare(asked("publish")[0].input.version, "v1");
            compare(asked("publish")[0].input.verdict, "comment");
        }

        // A post read of other findings than shown is not confirmed: it is read again.
        function test_a_review_changed_while_confirming_is_read_again() {
            plugin.preview = {
                version: "v1",
                verdict: "approve",
                body: "",
                comments: []
            };
            plugin.publishWaiting("v1");
            clickShown("codeReviewPublish");
            tryCompare(find("codeReviewPublishVerdict"), "text", "Posted as: Approve");
            plugin.preview = {
                version: "v2",
                verdict: "approve",
                body: "",
                comments: []
            };
            plugin.publishWaiting("v2");
            tryVerify(() => asked("preview").length === 2);
            clickShown("codeReviewPublishConfirm");
            compare(asked("publish")[0].input.version, "v2");
        }

        // An approval kept of another commit than the head can still be taken back.
        function test_an_approval_of_an_older_commit_can_be_withdrawn() {
            plugin.publishApproved("queued", second, first);
            clickShown("codeReviewUnapprove");
            compare(asked("unapprove").length, 1);
            compare(asked("unapprove")[0].input.key, "acme/api#13");
        }
    }
}
