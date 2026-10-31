// The desktop app's own updates (DesktopUpdateController, DesktopUpdater):
// the @desktop scenarios of features/settings/updates.feature's "Updating the
// desktop app". The feed, the download, the install and the clock are fakes
// in desktopUpdatePlatform(), fresh for every scenario's MC; the app is a
// packaged Linux AppImage on 1.3.0 unless a scenario says otherwise. The MC
// side is the wire: `server.reportDesktopUpdateStatus` calls are recorded and
// `desktopUpdateControl` frames are sent as the MC sends them.

#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonObject>

#include <algorithm>
#include <memory>

#include "DesktopUpdateController.h"
#include "DesktopUpdateSystem.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "World.h"

namespace {

using desktopUpdate::Release;

class FakeClock : public DesktopUpdater::Clock {
public:
  qint64 now() const override { return m_now; }
  void after(QObject* context, qint64 ms, std::function<void()> run) override {
    m_timers.append({m_now + ms, m_next++, context, std::move(run)});
  }
  // Runs every timer due by then, in order.
  void advance(qint64 ms) {
    const qint64 end = m_now + ms;
    for (;;) {
      const auto due = std::min_element(m_timers.begin(), m_timers.end(), [](const Timer& a, const Timer& b) {
        return a.due != b.due ? a.due < b.due : a.order < b.order;
      });
      if (due == m_timers.end() || due->due > end) break;
      const Timer timer = *due;
      m_timers.erase(due);
      m_now = std::max(m_now, timer.due);
      if (timer.context) timer.run();
    }
    m_now = end;
  }

private:
  struct Timer {
    qint64 due;
    quint64 order;
    QPointer<QObject> context;
    std::function<void()> run;
  };
  qint64 m_now = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate).toMSecsSinceEpoch();
  quint64 m_next = 0;
  QList<Timer> m_timers;
};

// The feed, the download and the install. Each answers at once unless held.
class FakeBackend : public DesktopUpdater::Backend {
public:
  QList<Release> releases;
  std::optional<QString> fetchError;
  bool holdFetch = false;
  int fetches = 0;
  std::optional<QString> downloadError;
  bool holdDownload = false;
  int downloads = 0;
  QSet<QString> stagedVersions;
  std::optional<QString> installError;
  bool holdInstall = false;
  int installs = 0;
  QString installed;

  void fetch(const DesktopUpdater::Environment&, Releases done) override {
    ++fetches;
    if (holdFetch) {
      m_fetches.append(std::move(done));
      return;
    }
    answer(done);
  }
  bool fetching() const { return !m_fetches.isEmpty(); }
  void answerFetches() {
    holdFetch = false;
    for (const Releases& done : std::exchange(m_fetches, {})) answer(done);
  }

  void download(const Release& release, std::function<void(int)> progress, Done done) override {
    ++downloads;
    m_downloading = release.version;
    if (holdDownload) {
      m_progress = std::move(progress);
      m_downloaded = std::move(done);
      return;
    }
    finishDownload(done);
  }
  bool downloading() const { return bool(m_downloaded); }
  void progress(int percent) {
    expect(bool(m_progress), QStringLiteral("no download is running"));
    m_progress(percent);
  }
  void completeDownload() {
    expect(bool(m_downloaded), QStringLiteral("no download is running"));
    m_progress = {};
    finishDownload(std::exchange(m_downloaded, {}));
  }
  bool staged(const QString& version) const override { return stagedVersions.contains(version); }

  void install(const DesktopUpdater::Environment&, const QString& version, Done done) override {
    ++installs;
    m_installing = version;
    if (holdInstall) {
      m_installed = std::move(done);
      return;
    }
    finishInstall(done);
  }
  bool installing() const { return bool(m_installed); }
  void completeInstall() {
    expect(bool(m_installed), QStringLiteral("no install is running"));
    finishInstall(std::exchange(m_installed, {}));
  }

private:
  void answer(const Releases& done) {
    if (fetchError) {
      done({}, *fetchError);
    } else {
      done(releases, std::nullopt);
    }
  }
  void finishDownload(const Done& done) {
    if (downloadError) {
      done(*downloadError);
      return;
    }
    stagedVersions.insert(m_downloading);
    done(std::nullopt);
  }
  void finishInstall(const Done& done) {
    if (installError) {
      done(*installError);
      return;
    }
    installed = m_installing;
    done(std::nullopt);
  }

  QList<Releases> m_fetches;
  QString m_downloading;
  std::function<void(int)> m_progress;
  Done m_downloaded;
  QString m_installing;
  Done m_installed;
};

struct Fake {
  std::shared_ptr<FakeBackend> backend = std::make_shared<FakeBackend>();
  std::shared_ptr<FakeClock> clock = std::make_shared<FakeClock>();
  QList<desktopUpdate::Release> parsed;
  QByteArray downloadedBytes;
  int mcStops = 0;
  int mcStarts = 0;
  bool quit = false;
  bool openFails = false;
  QList<QUrl> opened;
  // What the last failure the scenario caused gave as its reason.
  QString reason;
  QStringList windows;
  // A release-notes state the scenario reads instead of the app's.
  std::optional<desktopUpdate::State> notes;
  // What each step of "the update track cannot change" was told.
  QStringList trackRefusals;
  QString trackBefore;
  // Release notes written with markup, for the next release offered.
  QString markup;
};

std::shared_ptr<Fake>& current() {
  static std::shared_ptr<Fake> fake;
  return fake;
}

Fake& fake() {
  return *current();
}

DesktopUpdater::Environment packaged() {
  DesktopUpdater::Environment environment;
  environment.appVersion = QStringLiteral("1.3.0");
  environment.platform = QStringLiteral("linux");
  environment.appImage = QStringLiteral("/opt/hal-c2/HAL-C2.AppImage");
  environment.packaged = true;
  environment.feedUrl = QStringLiteral("https://updates.example/releases");
  environment.hostArch = QStringLiteral("x64");
  environment.appArch = QStringLiteral("x64");
  return environment;
}

const FakeMc::Extension extension([](FakeMc& mc) {
  current() = std::make_shared<Fake>();
  std::shared_ptr<Fake> fake = current();
  DesktopUpdatePlatform& platform = desktopUpdatePlatform();
  platform = {};
  platform.environment = packaged();
  platform.backend = fake->backend;
  platform.clock = fake->clock;
  platform.stopMc = [fake] { ++fake->mcStops; };
  platform.startMc = [fake] { ++fake->mcStarts; };
  platform.quit = [fake] { fake->quit = true; };
  platform.openUrl = [fake](const QUrl& url) {
    if (fake->openFails) return false;
    fake->opened.append(url);
    return true;
  };
  mc.onRpc(QStringLiteral("server.reportDesktopUpdateStatus"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonObject()); });
  mc.onShape(QStringLiteral("desktopUpdateControl"), [](int, const QJsonObject&) {});
});

DesktopUpdater::Environment& environment() {
  return *desktopUpdatePlatform().environment;
}

DesktopUpdateController* controller(World& world) {
  return world.native().controller<DesktopUpdateController>();
}

QVariantMap view(World& world) {
  return world.state(QStringLiteral("desktopUpdate")).toMap();
}

QVariantMap shownState(World& world) {
  return view(world).value(QStringLiteral("state")).toMap();
}

QString describe(World& world) {
  return QStringLiteral("the update stands at %1").arg(show(view(world)));
}

// The shell connected and its updater running.
void ready(World& world) {
  if (!world.running()) world.launch();
  if (world.state(QStringLiteral("desktopUpdate")).isValid()) return;
  if (!world.native().client()->isReady()) world.connect();
  world.waitFor([&] { return world.state(QStringLiteral("desktopUpdate")).isValid(); }, QStringLiteral("the update button to be shown"));
}

// The app as `change` leaves this machine, from its start.
void given(World& world, const std::function<void(DesktopUpdater::Environment&)>& change) {
  const bool started = world.running() && controller(world) && controller(world)->updater();
  change(environment());
  if (started) {
    world.restart();
    world.connect();
  }
  ready(world);
}

void dispatch(World& world, const QString& action, const QVariantMap& payload = {}) {
  ready(world);
  world.bridge().dispatch(action, payload);
  world.sync();
}

void waitStatus(World& world, const QString& status) {
  world.waitFor([&] { return view(world).value(QStringLiteral("status")) == status; }, [&] { return describe(world); });
}

Release release(const QString& version, const QString& notes = {}) {
  Release release;
  release.version = version;
  release.notes = notes;
  release.prerelease = version.contains(QLatin1Char('-'));
  release.asset = QUrl(QStringLiteral("https://updates.example/HAL-C2-%1-x86_64.AppImage").arg(version));
  release.size = 1024;
  return release;
}

QString bare(const QString& version) {
  return version.startsWith(QLatin1Char('v')) ? version.mid(1) : version;
}

void check(World& world) {
  dispatch(world, QStringLiteral("desktopUpdate.check"));
}

void offer(World& world, const QString& version, const QString& notes = {}) {
  ready(world);
  fake().backend->releases = {release(version, notes)};
  check(world);
  waitStatus(world, QStringLiteral("available"));
}

void download(World& world) {
  dispatch(world, QStringLiteral("desktopUpdate.press"));
}

void downloaded(World& world, const QString& version) {
  offer(world, version);
  download(world);
  waitStatus(world, QStringLiteral("downloaded"));
}

void answer(World& world, bool accepted) {
  const QVariant question = world.state(QStringLiteral("confirmation"));
  expect(question.typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
  world.sync();
}

// Restart and install, confirmed.
void install(World& world) {
  dispatch(world, QStringLiteral("desktopUpdate.press"));
  answer(world, true);
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QVariantMap toast(World& world, const QString& title, const QString& description) {
  QVariantMap found;
  world.waitFor(
      [&] {
        for (const QVariant& item : toasts(world)) {
          const QVariantMap toast = item.toMap();
          if (toast.value(QStringLiteral("title")) == title && toast.value(QStringLiteral("description")) == description) {
            found = toast;
            return true;
          }
        }
        return false;
      },
      [&] { return QStringLiteral("the toast \"%1\" saying \"%2\"; the shell shows %3").arg(title, description, show(toasts(world))); });
  return found;
}

QString channelNamed(const QString& track) {
  return track == QLatin1String("Nightly") ? desktopUpdate::kNightly : desktopUpdate::kStable;
}

void switchTrack(World& world, const QString& track) {
  dispatch(world, QStringLiteral("desktopUpdate.setTrack"), {{QStringLiteral("channel"), channelNamed(track)}});
}

// The server's requests, as the MC sends them.
void control(World& world, const QString& type, const QString& requestId) {
  ready(world);
  world.waitFor([&] { return !world.mc.subscribers(QStringLiteral("desktopUpdateControl")).isEmpty(); },
                QStringLiteral("the app to take the MC's update requests"));
  for (const int id : world.mc.subscribers(QStringLiteral("desktopUpdateControl"))) {
    world.mc.send({{QStringLiteral("t"), QStringLiteral("desktopUpdateControl")},
                   {QStringLiteral("id"), id},
                   {QStringLiteral("event"), QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("type"), type},
                                                         {QStringLiteral("requestId"), requestId}}}});
  }
  world.sync();
}

QList<QJsonObject> reports(World& world, const QString& requestId = {}) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : world.mc.calls) {
    if (rpc.method != QLatin1String("server.reportDesktopUpdateStatus")) continue;
    if (!requestId.isEmpty() && rpc.payload.value(QLatin1String("requestId")).toString() != requestId) continue;
    found.append(rpc.payload);
  }
  return found;
}

std::optional<QJsonObject> outcome(World& world, const QString& requestId) {
  for (const QJsonObject& report : reports(world, requestId)) {
    if (report.contains(QLatin1String("outcome"))) return report;
  }
  return std::nullopt;
}

QJsonObject waitOutcome(World& world, const QString& requestId) {
  world.waitFor([&] { return outcome(world, requestId).has_value(); },
                [&] { return QStringLiteral("an outcome for %1; the MC heard %2").arg(requestId, show(QJsonArray::fromVariantList([&] {
                                                                                         QVariantList list;
                                                                                         for (const QJsonObject& r : reports(world)) list.append(r.toVariantMap());
                                                                                         return list;
                                                                                       }()))); });
  return *outcome(world, requestId);
}

void prepare(World& world, const QString& requestId) {
  fake().backend->releases = {release(QStringLiteral("1.4.0"))};
  control(world, QStringLiteral("requestDesktopUpdate"), requestId);
  const QJsonObject report = waitOutcome(world, requestId);
  expect(report.value(QLatin1String("outcome")) == QLatin1String("ready-to-install"), show(report.toVariantMap()));
}

QVariantMap popover(World& world) {
  if (fake().notes) return desktopUpdate::popover(*fake().notes).toVariantMap();
  return view(world).value(QStringLiteral("popover")).toMap();
}

QVariantList groups(World& world) {
  return popover(world).value(QStringLiteral("groups")).toList();
}

QStringList items(const QVariant& group) {
  return group.toMap().value(QStringLiteral("items")).toStringList();
}

const QString kNightlyCurrent = QStringLiteral("1.4.0-nightly.20260901.1");

QString nightly(int day) {
  return QStringLiteral("1.4.0-nightly.202609%1.1").arg(day, 2, 10, QLatin1Char('0'));
}

// A nightly app finds the release that has `notes`.
void nightlyNotes(World& world, const QList<Release>& releases) {
  given(world, [](DesktopUpdater::Environment& environment) { environment.appVersion = kNightlyCurrent; });
  fake().backend->releases = releases;
  check(world);
  waitStatus(world, QStringLiteral("available"));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Downloading and installing.
  step(QStringLiteral("an update to %1 is available").arg(q), [](World& world, const Captures& c, const Table&) { offer(world, c[0]); });
  step(QStringLiteral("the user downloads it"), [](World& world, const Captures&, const Table&) {
    fake().backend->holdDownload = true;
    download(world);
    waitStatus(world, QStringLiteral("downloading"));
  });
  step(QStringLiteral("the download shows its progress"), [](World& world, const Captures&, const Table&) {
    fake().backend->progress(30);
    world.waitFor([&] { return view(world).value(QStringLiteral("label")) == QLatin1String("Downloading update (30%)"); },
                  [&] { return describe(world); });
    fake().backend->completeDownload();
    waitStatus(world, QStringLiteral("downloaded"));
  });
  step(QStringLiteral("the user restarts to install and confirms"), [](World& world, const Captures&, const Table&) {
    // A second window, to come back with the first.
    world.native().openWindow();
    for (const auto& window : world.native().windows()) fake().windows.append(window->id());
    install(world);
  });
  step(QStringLiteral("the app relaunches on %1 with the same windows").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([] { return fake().quit; }, QStringLiteral("the app to quit for the new version"));
    expect(fake().backend->installed == c[0] && fake().mcStops == 1, QStringLiteral("installed \"%1\"").arg(fake().backend->installed));
    // The new build starts where this one stopped.
    environment().appVersion = c[0];
    world.restart();
    world.connect();
    ready(world);
    QStringList windows;
    for (const auto& window : world.native().windows()) windows.append(window->id());
    expect(windows == fake().windows, QStringLiteral("the windows are %1, not %2").arg(windows.join(u','), fake().windows.join(u',')));
    expect(view(world).value(QStringLiteral("currentVersion")) == c[0], describe(world));
  });

  step(QStringLiteral("an update download failed"), [](World& world, const Captures&, const Table&) {
    ready(world);
    fake().backend->downloadError = QStringLiteral("Network unreachable");
    offer(world, QStringLiteral("1.4.0"));
    download(world);
    world.waitFor([&] { return shownState(world).value(QStringLiteral("errorContext")) == QLatin1String("download"); },
                  [&] { return describe(world); });
    // The next try goes through.
    fake().backend->downloadError.reset();
    fake().backend->holdDownload = true;
  });
  step(QStringLiteral("the download starts again"), [](World& world, const Captures&, const Table&) {
    waitStatus(world, QStringLiteral("downloading"));
    expect(fake().backend->downloads == 2 && fake().backend->downloading(), describe(world));
  });

  // The sidebar's update button.
  step(QStringLiteral("the app is up to date"), [](World& world, const Captures&, const Table&) {
    ready(world);
    check(world);
    waitStatus(world, QStringLiteral("up-to-date"));
  });
  step(QStringLiteral("the app is checking for an update"), [](World& world, const Captures&, const Table&) {
    ready(world);
    fake().backend->holdFetch = true;
    check(world);
    waitStatus(world, QStringLiteral("checking"));
  });
  step(QStringLiteral("update v([0-9.]+) is available"), [](World& world, const Captures& c, const Table&) { offer(world, c[0]); });
  step(QStringLiteral("update v([0-9.]+) is downloading at (\\d+) percent"), [](World& world, const Captures& c, const Table&) {
    offer(world, c[0]);
    fake().backend->holdDownload = true;
    download(world);
    fake().backend->progress(c[1].toInt());
    world.sync();
  });
  step(QStringLiteral("update v([0-9.]+) was downloaded"), [](World& world, const Captures& c, const Table&) { downloaded(world, c[0]); });
  step(QStringLiteral("the download of v([0-9.]+) failed"), [](World& world, const Captures& c, const Table&) {
    ready(world);
    fake().backend->downloadError = QStringLiteral("Network unreachable");
    offer(world, c[0]);
    download(world);
    world.waitFor([&] { return shownState(world).value(QStringLiteral("errorContext")) == QLatin1String("download"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the install of v([0-9.]+) failed"), [](World& world, const Captures& c, const Table&) {
    downloaded(world, c[0]);
    fake().backend->installError = QStringLiteral("Disk full");
    install(world);
    world.waitFor([&] { return shownState(world).value(QStringLiteral("errorContext")) == QLatin1String("install"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the user points at the update button in the sidebar"), [](World& world, const Captures&, const Table&) {
    ready(world);
    expect(view(world).value(QStringLiteral("shown")).toBool(), QStringLiteral("the sidebar shows no update button: %1").arg(describe(world)));
  });
  step(QStringLiteral("its tooltip says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return view(world).value(QStringLiteral("label")) == c[0]; }, [&] { return describe(world); });
  });

  // Restarting to install.
  step(QStringLiteral("update %1 was downloaded").arg(q), [](World& world, const Captures& c, const Table&) { downloaded(world, bare(c[0])); });
  step(QStringLiteral("update %1 finished downloading").arg(q), [](World& world, const Captures& c, const Table&) { downloaded(world, bare(c[0])); });
  step(QStringLiteral("the user chooses to restart and install"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("desktopUpdate.press"));
  });
  step(QStringLiteral("the user is asked %1 and told running tasks will be interrupted").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap question = world.state(QStringLiteral("confirmation")).toMap();
    expect(question.value(QStringLiteral("title")) == c[0] && question.value(QStringLiteral("description")) == desktopUpdate::kConfirmationDetail,
           QStringLiteral("the user is asked %1").arg(show(question)));
  });
  step(QStringLiteral("the user declines"), [](World& world, const Captures&, const Table&) { answer(world, false); });
  step(QStringLiteral("the app keeps running on its current version"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!fake().quit && fake().backend->installed.isEmpty() && world.running(), QStringLiteral("the app quit for the update"));
    expect(view(world).value(QStringLiteral("currentVersion")) == environment().appVersion, describe(world));
  });

  // Failures.
  step(QStringLiteral("the user checks for updates and it fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ready(world);
    fake().backend->fetchError = c[0];
    fake().reason = c[0];
    check(world);
  });
  step(QStringLiteral("the user downloads the update and it fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    offer(world, QStringLiteral("1.4.0"));
    fake().backend->downloadError = c[0];
    fake().reason = c[0];
    download(world);
  });
  step(QStringLiteral("the user restarts to install and it fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    downloaded(world, QStringLiteral("1.4.0"));
    fake().backend->installError = c[0];
    fake().reason = c[0];
    install(world);
  });
  step(QStringLiteral("the user is told %1 with the reason").arg(q), [](World& world, const Captures& c, const Table&) {
    toast(world, c[0], fake().reason);
  });
  step(QStringLiteral("the user is told %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    toast(world, c[0], c[1] == QLatin1String("the reason this build cannot update itself") ? fake().reason : c[1]);
  });
  step(QStringLiteral("this build has automatic updates turned off and does not say why"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.unexplained = true; });
  });
  step(QStringLiteral("the user checks for updates"), [](World& world, const Captures&, const Table&) { check(world); });

  // Release notes.
  step(QStringLiteral("the user is on the (Nightly|Stable) track"), [](World& world, const Captures& c, const Table&) {
    given(world, [&](DesktopUpdater::Environment& environment) {
      environment.appVersion = c[0] == QLatin1String("Nightly") ? kNightlyCurrent : QStringLiteral("1.3.0");
    });
    expect(view(world).value(QStringLiteral("track")) == c[0], describe(world));
  });
  step(QStringLiteral("a nightly update has release notes"), [](World& world, const Captures&, const Table&) {
    fake().backend->releases = {release(nightly(3), QStringLiteral("- Newest change")), release(nightly(2), QStringLiteral("- Middle change")),
                                release(kNightlyCurrent, QStringLiteral("- Installed change"))};
    check(world);
    waitStatus(world, QStringLiteral("available"));
  });
  step(QStringLiteral("the user sees %1 with the notes of the newest release").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList shown = groups(world);
    expect(!shown.isEmpty() && at(shown.first(), QStringLiteral("title")) == c[0] && at(shown.first(), QStringLiteral("version")) == nightly(3) &&
               items(shown.first()) == QStringList{QStringLiteral("Newest change")},
           QStringLiteral("the notes are %1").arg(show(popover(world))));
  });
  step(QStringLiteral("each older release in between is listed under %1 its version").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList shown = groups(world);
    expect(shown.size() == 2 && at(shown.at(1), QStringLiteral("title")) == QStringLiteral("%1 %2").arg(c[0], nightly(2)) &&
               items(shown.at(1)) == QStringList{QStringLiteral("Middle change")},
           QStringLiteral("the notes are %1").arg(show(popover(world))));
  });

  step(QStringLiteral("a nightly release lists (\\d+) of (\\d+) changes and (\\d+) older releases were left out"),
       [](World&, const Captures& c, const Table&) {
         desktopUpdate::State state = desktopUpdate::initial(kNightlyCurrent, desktopUpdate::kNightly, true);
         desktopUpdate::ReleaseNote note{nightly(3), {}, c[1].toInt()};
         for (int i = 0; i < c[0].toInt(); ++i) note.items.append(QStringLiteral("Change %1").arg(i + 1));
         fake().notes = desktopUpdate::onUpdateAvailable(state, nightly(3), QStringLiteral("2026-09-23T10:00:00.000Z"), {note}, c[2].toInt());
       });
  step(QStringLiteral("the user reads the release notes"), [](World& world, const Captures&, const Table&) {
    if (!fake().notes) ready(world);
  });
  step(QStringLiteral("the user sees a link %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap shown = popover(world);
    QStringList links{shown.value(QStringLiteral("footer")).toString()};
    for (const QVariant& group : groups(world)) links.append(at(group, QStringLiteral("link")).toString());
    expect(links.contains(c[0]), QStringLiteral("the links are %1").arg(links.join(QStringLiteral(" | "))));
  });

  step(QStringLiteral("a release's notes are written with markup, links and bold text"), [](World&, const Captures&, const Table&) {
    fake().markup =
        QStringLiteral("<ul><li>**Faster** threads by @maria in [#12](https://github.com/hal-c2/hal-c2/pull/12)</li></ul>\n");
  });
  step(QStringLiteral("one change is longer than 220 characters"), [](World& world, const Captures&, const Table&) {
    nightlyNotes(world, {release(nightly(2), fake().markup + QStringLiteral("- ") + QString(240, QLatin1Char('a')))});
  });
  step(QStringLiteral("each change is plain text with links shown as their words"), [](World& world, const Captures&, const Table&) {
    const QStringList listed = items(groups(world).value(0));
    expect(listed.contains(QStringLiteral("Faster threads by @maria in #12")), QStringLiteral("the changes are %1").arg(listed.join(u'|')));
  });
  step(QStringLiteral("the long change is cut short with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList listed = items(groups(world).value(0));
    expect(std::any_of(listed.cbegin(), listed.cend(), [&](const QString& item) { return item.size() == 220 && item.endsWith(c[0]); }),
           QStringLiteral("the changes are %1").arg(listed.join(u'|')));
  });
  step(QStringLiteral("a release's notes contain a %1 heading, compare links, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    nightlyNotes(world, {release(nightly(2), QStringLiteral("## %1\n* Fix the sidebar by @maria\n\nCompare: https://github.com/hal-c2/hal-c2/compare/a...b\n\n"
                                                            "## %2\n* @maria made their first contribution\n\n**%3**: "
                                                            "https://github.com/hal-c2/hal-c2/compare/v1...v2\n")
                                                 .arg(c[0], c[1], c[2]))});
  });
  step(QStringLiteral("only the changes themselves are listed"), [](World& world, const Captures&, const Table&) {
    const QVariantList shown = groups(world);
    expect(shown.size() == 1 && items(shown.first()) == QStringList{QStringLiteral("Fix the sidebar by @maria")},
           QStringLiteral("the notes are %1").arg(show(popover(world))));
  });
  step(QStringLiteral("the notes cover a manually cut preview release as well as nightly releases"), [](World& world, const Captures&, const Table&) {
    fake().backend->releases = {release(QStringLiteral("1.4.0-preview.1"), QStringLiteral("- Preview change")),
                                release(nightly(3), QStringLiteral("- Third nightly")), release(nightly(2), QStringLiteral("- Second nightly"))};
    check(world);
    waitStatus(world, QStringLiteral("available"));
  });
  step(QStringLiteral("only the nightly releases are listed"), [](World& world, const Captures&, const Table&) {
    QStringList versions;
    for (const QVariant& group : groups(world)) versions.append(at(group, QStringLiteral("version")).toString());
    expect(versions == QStringList{nightly(3), nightly(2)}, QStringLiteral("the notes list %1").arg(versions.join(u',')));
  });
  step(QStringLiteral("a release's notes contain only a heading and a compare link"), [](World& world, const Captures&, const Table&) {
    nightlyNotes(world, {release(nightly(3), QStringLiteral("- Third nightly")),
                         release(nightly(2), QStringLiteral("## What's Changed\nhttps://github.com/hal-c2/hal-c2/compare/a...b\n"))});
  });
  step(QStringLiteral("that release is not listed"), [](World& world, const Captures&, const Table&) {
    QStringList versions;
    for (const QVariant& group : groups(world)) versions.append(at(group, QStringLiteral("version")).toString());
    expect(versions == QStringList{nightly(3)}, QStringLiteral("the notes list %1").arg(versions.join(u',')));
  });
  step(QStringLiteral("an update is available"), [](World& world, const Captures&, const Table&) {
    offer(world, QStringLiteral("1.4.0"), QStringLiteral("- A stable change"));
  });
  step(QStringLiteral("the user sees only where the update stands"), [](World& world, const Captures&, const Table&) {
    expect(view(world).value(QStringLiteral("popover")).isNull() &&
               view(world).value(QStringLiteral("label")) == QLatin1String("Update v1.4.0 ready to download"),
           describe(world));
  });

  // The update track.
  step(QStringLiteral("the user switches the update track to (Nightly|Stable)"), [](World& world, const Captures& c, const Table&) {
    ready(world);
    if (view(world).value(QStringLiteral("track")) == c[0]) {
      switchTrack(world, c[0] == QLatin1String("Nightly") ? QStringLiteral("Stable") : QStringLiteral("Nightly"));
    }
    fake().reason = QString::number(fake().backend->fetches);
    switchTrack(world, c[0]);
  });
  step(QStringLiteral("the app checks for (Nightly|Stable) releases"), [](World& world, const Captures& c, const Table&) {
    expect(view(world).value(QStringLiteral("track")) == c[0] && fake().backend->fetches == fake().reason.toInt() + 1, describe(world));
    // This device keeps it.
    const QVariantMap stored = world.native().controller<SettingsController>()->deviceValue(QStringLiteral("desktopUpdate")).toMap();
    expect(stored.value(QStringLiteral("channel")) == channelNamed(c[0]) && stored.value(QStringLiteral("channelChosen")).toBool(), show(stored));
  });
  step(QStringLiteral("the user can switch back at any time"), [](World& world, const Captures&, const Table&) {
    const QString back = view(world).value(QStringLiteral("track")) == QLatin1String("Nightly") ? QStringLiteral("Stable") : QStringLiteral("Nightly");
    expect(view(world).value(QStringLiteral("canChangeTrack")).toBool(), describe(world));
    switchTrack(world, back);
    expect(view(world).value(QStringLiteral("track")) == back, describe(world));
  });
  step(QStringLiteral("the update track is (?:still )?(Nightly|Stable)"), [](World& world, const Captures& c, const Table&) {
    ready(world);
    if (!world.checking && view(world).value(QStringLiteral("track")) != c[0]) switchTrack(world, c[0]);
    expect(view(world).value(QStringLiteral("track")) == c[0], describe(world));
  });
  step(QStringLiteral("the user switches the update track to (Nightly|Stable) and it fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ready(world);
    const QString error = c[1];
    desktopUpdatePlatform().persistTrack = [error](const QString&) -> std::optional<QString> { return error; };
    fake().reason = error;
    switchTrack(world, c[0]);
  });
  step(QStringLiteral("the user has never chosen an update track"), [](World& world, const Captures&, const Table&) {
    expect(!world.native().controller<SettingsController>()->deviceValue(QStringLiteral("desktopUpdate")).isValid(),
           QStringLiteral("a track is already chosen"));
  });
  step(QStringLiteral("the installed build is a (nightly build|stable release)"), [](World&, const Captures& c, const Table&) {
    environment().appVersion = c[0] == QLatin1String("nightly build") ? kNightlyCurrent : QStringLiteral("1.3.0");
  });
  step(QStringLiteral("the (?:desktop )?app starts"), [](World& world, const Captures&, const Table&) { ready(world); });
  step(QStringLiteral("a track the user chose earlier is kept instead"), [](World& world, const Captures&, const Table&) {
    const QString other = view(world).value(QStringLiteral("track")) == QLatin1String("Nightly") ? QStringLiteral("Stable") : QStringLiteral("Nightly");
    switchTrack(world, other);
    world.restart();
    world.connect();
    ready(world);
    expect(view(world).value(QStringLiteral("track")) == other, describe(world));
  });

  // Checking by itself.
  step(QStringLiteral("this build can update itself"), [](World& world, const Captures&, const Table&) {
    ready(world);
    expect(shownState(world).value(QStringLiteral("enabled")).toBool(), describe(world));
  });
  step(QStringLiteral("it checks for an update about fifteen seconds after launch"), [](World& world, const Captures&, const Table&) {
    fake().clock->advance(DesktopUpdater::kStartupDelayMs - 1);
    world.sync();
    expect(fake().backend->fetches == 0, QStringLiteral("it checked before fifteen seconds"));
    fake().clock->advance(1);
    world.sync();
    expect(fake().backend->fetches == 1, QStringLiteral("it checked %1 times").arg(fake().backend->fetches));
  });
  step(QStringLiteral("again every four minutes while it runs"), [](World& world, const Captures&, const Table&) {
    for (int checks = 2; checks <= 3; ++checks) {
      fake().clock->advance(DesktopUpdater::kPollIntervalMs - 1);
      world.sync();
      expect(fake().backend->fetches == checks - 1, QStringLiteral("it checked %1 times").arg(fake().backend->fetches));
      fake().clock->advance(1);
      world.sync();
      expect(fake().backend->fetches == checks, QStringLiteral("it checked %1 times").arg(fake().backend->fetches));
    }
  });

  // Builds that cannot update.
  step(QStringLiteral("the update source is not https"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.feedUrl = QStringLiteral("http://updates.example/releases"); });
  });
  step(QStringLiteral("no update source is configured"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.feedUrl.clear(); });
  });
  step(QStringLiteral("the app runs from a development or unpacked build"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.packaged = false; });
  });
  step(QStringLiteral("automatic updates were turned off for this run"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.disabledByEnv = true; });
  });
  step(QStringLiteral("the app on Linux is not the AppImage build"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.appImage.clear(); });
  });

  // The command palette's Check for Updates (this app has no application menu).
  step(QStringLiteral("the app is on version %1 and no newer one exists").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, [&](DesktopUpdater::Environment& environment) { environment.appVersion = c[0]; });
    fake().backend->releases = {release(c[0])};
  });
  step(QStringLiteral("the user chooses Check for Updates from the application menu"), [](World& world, const Captures&, const Table&) {
    ready(world);
    CommandRegistry* commands = world.native().controller<KeybindingController>()->commands();
    expect(commands->run(QStringLiteral("desktopUpdate.check")), QStringLiteral("the palette has no Check for Updates"));
    world.sync();
  });
  step(QStringLiteral("the check fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ready(world);
    fake().backend->fetchError = c[0];
  });
  step(QStringLiteral("the check fails with no reason"), [](World& world, const Captures&, const Table&) {
    ready(world);
    fake().backend->fetchError = QString();
  });
  step(QStringLiteral("this build cannot update itself"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.packaged = false; });
    fake().reason = shownState(world).value(QStringLiteral("message")).toString();
    expect(!fake().reason.isEmpty(), describe(world));
  });

  // The track while an update step runs: each of the three in turn.
  step(QStringLiteral("the app is checking for, downloading or installing an update"), [](World& world, const Captures&, const Table&) {
    ready(world);
    fake().trackBefore = view(world).value(QStringLiteral("track")).toString();
  });
  step(QStringLiteral("the user switches the update track"), [](World& world, const Captures&, const Table&) {
    const auto attempt = [&] {
      switchTrack(world, QStringLiteral("Nightly"));
      for (const QVariant& item : toasts(world)) {
        if (at(item, QStringLiteral("title")) == QLatin1String("Could not change update track")) {
          fake().trackRefusals.append(at(item, QStringLiteral("description")).toString());
          world.bridge().dispatch(QStringLiteral("notification.dismiss"), QVariantMap{{QStringLiteral("id"), at(item, QStringLiteral("id"))}});
        }
      }
    };
    FakeBackend& backend = *fake().backend;
    backend.holdFetch = true;
    backend.releases = {release(QStringLiteral("1.4.0"))};
    check(world);
    waitStatus(world, QStringLiteral("checking"));
    attempt();
    backend.answerFetches();
    waitStatus(world, QStringLiteral("available"));
    backend.holdDownload = true;
    download(world);
    waitStatus(world, QStringLiteral("downloading"));
    attempt();
    backend.completeDownload();
    waitStatus(world, QStringLiteral("downloaded"));
    backend.holdInstall = true;
    install(world);
    world.waitFor([&] { return backend.installing(); }, QStringLiteral("the install to start"));
    attempt();
  });
  step(QStringLiteral("the user is told the track cannot change while that update step is in progress"), [](World&, const Captures&, const Table&) {
    QStringList wanted;
    for (const char* step : {"check", "download", "install"}) {
      wanted.append(QStringLiteral("The update track cannot change while an update %1 is in progress.").arg(QLatin1String(step)));
    }
    expect(fake().trackRefusals == wanted, QStringLiteral("the user was told %1").arg(fake().trackRefusals.join(u'|')));
  });
  step(QStringLiteral("the update track stays as it was"), [](World& world, const Captures&, const Table&) {
    expect(view(world).value(QStringLiteral("track")) == fake().trackBefore &&
               !world.native().controller<SettingsController>()->deviceValue(QStringLiteral("desktopUpdate")).isValid(),
           describe(world));
  });

  step(QStringLiteral("the app is on the Nightly track at a build newer than the latest stable release"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.appVersion = QStringLiteral("1.5.0-nightly.20260901.1"); });
    fake().backend->releases = {release(QStringLiteral("1.5.0-nightly.20260901.1")), release(QStringLiteral("1.4.0"))};
    check(world);
    waitStatus(world, QStringLiteral("up-to-date"));
  });
  step(QStringLiteral("the app offers the latest stable release even though it is older"), [](World& world, const Captures&, const Table&) {
    waitStatus(world, QStringLiteral("available"));
    expect(shownState(world).value(QStringLiteral("availableVersion")) == QLatin1String("1.4.0"), describe(world));
  });
  step(QStringLiteral("installing it is allowed to go back in version"), [](World& world, const Captures&, const Table&) {
    download(world);
    waitStatus(world, QStringLiteral("downloaded"));
    install(world);
    world.waitFor([] { return fake().quit; }, QStringLiteral("the app to quit for the older version"));
    expect(fake().backend->installed == QLatin1String("1.4.0"), fake().backend->installed);
  });

  step(QStringLiteral("the app stopped its MC to install an update"), [](World& world, const Captures&, const Table&) {
    downloaded(world, QStringLiteral("1.4.0"));
    fake().backend->holdInstall = true;
    install(world);
    world.waitFor([] { return fake().backend->installing() && fake().mcStops == 1; }, QStringLiteral("the install to stop the MC"));
  });
  step(QStringLiteral("the install fails"), [](World& world, const Captures&, const Table&) {
    fake().backend->installError = QStringLiteral("Could not replace /opt/hal-c2/HAL-C2.AppImage.");
    fake().reason = *fake().backend->installError;
    fake().backend->completeInstall();
    world.sync();
  });
  step(QStringLiteral("the MC is started again"), [](World&, const Captures&, const Table&) {
    expect(fake().mcStarts == 1, QStringLiteral("the MC was started %1 times").arg(fake().mcStarts));
  });

  step(QStringLiteral("a later check (fails|finds nothing newer)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("fails")) {
      fake().backend->fetchError = QStringLiteral("Network unreachable");
    } else {
      fake().backend->releases = {};
    }
    const int before = fake().backend->fetches;
    check(world);
    world.waitFor([&] { return fake().backend->fetches == before + 1 && view(world).value(QStringLiteral("status")) != QLatin1String("checking"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the update is still shown as downloaded and ready to install"), [](World& world, const Captures&, const Table&) {
    expect(view(world).value(QStringLiteral("action")) == QLatin1String("install") &&
               shownState(world).value(QStringLiteral("downloadedVersion")) == QLatin1String("1.4.0") &&
               view(world).value(QStringLiteral("label")) == QLatin1String("Update v1.4.0 downloaded. Click to restart and install."),
           describe(world));
  });

  step(QStringLiteral("a check finds only a nightly release"), [](World& world, const Captures&, const Table&) {
    fake().backend->releases = {release(QStringLiteral("1.5.0-nightly.20260901.1"))};
    check(world);
  });
  step(QStringLiteral("the app says it is up to date"), [](World& world, const Captures&, const Table&) {
    waitStatus(world, QStringLiteral("up-to-date"));
  });

  step(QStringLiteral("an update is downloading"), [](World& world, const Captures&, const Table&) {
    offer(world, QStringLiteral("1.4.0"));
    fake().backend->holdDownload = true;
    download(world);
    waitStatus(world, QStringLiteral("downloading"));
  });
  step(QStringLiteral("the timer for the next automatic check comes up"), [](World& world, const Captures&, const Table&) {
    fake().reason = QString::number(fake().backend->fetches);
    fake().clock->advance(DesktopUpdater::kStartupDelayMs + DesktopUpdater::kPollIntervalMs);
    world.sync();
  });
  step(QStringLiteral("no check starts"), [](World&, const Captures&, const Table&) {
    expect(fake().backend->fetches == fake().reason.toInt(), QStringLiteral("a check started"));
  });
  step(QStringLiteral("the download goes on"), [](World& world, const Captures&, const Table&) {
    expect(fake().backend->downloading(), describe(world));
    fake().backend->progress(60);
    world.waitFor([&] { return shownState(world).value(QStringLiteral("downloadPercent")) == 60; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the download advances from (\\d+) to (\\d+) percent"), [](World& world, const Captures& c, const Table&) {
    fake().backend->progress(c[0].toInt());
    world.sync();
    fake().reason = shownState(world).value(QStringLiteral("downloadPercent")).toString();
    for (int percent = c[0].toInt() + 1; percent <= c[1].toInt(); ++percent) fake().backend->progress(percent);
    world.sync();
  });
  step(QStringLiteral("the shown progress does not change"), [](World& world, const Captures&, const Table&) {
    expect(shownState(world).value(QStringLiteral("downloadPercent")).toString() == fake().reason, describe(world));
  });
  step(QStringLiteral("the download reaches (\\d+) percent"), [](World& world, const Captures& c, const Table&) {
    fake().backend->progress(c[0].toInt());
    world.sync();
  });
  step(QStringLiteral("the shown progress becomes (\\d+) percent"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shownState(world).value(QStringLiteral("downloadPercent")) == c[0].toInt(); }, [&] { return describe(world); });
  });

  step(QStringLiteral("the desktop app already found an update"), [](World& world, const Captures&, const Table&) {
    offer(world, QStringLiteral("1.4.0"));
  });
  step(QStringLiteral("its MC restarts and connects to the app"), [](World& world, const Captures&, const Table&) {
    fake().reason = QString::number(fake().backend->fetches);
    world.mc.calls.clear();
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the app to see its MC go"));
    world.waitFor([&] { return world.native().client()->isReady(); }, QStringLiteral("the MC to connect again"));
  });
  step(QStringLiteral("the MC receives the current update state without another check"), [](World& world, const Captures&, const Table&) {
    world.waitFor(
        [&] {
          for (const QJsonObject& report : reports(world)) {
            const QJsonObject state = report.value(QLatin1String("state")).toObject();
            if (state.value(QLatin1String("status")) == QLatin1String("available") &&
                state.value(QLatin1String("availableVersion")) == QLatin1String("1.4.0")) {
              return true;
            }
          }
          return false;
        },
        QStringLiteral("the MC to hear of the update"));
    expect(fake().backend->fetches == fake().reason.toInt(), QStringLiteral("the app checked again"));
  });

  // The Intel build on Apple Silicon.
  step(QStringLiteral("the Intel build runs on an Apple Silicon Mac"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) {
      environment.platform = QStringLiteral("macos");
      environment.appImage.clear();
      environment.hostArch = QStringLiteral("arm64");
      environment.appArch = QStringLiteral("x64");
      environment.translated = true;
    });
  });
  step(QStringLiteral("the user is warned to install the Apple Silicon build"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return at(view(world), QStringLiteral("warning.title")) == QLatin1String("Intel build on Apple Silicon"); },
                  [&] { return describe(world); });
    expect(at(view(world), QStringLiteral("warning.description")).toString().contains(QLatin1String("Apple Silicon build")), describe(world));
  });
  step(QStringLiteral("an update is available to download"), [](World& world, const Captures&, const Table&) { offer(world, QStringLiteral("1.4.0")); });
  step(QStringLiteral("an update was downloaded"), [](World& world, const Captures&, const Table&) { downloaded(world, QStringLiteral("1.4.0")); });
  step(QStringLiteral("no update is available"), [](World& world, const Captures&, const Table&) {
    check(world);
    waitStatus(world, QStringLiteral("up-to-date"));
  });
  step(QStringLiteral("the user reads the warning"), [](World& world, const Captures&, const Table&) { ready(world); });
  step(QStringLiteral("it says (to download the update to switch to the native build|to restart to install the native build|"
                      "the next app update will replace it with the native one)"),
       [](World& world, const Captures& c, const Table&) {
         const QString advice = c[0].startsWith(QLatin1String("to download"))
                                    ? QStringLiteral("Download the available update to switch to the native Apple Silicon build.")
                                : c[0].startsWith(QLatin1String("to restart")) ? QStringLiteral("Restart to install the downloaded Apple Silicon build.")
                                                                                : QStringLiteral("The next app update will replace it with the native Apple Silicon build.");
         expect(at(view(world), QStringLiteral("warning.description")).toString().endsWith(advice), describe(world));
       });

  // The downloaded notice.
  step(QStringLiteral("the user is told %1 and to restart the app from the update button").arg(q), [](World& world, const Captures& c, const Table&) {
    toast(world, c[0], QStringLiteral("Restart the app from the update button to install it."));
  });
  step(QStringLiteral("the notice links to the release notes of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap notice = toast(world, QStringLiteral("Update downloaded"), QStringLiteral("Restart the app from the update button to install it."));
    expect(at(notice.value(QStringLiteral("actions")).toList().value(0), QStringLiteral("label")) == QLatin1String("Read more"), show(notice));
    world.bridge().dispatch(QStringLiteral("notification.action"), QVariantMap{{QStringLiteral("id"), notice.value(QStringLiteral("id"))}});
    world.sync();
    const QUrl wanted(QStringLiteral("https://github.com/hal-c2/hal-c2/releases/tag/v") + c[0]);
    expect(fake().opened == QList<QUrl>{wanted}, QStringLiteral("opened %1").arg(fake().opened.value(0).toString()));
  });
  step(QStringLiteral("the notice for the downloaded update links its release notes"), [](World& world, const Captures&, const Table&) {
    downloaded(world, QStringLiteral("1.4.0"));
    toast(world, QStringLiteral("Update downloaded"), QStringLiteral("Restart the app from the update button to install it."));
  });
  step(QStringLiteral("the user chooses the link and the system cannot open it"), [](World& world, const Captures&, const Table&) {
    fake().openFails = true;
    const QVariantMap notice = toast(world, QStringLiteral("Update downloaded"), QStringLiteral("Restart the app from the update button to install it."));
    world.bridge().dispatch(QStringLiteral("notification.action"), QVariantMap{{QStringLiteral("id"), notice.value(QStringLiteral("id"))}});
    world.sync();
  });

  // Updates a server asks for.
  step(QStringLiteral("the app last found no update some time ago"), [](World& world, const Captures&, const Table&) {
    ready(world);
    check(world);
    waitStatus(world, QStringLiteral("up-to-date"));
    fake().clock->advance(10 * 60'000);
    world.sync();
    fake().backend->holdFetch = true;
    fake().reason = QString::number(fake().backend->fetches);
  });
  step(QStringLiteral("a server asks the desktop app to update"), [](World& world, const Captures&, const Table&) {
    control(world, QStringLiteral("requestDesktopUpdate"), QStringLiteral("req-1"));
  });
  step(QStringLiteral("the app checks again before answering"), [](World& world, const Captures&, const Table&) {
    world.waitFor([] { return fake().backend->fetching(); }, QStringLiteral("the app to check again"));
    expect(fake().backend->fetches == fake().reason.toInt() + 1 && !outcome(world, QStringLiteral("req-1")), QStringLiteral("the app answered before it checked"));
    fake().backend->answerFetches();
  });
  step(QStringLiteral("it answers that the app is up to date only after that check"), [](World& world, const Captures&, const Table&) {
    const QJsonObject report = waitOutcome(world, QStringLiteral("req-1"));
    expect(report.value(QLatin1String("outcome")) == QLatin1String("up-to-date"), show(report.toVariantMap()));
  });
  step(QStringLiteral("a server asks the desktop app to update and the download fails three times"), [](World& world, const Captures&, const Table&) {
    fake().backend->downloadError = QStringLiteral("Network unreachable");
    control(world, QStringLiteral("requestDesktopUpdate"), QStringLiteral("req-1"));
  });
  step(QStringLiteral("the request fails with the reason the download gave"), [](World& world, const Captures&, const Table&) {
    const QJsonObject report = waitOutcome(world, QStringLiteral("req-1"));
    expect(report.value(QLatin1String("outcome")) == QLatin1String("failed") && report.value(QLatin1String("reason")) == QLatin1String("Network unreachable") &&
               fake().backend->downloads == 3,
           QStringLiteral("%1 after %2 downloads").arg(show(report.toVariantMap())).arg(fake().backend->downloads));
  });
  step(QStringLiteral("automatic updates are disabled on this machine"), [](World& world, const Captures&, const Table&) {
    given(world, [](DesktopUpdater::Environment& environment) { environment.unexplained = true; });
  });
  step(QStringLiteral("the downloaded update is gone before it is ready"), [](World& world, const Captures&, const Table&) {
    downloaded(world, QStringLiteral("1.4.0"));
    fake().backend->stagedVersions.clear();
  });
  step(QStringLiteral("the request fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject report = waitOutcome(world, QStringLiteral("req-1"));
    expect(report.value(QLatin1String("outcome")) == QLatin1String("failed") && report.value(QLatin1String("reason")) == c[0],
           show(report.toVariantMap()));
  });
  step(QStringLiteral("the desktop app prepared an update for a server's request"), [](World& world, const Captures&, const Table&) {
    prepare(world, QStringLiteral("req-1"));
  });
  step(QStringLiteral("five minutes pass without the request being confirmed"), [](World& world, const Captures&, const Table&) {
    fake().clock->advance(DesktopRemoteUpdates::kPreparedTtlMs);
    world.sync();
  });
  step(QStringLiteral("confirming it fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.calls.clear();
    control(world, QStringLiteral("commitDesktopUpdate"), QStringLiteral("req-1"));
    const QJsonObject report = waitOutcome(world, QStringLiteral("req-1"));
    expect(report.value(QLatin1String("outcome")) == QLatin1String("failed") && report.value(QLatin1String("reason")) == c[0],
           show(report.toVariantMap()));
    expect(fake().backend->installs == 0, QStringLiteral("the update was installed"));
  });
  step(QStringLiteral("a new update request can start"), [](World& world, const Captures&, const Table&) { prepare(world, QStringLiteral("req-2")); });
  step(QStringLiteral("a server's update is installing and its MC stopped for it"), [](World& world, const Captures&, const Table&) {
    prepare(world, QStringLiteral("req-1"));
    fake().backend->holdInstall = true;
    control(world, QStringLiteral("commitDesktopUpdate"), QStringLiteral("req-1"));
    world.waitFor([] { return fake().backend->installing() && fake().mcStops == 1; }, QStringLiteral("the install to stop the MC"));
  });
  step(QStringLiteral("the install fails and the connection comes back"), [](World& world, const Captures&, const Table&) {
    world.mc.calls.clear();
    world.mc.drop();
    fake().backend->installError = QStringLiteral("Could not replace /opt/hal-c2/HAL-C2.AppImage.");
    fake().reason = *fake().backend->installError;
    fake().backend->completeInstall();
    world.sync();
  });
  step(QStringLiteral("the MC hears that request failed with the install's reason"), [](World& world, const Captures&, const Table&) {
    const QJsonObject report = waitOutcome(world, QStringLiteral("req-1"));
    expect(report.value(QLatin1String("outcome")) == QLatin1String("failed") && report.value(QLatin1String("reason")) == fake().reason,
           show(report.toVariantMap()));
  });
  step(QStringLiteral("that install fails"), [](World& world, const Captures&, const Table&) {
    world.sync();
    fake().backend->installError = QStringLiteral("Could not replace /opt/hal-c2/HAL-C2.AppImage.");
    fake().reason = *fake().backend->installError;
    fake().backend->completeInstall();
    world.sync();
  });
  step(QStringLiteral("the update feed lists a release whose asset (.+)"), [](World&, const Captures& c, const Table&) {
    const bool https = c[0].contains(QLatin1String("https"));
    QJsonObject asset{{QStringLiteral("name"), QStringLiteral("HAL-C2.AppImage")},
                      {QStringLiteral("browser_download_url"), QStringLiteral("%1://updates.example/HAL-C2.AppImage").arg(https ? QStringLiteral("https") : QStringLiteral("http"))}};
    if (!c[0].contains(QLatin1String("no digest"))) asset.insert(QStringLiteral("digest"), QStringLiteral("sha256:") + QString(64, QLatin1Char('a')));
    const QJsonArray feed{QJsonObject{{QStringLiteral("tag_name"), QStringLiteral("v1.4.0")}, {QStringLiteral("assets"), QJsonArray{asset}}}};
    fake().parsed = desktopUpdate::parseFeed(QJsonDocument(feed).toJson(), QStringLiteral("linux"), QStringLiteral("x64"));
  });
  step(QStringLiteral("that release is (offered|not offered)"), [](World&, const Captures& c, const Table&) {
    expect(fake().parsed.isEmpty() == (c[0] == QLatin1String("not offered")), QStringLiteral("%1 releases").arg(fake().parsed.size()));
  });
  step(QStringLiteral("a download whose bytes (match|do not match) the release's digest"), [](World&, const Captures& c, const Table&) {
    fake().downloadedBytes = c[0] == QLatin1String("match") ? QByteArrayLiteral("update") : QByteArrayLiteral("tampered");
  });
  step(QStringLiteral("the app (accepts|refuses) it"), [](World&, const Captures& c, const Table&) {
    QCryptographicHash bytes(QCryptographicHash::Sha256);
    bytes.addData(fake().downloadedBytes);
    const QString digest = QString::fromLatin1(QCryptographicHash::hash("update", QCryptographicHash::Sha256).toHex());
    expect(desktopUpdate::matchesDigest(bytes, digest) == (c[0] == QLatin1String("accepts")), c[0]);
  });
  step(QStringLiteral("the desktop app is already installing the downloaded version"), [](World& world, const Captures&, const Table&) {
    prepare(world, QStringLiteral("req-1"));
    fake().backend->holdInstall = true;
    install(world);
    world.waitFor([] { return fake().backend->installing(); }, QStringLiteral("the install to start"));
  });
  step(QStringLiteral("a server confirms its prepared update of that version"), [](World& world, const Captures&, const Table&) {
    world.mc.calls.clear();
    control(world, QStringLiteral("commitDesktopUpdate"), QStringLiteral("req-1"));
  });
  step(QStringLiteral("no second install starts"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fake().backend->installs == 1, QStringLiteral("%1 installs started").arg(fake().backend->installs));
  });
  step(QStringLiteral("no failure is reported"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const std::optional<QJsonObject> heard = outcome(world, QStringLiteral("req-1"));
    expect(!heard, QStringLiteral("the MC heard %1").arg(heard ? show(heard->toVariantMap()) : QString()));
  });
});

}  // namespace
