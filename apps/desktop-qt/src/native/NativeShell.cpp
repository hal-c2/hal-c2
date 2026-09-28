#include "NativeShell.h"

#include <QJsonObject>
#include <QQmlEngine>
#include <QtLogging>

#include <algorithm>

#include "DraftController.h"
#include "NavigationController.h"
#include "SettingsController.h"
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
        if (auto* settings = controller<SettingsController>()) settings->pageReady();
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
  // The sidebar lists the drafts.
  if (auto* drafts = controller<DraftController>()) {
    connect(drafts, &DraftController::changed, &m_sidebar, &SidebarController::refresh);
  }
  // And groups, orders and dates them as this device's preferences say.
  if (auto* settings = controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, &m_sidebar, &SidebarController::refresh);
  }
}

void NativeShell::registerQmlSingletons() const {
  for (const Controller& entry : m_controllers) {
    if (entry.qmlName) qmlRegisterSingletonInstance("HalC2.Shell", 1, 0, entry.qmlName, entry.object.get());
  }
}

void NativeShell::update() {
  if (m_active || !m_store.synchronized()) return;
  m_active = true;
  for (const Controller& entry : m_controllers) entry.native->activate();
  m_bridge->claimKey(QStringLiteral("sidebar"));
  m_sidebar.activate();
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
