// Which links in the conversation are pull requests (PullRequestLinks): the
// path shape each host alone uses, GitHub's "#123" autolinks as candidates,
// and the project that can read one, which a lookalike host never has.

#include <QTest>

#include "PullRequestLinks.h"

namespace {

QJsonObject project(const QString& id, const QString& canonicalKey) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), canonicalKey}}}};
}

}  // namespace

class PullRequestLinksTest : public QObject {
  Q_OBJECT

private slots:
  void parsesEachHost_data() {
    QTest::addColumn<QString>("url");
    QTest::addColumn<QString>("provider");
    QTest::addColumn<QString>("host");
    QTest::addColumn<QString>("repository");
    QTest::addColumn<int>("number");
    QTest::newRow("github") << "https://github.com/Acme/Shop/pull/42/files" << "github" << "github.com" << "acme/shop" << 42;
    QTest::newRow("enterprise") << "https://github.example.com/acme/shop/pull/7" << "github" << "github.example.com" << "acme/shop" << 7;
    QTest::newRow("gitlab subgroup") << "https://gitlab.com/acme/tools/shop/-/merge_requests/3" << "gitlab" << "gitlab.com"
                                     << "acme/tools/shop" << 3;
    QTest::newRow("self-hosted gitlab") << "https://code.acme.test/acme/shop/-/merge_requests/3" << "gitlab" << "code.acme.test"
                                        << "acme/shop" << 3;
    QTest::newRow("forgejo port") << "http://git.acme.test:3000/acme/shop/pulls/5" << "forgejo" << "git.acme.test:3000" << "acme/shop" << 5;
    QTest::newRow("bitbucket") << "https://bitbucket.org/acme/shop/pull-requests/9" << "bitbucket" << "bitbucket.org" << "acme/shop" << 9;
    QTest::newRow("azure") << "https://dev.azure.com/acme/web/_git/shop/pullrequest/11" << "azure-devops" << "dev.azure.com"
                           << "acme/web/_git/shop" << 11;
  }
  void parsesEachHost() {
    QFETCH(QString, url);
    const std::optional<PullRequestLink> link = PullRequestLinks::parse(url);
    QVERIFY(link);
    QTEST(link->provider, "provider");
    QTEST(link->host, "host");
    QTEST(link->repository, "repository");
    QTEST(link->number, "number");
    QCOMPARE(link->url, url);
    QVERIFY(!link->candidate);
  }

  void claimsNothingItCannotBeSureOf_data() {
    QTest::addColumn<QString>("url");
    QTest::newRow("commit") << "https://github.com/acme/shop/commit/0a1b2c3";
    QTest::newRow("repository root") << "https://github.com/acme/shop";
    QTest::newRow("not a number") << "https://github.com/acme/shop/pull/abc";
    QTest::newRow("zero") << "https://github.com/acme/shop/pull/0";
    QTest::newRow("gitlab snippet") << "https://gitlab.com/acme/shop/-/snippets/12";
    QTest::newRow("blog") << "https://blog.example.test/2026/updates/pull/3";
    QTest::newRow("bitbucket shape elsewhere") << "https://example.test/acme/shop/pull-requests/3";
    QTest::newRow("mailto") << "mailto:ada@example.test";
    QTest::newRow("javascript") << "javascript:alert(1)";
  }
  void claimsNothingItCannotBeSureOf() {
    QFETCH(QString, url);
    QVERIFY(!PullRequestLinks::parse(url));
    QVERIFY(!PullRequestLinks::claim(url));
  }

  void anIssueAutolinkIsACandidate() {
    const std::optional<PullRequestLink> link = PullRequestLinks::claim(QStringLiteral("https://github.com/acme/shop/issues/42#top"));
    QVERIFY(link);
    QVERIFY(link->candidate);
    QCOMPARE(link->url, QStringLiteral("https://github.com/acme/shop/pull/42"));
    QCOMPARE(link->key(), QStringLiteral("github.com/acme/shop#42"));
    QVERIFY(!PullRequestLinks::parse(QStringLiteral("https://github.com/acme/shop/issues/42")));
    QVERIFY(!PullRequestLinks::claim(QStringLiteral("https://gitlab.com/acme/shop/issues/42")));
  }

  void findsTheProjectThatReadsIt() {
    const QList<QJsonObject> projects{project(QStringLiteral("other"), QStringLiteral("github.com/acme/other")),
                                      project(QStringLiteral("shop"), QStringLiteral("github.com/acme/shop")),
                                      project(QStringLiteral("azure"), QStringLiteral("acme.visualstudio.com/web/_git/shop"))};
    const auto of = [&](const QString& url, bool anyHost) {
      return PullRequestLinks::projectFor(projects, *PullRequestLinks::parse(url), anyHost);
    };
    QCOMPARE(of(QStringLiteral("https://github.com/acme/shop/pull/42"), false), QStringLiteral("shop"));
    QCOMPARE(of(QStringLiteral("https://github.com/someone/else/pull/1"), false), QString());
    QCOMPARE(of(QStringLiteral("https://github.com/someone/else/pull/1"), true), QStringLiteral("other"));
    // Two hosts stay apart, and a lookalike reads as nobody's.
    QCOMPARE(of(QStringLiteral("https://github.example.com/acme/shop/pull/42"), true), QString());
    QCOMPARE(of(QStringLiteral("https://github.com.evil.test/acme/shop/pull/42"), true), QString());
    // Azure DevOps however it is addressed, and only by its own repository.
    QCOMPARE(of(QStringLiteral("https://dev.azure.com/acme/web/_git/shop/pullrequest/3"), true), QStringLiteral("azure"));
    QCOMPARE(of(QStringLiteral("https://dev.azure.com/acme/web/_git/cart/pullrequest/3"), true), QString());
  }

  void namesWhereTheUserLands() {
    QCOMPARE(PullRequestLinks::openOnHostLabel(QStringLiteral("azure-devops")), QStringLiteral("Open on Azure DevOps"));
    QCOMPARE(PullRequestLinks::openOnHostLabel(QStringLiteral("gitlab")), QStringLiteral("Open on GitLab"));
    QCOMPARE(PullRequestLinks::openOnHostLabel(QStringLiteral("gitea")), QStringLiteral("Open on host"));
  }

  void pagesFromTheHostAlone() {
    QCOMPARE(PullRequestLinks::pageOf(QStringLiteral("gitlab.com"), QStringLiteral("acme/shop"), 3),
             QStringLiteral("https://gitlab.com/acme/shop/-/merge_requests/3"));
    QCOMPARE(PullRequestLinks::pageOf(QStringLiteral("github.com"), QStringLiteral("acme/shop"), 3),
             QStringLiteral("https://github.com/acme/shop/pull/3"));
  }
};

QTEST_GUILESS_MAIN(PullRequestLinksTest)
#include "tst_PullRequestLinks.moc"
