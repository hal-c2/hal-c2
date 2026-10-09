import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

Item {
    id: root
    width: 900
    height: 700

    Component {
        id: pageComponent
        PullRequestsPage {
            width: 880
            height: 680
        }
    }

    function row(number, group) {
        return {
            key: "env-local:github.com:acme/shop#" + number,
            group: group,
            environmentId: "env-local",
            environmentLabel: "",
            projectTitle: "acme/shop",
            repository: "acme/shop",
            number: number,
            title: "Fix " + number,
            url: "https://github.com/acme/shop/pull/" + number,
            state: "open",
            isDraft: false,
            author: "octocat",
            headBranch: "topic",
            baseBranch: "main",
            updatedAt: "2026-09-20T10:00:00Z",
            reviewDecision: "",
            checksState: "failing",
            conflicting: false,
            additions: 3,
            deletions: 1,
            labels: []
        };
    }

    function list(fields) {
        return Object.assign({
            open: true,
            loading: false,
            filters: { state: "open", involvement: "all", draft: "", review: "", checks: "", query: "", environmentId: "", projectKey: "" },
            filtered: false,
            groups: [],
            count: 0,
            environments: [],
            environmentChoices: [{ id: "env-local", label: "desk" }],
            problems: [],
            empty: null,
            error: null,
            projects: [{ key: "env-local:acme/shop", label: "acme/shop" }],
            notice: null
        }, fields);
    }

    TestCase {
        name: "PullRequestsPageTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_rowsOpenTheirThread() {
            Shell.state = { pullRequestList: list({ groups: [{ id: "others", label: "Others", rows: [row(12, "others")] }], count: 1 }) };
            const page = createTemporaryObject(pageComponent, root);
            const view = findChild(page, "pullRequestRows");
            tryCompare(view, "count", 2, 1000, "a header and the row");
            tryVerify(() => view.itemAtIndex(1) !== null, 1000, "the row is drawn");
            mouseClick(view.itemAtIndex(1), 40, 10);
            tryCompare(Shell, "dispatchCount", 1);
            compare(Shell.dispatchedActions[0].action, "pullRequestList.open");
            compare(Shell.dispatchedActions[0].payload.key, "env-local:github.com:acme/shop#12");
        }

        function test_loadingKeepsTheHeaderAndFiltersInPlace() {
            Shell.state = { pullRequestList: list({ groups: [{ id: "others", label: "Others", rows: [row(12, "others")] }], count: 1 }) };
            const loaded = createTemporaryObject(pageComponent, root);
            const loadedSearch = findChild(loaded, "pullRequestSearch");
            tryVerify(() => findChild(loaded, "pullRequestRows").count === 2, 1000, "the rows are drawn");
            const headerY = loadedSearch.mapToItem(loaded, 0, 0).y;

            Shell.state = { pullRequestList: list({ loading: true }) };
            const loading = createTemporaryObject(pageComponent, root);
            const search = findChild(loading, "pullRequestSearch");
            const title = findChild(loading, "pullRequestMessageTitle");
            verify(title.visible);
            compare(title.text, "Loading pull requests…");
            compare(search.mapToItem(loading, 0, 0).y, headerY, "the search row does not move while loading");
            verify(title.mapToItem(loading, 0, 0).y < 160, "the loading state takes the list's place under the filters");
        }

        function test_anEmptyListSaysWhyAndOffersItsWayOut() {
            Shell.state = { pullRequestList: list({ filtered: true, empty: { title: "Nothing under these filters", body: "Widen the state, involvement or project filter to see more." } }) };
            const page = createTemporaryObject(pageComponent, root);
            const title = findChild(page, "pullRequestMessageTitle");
            verify(title.visible);
            compare(title.text, "Nothing under these filters");
        }

        function test_anErrorOffersARetry() {
            Shell.state = { pullRequestList: list({ error: { title: "Could not load pull requests", message: "gh auth login is required." } }) };
            const page = createTemporaryObject(pageComponent, root);
            const action = findChild(page, "pullRequestMessageAction");
            verify(action.visible);
            compare(action.text, "Retry");
            mouseClick(action);
            compare(Shell.dispatchedActions[0].action, "pullRequestList.refresh");
        }

        function test_aFailedProjectBesideRowsOffersARetry() {
            Shell.state = { pullRequestList: list({ groups: [{ id: "others", label: "Others", rows: [row(12, "others")] }], count: 1, problems: ["acme/api could not be read: github.com did not answer in time. Try again."] }) };
            const page = createTemporaryObject(pageComponent, root);
            const retry = findChild(page, "pullRequestProblemsRetry");
            verify(retry.visible);
            mouseClick(retry);
            compare(Shell.dispatchedActions[0].action, "pullRequestList.refresh");
        }

        function test_noRetryBesideTheListWhenNothingFailed() {
            Shell.state = { pullRequestList: list({ groups: [{ id: "others", label: "Others", rows: [row(12, "others")] }], count: 1 }) };
            const page = createTemporaryObject(pageComponent, root);
            verify(!findChild(page, "pullRequestProblemsRetry").visible);
        }
    }
}
