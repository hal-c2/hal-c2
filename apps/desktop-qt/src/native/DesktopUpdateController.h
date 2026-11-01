#pragma once

#include <QObject>
#include <QPointer>
#include <QUrl>

#include "DesktopUpdater.h"
#include "NativeController.h"

class McClient;
class NativeWindow;
class SettingsController;
class ShellBridge;
class ToastController;

// The desktop app's own updates in the shell: `desktopUpdate` is what the
// sidebar's update button, Settings > General and the Intel build warning
// show (DesktopUpdater's state and the words for it); the button's actions,
// the track switch and "Check for Updates" in the command palette (the
// application menu's, which this app has none of) land here. The track is
// this device's (`desktopUpdate` in its settings): the installed build's
// until the user picks one. It also tells the MC where the update stands
// (`server.reportDesktopUpdateStatus`) and takes the MC's update requests
// (`desktopUpdateControl`). One per process.
//
// Actions: desktopUpdate.press (what the button does now), .check, .menuCheck,
// .download, .install, .setTrack {channel}, .openReleaseNotes {url}.
class DesktopUpdateController : public QObject, public NativeController {
  Q_OBJECT

public:
  DesktopUpdateController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;
  void attach(NativeWindow* window) override;

  DesktopUpdater* updater() const { return m_updater; }
  DesktopRemoteUpdates* remote() const { return m_remote; }
  // The track this device follows.
  QString channel() const;

private:
  void publish();
  void report(const QJsonObject& payload);
  void onControl(const QJsonObject& frame);
  void check(bool fromMenu);
  void download();
  void confirmInstall();
  void install();
  void setTrack(const QString& channel);
  bool openUrl(const QUrl& url);
  void toldDownloaded();
  ToastController* toasts() const;
  SettingsController* settings() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  DesktopUpdater* m_updater = nullptr;
  DesktopRemoteUpdates* m_remote = nullptr;
  int m_control = -1;
  QJsonObject m_unsentFailure;
};
