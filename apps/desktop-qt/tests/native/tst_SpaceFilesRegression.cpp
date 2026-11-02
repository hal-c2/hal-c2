// What tests/prop/tst_SpaceFilesProp.cpp found in SpaceController's project files,
// what opening a file says when there is no Space to open it in, and a refused
// list of files told apart from an empty one.

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

  // With no Space shown the file opens in the first the MC lists; with none listed
  // the user is told to make one first.
  void noSpaceAsksForOneFirst() {
    Shell shell;
    shell.mc.onRpc(QStringLiteral("space.list"), [&](const FakeMc::Rpc& rpc) { shell.mc.reply(rpc, QJsonObject{{QStringLiteral("spaces"), QJsonArray{}}}); });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.error(), QStringLiteral("There is no Space to open the file in. Make a Space first, then open the file."));
    QCOMPARE(shell.written, QStringList{});
  }

  // A list that failed is not an empty one: the user is told what the MC said.
  void aFailedListSaysWhy() {
    Shell shell;
    shell.mc.onRpc(QStringLiteral("space.list"), [&](const FakeMc::Rpc& rpc) { shell.mc.refuse(rpc, QStringLiteral("The Spaces could not be read.")); });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.error(), QStringLiteral("The Spaces could not be read."));
  }

  // The phone's Space screen opens the page `written` names when it changes, so
  // opening the same file again has to say its page again.
  void openingAFileAgainSaysItsPageAgain() {
    Shell shell;
    const QJsonObject personal{{QStringLiteral("id"), QStringLiteral("space-1")}, {QStringLiteral("name"), QStringLiteral("Personal")}};
    shell.mc.onRpc(QStringLiteral("space.list"), [&](const FakeMc::Rpc& rpc) { shell.mc.reply(rpc, QJsonObject{{QStringLiteral("spaces"), QJsonArray{personal}}}); });
    shell.mc.onRpc(QStringLiteral("space.page.openFile"), [&](const FakeMc::Rpc& rpc) {
      shell.mc.reply(rpc, QJsonObject{{QStringLiteral("spaceId"), QStringLiteral("space-1")},
                                      {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), QStringLiteral("page-1")}}},
                                      {QStringLiteral("created"), false}});
    });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, QStringList{QStringLiteral("page-1")});
    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, (QStringList{QStringLiteral("page-1"), QString(), QStringLiteral("page-1")}));
    QCOMPARE(shell.error(), QString());
  }

  // OpenFile(beta, page-1), SelectPage(page-2): the file's page was shown already,
  // so it stayed awaited, and the next rebuild took the view back from page-2.
  void aPageOpenedWhileShownIsNotAwaited() {
    Shell shell;
    shell.mc.onRpc(QStringLiteral("space.page.openFile"), [&](const FakeMc::Rpc& rpc) {
      shell.mc.reply(rpc, QJsonObject{{QStringLiteral("spaceId"), QStringLiteral("space-1")},
                                      {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), QStringLiteral("page-1")}}},
                                      {QStringLiteral("created"), false}});
    });
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    const QJsonObject research{{QStringLiteral("id"), QStringLiteral("space-1")}, {QStringLiteral("name"), QStringLiteral("Research")},
                               {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    shell.space()->receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                                 {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("space"), QStringLiteral("space-1"), research})}},
                                 {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    shell.space()->selectSpace(QStringLiteral("space-1"));
    QJsonArray rows;
    for (const QString id : {QStringLiteral("page-1"), QStringLiteral("page-2")}) {
      rows.append(QJsonArray{QStringLiteral("page"), id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                                         {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}});
    }
    shell.space()->receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                                 {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    shell.space()->selectPage(QStringLiteral("page-1"));

    QVERIFY(shell.open(QStringLiteral("docs/guide.md")));
    QTRY_COMPARE(shell.written, QStringList{QStringLiteral("page-1")});
    QVERIFY(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), QStringLiteral("page-2")}}));
    QCOMPARE(shell.space()->pageId(), QStringLiteral("page-2"));
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
