// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/code-review/test
import QtQuick
import QtTest
import HalC2.Shell

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

    // A review of `number` in `status` for the topic.
    function review(number, status, title, branch) {
        return {
            key: "acme/api#" + number,
            number: number,
            title: title,
            repository: "acme/api",
            author: "octocat",
            headBranch: branch,
            baseBranch: "main",
            status: status,
            headSha: "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            comments: []
        };
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

        // The list narrows to what matches every word, once typing pauses.
        function test_search_narrows_the_list() {
            plugin.listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [review(12, "running", "Add rate limits", "feature/limits"), review(83, "queued", "Cache the session", "fix/cache"), review(830, "failed", "Bump the parser", "chore/parser")]
            });
            const list = find("codeReviewList");
            tryCompare(list, "count", 3);
            const search = find("codeReviewSearch");
            search.text = "#83";
            tryCompare(list, "count", 1);
            compare(list.model[0].number, 83, "a number matches only that pull request");
            search.text = "cache SESSION";
            tryCompare(list, "count", 1);
            compare(list.model[0].number, 83);
            search.text = "feature/limits";
            tryVerify(() => list.count === 1 && list.model[0].number === 12, 1000, "a branch matches");
            search.text = "83";
            tryVerify(() => list.count === 1 && list.model[0].number === 83, 1000, "a bare number is its pull request, not one whose number holds it");
            // A bare number also finds a branch or title that names it.
            search.text = "1683";
            tryCompare(list, "count", 0);
            plugin.listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [review(12, "running", "Add rate limits", "feature/limits"), review(83, "queued", "Cache the session", "fix/cache"), review(830, "failed", "Bump the parser", "fix/1683-resume")]
            });
            tryVerify(() => list.count === 1 && list.model[0].number === 830, 1000, "a bare number finds a branch naming it");
            search.text = "nothing like it";
            tryCompare(list, "count", 0);
            search.text = "";
            tryCompare(list, "count", 3);
        }

        // A pause says when it ends in the user's time, and can be ended now.
        function test_a_paused_queue_resumes_now() {
            const until = "2026-11-22T19:00:00Z";
            plugin.listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                problem: "Reviews are paused: the agent hit its usage limit.",
                pausedUntil: until,
                reviews: [review(83, "queued", "Cache the session", "fix/cache")]
            });
            const line = find("codeReviewProblem:local");
            tryVerify(() => line.visible && line.text.includes("They start again at"));
            verify(!line.text.includes("2026-11-22T19"), line.text);
            const resume = find("codeReviewResume:local");
            tryVerify(() => resume.visible);
            mouseClick(resume);
            compare(plugin.calls.filter(each => each.method === "resume").length, 1);
        }

        // A queued review can be started now.
        function test_a_queued_review_starts_now() {
            plugin.listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [review(83, "queued", "Cache the session", "fix/cache")]
            });
            const now = find("codeReviewRetry");
            tryVerify(() => now.visible && now.text === "Review now");
            // Once the layout has made room for it, as for Approve.
            tryVerify(() => now.width > 0 && now.mapToItem(find("codeReviewDetail").contentItem, 0, now.height).y <= find("codeReviewDetail").contentHeight);
            mouseClick(now);
            const asked = plugin.calls.filter(each => each.method === "retry");
            compare(asked.length, 1);
            compare(asked[0].input.key, "acme/api#83");
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

        // Ctrl-clicks `word` in the Markdown brick `markdown`, as the user opens a link.
        function ctrlClickWord(markdown, word) {
            const prose = findChild(markdown, "markdownProse");
            verify(prose, "the text is drawn as Markdown");
            tryVerify(() => prose.visible && prose.width > 0);
            const at = prose.getText(0, prose.length).indexOf(word);
            verify(at >= 0, "\"" + word + "\" is shown");
            const box = prose.positionToRectangle(at + 1);
            mouseClick(prose, box.x + 1, box.y + box.height / 2, Qt.LeftButton, Qt.ControlModifier);
        }

        // What the review agent wrote about a pull request anyone can open shows its
        // markup as text and loads nothing, and its links, like the pull request's
        // own, go to Shell.openWebLink, which opens only web addresses.
        function test_review_text_shows_its_markup_and_opens_links_only_on_the_web() {
            Shell.reset();
            plugin.listener({
                watching: ["acme/api"],
                unwatched: [],
                activation: "selective",
                reviews: [{
                        key: "acme/api#13",
                        number: 13,
                        title: "Limits",
                        repository: "acme/api",
                        author: "stranger",
                        status: "waiting",
                        headSha: first,
                        verdict: "comment",
                        version: "v1",
                        url: "https://github.com/acme/api/pull/13",
                        summary: "Read [the guide](https://example.com/guide) <img src=\"https://tracker.example/s.png\">",
                        comments: [{
                                id: "c1",
                                path: "src/limits.ts",
                                line: 12,
                                body: "See [hosts](file:///etc/hosts) <img src=\"https://tracker.example/c.png\">"
                            }]
                    }]
            });
            const summary = find("codeReviewSummary");
            tryVerify(() => summary?.visible === true);
            const summaryProse = findChild(summary, "markdownProse");
            verify(!/<img/i.test(summaryProse.text), "nothing in the summary loads: " + summaryProse.text);
            verify(summaryProse.getText(0, summaryProse.length).includes("<img src=\"https://tracker.example/s.png\">"), "its markup shows as text");
            ctrlClickWord(summary, "guide");
            compare(Shell.webLinks, ["https://example.com/guide"]);

            const body = find("codeReviewCommentBody");
            verify(!/<img/i.test(findChild(body, "markdownProse").text), "nothing in a comment loads");
            ctrlClickWord(body, "hosts");
            compare(Shell.webLinks, ["https://example.com/guide", "file:///etc/hosts"]);

            clickShown("codeReviewOpenOnGitHub");
            compare(Shell.webLinks, ["https://example.com/guide", "file:///etc/hosts", "https://github.com/acme/api/pull/13"]);
            compare(Shell.openedExternally, []);
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
