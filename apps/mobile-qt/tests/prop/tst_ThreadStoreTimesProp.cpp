// How the shell's threads (ThreadStore) write times for Format.qml and the
// usage limits: as the user's Time format setting and the locale say, through
// changes of either, the setting saved empty or taken away, and a restart that
// reads the setting back.

#include "Prop.h"

#include <QSignalSpy>

#include <memory>

#include "FakeMc.h"
#include "NativeShell.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SidebarModel.h"
#include "ThreadStore.h"
#include "TimelineModel.h"

namespace {

// What the user saved: a format, an empty one, or none.
const std::vector<std::string> kFormats{"locale", "12-hour", "24-hour", "", "none"};
const std::vector<std::string> kLocales{"en_US", "en_GB", "de_DE", "ja_JP"};

const QDateTime kNow = QDateTime(QDate(2026, 9, 23), QTime(16, 0), QTimeZone::UTC);
// Earlier today, tomorrow, another day this year, and last year.
const QList<QDateTime> kTimes{kNow.addSecs(-3 * 3600 - 300), kNow.addSecs(26 * 3600 + 65), kNow.addDays(-40), kNow.addDays(-400)};

struct Model {
  std::string saved = "none";
  // Set by the shell; the system's again after a restart.
  std::optional<std::string> locale;

  QString format() const {
    return saved == "none" || saved.empty() ? QStringLiteral("locale") : QString::fromStdString(saved);
  }
  QLocale qlocale() const { return locale ? QLocale(QString::fromStdString(*locale)) : QLocale(); }
};

struct Sut {
  QTemporaryDir dir;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  std::unique_ptr<QSignalSpy> changes;

  Sut() { start(); }
  ~Sut() { stop(); }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    shell = std::make_unique<NativeShell>(bridge.get());
    shell->setStoreDirs(dir.filePath(QStringLiteral("state")), dir.filePath(QStringLiteral("data")), dir.filePath(QStringLiteral("cache")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(QStringLiteral("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(QStringLiteral("config")));
    // The store reads the setting once the shell has the MC's snapshot.
    QSignalSpy ready(shell.get(), &NativeShell::ready);
    shell->open(mc.origin(), QStringLiteral("token"));
    RC_ASSERT(halc2::prop::until([&] { return !ready.isEmpty(); }));
    threads()->setClock([] { return kNow; });
    changes = std::make_unique<QSignalSpy>(threads(), &ThreadStore::timesChanged);
  }
  void stop() {
    changes.reset();
    shell.reset();
    bridge.reset();
  }

  ThreadStore* threads() const { return shell->controller<ThreadStore>(); }
  SettingsController* settings() const { return shell->controller<SettingsController>(); }
};

void expectSame(const Model& model, Sut& sut) {
  const ThreadStore* threads = sut.threads();
  RC_ASSERT(threads->timestampFormat() == model.format());
  for (const QDateTime& at : kTimes) {
    RC_ASSERT(threads->formatTime(at) == sidebar::timeOfDay(at.toLocalTime(), model.format(), model.qlocale()));
    RC_ASSERT(threads->formatDate(at) == shortDate(at, kNow, model.qlocale()));
    RC_ASSERT(threads->formatDateTime(at) == shortDateTime(at, kNow, model.format(), model.qlocale()));
    RC_ASSERT(threads->upcoming(at) == upcomingStamp(at, kNow, model.format(), model.qlocale()));
    RC_ASSERT(threads->formatRelative(at) == relativeTime(at, kNow));
  }
  RC_ASSERT(threads->formatTime(QDateTime()).isEmpty());
  RC_ASSERT(threads->formatDateTime(QDateTime()).isEmpty());
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.changes->clear();
    static_cast<const Self*>(this)->act(sut);
    // Whatever changed, the bindings that read the times were told. (Saving
    // the same preferences again changes nothing, and says nothing.)
    if (static_cast<const Self*>(this)->notifies(model, next)) RC_ASSERT(!sut.changes->isEmpty());
    expectSame(next, sut);
  }
  bool notifies(const Model& before, const Model& after) const { return before.saved != after.saved; }
};

// The user picks a Time format in Settings → General, or it is saved empty or
// taken out of the preferences file.
struct SetFormat : Step<SetFormat> {
  std::string format = *rc::gen::elementOf(kFormats);

  explicit SetFormat(const Model&) {}
  void apply(Model& model) const override { model.saved = format; }
  void act(Sut& sut) const {
    QJsonObject device = sut.settings()->deviceSettings();
    if (format == "none") {
      device.remove(QStringLiteral("timestampFormat"));
    } else {
      device.insert(QStringLiteral("timestampFormat"), QString::fromStdString(format));
    }
    RC_ASSERT(sut.settings()->setDeviceSettings(device));
  }
  void show(std::ostream& os) const override { os << "SetFormat(" << format << ")"; }
};

// The shell reads times in another locale.
struct SetLocale : Step<SetLocale> {
  std::string locale = *rc::gen::elementOf(kLocales);

  explicit SetLocale(const Model&) {}
  void apply(Model& model) const override { model.locale = locale; }
  void act(Sut& sut) const { sut.threads()->setLocale(QLocale(QString::fromStdString(locale))); }
  bool notifies(const Model&, const Model&) const { return true; }
  void show(std::ostream& os) const override { os << "SetLocale(" << locale << ")"; }
};

// The app quits and starts again: the saved format is read back.
struct Restart : Step<Restart> {
  explicit Restart(const Model&) {}
  void apply(Model& model) const override { model.locale.reset(); }
  void act(Sut& sut) const {
    sut.stop();
    sut.start();
  }
  bool notifies(const Model&, const Model&) const { return false; }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class ThreadStoreTimesProp : public QObject {
  Q_OBJECT

private slots:
  void followsTheTimeFormat() {
    QVERIFY(rc::check("times read as the saved Time format and the locale say", [] {
      Sut sut;
      expectSame(Model{}, sut);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model{}, rc::state::gen::execOneOfWithArgs<SetFormat, SetFormat, SetFormat, SetLocale, SetLocale, Restart>()));
      rc::state::runAll(commands, Model{}, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ThreadStoreTimesProp)
#include "tst_ThreadStoreTimesProp.moc"
