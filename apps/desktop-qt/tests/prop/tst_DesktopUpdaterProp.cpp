// DesktopUpdater as a state machine: checks the user starts and the timer
// starts (15 s after launch, then every 4 minutes), each answered later with
// an error, nothing newer or a release; downloads that finish or fail;
// installs that relaunch or fail; and track switches tried along the way.
// After every step the updater runs at most one step, offers and keeps what
// the model says (a downloaded update survives a check that fails or finds
// nothing), refuses what it must, has its MC running unless an install is
// under way or done, and quits only after an install succeeded.
//
// The release-notes normalisation's laws are plain properties beside it.

#include "Prop.h"

#include "DesktopUpdater.h"

#include <QDateTime>
#include <QPointer>

#include <optional>
#include <tuple>
#include <vector>

namespace {

using desktopUpdate::Release;

const QString kCurrent = QStringLiteral("1.3.0");
const std::vector<QString> kReleases{QString(), QStringLiteral("1.2.0"), QStringLiteral("1.3.0"), QStringLiteral("1.4.0"),
                                     QStringLiteral("1.5.0"), QStringLiteral("1.6.0-nightly.20260901.1")};

class Clock : public DesktopUpdater::Clock {
public:
  qint64 now() const override { return m_now; }
  void after(QObject* context, qint64 ms, std::function<void()> run) override {
    m_timers.push_back({m_now + ms, m_next++, context, std::move(run)});
  }
  void advance(qint64 ms) {
    const qint64 end = m_now + ms;
    for (;;) {
      auto due = m_timers.end();
      for (auto it = m_timers.begin(); it != m_timers.end(); ++it) {
        if (it->due <= end && (due == m_timers.end() || std::tie(it->due, it->order) < std::tie(due->due, due->order))) due = it;
      }
      if (due == m_timers.end()) break;
      const Timer timer = *due;
      m_timers.erase(due);
      m_now = timer.due;
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
  qint64 m_now = 1'790'000'000'000;
  quint64 m_next = 0;
  std::vector<Timer> m_timers;
};

// Every step waits for the property to answer it.
class Backend : public DesktopUpdater::Backend {
public:
  Releases fetched;
  Done downloaded;
  Done installed;
  QString downloading;
  QSet<QString> staging;

  void fetch(const DesktopUpdater::Environment&, Releases done) override { fetched = std::move(done); }
  void download(const Release& release, std::function<void(int)>, Done done) override {
    downloading = release.version;
    downloaded = std::move(done);
  }
  bool staged(const QString& version) const override { return staging.contains(version); }
  void install(const DesktopUpdater::Environment&, const QString&, Done done) override { installed = std::move(done); }
};

DesktopUpdater::Environment environment() {
  DesktopUpdater::Environment environment;
  environment.appVersion = kCurrent;
  environment.platform = QStringLiteral("linux");
  environment.appImage = QStringLiteral("/opt/hal-c2/HAL-C2.AppImage");
  environment.packaged = true;
  environment.feedUrl = QStringLiteral("https://updates.example/releases");
  environment.hostArch = QStringLiteral("x64");
  environment.appArch = QStringLiteral("x64");
  return environment;
}

struct Sut {
  std::shared_ptr<Backend> backend = std::make_shared<Backend>();
  std::shared_ptr<Clock> clock = std::make_shared<Clock>();
  DesktopUpdater updater{environment(), backend, clock, desktopUpdate::kStable};
  int mcStops = 0;
  int mcStarts = 0;
  int quits = 0;

  Sut() {
    updater.setMcControl([this] { ++mcStops; }, [this] { ++mcStarts; });
    QObject::connect(&updater, &DesktopUpdater::installed, [this] { ++quits; });
    updater.start();
  }
};

struct Model {
  // "", check, download or install: what is waiting for its answer.
  QString active;
  QString status = QStringLiteral("idle");
  QString offered;
  QString downloaded;
  bool quit = false;
  // When the timer checks next.
  qint64 elapsed = 0;
  qint64 nextPoll = DesktopUpdater::kStartupDelayMs;

  bool canCheck() const { return !quit && active.isEmpty() && status != QLatin1String("downloading"); }
  bool canDownload() const { return !quit && active.isEmpty() && status == QLatin1String("available"); }
  bool canInstall() const { return !quit && active.isEmpty() && !downloaded.isEmpty() && status == QLatin1String("downloaded"); }
  void startCheck() {
    active = QStringLiteral("check");
    status = QStringLiteral("checking");
  }
};

void check(const Model& model, const Sut& sut) {
  const desktopUpdate::State& state = sut.updater.state();
  RC_ASSERT(sut.updater.activeAction() == model.active);
  RC_ASSERT(state.status == model.status);
  RC_ASSERT(state.availableVersion == model.offered);
  RC_ASSERT(state.downloadedVersion == model.downloaded);
  RC_ASSERT(sut.quits == (model.quit ? 1 : 0));
  // The MC is down only while an install runs and after it succeeded.
  const bool mcDown = model.active == QLatin1String("install") || model.quit;
  RC_ASSERT(sut.mcStops - sut.mcStarts == (mcDown ? 1 : 0));
}

using Command = rc::state::Command<Model, Sut>;

struct Check : Command {
  void apply(Model& model) const override {
    if (model.canCheck()) model.startCheck();
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(sut.updater.check() == model.canCheck());
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Check"; }
};

// The feed answers: an error (empty), nothing on the track, or a release.
struct AnswerCheck : Command {
  // Empty: the feed lists nothing.
  QString version = *rc::gen::elementOf(kReleases);
  bool fails = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override { RC_PRE(model.active == QLatin1String("check")); }
  void apply(Model& model) const override {
    model.active.clear();
    const bool newer = !fails && !version.contains(u'-') && desktopUpdate::compareVersions(version, kCurrent) > 0;
    if (newer) {
      model.offered = version;
      if (model.downloaded != version) model.downloaded.clear();
      model.status = model.downloaded.isEmpty() ? QStringLiteral("available") : QStringLiteral("downloaded");
    } else if (!model.downloaded.isEmpty()) {
      model.status = QStringLiteral("downloaded");
      if (!fails) model.offered = model.downloaded;
    } else if (fails) {
      model.status = QStringLiteral("error");
    } else {
      model.status = QStringLiteral("up-to-date");
      model.offered.clear();
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(bool(sut.backend->fetched));
    const auto answer = std::exchange(sut.backend->fetched, {});
    QList<Release> releases;
    if (!version.isEmpty()) {
      Release release;
      release.version = version;
      release.prerelease = version.contains(u'-');
      release.asset = QUrl(QStringLiteral("https://updates.example/HAL-C2-%1.AppImage").arg(version));
      releases.append(release);
    }
    if (fails) {
      answer({}, QStringLiteral("Network unreachable"));
    } else {
      answer(releases, std::nullopt);
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "AnswerCheck " << (fails ? "fails" : version.isEmpty() ? "nothing" : version.toStdString());
  }
};

struct Download : Command {
  void apply(Model& model) const override {
    if (!model.canDownload()) return;
    model.active = QStringLiteral("download");
    model.status = QStringLiteral("downloading");
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    bool answered = false;
    sut.updater.download([&answered](const DesktopUpdater::Result&) { answered = true; });
    // A refused download answers at once; a started one when it ends.
    RC_ASSERT(answered == !model.canDownload());
    if (model.canDownload()) RC_ASSERT(sut.backend->downloading == model.offered);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Download"; }
};

struct AnswerDownload : Command {
  bool fails = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override { RC_PRE(model.active == QLatin1String("download")); }
  void apply(Model& model) const override {
    model.active.clear();
    if (fails) {
      model.status = QStringLiteral("available");
    } else {
      model.downloaded = model.offered;
      model.status = QStringLiteral("downloaded");
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(bool(sut.backend->downloaded));
    if (!fails) sut.backend->staging.insert(sut.backend->downloading);
    std::exchange(sut.backend->downloaded, {})(fails ? std::optional<QString>(QStringLiteral("Disk full")) : std::nullopt);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "AnswerDownload" << (fails ? " fails" : ""); }
};

struct Install : Command {
  void apply(Model& model) const override {
    if (model.canInstall()) model.active = QStringLiteral("install");
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    bool answered = false;
    sut.updater.install({}, [&answered](const DesktopUpdater::Result&) { answered = true; });
    RC_ASSERT(answered == !model.canInstall());
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Install"; }
};

struct AnswerInstall : Command {
  bool fails = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.active == QLatin1String("install"));
    RC_PRE(!model.quit);
  }
  void apply(Model& model) const override {
    if (fails) {
      model.active.clear();
      model.status = QStringLiteral("downloaded");
    } else {
      // The new version runs; this one is on its way out.
      model.quit = true;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(bool(sut.backend->installed));
    std::exchange(sut.backend->installed, {})(fails ? std::optional<QString>(QStringLiteral("Could not replace it.")) : std::nullopt);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "AnswerInstall" << (fails ? " fails" : ""); }
};

// Time passes: each poll it crosses checks if it can, and the next is due
// four minutes on.
struct Advance : Command {
  qint64 ms = *rc::gen::element<qint64>(1'000, DesktopUpdater::kStartupDelayMs, DesktopUpdater::kPollIntervalMs);

  void apply(Model& model) const override {
    model.elapsed += ms;
    while (model.nextPoll <= model.elapsed) {
      if (model.canCheck()) model.startCheck();
      model.nextPoll += DesktopUpdater::kPollIntervalMs;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.clock->advance(ms);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Advance " << ms; }
};

// A switch to Nightly whose store fails: refused while a step runs, else the
// store's reason; either way nothing changes.
struct SwitchTrack : Command {
  void run(const Model& model, Sut& sut) const override {
    bool stored = false;
    const std::optional<QString> error = sut.updater.setChannel(desktopUpdate::kNightly, [&stored](const QString&) {
      stored = true;
      return std::optional<QString>(QStringLiteral("Read-only settings."));
    });
    RC_ASSERT(bool(error));
    const QString step = model.active.isEmpty() ? QString() : model.active;
    RC_ASSERT(stored == step.isEmpty());
    RC_ASSERT(*error == (step.isEmpty() ? QStringLiteral("Read-only settings.")
                                        : QStringLiteral("The update track cannot change while an update %1 is in progress.").arg(step)));
    RC_ASSERT(sut.updater.state().channel == desktopUpdate::kStable);
    check(model, sut);
  }
  void show(std::ostream& os) const override { os << "SwitchTrack"; }
};

// Release notes of lines drawn from GitHub's release markup.
QString notesOf(const std::vector<int>& lines) {
  static const QStringList kLines{
      QStringLiteral("## What's Changed"),
      QStringLiteral("* **Faster** threads by @maria in [#12](https://github.com/hal-c2/hal-c2/pull/12)"),
      QStringLiteral("- Fix the sidebar"),
      QStringLiteral("- ") + QString(300, u'x'),
      QStringLiteral("<ul><li>Markup change</li></ul>"),
      QStringLiteral("Full diff: https://github.com/hal-c2/hal-c2/compare/a...b"),
      QStringLiteral("## New Contributors"),
      QStringLiteral("* @maria made their first contribution"),
      QStringLiteral("**Full Changelog**: https://github.com/hal-c2/hal-c2/compare/v1...v2"),
      QString(),
  };
  QStringList note;
  for (const int line : lines) note.append(kLines.at(line % kLines.size()));
  return note.join(u'\n');
}

}  // namespace

class DesktopUpdaterProp : public QObject {
  Q_OBJECT

private slots:
  void oneStepAtATime() {
    QVERIFY(rc::check("the desktop updater runs one step at a time and keeps what it downloaded", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Check, Check, AnswerCheck, AnswerCheck, AnswerCheck, Download, Download,
                                                         AnswerDownload, AnswerDownload, Install, Install, AnswerInstall,
                                                         Advance, SwitchTrack>());
      RC_CLASSIFY(!sut.updater.state().downloadedVersion.isEmpty(), "downloaded");
      RC_CLASSIFY(sut.quits > 0, "installed");
      RC_CLASSIFY(sut.mcStarts > 0, "install failed");
    }));
  }

  void releaseNotesAreShortPlainLines() {
    QVERIFY(rc::check("release notes keep at most six releases of at most eight short plain changes", [] {
      const auto releases = *rc::gen::container<std::vector<std::vector<int>>>(
          *rc::gen::inRange(0, 9), rc::gen::container<std::vector<int>>(*rc::gen::inRange(0, 14), rc::gen::inRange(0, 100)));
      QList<desktopUpdate::NoteSource> sources;
      for (std::size_t i = 0; i < releases.size(); ++i) {
        sources.append({QStringLiteral("1.4.0-nightly.202609%1.1").arg(int(i) + 1, 2, 10, QLatin1Char('0')), notesOf(releases.at(i))});
      }
      const desktopUpdate::Notes notes = desktopUpdate::normalizeReleaseNotes(sources, desktopUpdate::kNightly);
      RC_ASSERT(notes.releaseNotes.size() <= 6);
      RC_ASSERT(notes.omittedReleaseCount >= 0);
      RC_ASSERT(int(notes.releaseNotes.size()) + notes.omittedReleaseCount <= int(sources.size()));
      for (const desktopUpdate::ReleaseNote& note : notes.releaseNotes) {
        RC_ASSERT(!note.items.isEmpty());
        RC_ASSERT(note.items.size() <= 8);
        RC_ASSERT(note.totalItems >= int(note.items.size()));
        for (const QString& item : note.items) {
          RC_ASSERT(item.size() <= 220);
          RC_ASSERT(!item.contains(QLatin1String("](")));
          RC_ASSERT(!item.contains(QLatin1String("**")));
          RC_ASSERT(!item.contains(QLatin1String("/compare/")));
          RC_ASSERT(!item.contains(u'<'));
        }
      }
    }));
  }
};

HAL_C2_PROP_MAIN(DesktopUpdaterProp)
#include "tst_DesktopUpdaterProp.moc"
