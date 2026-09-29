#include "LayoutController.h"

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<LayoutController> registrar(QStringLiteral("layout"), {QStringLiteral("layout")});

const QString kSidebarCollapsed = QStringLiteral("sidebarCollapsed");

}  // namespace

// The layout needs no node, so it shows before the first snapshot: as soon
// as main.cpp has given the settings their file.
LayoutController::LayoutController(ShellBridge* bridge, NodeClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {
  QMetaObject::invokeMethod(this, &LayoutController::load, Qt::QueuedConnection);
}

void LayoutController::load() {
  if (m_loaded) return;
  m_loaded = true;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    m_sidebarCollapsed = settings->deviceValue(kSidebarCollapsed).toBool();
  }
  m_bridge->claimKey(QStringLiteral("layout"));
  publish();
}

void LayoutController::activate() {
  load();
  if (m_active) return;
  m_active = true;
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("sidebar.toggle"), keybindings::commandLabel(QStringLiteral("sidebar.toggle")),
                          [this] { toggleSidebar(); });
  }
}

bool LayoutController::handle(const QString& action, const QVariant&) {
  if (action != QLatin1String("sidebar.toggle")) return false;
  toggleSidebar();
  return true;
}

void LayoutController::setSidebarCollapsed(bool collapsed) {
  load();
  if (collapsed == m_sidebarCollapsed) return;
  m_sidebarCollapsed = collapsed;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kSidebarCollapsed, collapsed);
  }
  publish();
}

void LayoutController::publish() {
  m_bridge->publish(QStringLiteral("layout"), QVariantMap{{kSidebarCollapsed, m_sidebarCollapsed}});
}
