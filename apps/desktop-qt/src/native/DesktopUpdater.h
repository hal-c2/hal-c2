#pragma once

#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QUrl>

#include <functional>
#include <memory>
#include <optional>

#include "DesktopUpdateLogic.h"

// The desktop app updating itself (upstream apps/desktop/src/updates/
// DesktopUpdates.ts): checks the feed 15 s after launch and every 4 minutes,
// downloads what the button asks for, and installs it by stopping the MC,
// replacing the app and relaunching it. One step at a time; a failed install
// starts the MC again. What it touches is behind seams (the environment, the
// feed and the files, the clock) so tests drive it without a network or a
// sleep. DesktopUpdateController shows it; DesktopRemoteUpdates runs it for
// the MC.
class DesktopUpdater : public QObject {
  Q_OBJECT

public:
  struct Environment {
    QString appVersion;
    // linux, macos, or another platform this app cannot update itself on.
    QString platform;
    // $APPIMAGE: the AppImage the app runs from on Linux.
    QString appImage;
    // A release build, from its bundle on macOS.
    bool packaged = false;
    // HAL_C2_DISABLE_AUTO_UPDATE=1.
    bool disabledByEnv = false;
    QString feedUrl;
    // x64 or arm64: the machine's and the build's.
    QString hostArch;
    QString appArch;
    bool translated = false;
    // Updates are off and no reason is given.
    bool unexplained = false;
  };
  // This process's.
  static Environment system();
  // Why `environment` cannot update itself; empty when it can (and when it
  // says nothing).
  static QString disabledReason(const Environment& environment);
  static bool enabledFor(const Environment& environment);

  // The feed and the files.
  class Backend {
  public:
    virtual ~Backend() = default;
    using Releases = std::function<void(const QList<desktopUpdate::Release>& releases, const std::optional<QString>& error)>;
    using Done = std::function<void(const std::optional<QString>& error)>;
    virtual void fetch(const Environment& environment, Releases done) = 0;
    // Stages the release's asset; `progress` in percent.
    virtual void download(const desktopUpdate::Release& release, std::function<void(int percent)> progress, Done done) = 0;
    // Whether the release is still staged.
    virtual bool staged(const QString& version) const = 0;
    // Replaces the running app with the staged release and starts it; the
    // caller quits once it succeeds.
    virtual void install(const Environment& environment, const QString& version, Done done) = 0;
  };

  class Clock {
  public:
    virtual ~Clock() = default;
    virtual qint64 now() const = 0;
    // Runs `run` in `ms` while `context` lives.
    virtual void after(QObject* context, qint64 ms, std::function<void()> run) = 0;
  };
  static std::shared_ptr<Clock> systemClock();

  struct Result {
    bool accepted = false;
    bool completed = false;
    bool failed = false;
  };
  using Finished = std::function<void(const Result& result)>;

  static constexpr qint64 kStartupDelayMs = 15'000;
  static constexpr qint64 kPollIntervalMs = 4 * 60'000;
  static constexpr qint64 kPreparedCheckWaitMs = 90'000;

  DesktopUpdater(Environment environment, std::shared_ptr<Backend> backend, std::shared_ptr<Clock> clock,
                 const QString& channel, QObject* parent = nullptr);

  // Starts the automatic checks of a build that can update itself.
  void start();
  const desktopUpdate::State& state() const { return m_state; }
  const Environment& environment() const { return m_environment; }
  QString disabledReason() const { return disabledReason(m_environment); }
  // check, download, install, install-recovery, channel; empty when idle.
  QString activeAction() const { return m_active; }
  bool staged(const QString& version) const { return m_backend->staged(version); }
  // The MC the app runs, stopped while it installs.
  void setMcControl(std::function<void()> stop, std::function<void()> start) {
    m_stopMc = std::move(stop);
    m_startMc = std::move(start);
  }

  // Starts a check; false when none can start (disabled, quitting, busy).
  // `done` runs once it has an answer.
  bool check(std::function<void()> done = {});
  void download(Finished done);
  // Installs the downloaded update (of `expectedVersion`, when given: a check
  // running first is waited for, up to 90 s).
  void install(const QString& expectedVersion, Finished done);
  // Switches the track and checks it; why it could not otherwise. `persist`
  // stores it, saying why it could not.
  std::optional<QString> setChannel(const QString& channel, const std::function<std::optional<QString>(const QString&)>& persist);

signals:
  void changed();
  // The new version is installed and running: this process quits.
  void installed();

private:
  void apply(const desktopUpdate::State& state);
  QString now() const;
  void poll();
  void installNow(Finished done);

  Environment m_environment;
  std::shared_ptr<Backend> m_backend;
  std::shared_ptr<Clock> m_clock;
  desktopUpdate::State m_state;
  QString m_active;
  bool m_quitting = false;
  bool m_started = false;
  // Switching track may go back in version.
  bool m_trackSwitched = false;
  std::optional<desktopUpdate::Release> m_offer;
  std::function<void()> m_stopMc;
  std::function<void()> m_startMc;
  // An install waiting for the check before it.
  std::function<void()> m_afterCheck;
  int m_checkRun = 0;
};

// The desktop app's half of an update a server asks for (upstream
// DesktopRemoteUpdates.ts, remoteUpdateFlow.ts): `requestDesktopUpdate`
// checks, downloads and prepares the update and reports "ready-to-install";
// `commitDesktopUpdate` installs what it prepared, within 5 minutes;
// `cancelDesktopUpdate` drops it. Every report goes out through `report`.
class DesktopRemoteUpdates : public QObject {
  Q_OBJECT

public:
  static constexpr qint64 kRetryMs = 250;
  static constexpr qint64 kPreparedTtlMs = 5 * 60'000;

  DesktopRemoteUpdates(DesktopUpdater* updater, std::shared_ptr<DesktopUpdater::Clock> clock,
                       std::function<void(const QJsonObject& report)> report, QObject* parent = nullptr);

  // The request the next status report belongs to.
  QString activeRequestId() const;
  void request(const QString& requestId);
  void commit(const QString& requestId);
  void cancel(const QString& requestId);
  // `server.reportDesktopUpdateStatus`'s payload.
  QJsonObject statusReport(const QString& requestId = {}, const QString& outcome = {}, const QString& reason = {}) const;

private:
  void step();
  void finish(const QString& outcome, const QString& reason = {});
  void retryLater();

  DesktopUpdater* m_updater;
  std::shared_ptr<DesktopUpdater::Clock> m_clock;
  std::function<void(const QJsonObject&)> m_report;
  struct Run {
    QString requestId;
    int checks = 0;
    int downloads = 0;
  };
  std::optional<Run> m_run;
  bool m_stepQueued = false;
  QSet<QString> m_cancelledBeforeStart;
  struct Prepared {
    QString requestId;
    QString version;
    // prepared, committing, failed
    QString status;
    QString failureReason;
    qint64 expiresAt = 0;
  };
  std::optional<Prepared> m_prepared;
};
