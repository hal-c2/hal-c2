#include <QTest>

#include "PullRequestReference.h"

// What the pull request thread dialog reads from a pasted reference
// (upstream pullRequestReference.ts).
class PullRequestReferenceTest : public QObject {
  Q_OBJECT

private slots:
  void readsLinksAndCheckoutCommands_data() {
    QTest::addColumn<QString>("input");
    QTest::addColumn<QString>("reference");
    QTest::newRow("number") << "42" << "42";
    QTest::newRow("hash") << " #42 " << "42";
    QTest::newRow("github") << "https://github.com/acme/shop/pull/42/files" << "https://github.com/acme/shop/pull/42/files";
    QTest::newRow("gitlab") << "https://gitlab.com/acme/shop/-/merge_requests/7" << "https://gitlab.com/acme/shop/-/merge_requests/7";
    QTest::newRow("self-hosted gitlab") << "https://gitlab.acme.test/group/sub/shop/-/merge_requests/7" << "https://gitlab.acme.test/group/sub/shop/-/merge_requests/7";
    QTest::newRow("codeberg") << "https://codeberg.org/acme/shop/pulls/7" << "https://codeberg.org/acme/shop/pulls/7";
    QTest::newRow("azure") << "https://dev.azure.com/acme/shop/_git/web/pullrequest/7" << "https://dev.azure.com/acme/shop/_git/web/pullrequest/7";
    QTest::newRow("visualstudio") << "https://acme.visualstudio.com/shop/_git/web/pullrequest/7" << "https://acme.visualstudio.com/shop/_git/web/pullrequest/7";
    QTest::newRow("gh") << "gh pr checkout 7" << "7";
    QTest::newRow("gh link") << "gh pr checkout https://github.com/acme/shop/pull/7" << "https://github.com/acme/shop/pull/7";
    QTest::newRow("glab") << "glab mr checkout 7" << "7";
    QTest::newRow("tea") << "tea pr checkout 7" << "7";
    QTest::newRow("tea pulls") << "tea pulls checkout #7" << "7";
    QTest::newRow("az --id") << "az repos pr checkout --id 7" << "7";
    QTest::newRow("az --id=") << "az repos pr checkout --org x --id=7" << "7";
    QTest::newRow("az -i") << "az repos pr checkout -i 7" << "7";
  }
  void readsLinksAndCheckoutCommands() {
    QFETCH(QString, input);
    QFETCH(QString, reference);
    QCOMPARE(pullRequestReference::parse(input), std::optional<QString>(reference));
  }

  void refusesWhatNamesNoPullRequest_data() {
    QTest::addColumn<QString>("input");
    QTest::newRow("empty") << "  ";
    QTest::newRow("words") << "see the tax change";
    QTest::newRow("commit") << "https://github.com/acme/shop/commit/0a1b2c3";
    QTest::newRow("github lookalike") << "https://github.com.evil.test/acme/shop/pull/42";
    QTest::newRow("plain http github") << "http://github.com/acme/shop/pull/42";
    QTest::newRow("bare checkout") << "gh pr checkout";
    QTest::newRow("checkout of words") << "gh pr checkout tax";
  }
  void refusesWhatNamesNoPullRequest() {
    QFETCH(QString, input);
    QCOMPARE(pullRequestReference::parse(input), std::nullopt);
  }
};

QTEST_GUILESS_MAIN(PullRequestReferenceTest)
#include "tst_PullRequestReference.moc"
