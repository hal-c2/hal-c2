// What tests/prop/tst_SpaceFilesProp.cpp and tst_SpaceProjectsProp.cpp found in
// SpaceController's project files, a refused list of files told apart from an
// empty one, and a file's page shown from its project's Space.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SpaceController.h"

namespace {

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QList<FakeMc::Rpc> held;
  // Every value `space.written` took, in order.
  QStringList written;

  Shell() {
    mc.onRpc(QStringLiteral("space.files.list"), [this](const FakeMc::Rpc& rpc) { held.append(rpc); });
    QObject::connect(&bridge, &ShellBridge::stateEntryChanged, &bridge, [this](const QString& key, const QVariant& value) {
      if (key != QLatin1String("space")) return;
      const QString now = value.toMap().value(QStringLiteral("written")).toString();
      if (now != (written.isEmpty() ? QString() : written.last())) written.append(now);
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
  }

  SpaceController* space() { return native.controller<SpaceController>(); }
  bool list(const QString& project) { return space()->handle(QStringLiteral("space.files.list"), QVariantMap{{QStringLiteral("projectId"), project}}); }
  void answer(const FakeMc::Rpc& rpc, const QString& path) {
    const QJsonObject file{{QStringLiteral("relativePath"), path}, {QStringLiteral("kind"), QStringLiteral("markdown")}, {QStringLiteral("page"), QJsonValue::Null}};
    mc.reply(rpc, QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), QJsonArray{file}}});
  }
  bool open(const QString& path) {
    return space()->handle(QStringLiteral("space.openFile"), QVariantMap{{QStringLiteral("projectId"), QStringLiteral("alpha")}, {QStringLiteral("relativePath"), path}});
  }
  QString error() const { return bridge.state()->value(QStringLiteral("space")).toMap().value(QStringLiteral("error")).toString(); }
  QVariantMap listed(const QString& project) const {
    return bridge.state()->value(QStringLiteral("space")).toMap().value(QStringLiteral("files")).toMap().value(project).toMap();
  }
  QStringList paths(const QString& project) const { return listed(project).value(QStringLiteral("paths")).toMap().keys(); }
  // The Space "Research" selected, holding page-1, page-2 and the deck deck-1.
  void showResearch() {
    const QJsonObject research{{QStringLiteral("id"), QStringLiteral("space-1")}, {QStringLiteral("name"), QStringLiteral("Research")},
                               {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    space()->receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                           {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("space"), QStringLiteral("space-1"), research})}},
                           {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    space()->selectSpace(QStringLiteral("space-1"));
    QJsonArray rows;
    for (const QString id : {QStringLiteral("page-1"), QStringLiteral("page-2")}) {
      rows.append(QJsonArray{QStringLiteral("page"), id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                                         {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}});
    }
    rows.append(QJsonArray{QStringLiteral("deck"), QStringLiteral("deck-1"),
                           QJsonObject{{QStringLiteral("id"), QStringLiteral("deck-1")}, {QStringLiteral("title"), QStringLiteral("Talk")},
                                       {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}});
    space()->receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                           {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
  }
  // The MC answers an open of docs/guide.md with page-9 of alpha's Space "project-1".
  void answerOpens() {
    mc.onRpc(QStringLiteral("space.page.openFile"), [this](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("spaceId"), QStringLiteral("project-1")},
                                {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), QStringLiteral("page-9")}}},
                                {QStringLiteral("created"), true}});
    });
  }
  // The copy of alpha's Space, holding page-9 for docs/guide.md.
  void projectSpaceArrives() {
    const QJsonObject guide{{QStringLiteral("id"), QStringLiteral("page-9")}, {QStringLiteral("title"), QStringLiteral("Guide")},
                            {QStringLiteral("parentPageId"), QJsonValue::Null}, {QStringLiteral("trashedAt"), QJsonValue::Null},
                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    space()->receiveFileSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                               {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("page"), QStringLiteral("page-9"), guide})}},
                               {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("project-log-1")}});
  }
};

}  // namespace

class SpaceFilesRegression : public QObject {
  Q_OBJECT

private slots:
  // ListFiles(alpha), Answer(0), ListFiles(alpha), GoOffline: the second list,
  // answered "disconnected" by the drop, wiped the files the first had brought.
  void aDropWhileListingKeepsTheFiles() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.answer(shell.held.takeFirst(), QStringLiteral("alpha-1.md"));
    QTRY_COMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-1.md")});

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.mc.stopAccepting();
    shell.mc.drop();
    shell.held.clear();
    QTRY_VERIFY(!shell.native.client()->isReady());
    QCOMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-1.md")});

    // On connecting it asks again, and that answer stands.
    shell.mc.startAccepting();
    QTRY_COMPARE(shell.held.size(), 1);
    shell.answer(shell.held.takeFirst(), QStringLiteral("alpha-2.md"));
    QTRY_COMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-2.md")});
  }

  // A refused list used to drop the project's entry, which the picker reads as
  // still looking: it said "Looking for the files of …" for good. It now keeps
  // the MC's error, and an empty answer stays an empty list with no error.
  void aRefusedListIsNotAnEmptyOne() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.mc.refuse(shell.held.takeFirst(), QStringLiteral("The project could not be read."));
    QTRY_COMPARE(shell.listed(QStringLiteral("alpha")).value(QStringLiteral("error")).toString(), QStringLiteral("The project could not be read."));
    QCOMPARE(shell.paths(QStringLiteral("alpha")), QStringList{});

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.mc.reply(shell.held.takeFirst(), QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), QJsonArray{}}});
    QTRY_COMPARE(shell.listed(QStringLiteral("alpha")).value(QStringLiteral("config")).toString(), QStringLiteral("default"));
    QVERIFY(!shell.listed(QStringLiteral("alpha")).contains(QStringLiteral("error")));
    QCOMPARE(shell.paths(QStringLiteral("alpha")), QStringList{});
  }

  // The sections are in the order of the projects' names, not of the MC's rows.
  void sectionsAreByName() {
    SpaceProjects projects;
    projects.setProjects({{QStringLiteral("p2"), QStringLiteral("tools")}, {QStringLiteral("p1"), QStringLiteral("Shop")}});
    projects.setFiles(QStringLiteral("p2"), {{QStringLiteral("README.md"), QString()}});
    projects.setFiles(QStringLiteral("p1"), {{QStringLiteral("guide.md"), QString()}});
    QStringList shown;
    for (const QVariantMap& row : projects.rows()) shown.append(row.value(QStringLiteral("projectId")).toString());
    QCOMPARE(shown, (QStringList{QStringLiteral("p1"), QStringLiteral("p2")}));
  }

  // A file's page is its project's: the Space's own page stays shown until the
  // project's Space arrives, and one pick of a Space page goes back to it.
  void aFileOpensInItsProjectSpace() {
    Shell shell;
    shell.answerOpens();
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.showResearch();
    shell.space()->selectPage(QStringLiteral("page-1"));

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, QStringList{QStringLiteral("page-9")});
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-1"));
    QCOMPARE(shell.space()->fileSpaceId(), QString());
    QVERIFY(shell.space()->projects()->isExpanded(QStringLiteral("alpha")));

    shell.projectSpaceArrives();
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-9"));
    QCOMPARE(shell.space()->fileSpaceId(), QStringLiteral("project-1"));
    QCOMPARE(shell.space()->spaceId(), QStringLiteral("space-1"));

    QVERIFY(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-2")}}));
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-2"));
    QCOMPARE(shell.space()->fileSpaceId(), QString());
  }

  // A pick made while a file was opening stands: the answer does not take the view.
  void aPickWhileOpeningAFileStands() {
    Shell shell;
    QList<FakeMc::Rpc> opens;
    shell.mc.onRpc(QStringLiteral("space.page.openFile"), [&](const FakeMc::Rpc& rpc) { opens.append(rpc); });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.showResearch();
    shell.space()->selectPage(QStringLiteral("page-1"));

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(opens.size(), 1);
    QVERIFY(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-2")}}));
    shell.mc.reply(opens.takeFirst(), QJsonObject{{QStringLiteral("spaceId"), QStringLiteral("project-1")},
                                                  {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), QStringLiteral("page-9")}}},
                                                  {QStringLiteral("created"), true}});
    // The files list the open asks for lands after the open's answer.
    QTRY_VERIFY(!shell.held.isEmpty());
    shell.projectSpaceArrives();
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-2"));
    QCOMPARE(shell.space()->fileSpaceId(), QString());
    QCOMPARE(shell.written, QStringList{});
  }

  // A file the MC will not open says why, in the words of the sidebar.
  void aRefusedOpenSaysWhy() {
    Shell shell;
    shell.mc.onRpc(QStringLiteral("space.page.openFile"), [&](const FakeMc::Rpc& rpc) {
      shell.mc.refuse(rpc, QStringLiteral("not a Space file"), QJsonObject{{QStringLiteral("reason"), QStringLiteral("notSpaceFile")}});
    });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.open(QStringLiteral("src/main.c")));
    QTRY_VERIFY(shell.error().startsWith(QStringLiteral("src/main.c is not a file this project shows in the Space sidebar.")));
    QCOMPARE(shell.written, QStringList{});
  }

  // The phone's Space screen opens the page `written` names when it changes, so
  // opening the same file again has to say its page again.
  void openingAFileAgainSaysItsPageAgain() {
    Shell shell;
    shell.answerOpens();
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, QStringList{QStringLiteral("page-9")});
    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, (QStringList{QStringLiteral("page-9"), QString(), QStringLiteral("page-9")}));
    QCOMPARE(shell.error(), QString());
  }

  // OpenFile, SelectPage(page-2), then the project's Space catching up: a copy
  // still on its way once the user went back took the view to the file's page.
  void theProjectSpaceCatchingUpKeepsThePagePicked() {
    Shell shell;
    shell.answerOpens();
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.showResearch();

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, QStringList{QStringLiteral("page-9")});
    shell.projectSpaceArrives();
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-9"));
    QVERIFY(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-2")}}));
    shell.projectSpaceArrives();
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-2"));
    QCOMPARE(shell.space()->fileSpaceId(), QString());
  }

  // The same for a deck: one made from a page while it was shown already stayed
  // awaited, and picking a page brought the deck back over it.
  void aDeckOpenedWhileShownIsNotAwaited() {
    Shell shell;
    shell.mc.onRpc(QStringLiteral("space.deck.createFromPage"), [&](const FakeMc::Rpc& rpc) {
      shell.mc.reply(rpc, QJsonObject{{QStringLiteral("deck"), QJsonObject{{QStringLiteral("id"), QStringLiteral("deck-1")}}}});
    });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.showResearch();
    shell.space()->selectDeck(QStringLiteral("deck-1"));

    QVERIFY(shell.space()->handle(QStringLiteral("space.deck.createFromPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-1")}}));
    // The MC answers in order, so a list asked after it lands after the deck's answer.
    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.answer(shell.held.takeFirst(), QStringLiteral("notes.md"));
    QTRY_COMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("notes.md")});
    QCOMPARE(shell.space()->deckId(), QStringLiteral("deck-1"));

    QVERIFY(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-2")}}));
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-2"));
    QCOMPARE(shell.space()->deckId(), QString());
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/space-files-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SpaceFilesRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SpaceFilesRegression.moc"
