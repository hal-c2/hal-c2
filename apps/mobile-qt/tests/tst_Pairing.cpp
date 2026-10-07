// The phone pairing with an environment, against a fake MC: the scenarios of
// features/mobile/pairing-and-environments.feature that need no camera and no
// relay. Each test is what `Shell.state.pairing` says, what the shell opened,
// and what is kept on the device.

#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QUrlQuery>

#include <memory>

#include "ConnectionHealthController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PairableMc.h"
#include "Pairing.h"
#include "PairingExchange.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

// Runs the event loop until `met`, asked again each time `signal` fires. A
// state that is only passed through within one event is not the one waited
// for. The timeout only ends a wait that has already failed.
template <class Sender, class Signal>
bool waitUntil(Sender* sender, Signal signal, const std::function<bool()>& met) {
  QEventLoop loop;
  QTimer failed;
  failed.setSingleShot(true);
  failed.start(10000);
  QObject::connect(&failed, &QTimer::timeout, &loop, &QEventLoop::quit);
  const auto watching = QObject::connect(sender, signal, &loop, [&] {
    if (met()) loop.quit();
  });
  while (!met() && failed.isActive()) loop.exec();
  QObject::disconnect(watching);
  return met();
}

const pairing::Client kTestPhone{QStringLiteral("HAL-C2 on Test Phone"), QStringLiteral("mobile"), QStringLiteral("Android")};

// The shell as the phone's main.cpp builds it, over `home`.
class Shell {
public:
  explicit Shell(const QString& home) : bridge(std::make_unique<ShellBridge>()), shell(std::make_unique<NativeShell>(bridge.get())) {
    const QDir dir(home);
    dir.mkpath(QStringLiteral("config"));
    shell->client()->setRetryDelays({20});
    shell->setStoreDirs(dir.filePath(QStringLiteral("state")), dir.filePath(QStringLiteral("data")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(QStringLiteral("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(QStringLiteral("config")));
  }

  QVariantMap state(const QString& key) const { return bridge->state()->value(key).toMap(); }
  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge->dispatch(action, payload); }
  bool waitForState(const QString& key, const std::function<bool(const QVariantMap&)>& met) {
    return waitUntil(bridge.get(), &ShellBridge::stateEntryChanged, [&] { return met(state(key)); });
  }
  bool waitForConnection(const QString& phase) {
    return waitForState(QStringLiteral("connection"), [&](const QVariantMap& connection) { return connection.value(QStringLiteral("phase")) == phase; });
  }
  // The titles of the threads the shell holds, sorted.
  QStringList threads() const {
    QStringList titles;
    for (const sidebar::Thread& thread : shell->store()->threads()) titles.append(thread.title);
    titles.sort();
    return titles;
  }
  bool waitForThreads(const QStringList& titles) {
    return waitUntil(shell->store(), &ShellStore::changed, [&] { return threads() == titles; });
  }
  // A call through the MC and back: what the shell sent before it has arrived there.
  bool roundTrip(const QString& environment) {
    QEventLoop loop;
    bool answered = false;
    shell->client()->call(shell.get(), environment, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&](const QJsonValue&, const std::optional<QString>& error) {
                            answered = !error;
                            loop.quit();
                          });
    QTimer::singleShot(10000, &loop, &QEventLoop::quit);
    loop.exec();
    return answered;
  }
  // What the sidebar publishes, as text to look a title up in.
  QString sidebar() const {
    return QString::fromUtf8(QJsonDocument::fromVariant(bridge->state()->value(QStringLiteral("sidebar"))).toJson(QJsonDocument::Compact));
  }

  // Declared in teardown order: the shell goes before the bridge it intercepts.
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
};

// The phone: the shell and its pairing, started.
class Phone : public Shell {
public:
  explicit Phone(const QString& home)
      : Shell(home),
        file(QDir(home).filePath(QStringLiteral("data/pairing.json"))),
        pairing(std::make_unique<Pairing>(bridge.get(), shell.get(), QDir(home).filePath(QStringLiteral("data")), kTestPhone)) {
    pairing->start();
  }
  ~Phone() { pairing.reset(); }

  QVariantMap pairingState() const { return state(QStringLiteral("pairing")); }
  QString phase() const { return pairingState().value(QStringLiteral("phase")).toString(); }
  QString error() const { return pairingState().value(QStringLiteral("error")).toString(); }
  // The user enters `link` and adds the environment; true once the phone has an answer.
  bool pair(const QString& link) {
    dispatch(QStringLiteral("pairing.pair"), {{QStringLiteral("link"), link}});
    return waitForState(QStringLiteral("pairing"), [](const QVariantMap& pairing) { return pairing.value(QStringLiteral("phase")) != QLatin1String("pairing"); });
  }
  // What the device keeps of the paired environment; empty when it keeps none.
  QJsonObject kept() const {
    QFile saved(file);
    return saved.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(saved.readAll()).object() : QJsonObject();
  }

  QString file;
  std::unique_ptr<Pairing> pairing;
};

const QVariantMap kUnpaired{{QStringLiteral("phase"), QStringLiteral("unpaired")},
                            {QStringLiteral("error"), QString()},
                            {QStringLiteral("link"), QString()},
                            {QStringLiteral("origin"), QString()},
                            {QStringLiteral("label"), QString()}};

}  // namespace

class tst_Pairing : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { QStandardPaths::setTestModeEnabled(true); }

  // First launch with no environments invites the user to add one.
  void firstLaunchHasNothingPaired() {
    QTemporaryDir home;
    Phone phone(home.path());
    QCOMPARE(phone.pairingState(), kUnpaired);
    QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
    QVERIFY(phone.shell->store()->environments().isEmpty());
    QVERIFY(!QFile::exists(phone.file));
  }

  // Pasting a pairing link adds the environment.
  void pairingLinkAddsTheEnvironment() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    Phone phone(home.path());
    const QString link = macbook.link();
    phone.dispatch(QStringLiteral("pairing.pair"), {{QStringLiteral("link"), link}});
    QCOMPARE(phone.phase(), QStringLiteral("pairing"));
    QVERIFY(phone.waitForState(QStringLiteral("pairing"), [](const QVariantMap& pairing) { return pairing.value(QStringLiteral("phase")) == QLatin1String("paired"); }));
    const QVariantMap paired{{QStringLiteral("phase"), QStringLiteral("paired")},
                             {QStringLiteral("error"), QString()},
                             {QStringLiteral("link"), QString()},
                             {QStringLiteral("origin"), macbook.mc.origin().toString()},
                             {QStringLiteral("label"), QStringLiteral("My MacBook")}};
    QCOMPARE(phone.pairingState(), paired);

    // The MC was told who asked, and its token bought one session.
    QCOMPARE(macbook.exchanges.size(), 1);
    const QUrlQuery form = macbook.exchanges.first();
    QCOMPARE(form.queryItemValue(QStringLiteral("grant_type"), QUrl::FullyDecoded), QStringLiteral("urn:ietf:params:oauth:grant-type:token-exchange"));
    QCOMPARE(form.queryItemValue(QStringLiteral("subject_token_type"), QUrl::FullyDecoded),
             QStringLiteral("urn:hal-c2:params:oauth:token-type:environment-bootstrap"));
    QCOMPARE(form.queryItemValue(QStringLiteral("client_label"), QUrl::FullyDecoded), QStringLiteral("HAL-C2 on Test Phone"));
    QCOMPARE(form.queryItemValue(QStringLiteral("client_device_type")), QStringLiteral("mobile"));
    QCOMPARE(form.queryItemValue(QStringLiteral("client_os")), QStringLiteral("Android"));
    QVERIFY(macbook.pairingTokens.isEmpty());

    // Its threads load, over a socket the session's ticket opened.
    QVERIFY(phone.waitForThreads({macbook.threadTitle()}));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    QVERIFY(macbook.connectedWithTicket());
    QVERIFY(phone.sidebar().contains(macbook.threadTitle()));

    // The session is kept on the device, for its user alone.
    const QJsonObject kept{{QStringLiteral("origin"), macbook.mc.origin().toString()},
                           {QStringLiteral("token"), macbook.sessions.last()},
                           {QStringLiteral("label"), QStringLiteral("My MacBook")},
                           {QStringLiteral("environmentId"), QStringLiteral("env-a")}};
    QCOMPARE(phone.kept(), kept);
    QCOMPARE(QFile::permissions(phone.file), QFile::ReadOwner | QFile::WriteOwner | QFile::ReadUser | QFile::WriteUser);
  }

  // The address the user types is completed with a sensible scheme.
  void addressIsCompletedWithAScheme_data() {
    QTest::addColumn<QString>("typed");
    QTest::addColumn<QStringList>("tried");
    QTest::addColumn<QString>("token");
    QTest::newRow("address and port") << "192.168.1.20:3773#token=abc" << QStringList{"https://192.168.1.20:3773", "http://192.168.1.20:3773"} << "abc";
    QTest::newRow("name") << "devbox.tailnet.ts.net#token=abc" << QStringList{"https://devbox.tailnet.ts.net", "http://devbox.tailnet.ts.net"} << "abc";
    QTest::newRow("https, token in the query") << "https://devbox.example/?token=a" << QStringList{"https://devbox.example"} << "a";
    QTest::newRow("http is kept") << "http://192.168.1.20:3780/?token=a" << QStringList{"http://192.168.1.20:3780"} << "a";
    QTest::newRow("a path is not part of the origin") << "https://box.tailnet.ts.net/pair#token=a" << QStringList{"https://box.tailnet.ts.net"} << "a";
    QTest::newRow("the fragment's token wins") << "https://devbox.example/?token=query#token=fragment" << QStringList{"https://devbox.example"} << "fragment";
    QTest::newRow("spaces around it") << "  devbox.example:3780/?token=a%2Fb \n" << QStringList{"https://devbox.example:3780", "http://devbox.example:3780"} << "a/b";
    QTest::newRow("no token") << "https://devbox.example/" << QStringList{} << "";
    QTest::newRow("no address") << "#token=abc" << QStringList{} << "";
    QTest::newRow("not a web address") << "ssh://devbox.example/?token=a" << QStringList{} << "";
    QTest::newRow("nothing") << "" << QStringList{} << "";
  }
  void addressIsCompletedWithAScheme() {
    QFETCH(QString, typed);
    QFETCH(QStringList, tried);
    QFETCH(QString, token);
    const auto link = pairing::readLink(typed);
    QCOMPARE(link.has_value(), !tried.isEmpty());
    if (!link) return;
    QStringList origins;
    for (const QUrl& origin : link->origins) origins.append(origin.toString());
    QCOMPARE(origins, tried);
    QCOMPARE(link->token, token);
  }

  // An address typed without a scheme reaches an MC that serves plain HTTP.
  void addressWithoutASchemeFallsBackToHttp() {
    QTemporaryDir home;
    PairableMc devbox(QStringLiteral("a"), QStringLiteral("devbox"));
    PlainListener listener(devbox.mc.origin());
    Phone phone(home.path());
    const QString token = QUrl(devbox.link()).query();
    QVERIFY(phone.pair(listener.address() + QLatin1Char('#') + token));
    QCOMPARE(phone.error(), QString());
    QCOMPARE(phone.phase(), QStringLiteral("paired"));
    QCOMPARE(phone.pairingState().value(QStringLiteral("origin")).toString(), QStringLiteral("http://") + listener.address());
    QCOMPARE(phone.shell->client()->origin(), QUrl(QStringLiteral("http://") + listener.address()));
    QVERIFY(phone.waitForThreads({devbox.threadTitle()}));
  }

  // A spent or wrong pairing token is refused.
  void refusedTokenKeepsTheForm_data() {
    QTest::addColumn<bool>("spent");
    QTest::newRow("spent") << true;
    QTest::newRow("wrong") << false;
  }
  void refusedTokenKeepsTheForm() {
    QFETCH(bool, spent);
    QTemporaryDir home, other;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    QString link = macbook.mc.origin().toString() + QStringLiteral("/?token=never-issued");
    if (spent) {
      link = macbook.link();
      Phone first(other.path());
      QVERIFY(first.pair(link));
      QCOMPARE(first.phase(), QStringLiteral("paired"));
    }
    const qsizetype sessions = macbook.sessions.size();
    const qsizetype sockets = macbook.mc.connections.size();
    Phone phone(home.path());
    QVERIFY(phone.pair(link));
    const QVariantMap refused{{QStringLiteral("phase"), QStringLiteral("unpaired")},
                              {QStringLiteral("error"), QStringLiteral("Pairing failed: the link was already used or has expired. Ask the environment for a fresh one.")},
                              {QStringLiteral("link"), link},
                              {QStringLiteral("origin"), QString()},
                              {QStringLiteral("label"), QString()}};
    QCOMPARE(phone.pairingState(), refused);
    QCOMPARE(macbook.sessions.size(), sessions);
    QCOMPARE(macbook.mc.connections.size(), sockets);
    QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
    QVERIFY(!QFile::exists(phone.file));
  }

  // An unreachable address reports that the environment cannot be reached.
  void unreachableAddressSaysSo_data() {
    QTest::addColumn<QString>("scheme");
    QTest::newRow("http") << "http://";
    QTest::newRow("no scheme") << "";
  }
  void unreachableAddressSaysSo() {
    QFETCH(QString, scheme);
    QTemporaryDir home;
    Phone phone(home.path());
    const QString address = deadAddress();
    const QString link = scheme + address + QStringLiteral("/?token=abc");
    QVERIFY(phone.pair(link));
    QCOMPARE(phone.error(), QStringLiteral("The environment at %1 could not be reached. Check the address, and that this device is on its network.").arg(address));
    QCOMPARE(phone.phase(), QStringLiteral("unpaired"));
    QCOMPARE(phone.pairingState().value(QStringLiteral("link")).toString(), link);
    QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
    QVERIFY(!QFile::exists(phone.file));
  }

  // Something answers at the address, and it is not an MC: the token stays unspent.
  void addressThatIsNotAnMcSaysSo() {
    QTemporaryDir home;
    PairableMc router(QStringLiteral("a"), QStringLiteral("router"));
    router.isMc = false;
    Phone phone(home.path());
    const QString link = router.link();
    QVERIFY(phone.pair(link));
    QCOMPARE(phone.error(), QStringLiteral("%1 answered, but it is not a HAL-C2 environment. Check the address.").arg(router.mc.origin().authority()));
    QCOMPARE(phone.phase(), QStringLiteral("unpaired"));
    QCOMPARE(phone.pairingState().value(QStringLiteral("link")).toString(), link);
    QVERIFY(router.exchanges.isEmpty());
    QVERIFY(!QFile::exists(phone.file));
  }

  // What is entered is not a pairing link at all.
  void textThatIsNotALinkSaysSo() {
    QTemporaryDir home;
    Phone phone(home.path());
    phone.dispatch(QStringLiteral("pairing.pair"), {{QStringLiteral("link"), QStringLiteral("devbox.example")}});
    QCOMPARE(phone.phase(), QStringLiteral("unpaired"));
    QCOMPARE(phone.error(), QStringLiteral("That is not a pairing link. Enter the link the environment gave you, with its token."));
    QCOMPARE(phone.pairingState().value(QStringLiteral("link")).toString(), QStringLiteral("devbox.example"));
  }

  // An environment running an incompatible version is explained, and its token is not spent.
  void incompatibleVersionIsExplained_data() {
    QTest::addColumn<int>("protocol");
    QTest::addColumn<QString>("told");
    QTest::newRow("newer server") << McClient::kProtocol + 1
                                  << "This app is too old for My MacBook. Update the app: the two need compatible versions of HAL-C2.";
    QTest::newRow("older server") << McClient::kProtocol - 1
                                  << "My MacBook runs an older HAL-C2 than this app. Update it: the two need compatible versions of HAL-C2.";
  }
  void incompatibleVersionIsExplained() {
    QFETCH(int, protocol);
    QFETCH(QString, told);
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    macbook.protocol = protocol;
    Phone phone(home.path());
    QVERIFY(phone.pair(macbook.link()));
    QCOMPARE(phone.error(), told);
    QCOMPARE(phone.phase(), QStringLiteral("unpaired"));
    // It does not try to sync it: no session was bought and no socket opened.
    QVERIFY(macbook.exchanges.isEmpty());
    QVERIFY(macbook.mc.connections.isEmpty());
    QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
    QVERIFY(!QFile::exists(phone.file));
  }

  // A paired environment that now runs an incompatible version is not synced either.
  void pairedEnvironmentThatBecameIncompatibleIsNotSynced() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    }
    const qsizetype sockets = macbook.mc.connections.size();
    macbook.protocol = McClient::kProtocol + 1;
    Phone phone(home.path());
    QVERIFY(phone.waitForConnection(QStringLiteral("blocked")));
    QCOMPARE(phone.state(QStringLiteral("connection")).value(QStringLiteral("detail")).toString(), QStringLiteral("Update HAL-C2 on this device to connect."));
    QCOMPARE(phone.phase(), QStringLiteral("paired"));
    QCOMPARE(phone.shell->client()->retryDelay(), 0);
    QCOMPARE(macbook.mc.connections.size(), sockets);
  }

  // Pairing with an environment that is already paired updates it instead of duplicating it.
  void pairingAgainDoesNotDuplicate_data() {
    QTest::addColumn<bool>("elsewhere");
    QTest::newRow("at the same address") << false;
    QTest::newRow("at another address of it") << true;
  }
  void pairingAgainDoesNotDuplicate() {
    QFETCH(bool, elsewhere);
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    PlainListener other(macbook.mc.origin());
    Phone phone(home.path());
    QVERIFY(phone.pair(macbook.link()));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    const QString firstSession = macbook.sessions.last();
    const quint64 snapshots = phone.shell->store()->snapshots();

    const QString again = macbook.link();
    const QString origin = elsewhere ? QStringLiteral("http://") + other.address() : macbook.mc.origin().toString();
    QVERIFY(phone.pair(origin + QStringLiteral("/?") + QUrl(again).query()));
    QCOMPARE(phone.phase(), QStringLiteral("paired"));
    QCOMPARE(phone.error(), QString());
    // What it showed stays while the new session connects. At another address
    // the rows held are another origin's (ShellStore::open) until its MC answers.
    if (!elsewhere) QCOMPARE(phone.threads(), QStringList{macbook.threadTitle()});
    QVERIFY(waitUntil(phone.shell->store(), &ShellStore::changed, [&] { return phone.shell->store()->snapshots() > snapshots; }));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));

    // One environment, once, on the new session.
    QCOMPARE(phone.shell->store()->environments(), QStringList{QStringLiteral("env-a")});
    QCOMPARE(phone.threads(), QStringList{macbook.threadTitle()});
    QCOMPARE(phone.sidebar().count(macbook.threadTitle()), 1);
    QCOMPARE(phone.pairingState().value(QStringLiteral("origin")).toString(), origin);
    QCOMPARE(phone.pairingState().value(QStringLiteral("label")).toString(), QStringLiteral("My MacBook"));
    QVERIFY(macbook.sessions.last() != firstSession);
    const QJsonObject kept{{QStringLiteral("origin"), origin},
                           {QStringLiteral("token"), macbook.sessions.last()},
                           {QStringLiteral("label"), QStringLiteral("My MacBook")},
                           {QStringLiteral("environmentId"), QStringLiteral("env-a")}};
    QCOMPARE(phone.kept(), kept);
    // The socket of the first session was given up for the second's.
    QCOMPARE(macbook.mc.connections.size(), 2);
    QVERIFY(macbook.connectedWithTicket());
  }

  // Pairing with another environment replaces the one the phone had.
  void pairingWithAnotherReplaces() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    PairableMc office(QStringLiteral("b"), QStringLiteral("Office Mac"));
    Phone phone(home.path());
    QVERIFY(phone.pair(macbook.link()));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));

    QVERIFY(phone.pair(office.link()));
    QCOMPARE(phone.pairingState().value(QStringLiteral("label")).toString(), QStringLiteral("Office Mac"));
    // The MacBook's rows went as soon as it was replaced.
    QVERIFY(!phone.threads().contains(macbook.threadTitle()));
    QVERIFY(phone.waitForThreads({office.threadTitle()}));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    QCOMPARE(phone.shell->store()->environments(), QStringList{QStringLiteral("env-b")});
    QVERIFY(!phone.sidebar().contains(macbook.threadTitle()));
    QCOMPARE(phone.kept().value(QLatin1String("origin")).toString(), office.mc.origin().toString());
    QCOMPARE(phone.kept().value(QLatin1String("environmentId")).toString(), QStringLiteral("env-b"));
  }

  // Started again, the phone opens the environment it kept without asking.
  void restartOpensTheKeptEnvironment() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    }
    const qsizetype sockets = macbook.mc.connections.size();
    Phone phone(home.path());
    // Before anything answers: it is paired, with what it knew of the environment.
    const QVariantMap paired{{QStringLiteral("phase"), QStringLiteral("paired")},
                             {QStringLiteral("error"), QString()},
                             {QStringLiteral("link"), QString()},
                             {QStringLiteral("origin"), macbook.mc.origin().toString()},
                             {QStringLiteral("label"), QStringLiteral("My MacBook")}};
    QCOMPARE(phone.pairingState(), paired);
    QVERIFY(phone.waitForThreads({macbook.threadTitle()}));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    // On the session it had: nothing was exchanged again.
    QCOMPARE(macbook.exchanges.size(), 1);
    QCOMPARE(macbook.mc.connections.size(), sockets + 1);
    QVERIFY(macbook.connectedWithTicket());
  }

  // The label the phone shows follows the environment's own.
  void labelFollowsTheEnvironment() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("devbox"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    }
    macbook.mc.label = QStringLiteral("My MacBook");
    Phone phone(home.path());
    QCOMPARE(phone.pairingState().value(QStringLiteral("label")).toString(), QStringLiteral("devbox"));
    QVERIFY(phone.waitForState(QStringLiteral("pairing"), [](const QVariantMap& pairing) { return pairing.value(QStringLiteral("label")) == QLatin1String("My MacBook"); }));
    QCOMPARE(phone.kept().value(QLatin1String("label")).toString(), QStringLiteral("My MacBook"));
  }

  // The user removes the environment from the phone.
  void forgettingRemovesTheEnvironment() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
      QVERIFY(phone.sidebar().contains(macbook.threadTitle()));
      // A thread of it open, and a draft with unsent text.
      phone.dispatch(QStringLiteral("thread.open"), {{QStringLiteral("key"), QStringLiteral("env-a:t-a")}});
      auto* drafts = phone.shell->controller<DraftController>();
      drafts->setText(drafts->start(QStringLiteral("env-a"), QStringLiteral("p-a")), QStringLiteral("roll back the deploy"));
      QCOMPARE(drafts->drafts().size(), 1);

      phone.dispatch(QStringLiteral("pairing.forget"));
      QCOMPARE(phone.pairingState(), kUnpaired);
      QVERIFY(!QFile::exists(phone.file));
      QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
      // Nothing of it is left to show.
      QVERIFY(phone.shell->store()->environments().isEmpty());
      QVERIFY(phone.threads().isEmpty());
      QVERIFY(phone.shell->store()->projects().isEmpty());
      QVERIFY(!phone.sidebar().contains(macbook.threadTitle()));
      QVERIFY(!phone.sidebar().contains(QStringLiteral("project of a")));
      QVERIFY(drafts->drafts().isEmpty());
      QVERIFY(!phone.sidebar().contains(QStringLiteral("roll back the deploy")));
      QVERIFY(phone.state(QStringLiteral("route")).value(QStringLiteral("threadKey")).isNull());
      QVERIFY(phone.state(QStringLiteral("route")).value(QStringLiteral("draftId")).isNull());
    }
    // Nor to come back to.
    const qsizetype sockets = macbook.mc.connections.size();
    Phone phone(home.path());
    QCOMPARE(phone.pairingState(), kUnpaired);
    QCOMPARE(phone.shell->client()->phase(), McClient::Phase::Closed);
    QCOMPARE(macbook.mc.connections.size(), sockets);
  }

  // Forgetting before the environment has answered (it is offline, or the app
  // just started) leaves none of the drafts written for it either.
  void forgettingBeforeItAnswersDropsItsDrafts() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
      auto* drafts = phone.shell->controller<DraftController>();
      drafts->setText(drafts->start(QStringLiteral("env-a"), QStringLiteral("p-a")), QStringLiteral("roll back the deploy"));
    }
    {
      // Started again: the draft is read, and no row of the environment is in yet.
      Phone phone(home.path());
      QCOMPARE(phone.phase(), QStringLiteral("paired"));
      QCOMPARE(phone.shell->controller<DraftController>()->drafts().size(), 1);
      QVERIFY(phone.shell->store()->environments().isEmpty());
      phone.dispatch(QStringLiteral("pairing.forget"));
      QCOMPARE(phone.pairingState(), kUnpaired);
      QVERIFY(phone.shell->controller<DraftController>()->drafts().isEmpty());
    }
    Phone phone(home.path());
    QVERIFY(phone.shell->controller<DraftController>()->drafts().isEmpty());
  }

  // A session that cannot be deleted from the device is not reported as
  // forgotten: it would be opened again at the next start.
  void aSessionThatCannotBeDeletedStaysPaired() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    Phone phone(home.path());
    QVERIFY(phone.pair(macbook.link()));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    const QString data = QFileInfo(phone.file).absolutePath();
    QVERIFY(QFile::setPermissions(data, QFile::ReadOwner | QFile::ExeOwner));

    phone.dispatch(QStringLiteral("pairing.forget"));
    QVERIFY(QFile::setPermissions(data, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
    QCOMPARE(phone.phase(), QStringLiteral("paired"));
    QVERIFY(phone.error().contains(QStringLiteral("could not be forgotten")));
    QVERIFY(QFile::exists(phone.file));
    QVERIFY(phone.sidebar().contains(macbook.threadTitle()));
    QVERIFY(phone.shell->client()->phase() != McClient::Phase::Closed);

    // Once it can be deleted, forgetting works and the error goes.
    phone.dispatch(QStringLiteral("pairing.forget"));
    QCOMPARE(phone.pairingState(), kUnpaired);
    QVERIFY(!QFile::exists(phone.file));
  }

  // Forgetting one environment and pairing with another shows the other alone.
  void forgetThenPairAnother() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    PairableMc office(QStringLiteral("b"), QStringLiteral("Office Mac"));
    // The MacBook streams the thread the phone opens, up to an offset of its own.
    macbook.mc.onShape(QStringLiteral("stream"), [&macbook](int id, const QJsonObject&) {
      macbook.mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")},
                       {QStringLiteral("id"), id},
                       {QStringLiteral("part"), 0},
                       {QStringLiteral("rows"), QJsonArray()},
                       {QStringLiteral("done"), true},
                       {QStringLiteral("offset"), 7}});
      macbook.mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}});
    });
    // An MC sends the settings of its own machines, and knows no other's.
    for (PairableMc* member : {&macbook, &office}) {
      member->mc.onShape(QStringLiteral("config"), [member](int id, const QJsonObject& shape) {
        FakeMc& mc = member->mc;
        if (shape.value(QLatin1String("environment")) == mc.environmentId) {
          mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), QJsonObject()}});
        } else {
          mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unknown environment")}});
          mc.forget(id);
        }
      });
    }
    Phone phone(home.path());
    QVERIFY(phone.pair(macbook.link()));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    phone.dispatch(QStringLiteral("thread.open"), {{QStringLiteral("key"), QStringLiteral("env-a:t-a")}});
    QVERIFY(phone.waitForState(QStringLiteral("route"), [](const QVariantMap& route) { return route.value(QStringLiteral("threadKey")) == QLatin1String("env-a:t-a"); }));

    phone.dispatch(QStringLiteral("pairing.forget"));
    QVERIFY(phone.pair(office.link()));
    QCOMPARE(phone.error(), QString());
    QVERIFY(phone.waitForThreads({office.threadTitle()}));
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));

    const QVariantMap paired{{QStringLiteral("phase"), QStringLiteral("paired")},
                             {QStringLiteral("error"), QString()},
                             {QStringLiteral("link"), QString()},
                             {QStringLiteral("origin"), office.mc.origin().toString()},
                             {QStringLiteral("label"), QStringLiteral("Office Mac")}};
    QCOMPARE(phone.pairingState(), paired);
    QCOMPARE(phone.kept().value(QLatin1String("environmentId")).toString(), QStringLiteral("env-b"));
    QCOMPARE(phone.shell->store()->environments(), QStringList{QStringLiteral("env-b")});
    QVERIFY(phone.sidebar().contains(office.threadTitle()));
    QVERIFY(!phone.sidebar().contains(macbook.threadTitle()));
    QVERIFY(!phone.sidebar().contains(QStringLiteral("project of a")));

    // Everything the shell asked the Office Mac for has arrived there.
    QVERIFY(phone.roundTrip(QStringLiteral("env-b")));
    // The thread it had open is not asked of the Office Mac, whose offsets are not the MacBook's.
    QStringList streams;
    for (const QJsonObject& sub : std::as_const(office.mc.subscriptions)) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("stream")) {
        streams.append(QString::fromUtf8(QJsonDocument(sub).toJson(QJsonDocument::Compact)));
      }
    }
    QVERIFY2(streams.isEmpty(), qPrintable(streams.join(QLatin1Char('\n'))));
    QVERIFY(phone.state(QStringLiteral("route")).value(QStringLiteral("threadKey")).isNull());
    // The settings it follows and reads are the Office Mac's.
    QStringList followed, own;
    for (const int id : office.mc.subscribers(QStringLiteral("config"))) {
      const QJsonObject shape = office.mc.shapeOf(id);
      followed.append(shape.value(QLatin1String("environment")).toString());
      // The shell's own settings, among each machine's.
      if (shape.value(QLatin1String("usageLimitsCommand")).toBool()) own.append(followed.last());
    }
    QCOMPARE(own, QStringList{QStringLiteral("env-b")});
    QCOMPARE(followed.count(QStringLiteral("env-b")), followed.size());
    QStringList read;
    for (const FakeMc::Rpc& rpc : std::as_const(office.mc.calls)) {
      if (rpc.method == QLatin1String("hal-c2.readSettings")) read.append(rpc.environment);
    }
    QVERIFY(!read.isEmpty());
    QCOMPARE(read.count(QStringLiteral("env-b")), read.size());
    QVERIFY(phone.shell->controller<SettingsController>()->ready());
  }

  // A session the MC later refuses asks for a fresh link, and the session that buys is kept.
  void refusedSessionIsPairedAgain() {
    QTemporaryDir home;
    PairableMc macbook(QStringLiteral("a"), QStringLiteral("My MacBook"));
    {
      Phone phone(home.path());
      QVERIFY(phone.pair(macbook.link()));
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
      const QString revoked = macbook.sessions.last();
      macbook.revoke(revoked);
      QVERIFY(phone.waitForConnection(QStringLiteral("refused")));
      QVERIFY(phone.state(QStringLiteral("connection")).value(QStringLiteral("needsPairing")).toBool());
      // Still its environment, with what it showed of it.
      QCOMPARE(phone.phase(), QStringLiteral("paired"));
      QCOMPARE(phone.threads(), QStringList{macbook.threadTitle()});

      phone.dispatch(QStringLiteral("connection.pair"), {{QStringLiteral("pairingUrl"), macbook.link()}});
      QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
      QVERIFY(macbook.sessions.last() != revoked);
      QCOMPARE(phone.kept().value(QLatin1String("token")).toString(), macbook.sessions.last());
      QCOMPARE(phone.kept().value(QLatin1String("label")).toString(), QStringLiteral("My MacBook"));
      // The MC lists the same phone, not a desktop.
      QCOMPARE(macbook.exchanges.last().queryItemValue(QStringLiteral("client_label"), QUrl::FullyDecoded), QStringLiteral("HAL-C2 on Test Phone"));
      QCOMPARE(macbook.exchanges.last().queryItemValue(QStringLiteral("client_device_type")), QStringLiteral("mobile"));
    }
    // The next start uses the session that was bought.
    Phone phone(home.path());
    QVERIFY(phone.waitForConnection(QStringLiteral("connected")));
    QCOMPARE(macbook.exchanges.size(), 2);
  }

  // The desktop's "pair again" is as it was: a shell with no Pairing says it is the desktop.
  void desktopPairsAgainAsBefore() {
    QTemporaryDir home;
    PairableMc workstation(QStringLiteral("a"), QStringLiteral("Workstation"));
    Shell desktop(home.path());
    desktop.shell->open(workstation.mc.origin(), QStringLiteral("a-session-it-revoked"));
    QVERIFY(desktop.waitForConnection(QStringLiteral("refused")));

    desktop.dispatch(QStringLiteral("connection.pair"), {{QStringLiteral("pairingUrl"), QStringLiteral("not a link")}});
    QCOMPARE(desktop.state(QStringLiteral("connection")).value(QStringLiteral("pairingError")).toString(), QStringLiteral("Enter a pairing link from the environment."));

    desktop.dispatch(QStringLiteral("connection.pair"), {{QStringLiteral("pairingUrl"), workstation.mc.origin().toString() + QStringLiteral("/pair#token=spent")}});
    QVERIFY(desktop.state(QStringLiteral("connection")).value(QStringLiteral("pairing")).toBool());
    QVERIFY(desktop.waitForState(QStringLiteral("connection"), [](const QVariantMap& connection) { return !connection.value(QStringLiteral("pairing")).toBool(); }));
    QCOMPARE(desktop.state(QStringLiteral("connection")).value(QStringLiteral("pairingError")).toString(),
             QStringLiteral("The pairing link is invalid or expired. Ask for a fresh one."));

    const QString token = QUrl(workstation.link()).query();
    desktop.dispatch(QStringLiteral("connection.pair"), {{QStringLiteral("pairingUrl"), workstation.mc.origin().toString() + QStringLiteral("/pair#") + token}});
    QVERIFY(desktop.waitForConnection(QStringLiteral("connected")));
    QCOMPARE(desktop.state(QStringLiteral("connection")).value(QStringLiteral("pairingError")).toString(), QString());
    QVERIFY(workstation.connectedWithTicket());
    // The form the desktop has always sent.
    const QList<std::pair<QString, QString>> form{
        {QStringLiteral("grant_type"), QStringLiteral("urn:ietf:params:oauth:grant-type:token-exchange")},
        {QStringLiteral("subject_token_type"), QStringLiteral("urn:hal-c2:params:oauth:token-type:environment-bootstrap")},
        {QStringLiteral("subject_token"), QStringLiteral("pair-env-a-1")},
        {QStringLiteral("client_label"), QStringLiteral("HAL-C2 desktop")},
        {QStringLiteral("client_device_type"), QStringLiteral("desktop")},
    };
    QCOMPARE(workstation.exchanges.last().queryItems(QUrl::FullyDecoded), form);
  }
};

QTEST_MAIN(tst_Pairing)
#include "tst_Pairing.moc"
