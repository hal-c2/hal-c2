// What tests/prop/tst_WorkspaceFilesProp.cpp found in WorkspaceFiles.

#include <QtTest>

#include <QJsonArray>

#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"
#include "TestTime.h"

namespace {

// An MC that holds every listing and search until the test answers it.
struct Held {
  FakeMc mc;
  McClient client;
  QList<FakeMc::Rpc> calls;

  Held() {
    const auto hold = [this](const FakeMc::Rpc& rpc) { calls.append(rpc); };
    mc.onRpc(QStringLiteral("projects.listEntries"), hold);
    mc.onRpc(QStringLiteral("projects.searchEntries"), hold);
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
  }

  bool ready() { return halc2::test::waitFor([this] { return client.isReady(); }); }
  bool asked(qsizetype count) { return halc2::test::waitFor([this, count] { return calls.size() == count; }); }
  // Answers the call with one file, and waits for the client to read it.
  bool answer(qsizetype call, const QString& file) {
    const FakeMc::Rpc rpc = calls.at(call);
    mc.reply(rpc, QJsonObject{{QStringLiteral("entries"),
                               QJsonArray{QJsonObject{{QStringLiteral("path"), file}, {QStringLiteral("kind"), QStringLiteral("file")}}}}});
    bool done = false;
    QObject context;
    client.call(&context, {}, QStringLiteral("test.barrier"), {}, [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    return halc2::test::waitFor([&done] { return done; });
  }
};

}  // namespace

class WorkspaceFilesRegression : public QObject {
  Q_OBJECT

private slots:
  // Two listings of one folder answered out of order: the older one, read
  // before the agent changed the workspace, replaced the newer.
  void anOlderListingAnsweredLateIsDropped() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
    files.setActive(true);
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringLiteral("first")));
    files.tree()->refresh();
    files.tree()->refresh();
    QVERIFY(held.asked(3));
    QVERIFY(held.answer(2, QStringLiteral("newer")));
    QVERIFY(held.answer(1, QStringLiteral("older")));
    QCOMPARE(files.tree()->visiblePaths(), QStringList{QStringLiteral("newer")});
  }

  // Switching workspace while a search was on its way showed the old
  // workspace's matches in the new one.
  void aSearchOfTheWorkspaceLeftIsDropped() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w1"));
    files.setQuery(QStringLiteral("x"));
    QVERIFY(held.asked(1));
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w2"));
    QVERIFY(held.answer(0, QStringLiteral("x-of-w1")));
    QVERIFY(!files.tree()->filtered());
    QVERIFY(files.tree()->visiblePaths().isEmpty());
  }

  // A query typed with no workspace said a search was on its way, forever.
  void aQueryWithoutAWorkspaceIsNotSearching() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QString());
    files.setQuery(QStringLiteral("x"));
    QVERIFY(!files.searching());
  }

  // The tab shown with a search's matches on screen never listed the top
  // folder: it judged "never listed" by the tree having no rows.
  void showingTheTabOverASearchListsTheTopFolder() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
    files.setQuery(QStringLiteral("x"));
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringLiteral("x")));
    files.setActive(true);
    QVERIFY(held.asked(2));
    QCOMPARE(held.calls.at(1).method, QStringLiteral("projects.listEntries"));
    // The search stays on screen until the query is cleared.
    QVERIFY(files.tree()->filtered());
    QVERIFY(held.answer(1, QStringLiteral("top")));
    files.setQuery({});
    QCOMPARE(files.tree()->visiblePaths(), QStringList{QStringLiteral("top")});
  }

  // A CSV's table is padded to its widest row, so one header of half a
  // million commas made every row that wide: 1.5 GB of table from a 500 KB
  // file. The table keeps the web's first 30 columns, and says so.
  void aWideCsvShowsItsFirstColumns() {
    FakeMc mc;
    McClient client;
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([&client] { return client.isReady(); }));
    QString wide = QString(100000, u',') + u'\n';
    for (int row = 0; row < 40; ++row) wide += QStringLiteral("a,b\n");
    fakeFiles(mc).files.insert(QStringLiteral("wide.csv"), wide);

    WorkspaceFiles files(&client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
    files.openFile(QStringLiteral("wide.csv"));
    QVERIFY(QTest::qWaitFor([&files] { return files.fileStatus() == QLatin1String("ready"); }));

    const QString table = files.renderedText();
    QCOMPARE(files.renderKind(), QStringLiteral("csv"));
    QVERIFY2(table.size() < 10000, qPrintable(QStringLiteral("table of %1 characters").arg(table.size())));
    QCOMPARE(table.section(u'\n', 0, 0).count(u'|'), WorkspaceFiles::csvColumnLimit + 1);
    QVERIFY(table.endsWith(QStringLiteral("\nShowing the first 30 columns.\n")));
  }
};

QTEST_GUILESS_MAIN(WorkspaceFilesRegression)
#include "tst_WorkspaceFilesRegression.moc"
