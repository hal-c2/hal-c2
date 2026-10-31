#include "DesktopUpdateController.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QTimer>

#include "DesktopUpdateSystem.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<DesktopUpdateController> registrar(QStringLiteral("desktopUpdate"), {QStringLiteral("desktopUpdate")},
                                                                   nullptr, NativeControllerScope::Shared);

const QString kSettingsKey = QStringLiteral("desktopUpdate");
const QString kReport = QStringLiteral("server.reportDesktopUpdateStatus");

QString trackName(const QString& channel) {
  return channel == desktopUpdate::kNightly ? QStringLiteral("Nightly") : QStringLiteral("Stable");
}

QJsonValue orNull(const QJsonObject& object) {
  return object.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(object);
}

}  // namespace

DesktopUpdateController::DesktopUpdateController(ShellBridge* bridge, McClient* client, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client) {}

ToastController* DesktopUpdateController::toasts() const {
  NativeWindow* window = NativeShell::of(this);
  return window ? window->controller<ToastController>() : nullptr;
}

SettingsController* DesktopUpdateController::settings() const {
  auto* shell = qobject_cast<NativeShell*>(parent());
  return shell ? shell->shared<SettingsController>() : nullptr;
}

QString DesktopUpdateController::channel() const {
  if (m_updater) return m_updater->state().channel;
  const DesktopUpdatePlatform& platform = desktopUpdatePlatform();
  const QString version = platform.environment ? platform.environment->appVersion : QCoreApplication::applicationVersion();
  // The installed build's track until the user chooses one.
  const QVariantMap stored = settings() ? settings()->deviceValue(kSettingsKey).toMap() : QVariantMap();
  const QString chosen = stored.value(QStringLiteral("channel")).toString();
  if (stored.value(QStringLiteral("channelChosen")).toBool() && (chosen == desktopUpdate::kNightly || chosen == desktopUpdate::kStable)) {
    return chosen;
  }
  return desktopUpdate::channelOf(version);
}

void DesktopUpdateController::activate() {
  if (m_updater) return;
  DesktopUpdatePlatform& platform = desktopUpdatePlatform();
  if (!platform.backend) platform.backend = desktopUpdateSystemBackend();
  if (!platform.clock) platform.clock = DesktopUpdater::systemClock();
  m_updater = new DesktopUpdater(platform.environment.value_or(DesktopUpdater::system()), platform.backend, platform.clock, channel(), this);
  m_updater->setMcControl(
      [] {
        if (desktopUpdatePlatform().stopMc) desktopUpdatePlatform().stopMc();
      },
      [] {
        if (desktopUpdatePlatform().startMc) desktopUpdatePlatform().startMc();
      });
  m_remote = new DesktopRemoteUpdates(m_updater, platform.clock, [this](const QJsonObject& payload) { report(payload); }, this);
  connect(m_updater, &DesktopUpdater::changed, this, [this] {
    publish();
    report(m_remote->statusReport(m_remote->activeRequestId()));
  });
  connect(m_updater, &DesktopUpdater::installed, this, [] {
    if (desktopUpdatePlatform().quit) {
      desktopUpdatePlatform().quit();
    } else {
      QTimer::singleShot(0, qApp, &QCoreApplication::quit);
    }
  });
  // Where the update stands, for an MC that (re)connects; the MC asks for
  // updates on its own subscription, which the client sends again itself.
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready) report(m_remote->statusReport(m_remote->activeRequestId()));
  });
  m_control = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("desktopUpdateControl")}},
                                  [this](const QJsonObject& frame) { onControl(frame); });
  if (m_client->isReady()) report(m_remote->statusReport());
  publish();
  m_updater->start();
}

void DesktopUpdateController::attach(NativeWindow* window) {
  if (auto* keys = window->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("desktopUpdate.check"), tr("Check for Updates"), [this] { check(true); });
  }
}

void DesktopUpdateController::report(const QJsonObject& payload) {
  if (!m_client->isReady()) return;
  // An MC the desktop app did not start refuses it; nothing to tell anyone.
  m_client->call(this, m_client->environment(), kReport, payload, [](const QJsonValue&, const std::optional<QString>&) {});
}

void DesktopUpdateController::onControl(const QJsonObject& frame) {
  const QJsonObject event = frame.contains(QLatin1String("event")) ? frame.value(QLatin1String("event")).toObject() : frame;
  const QString type = event.value(QLatin1String("type")).toString();
  const QString requestId = event.value(QLatin1String("requestId")).toString();
  if (requestId.isEmpty() || !m_remote) return;
  if (type == QLatin1String("requestDesktopUpdate")) {
    m_remote->request(requestId);
  } else if (type == QLatin1String("commitDesktopUpdate")) {
    m_remote->commit(requestId);
  } else if (type == QLatin1String("cancelDesktopUpdate")) {
    m_remote->cancel(requestId);
  }
}

void DesktopUpdateController::publish() {
  if (!m_updater) return;
  const desktopUpdate::State& state = m_updater->state();
  const QString platform = m_updater->environment().platform;
  const bool busy = state.status == QLatin1String("checking") || state.status == QLatin1String("downloading");
  QJsonObject warning;
  if (desktopUpdate::showsIntelWarning(state)) {
    warning = {{QStringLiteral("title"), QStringLiteral("Intel build on Apple Silicon")},
               {QStringLiteral("description"), desktopUpdate::intelWarning(state)}};
  }
  const QJsonObject view{
      {QStringLiteral("shown"), platform == QLatin1String("linux") || platform == QLatin1String("macos")},
      {QStringLiteral("state"), state.toJson()},
      {QStringLiteral("status"), state.status},
      {QStringLiteral("channel"), state.channel},
      {QStringLiteral("track"), trackName(state.channel)},
      {QStringLiteral("currentVersion"), state.currentVersion},
      {QStringLiteral("action"), desktopUpdate::buttonAction(state)},
      {QStringLiteral("label"), desktopUpdate::label(state)},
      {QStringLiteral("details"), desktopUpdate::showsDetails(state)},
      // The button: busy while it checks or downloads, and nothing to press
      // in a build that cannot update.
      {QStringLiteral("disabled"), busy || (!desktopUpdate::showsDetails(state) && !desktopUpdate::canCheck(state))},
      // Settings' check: open to a build that cannot, to say why.
      {QStringLiteral("canCheck"), !busy},
      {QStringLiteral("canChangeTrack"), m_updater->activeAction().isEmpty()},
      {QStringLiteral("downloadPercent"), state.downloadPercent},
      {QStringLiteral("popover"), orNull(desktopUpdate::popover(state))},
      {QStringLiteral("warning"), orNull(warning)},
  };
  m_bridge->publish(QStringLiteral("desktopUpdate"), view.toVariantMap());
}

bool DesktopUpdateController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("desktopUpdate."))) return false;
  if (!m_updater) return true;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("desktopUpdate.press")) {
    const QString next = desktopUpdate::buttonAction(m_updater->state());
    if (next == QLatin1String("download")) {
      download();
    } else if (next == QLatin1String("install")) {
      confirmInstall();
    } else {
      check(false);
    }
  } else if (action == QLatin1String("desktopUpdate.check")) {
    check(false);
  } else if (action == QLatin1String("desktopUpdate.menuCheck")) {
    check(true);
  } else if (action == QLatin1String("desktopUpdate.download")) {
    download();
  } else if (action == QLatin1String("desktopUpdate.install")) {
    confirmInstall();
  } else if (action == QLatin1String("desktopUpdate.setTrack")) {
    setTrack(args.value(QStringLiteral("channel")).toString());
  } else if (action == QLatin1String("desktopUpdate.openReleaseNotes")) {
    if (!openUrl(QUrl(args.value(QStringLiteral("url")).toString()))) {
      if (ToastController* toasts = this->toasts()) toasts->error(QStringLiteral("Unable to open release notes"));
    }
  }
  return true;
}

// The button's and Settings' check say only when it could not run or
// failed; the menu's (the palette's) also say when the app is current.
void DesktopUpdateController::check(bool fromMenu) {
  QPointer<DesktopUpdateController> self(this);
  const bool started = m_updater->check([self, fromMenu] {
    if (!self) return;
    const desktopUpdate::State& state = self->m_updater->state();
    ToastController* toasts = self->toasts();
    if (!toasts) return;
    if (state.status == QLatin1String("error") && state.errorContext == QLatin1String("check")) {
      if (fromMenu) {
        toasts->error(QStringLiteral("Update check failed"),
                      state.message.isEmpty() ? QStringLiteral("An unknown error occurred. Please try again later.") : state.message);
      } else {
        toasts->error(QStringLiteral("Could not check for updates"), state.message.isEmpty() ? QStringLiteral("Update check failed.") : state.message);
      }
    } else if (fromMenu && state.status == QLatin1String("up-to-date")) {
      toasts->show(QStringLiteral("info"), QStringLiteral("You're up to date!"),
                   QStringLiteral("HAL-C2 %1 is currently the newest version available.").arg(state.currentVersion));
    }
  });
  if (started) return;
  const desktopUpdate::State& state = m_updater->state();
  ToastController* toasts = this->toasts();
  if (!toasts || state.status == QLatin1String("checking") || state.status == QLatin1String("downloading")) return;
  if (fromMenu && !state.enabled) {
    toasts->show(QStringLiteral("warning"), QStringLiteral("Updates unavailable"),
                 state.message.isEmpty() ? QStringLiteral("Automatic updates are not available right now.") : state.message);
    return;
  }
  toasts->error(QStringLiteral("Could not check for updates"),
                state.message.isEmpty() ? QStringLiteral("Automatic updates are not available in this build.") : state.message);
}

void DesktopUpdateController::download() {
  QPointer<DesktopUpdateController> self(this);
  m_updater->download([self](const DesktopUpdater::Result& result) {
    if (!self) return;
    ToastController* toasts = self->toasts();
    if (result.completed) {
      self->toldDownloaded();
    } else if (!toasts) {
      return;
    } else if (!result.accepted) {
      toasts->error(QStringLiteral("Could not start update download"), QStringLiteral("There is no update to download right now."));
    } else {
      const QString message = self->m_updater->state().message.trimmed();
      toasts->error(QStringLiteral("Could not download update"), message);
    }
  });
}

void DesktopUpdateController::toldDownloaded() {
  ToastController* toasts = this->toasts();
  if (!toasts) return;
  const desktopUpdate::State& state = m_updater->state();
  const QString version = state.downloadedVersion.isEmpty() ? state.availableVersion : state.downloadedVersion;
  const QUrl url(desktopUpdate::releaseUrl(version));
  std::optional<ToastController::Action> readMore;
  if (url.isValid() && !url.isEmpty()) {
    QPointer<DesktopUpdateController> self(this);
    readMore = ToastController::Action{QStringLiteral("Read more"), [self, url] {
                                         if (!self || self->openUrl(url)) return;
                                         if (ToastController* toasts = self->toasts()) toasts->error(QStringLiteral("Unable to open release notes"));
                                       }};
  }
  toasts->show(QStringLiteral("success"), QStringLiteral("Update downloaded"),
               QStringLiteral("Restart the app from the update button to install it."), readMore);
}

void DesktopUpdateController::confirmInstall() {
  NativeWindow* window = NativeShell::of(this);
  MenuController* menus = window ? window->controller<MenuController>() : nullptr;
  if (!menus) {
    if (ToastController* toasts = this->toasts()) toasts->error(QStringLiteral("Could not confirm update"), QStringLiteral("Update confirmation failed."));
    return;
  }
  QPointer<DesktopUpdateController> self(this);
  menus->confirm(desktopUpdate::confirmationTitle(m_updater->state()), desktopUpdate::kConfirmationDetail,
                 QStringLiteral("Restart and install"), false, [self] {
                   if (self) self->install();
                 });
}

void DesktopUpdateController::install() {
  QPointer<DesktopUpdateController> self(this);
  m_updater->install({}, [self](const DesktopUpdater::Result& result) {
    if (!self || result.completed) return;
    ToastController* toasts = self->toasts();
    if (!toasts) return;
    const QString message = self->m_updater->state().message.trimmed();
    if (!result.accepted) {
      toasts->error(QStringLiteral("Could not install update"), QStringLiteral("The update is not ready to install."));
    } else {
      toasts->error(QStringLiteral("Could not install update"), message);
    }
  });
}

void DesktopUpdateController::setTrack(const QString& channel) {
  if (channel != desktopUpdate::kNightly && channel != desktopUpdate::kStable) return;
  const auto persist = [this](const QString& next) -> std::optional<QString> {
    if (const auto& store = desktopUpdatePlatform().persistTrack) return store(next);
    SettingsController* settings = this->settings();
    if (!settings) return QStringLiteral("The settings are not loaded yet.");
    if (!settings->writeDevice(kSettingsKey, QVariantMap{{QStringLiteral("channel"), next}, {QStringLiteral("channelChosen"), true}})) {
      return settings->deviceError();
    }
    return std::nullopt;
  };
  if (const auto error = m_updater->setChannel(channel, persist)) {
    if (ToastController* toasts = this->toasts()) toasts->error(QStringLiteral("Could not change update track"), *error);
  }
  publish();
}

bool DesktopUpdateController::openUrl(const QUrl& url) {
  if (url.scheme() != QLatin1String("https")) return false;
  if (const auto& open = desktopUpdatePlatform().openUrl) return open(url);
  return QDesktopServices::openUrl(url);
}
