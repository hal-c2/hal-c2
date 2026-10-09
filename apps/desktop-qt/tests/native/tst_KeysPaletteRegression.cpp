// What tests/prop/tst_KeysPaletteProp.cpp found in CommandPaletteController.

#include <QtTest>

#include <QJsonArray>

#include "CommandPaletteController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TestTime.h"

namespace {

// The app on a fake MC with one project and a thread "Login" whose messages
// say "slow login"; stores in `home`.
struct Shell {
  explicit Shell(const QString& home) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("Login")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onRpc(QStringLiteral("orchestration.searchThreads"), [this](const FakeMc::Rpc& rpc) {
      const QString query = rpc.payload.value(QLatin1String("query")).toString();
      QJsonArray matches;
      if (QStringLiteral("slow login").contains(query, Qt::CaseInsensitive)) {
        matches.append(QJsonObject{{QStringLiteral("threadId"), QStringLiteral("t1")},
                                   {QStringLiteral("snippet"), QStringLiteral("slow login")}});
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("matches"), matches}});
    });
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  CommandPaletteController* palette() const { return native->controller<CommandPaletteController>(); }

  bool started() const {
    return native->isActive() && native->store()->thread(QStringLiteral("env-a:t1")).has_value();
  }

  int indexOf(const QString& kind, const QString& id) const {
    for (int row = 0; row < palette()->rowCount(); ++row) {
      if (palette()->kindAt(row) == kind && palette()->idAt(row) == id) return row;
    }
    return -1;
  }

  QStringList titles() const {
    QStringList list;
    for (int row = 0; row < palette()->rowCount(); ++row) {
      list.append(palette()->index(row).data(CommandPaletteController::TitleRole).toString());
    }
    return list;
  }

  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
};

}  // namespace

class KeysPaletteRegression : public QObject {
  Q_OBJECT

private slots:
  // Opening it again dropped what the rows listed from before read from
  // (m_entries) and then said its mode changed: whatever read the rows then
  // read past the end of the list.
  void reopeningReadsTheRowsItHas() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.started());
    CommandPaletteController* palette = shell.palette();
    palette->show();
    const QStringList listed = shell.titles();
    QVERIFY(!listed.isEmpty());
    palette->dismiss();

    QList<QStringList> read;
    connect(palette, &CommandPaletteController::modeChanged, this, [&] { read.append(shell.titles()); });
    palette->show();
    QVERIFY(!read.isEmpty());
    QCOMPARE(read.first(), listed);
  }

  // A row that stayed where it was but showed something else, a thread
  // found by its title once its messages no longer count, kept the snippet
  // until something else repainted the list.
  void aRowThatStaysRepaintsWhenItChanges() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.started());
    CommandPaletteController* palette = shell.palette();
    palette->setSearchDelay(0);
    palette->show();
    palette->setQuery(QStringLiteral("slow"));
    HAL_C2_TRY_VERIFY(!palette->searching());
    const int row = shell.indexOf(QStringLiteral("thread"), QStringLiteral("env-a:t1"));
    QVERIFY(row >= 0);
    QCOMPARE(palette->index(row).data(CommandPaletteController::DescriptionRole).toString(), QStringLiteral("slow login"));

    QSignalSpy changed(palette, &QAbstractItemModel::dataChanged);
    QSignalSpy inserted(palette, &QAbstractItemModel::rowsInserted);
    palette->setQuery(QStringLiteral("login"));
    QCOMPARE(shell.indexOf(QStringLiteral("thread"), QStringLiteral("env-a:t1")), row);
    QCOMPARE(palette->index(row).data(CommandPaletteController::DescriptionRole).toString(), QStringLiteral("Shop"));
    const bool repainted = std::any_of(changed.cbegin(), changed.cend(), [row](const QList<QVariant>& args) {
      return args.at(0).toModelIndex().row() <= row && args.at(1).toModelIndex().row() >= row;
    });
    const bool reinserted = std::any_of(inserted.cbegin(), inserted.cend(), [row](const QList<QVariant>& args) {
      return args.at(1).toInt() <= row && args.at(2).toInt() >= row;
    });
    QVERIFY(repainted || reinserted);
  }

  // Opening it said the highlight changed when it stayed on the first row.
  void reopeningKeepsAnUnmovedHighlightQuiet() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.started());
    CommandPaletteController* palette = shell.palette();
    palette->show();
    QCOMPARE(palette->highlighted(), 0);
    QSignalSpy highlighted(palette, &CommandPaletteController::highlightedChanged);
    palette->show();
    QCOMPARE(palette->highlighted(), 0);
    QCOMPARE(highlighted.count(), 0);
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/keys-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  KeysPaletteRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_KeysPaletteRegression.moc"
