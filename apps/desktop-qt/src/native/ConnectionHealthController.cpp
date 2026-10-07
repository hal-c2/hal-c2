#include "ConnectionHealthController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QHostAddress>
#include <QNetworkAccessManager>
#include <QNetworkInformation>
#include <QNetworkInterface>

#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ConnectionHealthController> registrar(QStringLiteral("connectionHealth"),
                                                                      {QStringLiteral("connection")}, nullptr,
                                                                      NativeControllerScope::Shared);

const QString kKey = QStringLiteral("connection");

// Whether some interface besides loopback is up with an address of its own: a
// second opinion for a backend that says the device is disconnected. Android's
// says so when any network is lost, the one a phone just left for another
// included, and stays there until some network next changes.
bool hasNetwork() {
  for (const QNetworkInterface& interface : QNetworkInterface::allInterfaces()) {
    const QNetworkInterface::InterfaceFlags flags = interface.flags();
    if (!flags.testFlag(QNetworkInterface::IsUp) || !flags.testFlag(QNetworkInterface::IsRunning) || flags.testFlag(QNetworkInterface::IsLoopBack)) continue;
    for (const QNetworkAddressEntry& entry : interface.addressEntries()) {
      if (!entry.ip().isLinkLocal() && !entry.ip().isLoopback()) return true;
    }
  }
  return false;
}
const QString kDismissals = QStringLiteral("versionMismatchDismissals");

struct Version {
  QList<int> core;
  QStringList prerelease;
};

// major.minor.patch with an optional `-prerelease`; short forms pad with zeros.
std::optional<Version> parse(QString text) {
  text = text.trimmed();
  if (text.startsWith(u'v')) text.remove(0, 1);
  text = text.section(u'+', 0, 0);
  const qsizetype dash = text.indexOf(u'-');
  Version version;
  for (const QString& part : (dash < 0 ? text : text.left(dash)).split(u'.', Qt::SkipEmptyParts)) {
    bool ok = false;
    const int number = part.trimmed().toInt(&ok);
    if (!ok || number < 0) return std::nullopt;
    version.core.append(number);
  }
  if (version.core.isEmpty() || version.core.size() > 3) return std::nullopt;
  while (version.core.size() < 3) version.core.append(0);
  if (dash >= 0) version.prerelease = text.mid(dash + 1).split(u'.', Qt::SkipEmptyParts);
  return version;
}

// Negative when `left` is the older.
int compare(const Version& left, const Version& right, bool withPrerelease) {
  for (int i = 0; i < 3; ++i) {
    if (left.core[i] != right.core[i]) return left.core[i] < right.core[i] ? -1 : 1;
  }
  if (!withPrerelease) return 0;
  // A release is newer than its prereleases.
  if (left.prerelease.isEmpty() != right.prerelease.isEmpty()) return left.prerelease.isEmpty() ? 1 : -1;
  for (qsizetype i = 0; i < std::min(left.prerelease.size(), right.prerelease.size()); ++i) {
    bool leftNumber = false, rightNumber = false;
    const qlonglong a = left.prerelease[i].toLongLong(&leftNumber);
    const qlonglong b = right.prerelease[i].toLongLong(&rightNumber);
    if (leftNumber && rightNumber) {
      if (a != b) return a < b ? -1 : 1;
    } else if (left.prerelease[i] != right.prerelease[i]) {
      return left.prerelease[i] < right.prerelease[i] ? -1 : 1;
    }
  }
  if (left.prerelease.size() != right.prerelease.size()) return left.prerelease.size() < right.prerelease.size() ? -1 : 1;
  return 0;
}

}  // namespace

bool ConnectionHealthController::serverBehind(const QString& client, const QString& server) {
  if (client.trimmed().isEmpty() || server.trimmed().isEmpty()) return false;
  const auto ours = parse(client);
  const auto theirs = parse(server);
  // Versions that are not semver differ when their text does.
  if (!ours || !theirs) return client.trimmed() != server.trimmed();
  const bool nightlies = ours->prerelease.value(0) == QLatin1String("nightly") && theirs->prerelease.value(0) == QLatin1String("nightly");
  return compare(*theirs, *ours, nightlies) < 0;
}

ConnectionHealthController::ConnectionHealthController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_writeClipboard([](const QString& text) {
        QGuiApplication::clipboard()->setText(text);
        return true;
      }),
      m_network{[] { return false; }, hasNetwork},
      m_clientVersion(QCoreApplication::applicationVersion()) {
  connect(client, &McClient::phaseChanged, this, &ConnectionHealthController::update);
  connect(client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready) m_snapshotsAtReady = m_store->snapshots();
    update();
  });
  connect(store, &ShellStore::changed, this, &ConnectionHealthController::update);
  // The app comes to the foreground: a waiting retry runs now, and a
  // connection that looks healthy is checked.
  if (qGuiApp) {
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
      if (state == Qt::ApplicationActive) m_client->wake();
    });
  }
  if (QNetworkInformation::loadDefaultBackend()) {
    QNetworkInformation* network = QNetworkInformation::instance();
    m_network.disconnected = [network] { return network->reachability() == QNetworkInformation::Reachability::Disconnected; };
    connect(network, &QNetworkInformation::reachabilityChanged, this, &ConnectionHealthController::networkChanged);
  }
  // The MC the client is opened at may be on this machine where the last one
  // was not, or the other way round.
  if (auto* shell = qobject_cast<NativeShell*>(parent)) {
    connect(shell, &NativeShell::opened, this, &ConnectionHealthController::networkChanged);
  }
  update();
}

// A remote MC is not retried while this device has no network, and is tried
// at once when it returns. The MC on this machine needs none.
void ConnectionHealthController::networkChanged() {
  const QString host = m_client->origin().host();
  const bool local = host == QLatin1String("localhost") || QHostAddress(host).isLoopback();
  const bool online = local || !m_network.disconnected() || m_network.interfaceUp();
  m_client->setOnline(online);
  if (online) m_client->wake();
}

void ConnectionHealthController::activate() {
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, &ConnectionHealthController::update, Qt::UniqueConnection);
  }
  update();
}

void ConnectionHealthController::attach(NativeWindow* window) {
  if (auto* keys = window->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("connection.retry"), tr("Reconnect to the environment"), [this] { m_client->retryNow(); });
  }
}

void ConnectionHealthController::setClientVersion(const QString& version) {
  m_clientVersion = version;
  update();
}

bool ConnectionHealthController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("connection."))) return false;
  if (action == QLatin1String("connection.retry")) {
    // A subscription the MC turned down is asked for again on a new socket.
    if (m_client->isReady()) {
      m_client->reconnect();
    } else {
      m_client->retryNow();
    }
  } else if (action == QLatin1String("connection.copyTraceId")) {
    const QString traceId = m_client->failureTraceId();
    if (traceId.isEmpty()) return true;
    const bool copied = m_writeClipboard(traceId);
    if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
      if (copied) {
        toasts->show(QStringLiteral("success"), tr("Trace ID copied"), traceId);
      } else {
        toasts->error(tr("Could not copy trace ID"), traceId);
      }
    }
  } else if (action == QLatin1String("connection.pair")) {
    pair(payload.toMap().value(QStringLiteral("pairingUrl")).toString().trimmed());
  } else if (action == QLatin1String("connection.dismissVersionWarning")) {
    const QVariantMap warning = versionWarning().toMap();
    auto* settings = NativeShell::of(this)->controller<SettingsController>();
    if (warning.isEmpty() || !settings) return true;
    QStringList keys = dismissed();
    keys.append(warning.value(QStringLiteral("key")).toString());
    settings->writeDevice(kDismissals, keys);
    update();
  } else {
    return false;
  }
  return true;
}

// Spends a pairing link's single-use token on a new session with the MC the
// link names, as the desktop host does when it attaches (host/elixirMc.ts),
// and connects with it. Everything the shell holds stays as it is.
void ConnectionHealthController::pair(const QString& pairingUrl) {
  if (m_pairing) return;
  const auto link = pairing::readLink(pairingUrl);
  if (!link) {
    m_pairingError = tr("Enter a pairing link from the environment.");
    update();
    return;
  }
  m_pairing = true;
  m_pairingError.clear();
  update();
  if (!m_http) m_http = new QNetworkAccessManager(this);
  pairing::exchange(m_http, this, *link, m_pairingClient, [this](const pairing::Result& result) {
    m_pairing = false;
    if (result.outcome != pairing::Outcome::Paired) {
      m_pairingError = tr("The pairing link is invalid or expired. Ask for a fresh one.");
      update();
      return;
    }
    NativeShell::of(this)->shell()->open(result.origin, result.token);
    update();
  });
}

QString ConnectionHealthController::label() const {
  const QString served = m_store->environmentOf(m_client->mc());
  QString label = m_store->environment(served).value(QLatin1String("label")).toString();
  if (label.isEmpty()) label = m_client->descriptor().value(QLatin1String("label")).toString();
  return label.isEmpty() ? tr("the environment") : label;
}

QStringList ConnectionHealthController::dismissed() const {
  // A shared controller has no window until the shell has one.
  const NativeWindow* window = NativeShell::of(this);
  const auto* settings = window ? window->controller<SettingsController>() : nullptr;
  return settings ? settings->deviceValue(kDismissals).toStringList() : QStringList();
}

QVariant ConnectionHealthController::versionWarning() const {
  QString server = m_store->environment(m_store->environmentOf(m_client->mc())).value(QLatin1String("serverVersion")).toString();
  if (server.isEmpty()) server = m_client->descriptor().value(QLatin1String("serverVersion")).toString();
  if (!serverBehind(m_clientVersion, server)) return QVariant::fromValue(nullptr);
  const QString key = m_client->environment() + u':' + m_clientVersion.trimmed() + u':' + server.trimmed();
  if (dismissed().contains(key)) return QVariant::fromValue(nullptr);
  return QVariantMap{{QStringLiteral("key"), key},
                     {QStringLiteral("clientVersion"), m_clientVersion.trimmed()},
                     {QStringLiteral("serverVersion"), server.trimmed()},
                     {QStringLiteral("text"), tr("Version mismatch: %1 runs HAL-C2 %2, older than this app (%3). Update it to stay in sync.")
                                                  .arg(label(), server.trimmed(), m_clientVersion.trimmed())}};
}

void ConnectionHealthController::update() {
  using Phase = McClient::Phase;
  const Phase phase = m_client->phase();
  const QString reason = m_client->failure();
  QString name, status, title, detail;
  bool canRetry = false;
  switch (phase) {
    case Phase::Closed:
    case Phase::Connecting:
    case Phase::Retrying:
      // A first attempt that has not failed is connecting; anything after a failure is a reconnect.
      if (reason.isEmpty()) {
        name = QStringLiteral("connecting");
        status = tr("Connecting");
      } else {
        name = QStringLiteral("reconnecting");
        status = tr("Reconnecting: %1").arg(reason);
        title = tr("Reconnecting to %1").arg(label());
        detail = reason;
        canRetry = phase == Phase::Retrying;
      }
      break;
    case Phase::Ready:
      if (!m_store->problem().isEmpty()) {
        name = QStringLiteral("problem");
        status = tr("Could not load its data: %1").arg(m_store->problem());
        title = tr("Could not load projects and threads");
        detail = m_store->problem();
        canRetry = true;
      } else if (m_store->snapshots() > m_snapshotsAtReady) {
        name = QStringLiteral("connected");
        status = tr("Connected");
      } else {
        // The socket is open; the environment has not described itself yet.
        name = reason.isEmpty() ? QStringLiteral("connecting") : QStringLiteral("reconnecting");
        status = tr("Connecting");
      }
      break;
    case Phase::Offline:
      name = QStringLiteral("offline");
      status = tr("Waiting for the network");
      title = tr("This device is offline");
      detail = tr("HAL-C2 connects again when the network is back.");
      break;
    case Phase::Refused:
      name = QStringLiteral("refused");
      status = tr("Access refused: pair it again");
      title = tr("%1 no longer accepts this device").arg(label());
      detail = tr("Pair again with a fresh pairing link from the environment.");
      canRetry = true;
      break;
    case Phase::Blocked:
      name = QStringLiteral("blocked");
      if (m_client->blockedProtocol() > McClient::kProtocol) {
        status = tr("This app is too old: update HAL-C2 on this device");
        title = tr("This app is too old for %1").arg(label());
        detail = tr("Update HAL-C2 on this device to connect.");
      } else {
        status = tr("Its server is too old: update HAL-C2 on that environment");
        title = tr("%1 runs an older HAL-C2").arg(label());
        detail = tr("Update HAL-C2 on that environment to connect.");
      }
      canRetry = true;
      break;
  }
  const bool connected = name == QLatin1String("connected");
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("phase"), name},
                              {QStringLiteral("status"), status},
                              {QStringLiteral("title"), title},
                              {QStringLiteral("detail"), detail},
                              {QStringLiteral("reason"), connected ? QString() : reason},
                              {QStringLiteral("traceId"), connected ? QString() : m_client->failureTraceId()},
                              {QStringLiteral("canRetry"), canRetry},
                              {QStringLiteral("needsPairing"), phase == Phase::Refused},
                              {QStringLiteral("pairing"), m_pairing},
                              {QStringLiteral("pairingError"), m_pairingError},
                              {QStringLiteral("versionWarning"), connected ? versionWarning() : QVariant::fromValue(nullptr)},
                          });
}
