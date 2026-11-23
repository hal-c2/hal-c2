// Forgetting the phone's own environment when an interrupted promote or
// re-pair left it in the saved environments too (#1746): the saved copy
// and its credential go with it. At start the saved copy is dropped only
// when it holds the pairing's own session: a tablet's Settings > Connections
// saves a newer one there.

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PairableMc.h"
#include "Pairing.h"
#include "PluginController.h"
#include "SavedEnvironmentsController.h"
#include "SecretStore.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const pairing::Client kPhone{QStringLiteral("HAL-C2 on Test Phone"), QStringLiteral("mobile"), QStringLiteral("Android")};
const QString kDead = QStringLiteral("http://127.0.0.1:9");

void writeJson(const QString& path, const QJsonObject& object) {
  QDir().mkpath(QFileInfo(path).absolutePath());
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly)) qFatal("the seed could not be written");
  file.write(QJsonDocument(object).toJson(QJsonDocument::Compact));
}

QJsonObject readJson(const QString& path) {
  QFile file(path);
  return file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object() : QJsonObject();
}

// The phone as its main.cpp builds it over `home`: the shell, and its
// pairing, started.
class Phone {
public:
  explicit Phone(const QString& home) : bridge(std::make_unique<ShellBridge>()), shell(std::make_unique<NativeShell>(bridge.get())) {
    const QDir dir(home);
    dir.mkpath(QStringLiteral("config"));
    shell->client()->setRetryDelays({20});
    shell->setStoreDirs(dir.filePath(QStringLiteral("state")), dir.filePath(QStringLiteral("data")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(QStringLiteral("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(QStringLiteral("config")));
    pairing = std::make_unique<Pairing>(bridge.get(), shell.get(), dir.filePath(QStringLiteral("data")), kPhone);
    pairing->start();
  }
  ~Phone() { pairing.reset(); }

  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  std::unique_ptr<Pairing> pairing;
};

// env-b in pairing.json on `own`, and `beside` in the catalog, each with
// its session under its id in the keyring. By default the state an
// interrupted promote leaves: both on one session.
struct Seeded {
  QTemporaryDir home;
  std::shared_ptr<MemorySecretStore::Keys> keys = std::make_shared<MemorySecretStore::Keys>();

  explicit Seeded(const QStringList& beside, const QString& own = QStringLiteral("session-env-b"), const QString& origin = kDead) {
    const QDir data(QDir(home.path()).filePath(QStringLiteral("data")));
    writeJson(data.filePath(QStringLiteral("pairing.json")),
              {{QStringLiteral("origin"), origin},
               {QStringLiteral("token"), own},
               {QStringLiteral("label"), QStringLiteral("env-b")},
               {QStringLiteral("environmentId"), QStringLiteral("env-b")}});
    QJsonArray environments;
    for (const QString& id : beside) {
      environments.append(
          QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("label"), id}, {QStringLiteral("origin"), kDead}});
      keys->secrets.insert(id, QStringLiteral("session-") + id);
    }
    writeJson(data.filePath(QStringLiteral("saved-environments.json")),
              {{QStringLiteral("version"), 1}, {QStringLiteral("environments"), environments}});
    SavedEnvironmentsController::setSecretStoreFactory(
        [keys = keys](const QString&) { return std::make_unique<MemorySecretStore>(keys); });
  }

  QString pairingFile() const { return QDir(home.path()).filePath(QStringLiteral("data/pairing.json")); }
  QString catalogFile() const { return QDir(home.path()).filePath(QStringLiteral("data/saved-environments.json")); }
  QStringList listed() const {
    QStringList ids;
    for (const QJsonValue& value : readJson(catalogFile()).value(QStringLiteral("environments")).toArray()) {
      ids.append(value.toObject().value(QStringLiteral("id")).toString());
    }
    return ids;
  }
  QStringList kept() const {
    QStringList sessions = keys->secrets.values();
    sessions.sort();
    return sessions;
  }
};

}  // namespace

class PairingRegression : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { QStandardPaths::setTestModeEnabled(true); }

  void forgettingOwnNotDuplicated() {
    Seeded seeded({});
    Phone phone(seeded.home.path());
    phone.bridge->dispatch(QStringLiteral("pairing.forget"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-b")}});
    QVERIFY(!QFile::exists(seeded.pairingFile()));
    QCOMPARE(seeded.listed(), QStringList{});
    QCOMPARE(seeded.kept(), QStringList{});
  }

  void forgettingOwnAlsoSavedForgetsIt() {
    Seeded seeded({QStringLiteral("env-b")}, QStringLiteral("session-own"));
    Phone phone(seeded.home.path());
    // The start leaves forget the copy to forget.
    QCOMPARE(seeded.listed(), QStringList{QStringLiteral("env-b")});
    phone.bridge->dispatch(QStringLiteral("pairing.forget"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-b")}});
    QVERIFY(!QFile::exists(seeded.pairingFile()));
    QCOMPARE(seeded.listed(), QStringList{});
    QCOMPARE(seeded.kept(), QStringList{});
  }

  void forgettingOwnAlsoSavedBehindAnotherPromotesTheOther() {
    Seeded seeded({QStringLiteral("env-c"), QStringLiteral("env-b")}, QStringLiteral("session-own"));
    Phone phone(seeded.home.path());
    QCOMPARE(seeded.listed(), QStringList({QStringLiteral("env-c"), QStringLiteral("env-b")}));
    phone.bridge->dispatch(QStringLiteral("pairing.forget"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-b")}});
    const QJsonObject own = readJson(seeded.pairingFile());
    QCOMPARE(own.value(QStringLiteral("environmentId")).toString(), QStringLiteral("env-c"));
    QCOMPARE(own.value(QStringLiteral("token")).toString(), QStringLiteral("session-env-c"));
    QCOMPARE(seeded.listed(), QStringList{});
    QCOMPARE(seeded.kept(), QStringList{});
  }

  void takingAwayOwnCopyMovesWhatItsLinkHeld_data() {
    QTest::addColumn<bool>("pairsAgain");
    QTest::newRow("removed in Settings") << false;
    QTest::newRow("paired again") << true;
  }

  // What is open over the copy's link is asked for again on the phone's
  // own connection, under the id it was given. The copy is of the same
  // environment at another address, so each connection's MC hears its own.
  void takingAwayOwnCopyMovesWhatItsLinkHeld() {
    QFETCH(bool, pairsAgain);
    PairableMc mc(QStringLiteral("b"), QStringLiteral("env-b"));
    PairableMc elsewhere(QStringLiteral("b"), QStringLiteral("env-b"));
    mc.sessions.append(QStringLiteral("session-own"));
    int asked = 0;
    int askedElsewhere = 0;
    mc.mc.onShape(QStringLiteral("probe"), [&](int, const QJsonObject&) { ++asked; });
    elsewhere.mc.onShape(QStringLiteral("probe"), [&](int, const QJsonObject&) { ++askedElsewhere; });
    Seeded seeded({}, QStringLiteral("session-own"), mc.mc.origin().toString());
    Phone phone(seeded.home.path());
    McClient* own = phone.shell->client();
    QTRY_VERIFY(own->phase() == McClient::Phase::Ready);
    phone.bridge->dispatch(QStringLiteral("savedEnvironments.pair"), QVariantMap{{QStringLiteral("link"), elsewhere.link()}});
    QTRY_VERIFY(phone.shell->store()->linkServing(QStringLiteral("env-b")) != nullptr);
    QObject context;
    const int id = own->subscribe(&context, {{QStringLiteral("type"), QStringLiteral("probe")}, {QStringLiteral("environmentId"), QStringLiteral("env-b")}},
                                  [](const QJsonObject&) {});
    QTRY_COMPARE(askedElsewhere, 1);
    QCOMPARE(asked, 0);

    if (pairsAgain) {
      phone.bridge->dispatch(QStringLiteral("pairing.pair"), QVariantMap{{QStringLiteral("link"), mc.link()}});
    } else {
      phone.bridge->dispatch(QStringLiteral("savedEnvironments.remove"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-b")}});
    }
    QTRY_COMPARE(asked, 1);
    QCOMPARE(mc.mc.subscribers(QStringLiteral("probe")), QList<int>{id});
    QCOMPARE(askedElsewhere, 1);
    own->unsubscribe(id);
    QTRY_VERIFY(mc.mc.subscribers(QStringLiteral("probe")).isEmpty());
  }

  // The live pairing stays, token and all: its credential is in
  // pairing.json, not under its id in the keyring.
  void startingWithOwnAlsoSavedDropsTheSavedCopy() {
    Seeded seeded({QStringLiteral("env-b"), QStringLiteral("env-c")});
    Phone phone(seeded.home.path());
    const QJsonObject own = readJson(seeded.pairingFile());
    QCOMPARE(own.value(QStringLiteral("environmentId")).toString(), QStringLiteral("env-b"));
    QCOMPARE(own.value(QStringLiteral("token")).toString(), QStringLiteral("session-env-b"));
    QCOMPARE(seeded.listed(), QStringList{QStringLiteral("env-c")});
    QCOMPARE(seeded.kept(), QStringList{QStringLiteral("session-env-c")});
    QCOMPARE(phone.bridge->state()->value(QStringLiteral("pairing")).toMap().value(QStringLiteral("phase")).toString(), QStringLiteral("paired"));
  }

  // The saved one may be the only session that works.
  void startingKeepsASavedCopyWithAnotherSession() {
    Seeded seeded({QStringLiteral("env-b")}, QStringLiteral("session-refused"));
    Phone phone(seeded.home.path());
    QCOMPARE(readJson(seeded.pairingFile()).value(QStringLiteral("token")).toString(), QStringLiteral("session-refused"));
    QCOMPARE(seeded.listed(), QStringList{QStringLiteral("env-b")});
    QCOMPARE(seeded.kept(), QStringList{QStringLiteral("session-env-b")});
  }
};

QTEST_MAIN(PairingRegression)
#include "tst_PairingRegression.moc"
