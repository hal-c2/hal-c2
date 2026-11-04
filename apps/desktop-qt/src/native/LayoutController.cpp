#include "LayoutController.h"

#include <QtMath>

#include <algorithm>
#include <limits>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<LayoutController> registrar(QStringLiteral("layout"), {QStringLiteral("layout")});

const QString kSidebarCollapsed = QStringLiteral("sidebarCollapsed");
const QString kZoomLevel = QStringLiteral("zoomLevel");
const QString kSidebarWidthKey = QStringLiteral("sidebarWidth");
// The zoom menu's step, and the range of 25% to 500%.
constexpr double kZoomStep = 0.5;
constexpr double kMinZoomLevel = -7.5;
constexpr double kMaxZoomLevel = 8.5;

bool g_systemReducedMotion = false;

}  // namespace

bool LayoutController::systemReducedMotion() {
  return g_systemReducedMotion;
}

void LayoutController::setSystemReducedMotion(bool reduced) {
  g_systemReducedMotion = reduced;
}

int LayoutController::panelAnimationMs() const {
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings || g_systemReducedMotion || settings->setting(QStringLiteral("reduceMotion")).toBool()) return 0;
  return std::clamp(settings->setting(QStringLiteral("panelAnimationDurationMs")).toInt(), 0, 400);
}

// The layout needs no MC, so it shows before the first snapshot: as soon
// as main.cpp has given the settings their file.
LayoutController::LayoutController(ShellBridge* bridge, McClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {
  QMetaObject::invokeMethod(this, &LayoutController::load, Qt::QueuedConnection);
}

void LayoutController::load() {
  if (m_loaded) return;
  m_loaded = true;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    m_sidebarCollapsed = settings->deviceValue(kSidebarCollapsed).toBool();
    m_zoomLevel = settings->deviceValue(kZoomLevel).toDouble();
    if (const int width = settings->deviceValue(kSidebarWidthKey).toInt(); width > 0) {
      m_sidebarWidth = std::max(width, kSidebarMinWidth);
    }
    // Another window zoomed.
    connect(settings, &SettingsController::deviceChanged, this, [this, settings] {
      const double level = settings->deviceValue(kZoomLevel).toDouble();
      if (level == m_zoomLevel) return;
      m_zoomLevel = level;
      publish();
    });
  }
  publish();
}

void LayoutController::activate() {
  load();
  if (m_active) return;
  m_active = true;
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("sidebar.toggle"), keybindings::commandLabel(QStringLiteral("sidebar.toggle")),
                          [this] { toggleSidebar(); });
    keys->commands()->add(QStringLiteral("view.zoomIn"), tr("Zoom in"), [this] { setZoomLevel(m_zoomLevel + kZoomStep); });
    keys->commands()->add(QStringLiteral("view.zoomOut"), tr("Zoom out"), [this] { setZoomLevel(m_zoomLevel - kZoomStep); });
    keys->commands()->add(QStringLiteral("view.resetZoom"), tr("Actual size"), [this] { setZoomLevel(0); });
  }
}

bool LayoutController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("sidebar.toggle")) {
    toggleSidebar();
  } else if (action == QLatin1String("sidebar.resize")) {
    if (map.contains(QStringLiteral("width"))) setSidebarWidth(map.value(QStringLiteral("width")).toInt());
    else resetSidebarWidth();
  } else if (action == QLatin1String("layout.window")) {
    if (map.contains(QStringLiteral("monospace"))) setMonospace(map.value(QStringLiteral("monospace")).toBool());
    setWindowWidth(map.value(QStringLiteral("width")).toInt());
  } else {
    return false;
  }
  return true;
}

int LayoutController::sidebarRoom() const {
  return m_windowWidth > 0 ? std::max(0, m_windowWidth - kContentMinWidth) : std::numeric_limits<int>::max();
}

QString LayoutController::sidebarMode() const {
  if (narrow() && !m_overlayOpen) return QStringLiteral("rail");
  if (!narrow() && m_windowWidth > 0 && m_windowWidth < kSlimBelow) return QStringLiteral("slim");
  return QStringLiteral("full");
}

int LayoutController::sidebarWidth() const {
  if (narrow() && !m_overlayOpen) return kRailWidth;
  const int chosen = m_sidebarWidth > 0 ? m_sidebarWidth : defaultSidebarWidth();
  return std::max(std::min(chosen, sidebarRoom()), kSidebarMinWidth);
}

void LayoutController::setSidebarWidth(int width) {
  load();
  width = std::max(std::min(width, sidebarRoom()), kSidebarMinWidth);
  // The default is not a choice: a monospace interface keeps its own.
  chooseSidebarWidth(width == defaultSidebarWidth() ? 0 : width);
}

void LayoutController::resetSidebarWidth() {
  load();
  chooseSidebarWidth(0);
}

void LayoutController::chooseSidebarWidth(int width) {
  if (width == m_sidebarWidth) return;
  const int before = sidebarWidth();
  m_sidebarWidth = width;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kSidebarWidthKey, width == 0 ? QVariant() : QVariant(width));
  }
  if (sidebarWidth() != before) publish();
}

void LayoutController::setMonospace(bool monospace) {
  load();
  if (monospace == m_monospace) return;
  const int before = sidebarWidth();
  m_monospace = monospace;
  if (sidebarWidth() != before) publish();
}

void LayoutController::setWindowWidth(int width) {
  load();
  if (width == m_windowWidth) return;
  const int before = sidebarWidth();
  const QString mode = sidebarMode();
  const bool overlay = sidebarOverlay();
  const bool collapsed = sidebarCollapsed();
  const bool wasNarrow = narrow();
  m_windowWidth = width;
  if (narrow() != wasNarrow) m_overlayOpen = false;
  if (sidebarWidth() != before || sidebarMode() != mode || sidebarOverlay() != overlay ||
      sidebarCollapsed() != collapsed) {
    publish();
  }
}

void LayoutController::toggleSidebar() {
  // A narrow window opens the full list over the thread, from the rail or
  // from nothing, and puts it away again.
  if (narrow()) {
    load();
    m_overlayOpen = !m_overlayOpen;
    publish();
    return;
  }
  setSidebarCollapsed(!sidebarCollapsed());
}

void LayoutController::setSidebarCollapsed(bool collapsed) {
  load();
  if (narrow()) {
    if (m_overlayOpen == !collapsed) return;
    m_overlayOpen = !collapsed;
    publish();
    return;
  }
  if (collapsed == sidebarCollapsed()) return;
  m_sidebarCollapsed = collapsed;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kSidebarCollapsed, collapsed);
  }
  publish();
}

double LayoutController::zoom() const {
  return qPow(1.2, m_zoomLevel);
}

void LayoutController::setZoomLevel(double level) {
  load();
  level = std::clamp(level, kMinZoomLevel, kMaxZoomLevel);
  if (level == m_zoomLevel) return;
  m_zoomLevel = level;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kZoomLevel, level == 0 ? QVariant() : QVariant(level));
  }
  publish();
}

void LayoutController::publish() {
  m_bridge->publish(QStringLiteral("layout"),
                    QVariantMap{{kSidebarCollapsed, sidebarCollapsed()},
                                {kSidebarWidthKey, sidebarWidth()},
                                {QStringLiteral("sidebarMode"), sidebarMode()},
                                {QStringLiteral("sidebarOverlay"), sidebarOverlay()},
                                {QStringLiteral("contentMinimumWidth"), kContentMinWidth},
                                {QStringLiteral("zoom"), zoom()}});
}
