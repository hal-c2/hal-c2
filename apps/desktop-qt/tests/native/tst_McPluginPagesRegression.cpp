// A plugin page two paired MCs both run reloaded when the copy of its files
// that came first in the store's list of environments finished unpacking
// after the other's: the tab took the url of whichever ready copy was first
// in that list.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

QJsonObject plugin(const QString& revision) {
  const auto page = QJsonObject{{QStringLiteral("id"), QStringLiteral("board")},
                                {QStringLiteral("title"), QStringLiteral("Board")},
                                {QStringLiteral("icon"), QStringLiteral("kanban")},
                                {QStringLiteral("qml"), QStringLiteral("pages/Board.qml")}};
  return {{QStringLiteral("id"), QStringLiteral("planner")},
          {QStringLiteral("name"), QStringLiteral("Planner")},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("revision"), revision},
          {QStringLiteral("contributes"), QJsonObject{{QStringLiteral("pages"), QJsonArray{page}}}}};
}

QVariantList pages(const ShellBridge& bridge) {
  return bridge.state()->value(QStringLiteral("mcPlugins")).toMap().value(QStringLiteral("pages")).toList();
}

QString urlOfPage(const ShellBridge& bridge) { return pages(bridge).first().toMap().value(QStringLiteral("url")).toString(); }

}  // namespace

class McPluginPagesRegression : public QObject {
  Q_OBJECT

private slots:
  void aPageKeepsTheCopyItShowsWhenAnotherCopyIsReady_data() {
    // The store lists its environments in no fixed order, so either may be the one that is slow.
    QTest::addColumn<int>("slow");
    QTest::newRow("the first environment is slow") << 0;
    QTest::newRow("the second environment is slow") << 1;
  }

  void aPageKeepsTheCopyItShowsWhenAnotherCopyIsReady() {
    QFETCH(int, slow);
    QTemporaryDir home;
    FakeMc mc;
    mc.join(QStringLiteral("b"));
    ShellBridge bridge;
    NativeShell native{&bridge};
    QList<FakeMc::Rpc> held;  // the slow MC's files
    const auto answer = [&mc](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("path"), rpc.payload.value(QLatin1String("path"))},
                                {QStringLiteral("encoding"), QStringLiteral("utf8")},
                                {QStringLiteral("content"), QStringLiteral("import QtQuick\nItem {}\n")},
                                {QStringLiteral("revision"), QStringLiteral("r1")}});
    };
    mc.onShape(QStringLiteral("plugins"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("plugins")},
               {QStringLiteral("id"), id},
               {QStringLiteral("plugins"), QJsonArray{plugin(QStringLiteral("r1"))}}});
    });
    mc.onRpc(QStringLiteral("plugins.file"), [&](const FakeMc::Rpc& rpc) {
      const QString environment = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
      if (environment == native.store()->environments().value(slow)) held.append(rpc);
      else answer(rpc);
    });
    mc.onRpc(QStringLiteral("test.barrier"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });

    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    QTRY_VERIFY(native.isActive() && native.store()->synchronized());

    // The other MC's copy is ready first, and the page shows it.
    QTRY_VERIFY(!pages(bridge).isEmpty() && !urlOfPage(bridge).isEmpty());
    QCOMPARE(pages(bridge).size(), 1);
    QTRY_VERIFY(!held.isEmpty());
    const QString shown = urlOfPage(bridge);

    // The slow MC's copy becomes ready after it: the page stays as it is.
    for (const FakeMc::Rpc& rpc : std::exchange(held, {})) answer(rpc);
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    QTRY_VERIFY(done);
    QCOMPARE(urlOfPage(bridge), shown);
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/mc-plugin-pages-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  McPluginPagesRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_McPluginPagesRegression.moc"
