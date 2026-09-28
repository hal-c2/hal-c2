#include "NativeShell.h"

#include <QJsonObject>
#include <QQmlEngine>
#include <QTimer>
#include <QtLogging>

#include <algorithm>

#include "NavigationController.h"
#include "ShellBridge.h"

QList<NativeControllerRegistration>& nativeControllerRegistry() {
  static QList<NativeControllerRegistration> registry;
  return registry;
}

NativeShell::NativeShell(ShellBridge* bridge, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(this),
      m_store(&m_client, this),
      m_sidebar(bridge, &m_client, &m_store, this) {
  // Static initialisers register in link order; name order keeps it stable.
  QList<NativeControllerRegistration> registrations = nativeControllerRegistry();
  std::sort(registrations.begin(), registrations.end(),
            [](const auto& a, const auto& b) { return a.name < b.name; });
  for (const NativeControllerRegistration& registration : registrations) {
    for (const QString& key : registration.stateKeys) bridge->declareKey(key);
    std::unique_ptr<QObject> object(registration.create(bridge, &m_client, &m_store, this));
    auto* native = dynamic_cast<NativeController*>(object.get());
    m_controllers.push_back({std::move(object), native, registration.qmlName});
  }
  bridge->addInterceptor([this](const QString& action, const QVariant& payload) {
    // A (re)loaded page asks who owns what; the answer comes as `shell.native`.
    if (action == QLatin1String("shell.native.query")) {
      if (m_active) {
        announce();
        // A page that just asked knows nothing of the route yet.
        if (auto* navigation = controller<NavigationController>()) navigation->pageReady();
      }
      return true;
    }
    if (m_sidebar.handle(action, payload)) return true;
    return std::any_of(m_controllers.cbegin(), m_controllers.cend(),
                       [&](const Controller& entry) { return entry.native->handle(action, payload); });
  });
  // The sidebar marks the thread the window shows.
  if (auto* navigation = controller<NavigationController>()) {
    connect(navigation, &NavigationController::changed, &m_sidebar, &SidebarController::refresh);
  }
  connect(&m_store, &ShellStore::changed, this, &NativeShell::update);
  connect(&m_store, &ShellStore::changed, this, &NativeShell::lend);
  // A new connection may be to a restarted node, which forgot every loan.
  connect(&m_client, &NodeClient::readyChanged, this, [this](bool ready) {
    if (!ready) m_lent.clear();
  });
  // After m_sidebar's own handler, so it has read the new input.
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    if (key == QLatin1String("sidebarInput")) update();
    if (key == QLatin1String("environmentAccess")) lend();
  });
}

void NativeShell::registerQmlSingletons() const {
  for (const Controller& entry : m_controllers) {
    if (entry.qmlName) qmlRegisterSingletonInstance("HalC2.Shell", 1, 0, entry.qmlName, entry.object.get());
  }
}

void NativeShell::lend() {
  const QString own = m_store.environmentOf(m_client.node());
  if (!m_client.isReady() || own.isEmpty()) return;
  QHash<QString, QString> wanted;
  QHash<QString, QString> origins;
  for (const QVariant& value : m_bridge->state()->value(QStringLiteral("environmentAccess")).toList()) {
    const QVariantMap access = value.toMap();
    const QString id = access.value(QStringLiteral("environmentId")).toString();
    if (id.isEmpty() || m_store.servesEnvironment(id)) continue;
    const QString token = access.value(QStringLiteral("token")).toString();
    // Listed without access: the page is not connected there now, so what was
    // lent stays lent.
    if (token.isEmpty()) {
      if (m_lent.contains(id)) wanted.insert(id, m_lent.value(id));
      continue;
    }
    wanted.insert(id, token);
    origins.insert(id, access.value(QStringLiteral("origin")).toString());
  }
  for (auto it = wanted.cbegin(); it != wanted.cend(); ++it) {
    if (m_lent.value(it.key()) == it.value()) continue;
    const QString id = it.key();
    m_lent.insert(id, it.value());
    const QJsonObject payload{{QStringLiteral("origin"), origins.value(id)}, {QStringLiteral("token"), it.value()}};
    m_client.call(own, QStringLiteral("hal-c2.linkEnvironment"), payload,
                  [this, id, token = it.value()](const QJsonValue&, const std::optional<QString>& error) {
                    // A dropped connection lends everything again once it is back.
                    if (!error || !m_client.isReady() || m_lent.value(id) != token) return;
                    // The environment is offline for now: lend it again later.
                    qWarning("hal-c2-desktop: the node cannot reach %s: %s", qPrintable(id), qPrintable(*error));
                    m_lent.remove(id);
                    QTimer::singleShot(30'000, this, &NativeShell::lend);
                  });
  }
  for (const QString& id : m_lent.keys()) {
    if (wanted.contains(id)) continue;
    m_lent.remove(id);
    const QJsonObject payload{{QStringLiteral("environmentId"), id}, {QStringLiteral("borrowed"), true}};
    m_client.call(own, QStringLiteral("hal-c2.unlinkEnvironment"), payload, [](auto&&...) {});
  }
}

void NativeShell::update() {
  if (!m_store.synchronized()) return;
  const bool sidebar = m_sidebar.coversPage();
  if (m_active && sidebar == m_sidebar.isActive()) return;
  m_active = true;
  for (const Controller& entry : m_controllers) entry.native->activate();
  if (sidebar) {
    m_bridge->claimKey(QStringLiteral("sidebar"));
    m_sidebar.activate();
  } else {
    m_bridge->releaseKey(QStringLiteral("sidebar"));
    m_sidebar.deactivate();
  }
  announce();
}

void NativeShell::announce() {
  const QVariantMap native{
      {QStringLiteral("sidebar"), m_sidebar.isActive()},
      {QStringLiteral("composer"), true},
  };
  m_bridge->publish(QStringLiteral("native"), native);
  m_bridge->sendToPage(QStringLiteral("shell.native"), native);
}
