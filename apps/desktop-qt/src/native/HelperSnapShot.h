#pragma once

#include "CaptureHelper.h"
#include "SnapShotBackend.h"

// Snap Shot on KDE Plasma and Hyprland: the window in front is captured by
// the capture helper (CaptureHelper), which setup installs when the user asks;
// the capture shortcut stays with the desktop portal's GlobalShortcuts session
// (`shortcuts`, a PortalSnapShot, which on Hyprland leaves the keys to the
// Hyprland config). Owns both.
class HelperSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  HelperSnapShot(const Platform& platform, SnapShotBackend* shortcuts, CaptureHelper* helper, QObject* parent = nullptr);

  Session session() const override;
  Shortcut shortcut() const override { return m_shortcuts->shortcut(); }
  void probe() override;
  void refresh() override;
  void bind(const QString& trigger) override { m_shortcuts->bind(trigger); }
  void release() override { m_shortcuts->release(); }
  void configure() override { m_shortcuts->configure(); }
  void checkShortcut(const QJsonObject& shortcut, std::function<void(const Check&)> done) override {
    m_shortcuts->checkShortcut(shortcut, std::move(done));
  }
  bool pause(bool paused, QString* reason) override { return m_shortcuts->pause(paused, reason); }
  void capture() override { m_helper->capture(); }
  void play(const QString& sound) override { m_shortcuts->play(sound); }
  std::optional<Setup> setup() const override;
  void perform(const QString& action) override;

  SnapShotBackend* shortcuts() const { return m_shortcuts; }
  CaptureHelper* helper() const { return m_helper; }

private:
  QString m_desktop;
  SnapShotBackend* m_shortcuts;
  CaptureHelper* m_helper;
  // The user checked again; the answer says whether that changed anything.
  bool m_rechecked = false;
};
