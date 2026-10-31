#include "MacPermissionHelper.h"

#include <algorithm>
#include <cmath>

MacPermissionHelper::MacPermissionHelper(MacPlatform* platform, QObject* parent) : QObject(parent), m_platform(platform) {
  m_checks.setInterval(1000);
  m_tracking.setInterval(500);
  connect(&m_checks, &QTimer::timeout, this, &MacPermissionHelper::check);
  connect(&m_tracking, &QTimer::timeout, this, &MacPermissionHelper::track);
  connect(platform, &MacPlatform::helperDismissed, this, &MacPermissionHelper::finish);
  connect(platform, &MacPlatform::helperRevealRequested, platform, &MacPlatform::revealApp);
}

QRect MacPermissionHelper::boundsBeside(const QRect& settings) {
  constexpr int sidebar = 216;
  constexpr int inset = 16;
  constexpr int height = 140;
  const int width = std::min(560, settings.width() - sidebar - inset * 2);
  const int x = int(std::lround(settings.x() + sidebar + (settings.width() - sidebar - width) / 2.0));
  return {x, settings.y() + settings.height() - height - inset, width, height};
}

bool MacPermissionHelper::granted() const {
  const auto permissions = m_platform ? m_platform->permissions() : std::nullopt;
  if (!permissions) return false;
  return m_permission == MacPlatform::kScreenRecording ? permissions->screenRecording : permissions->accessibility;
}

void MacPermissionHelper::show(const QString& permission) {
  close();
  m_permission = permission;
  if (!m_platform || granted()) {
    m_permission.clear();
    return;
  }
  m_checks.start();
  m_tracking.start();
  track();
}

void MacPermissionHelper::close() {
  m_checks.stop();
  m_tracking.stop();
  if (open() && m_platform) m_platform->closeHelper();
  m_permission.clear();
  m_visible = false;
  m_found = false;
  m_bounds = {};
}

void MacPermissionHelper::finish() {
  if (!open()) return;
  close();
  if (m_platform) m_platform->focusApp();
}

void MacPermissionHelper::check() {
  if (open() && granted()) finish();
}

void MacPermissionHelper::track() {
  if (!open() || !m_platform) return;
  const auto settings = m_platform->settingsWindow();
  const auto hide = [this] {
    if (m_visible) m_platform->hideHelper();
    m_visible = false;
  };
  // Without knowing where Settings is the panel would only be in the way.
  if (!settings) return hide();
  if (!settings->open) {
    if (m_found) return finish();
    return hide();
  }
  m_found = true;
  if (!settings->frontmost && !m_platform->helperFocused()) return hide();
  const QRect bounds = boundsBeside(settings->bounds);
  if (m_visible && bounds == m_bounds) return;
  m_bounds = bounds;
  m_visible = true;
  m_platform->showHelper(bounds, kText);
}
