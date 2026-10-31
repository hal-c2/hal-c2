#include "DesktopUpdater.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QPointer>
#include <QSysInfo>
#include <QTimeZone>
#include <QTimer>
#include <QUrl>

#ifdef Q_OS_MACOS
#include <sys/sysctl.h>
#endif

namespace {

#ifndef HAL_C2_UPDATE_FEED
#define HAL_C2_UPDATE_FEED ""
#endif

QString arch(const QString& qtArch) {
  if (qtArch == QLatin1String("x86_64")) return QStringLiteral("x64");
  return qtArch;
}

class SystemClock : public DesktopUpdater::Clock {
public:
  qint64 now() const override { return QDateTime::currentMSecsSinceEpoch(); }
  void after(QObject* context, qint64 ms, std::function<void()> run) override {
    QTimer::singleShot(std::chrono::milliseconds(ms), context, std::move(run));
  }
};

}  // namespace

DesktopUpdater::Environment DesktopUpdater::system() {
  Environment environment;
  environment.appVersion = QCoreApplication::applicationVersion();
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
  environment.platform = QStringLiteral("mobile");
#elif defined(Q_OS_LINUX)
  environment.platform = QStringLiteral("linux");
#elif defined(Q_OS_MACOS)
  environment.platform = QStringLiteral("macos");
#else
  environment.platform = QSysInfo::productType();
#endif
  environment.appImage = qEnvironmentVariable("APPIMAGE");
#ifdef HAL_C2_RELEASE_BUILD
  // The macOS app updates as its bundle.
  environment.packaged = environment.platform != QLatin1String("macos") ||
                         QCoreApplication::applicationDirPath().endsWith(QLatin1String(".app/Contents/MacOS"));
#endif
  environment.disabledByEnv = qEnvironmentVariable("HAL_C2_DISABLE_AUTO_UPDATE") == QLatin1String("1");
  environment.feedUrl = qEnvironmentVariable("HAL_C2_UPDATE_FEED", QStringLiteral(HAL_C2_UPDATE_FEED));
  environment.appArch = arch(QSysInfo::buildCpuArchitecture());
  environment.hostArch = environment.appArch;
#ifdef Q_OS_MACOS
  int translated = 0;
  size_t size = sizeof(translated);
  if (sysctlbyname("sysctl.proc_translated", &translated, &size, nullptr, 0) == 0 && translated == 1) {
    environment.translated = true;
    environment.hostArch = QStringLiteral("arm64");
  }
#endif
  return environment;
}

QString DesktopUpdater::disabledReason(const Environment& environment) {
  if (environment.unexplained) return {};
  if (environment.feedUrl.trimmed().isEmpty()) {
    return QStringLiteral("Automatic updates are not available because no update feed is configured.");
  }
  if (QUrl(environment.feedUrl.trimmed()).scheme() != QLatin1String("https")) {
    return QStringLiteral("Automatic updates are not available because the update feed is not https.");
  }
  if (!environment.packaged || (environment.platform != QLatin1String("linux") && environment.platform != QLatin1String("macos"))) {
    return QStringLiteral("Automatic updates are only available in packaged production builds.");
  }
  if (environment.disabledByEnv) return QStringLiteral("Automatic updates are disabled by the HAL_C2_DISABLE_AUTO_UPDATE setting.");
  if (environment.platform == QLatin1String("linux") && environment.appImage.isEmpty()) {
    return QStringLiteral("Automatic updates on Linux require running the AppImage build.");
  }
  return {};
}

bool DesktopUpdater::enabledFor(const Environment& environment) {
  return !environment.unexplained && disabledReason(environment).isEmpty();
}

std::shared_ptr<DesktopUpdater::Clock> DesktopUpdater::systemClock() {
  return std::make_shared<SystemClock>();
}

namespace {

desktopUpdate::State base(const DesktopUpdater::Environment& environment, const QString& channel) {
  desktopUpdate::State state = desktopUpdate::initial(environment.appVersion, channel, DesktopUpdater::enabledFor(environment));
  state.hostArch = environment.hostArch;
  state.appArch = environment.appArch;
  state.runningUnderArm64Translation = environment.translated;
  if (!state.enabled) state.message = DesktopUpdater::disabledReason(environment);
  return state;
}

}  // namespace

DesktopUpdater::DesktopUpdater(Environment environment, std::shared_ptr<Backend> backend, std::shared_ptr<Clock> clock,
                               const QString& channel, QObject* parent)
    : QObject(parent),
      m_environment(std::move(environment)),
      m_backend(std::move(backend)),
      m_clock(std::move(clock)),
      m_state(base(m_environment, channel)) {}

void DesktopUpdater::start() {
  if (m_started || !m_state.enabled) return;
  m_started = true;
  m_clock->after(this, kStartupDelayMs, [this] { poll(); });
}

void DesktopUpdater::poll() {
  check();
  m_clock->after(this, kPollIntervalMs, [this] { poll(); });
}

QString DesktopUpdater::now() const {
  return QDateTime::fromMSecsSinceEpoch(m_clock->now(), QTimeZone::UTC).toString(Qt::ISODateWithMs);
}

void DesktopUpdater::apply(const desktopUpdate::State& state) {
  if (state == m_state) return;
  m_state = state;
  emit changed();
}

bool DesktopUpdater::check(std::function<void()> done) {
  if (m_quitting || !m_state.enabled || m_state.status == QLatin1String("downloading") || !m_active.isEmpty()) return false;
  m_active = QStringLiteral("check");
  const int run = ++m_checkRun;
  apply(desktopUpdate::onCheckStart(m_state, now()));
  QPointer<DesktopUpdater> self(this);
  m_backend->fetch(m_environment, [self, run, done](const QList<desktopUpdate::Release>& releases, const std::optional<QString>& error) {
    if (!self || self->m_checkRun != run || self->m_active != QLatin1String("check")) return;
    if (error) {
      self->apply(desktopUpdate::onCheckFailure(self->m_state, *error, self->now()));
    } else if (const auto offer = desktopUpdate::select(releases, self->m_environment.appVersion, self->m_state.channel,
                                                        self->m_state.channel == desktopUpdate::kNightly || self->m_trackSwitched)) {
      self->m_offer = offer->release;
      self->apply(desktopUpdate::onUpdateAvailable(self->m_state, offer->release.version, self->now(), offer->notes, offer->omitted));
    } else {
      self->apply(desktopUpdate::onNoUpdate(self->m_state, self->now()));
    }
    self->m_active.clear();
    if (done) done();
    if (self && self->m_afterCheck) std::exchange(self->m_afterCheck, {})();
  });
  return true;
}

void DesktopUpdater::download(Finished done) {
  if (m_quitting || m_state.status != QLatin1String("available") || !m_active.isEmpty() || !m_offer) {
    done({});
    return;
  }
  m_active = QStringLiteral("download");
  apply(desktopUpdate::onDownloadStart(m_state));
  const desktopUpdate::Release release = *m_offer;
  QPointer<DesktopUpdater> self(this);
  m_backend->download(
      release,
      [self](int percent) {
        if (!self || self->m_active != QLatin1String("download")) return;
        if (desktopUpdate::showsProgress(self->m_state, percent)) self->apply(desktopUpdate::onDownloadProgress(self->m_state, percent));
      },
      [self, release, done](const std::optional<QString>& error) {
        if (!self || self->m_active != QLatin1String("download")) return;
        self->m_active.clear();
        if (error) {
          self->apply(desktopUpdate::onDownloadFailure(self->m_state, *error));
          done({true, false, true});
        } else {
          self->apply(desktopUpdate::onDownloadComplete(self->m_state, release.version));
          done({true, true, false});
        }
      });
}

void DesktopUpdater::install(const QString& expectedVersion, Finished done) {
  if (m_quitting || !m_state.enabled || m_state.downloadedVersion.isEmpty() ||
      (!expectedVersion.isEmpty() && expectedVersion != m_state.downloadedVersion)) {
    done({});
    return;
  }
  // A check that started first (the 4-minute one) ends before a prepared install.
  if (m_active == QLatin1String("check") && !expectedVersion.isEmpty() && !m_afterCheck) {
    auto pending = std::make_shared<bool>(true);
    m_afterCheck = [this, expectedVersion, done, pending] {
      if (!std::exchange(*pending, false)) return;
      install(expectedVersion, done);
    };
    m_clock->after(this, kPreparedCheckWaitMs, [this, done, pending] {
      if (!std::exchange(*pending, false)) return;
      m_afterCheck = {};
      done({});
    });
    return;
  }
  if (!m_active.isEmpty() || !desktopUpdate::installable(m_state)) {
    done({});
    return;
  }
  installNow(std::move(done));
}

void DesktopUpdater::installNow(Finished done) {
  m_active = QStringLiteral("install");
  m_quitting = true;
  if (m_stopMc) m_stopMc();
  QPointer<DesktopUpdater> self(this);
  m_backend->install(m_environment, m_state.downloadedVersion, [self, done](const std::optional<QString>& error) {
    if (!self) return;
    if (!error) {
      done({true, true, false});
      emit self->installed();
      return;
    }
    // The app stays: its MC comes back, and the update can be installed again.
    self->m_active = QStringLiteral("install-recovery");
    self->m_quitting = false;
    if (self->m_startMc) self->m_startMc();
    self->apply(desktopUpdate::onInstallFailure(self->m_state, *error));
    self->m_active.clear();
    done({true, false, true});
  });
}

std::optional<QString> DesktopUpdater::setChannel(const QString& channel,
                                                  const std::function<std::optional<QString>(const QString&)>& persist) {
  if (!m_active.isEmpty()) {
    const QString step = m_active.startsWith(QLatin1String("install")) ? QStringLiteral("install") : m_active;
    return QStringLiteral("The update track cannot change while an update %1 is in progress.").arg(step);
  }
  if (channel == m_state.channel) return std::nullopt;
  m_active = QStringLiteral("channel");
  if (const auto error = persist(channel)) {
    m_active.clear();
    return error;
  }
  m_trackSwitched = true;
  m_offer.reset();
  m_active.clear();
  apply(base(m_environment, channel));
  check();
  return std::nullopt;
}

DesktopRemoteUpdates::DesktopRemoteUpdates(DesktopUpdater* updater, std::shared_ptr<DesktopUpdater::Clock> clock,
                                           std::function<void(const QJsonObject&)> report, QObject* parent)
    : QObject(parent), m_updater(updater), m_clock(std::move(clock)), m_report(std::move(report)) {
  connect(updater, &DesktopUpdater::changed, this, [this] {
    if (!m_run) return;
    if (!m_stepQueued) {
      m_stepQueued = true;
      QMetaObject::invokeMethod(this, [this] {
        m_stepQueued = false;
        step();
      }, Qt::QueuedConnection);
    }
  });
}

QString DesktopRemoteUpdates::activeRequestId() const {
  if (m_run) return m_run->requestId;
  if (m_prepared && m_prepared->status == QLatin1String("committing")) return m_prepared->requestId;
  return {};
}

QJsonObject DesktopRemoteUpdates::statusReport(const QString& requestId, const QString& outcome, const QString& reason) const {
  QJsonObject report{{QStringLiteral("version"), 1},
                     {QStringLiteral("type"), QStringLiteral("desktopUpdateStatus")},
                     {QStringLiteral("state"), m_updater->state().toJson()}};
  if (!requestId.isEmpty()) report.insert(QStringLiteral("requestId"), requestId);
  if (!outcome.isEmpty()) report.insert(QStringLiteral("outcome"), outcome);
  if (!reason.trimmed().isEmpty()) report.insert(QStringLiteral("reason"), reason.trimmed());
  return report;
}

void DesktopRemoteUpdates::request(const QString& requestId) {
  if (m_cancelledBeforeStart.remove(requestId)) return;
  // Only an install under way refuses: a prepared run its MC never committed (the
  // app's socket dropped) gives way to this one.
  if (m_prepared && m_prepared->status == QLatin1String("committing")) {
    m_report(statusReport(requestId, QStringLiteral("failed"), QStringLiteral("A prepared desktop update is already in progress.")));
    return;
  }
  m_prepared.reset();
  m_run = Run{requestId};
  step();
}

void DesktopRemoteUpdates::retryLater() {
  if (!m_run) return;
  const QString requestId = m_run->requestId;
  m_clock->after(this, kRetryMs, [this, requestId] {
    if (m_run && m_run->requestId == requestId) step();
  });
}

void DesktopRemoteUpdates::step() {
  if (!m_run) return;
  const desktopUpdate::State& state = m_updater->state();
  const desktopUpdate::RemoteStep next =
      desktopUpdate::nextRemoteStep(state, m_run->checks, m_run->downloads, m_updater->disabledReason());
  switch (next.kind) {
    case desktopUpdate::RemoteStep::Wait:
      return;
    case desktopUpdate::RemoteStep::Check:
      // Counted before it starts; one that is refused is not a try.
      m_run->checks++;
      if (!m_updater->check()) {
        m_run->checks--;
        retryLater();
      }
      return;
    case desktopUpdate::RemoteStep::Download: {
      m_run->downloads++;
      const QString requestId = m_run->requestId;
      m_updater->download([this, requestId](const DesktopUpdater::Result& result) {
        if (result.accepted || !m_run || m_run->requestId != requestId) return;
        m_run->downloads--;
        retryLater();
      });
      return;
    }
    case desktopUpdate::RemoteStep::Install:
      if (!m_updater->activeAction().isEmpty()) {
        retryLater();
        return;
      }
      if (state.downloadedVersion.isEmpty() || !m_updater->staged(state.downloadedVersion)) {
        finish(QStringLiteral("failed"), QStringLiteral("The desktop app lost the downloaded update."));
        return;
      }
      m_prepared = Prepared{m_run->requestId, state.downloadedVersion, QStringLiteral("prepared"), {}, m_clock->now() + kPreparedTtlMs};
      finish(QStringLiteral("ready-to-install"));
      return;
    case desktopUpdate::RemoteStep::Done:
      finish(next.reason);
      return;
    case desktopUpdate::RemoteStep::Failed:
      finish(QStringLiteral("failed"), next.reason);
      return;
  }
}

void DesktopRemoteUpdates::finish(const QString& outcome, const QString& reason) {
  const QString requestId = m_run->requestId;
  m_run.reset();
  m_report(statusReport(requestId, outcome, reason));
}

void DesktopRemoteUpdates::cancel(const QString& requestId) {
  if (m_run && m_run->requestId == requestId) {
    m_run.reset();
  } else if (!m_prepared || m_prepared->requestId != requestId) {
    m_cancelledBeforeStart.insert(requestId);
  }
  if (m_prepared && m_prepared->requestId == requestId && m_prepared->status == QLatin1String("prepared")) m_prepared.reset();
}

void DesktopRemoteUpdates::commit(const QString& requestId) {
  const auto fail = [this, requestId](const QString& reason) {
    m_report(statusReport(requestId, QStringLiteral("failed"), reason));
  };
  if (!m_prepared || m_prepared->requestId != requestId ||
      (m_prepared->status == QLatin1String("prepared") && m_prepared->expiresAt <= m_clock->now())) {
    if (m_prepared && m_prepared->status == QLatin1String("prepared") && m_prepared->expiresAt <= m_clock->now()) m_prepared.reset();
    fail(QStringLiteral("This desktop update is no longer prepared."));
    return;
  }
  if (m_prepared->status == QLatin1String("failed")) {
    fail(m_prepared->failureReason.isEmpty() ? QStringLiteral("The desktop app failed to install the update.") : m_prepared->failureReason);
    return;
  }
  if (m_prepared->status == QLatin1String("committing")) return;
  m_prepared->status = QStringLiteral("committing");
  const QString version = m_prepared->version;
  const auto failed = [this, fail](const QString& reason) {
    if (m_prepared) {
      m_prepared->status = QStringLiteral("failed");
      m_prepared->failureReason = reason;
    }
    fail(reason);
  };
  if (m_updater->state().downloadedVersion != version) {
    failed(QStringLiteral("This desktop update is no longer prepared."));
    return;
  }
  m_updater->install(version, [this, version, failed](const DesktopUpdater::Result& result) {
    // The user already started this install: the commit rides along.
    if (!result.accepted && m_updater->activeAction() == QLatin1String("install") && m_updater->state().downloadedVersion == version) {
      return;
    }
    if (!result.accepted || result.failed) {
      const QString message = m_updater->state().message.trimmed();
      failed(message.isEmpty() ? QStringLiteral("The desktop app could not start the install.") : message);
    }
  });
}
