#include "NativeShell.h"

#include <QJsonObject>
#include <QTimer>
#include <QtLogging>

#include "ShellBridge.h"

NativeShell::NativeShell(ShellBridge* bridge, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(this),
      m_store(&m_client, this),
      m_sidebar(bridge, &m_client, &m_store, this),
      m_composer(bridge, &m_client, &m_store, this),
      m_terminals(bridge, &m_client, &m_store, this),
      m_cluster(bridge, &m_client, this) {
  bridge->addInterceptor([this](const QString& action, const QVariant& payload) {
    // A (re)loaded page asks who owns what; the answer comes as `shell.native`.
    if (action == QLatin1String("shell.native.query")) {
      if (m_composer.isActive()) announce();
      return true;
    }
    return m_sidebar.handle(action, payload) || m_composer.handle(action, payload) ||
           m_terminals.handle(action, payload) || m_cluster.handle(action, payload);
  });
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
  if (m_composer.isActive() && sidebar == m_sidebar.isActive()) return;
  m_composer.activate();
  m_terminals.activate();
  m_cluster.activate();
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
