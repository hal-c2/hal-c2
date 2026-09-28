#include "NativeShell.h"

#include "ShellBridge.h"

NativeShell::NativeShell(ShellBridge* bridge, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(this),
      m_store(&m_client, this),
      m_sidebar(bridge, &m_client, &m_store, this),
      m_composer(bridge, &m_client, &m_store, this),
      m_terminals(bridge, &m_client, &m_store, this) {
  bridge->addInterceptor([this](const QString& action, const QVariant& payload) {
    // A (re)loaded page asks who owns what; the answer comes as `shell.native`.
    if (action == QLatin1String("shell.native.query")) {
      if (m_composer.isActive()) announce();
      return true;
    }
    return m_sidebar.handle(action, payload) || m_composer.handle(action, payload) ||
           m_terminals.handle(action, payload);
  });
  connect(&m_store, &ShellStore::changed, this, &NativeShell::update);
  // After m_sidebar's own handler, so it has read the new input.
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    if (key == QLatin1String("sidebarInput")) update();
  });
}

void NativeShell::update() {
  if (!m_store.synchronized()) return;
  const bool sidebar = m_sidebar.coversPage();
  if (m_composer.isActive() && sidebar == m_sidebar.isActive()) return;
  m_composer.activate();
  m_terminals.activate();
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
