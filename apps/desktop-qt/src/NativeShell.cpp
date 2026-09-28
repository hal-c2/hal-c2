#include "NativeShell.h"

#include "ShellBridge.h"

NativeShell::NativeShell(ShellBridge* bridge, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(this),
      m_store(&m_client, this),
      m_sidebar(bridge, &m_client, &m_store, this),
      m_composer(bridge, &m_client, &m_store, this) {
  bridge->addInterceptor([this](const QString& action, const QVariant& payload) {
    // A (re)loaded page asks who owns what; the answer comes as `shell.native`.
    if (action == QLatin1String("shell.native.query")) {
      if (m_sidebar.isActive()) announce();
      return true;
    }
    return m_sidebar.handle(action, payload) || m_composer.handle(action, payload);
  });
  connect(&m_store, &ShellStore::changed, this, [this] {
    if (m_sidebar.isActive() || !m_store.synchronized()) return;
    m_bridge->claimKey(QStringLiteral("sidebar"));
    m_sidebar.activate();
    m_composer.activate();
    announce();
  });
}

void NativeShell::announce() {
  const QVariantMap native{
      {QStringLiteral("sidebar"), true},
      {QStringLiteral("composer"), true},
  };
  m_bridge->publish(QStringLiteral("native"), native);
  m_bridge->sendToPage(QStringLiteral("shell.native"), native);
}
