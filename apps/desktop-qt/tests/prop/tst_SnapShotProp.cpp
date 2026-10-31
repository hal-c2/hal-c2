// Snap Shot's settings (SnapShotController) on a fake desktop portal. The user
// turns Snap Shot on and off, walks into setup and out of it, records, saves
// and discards shortcuts, leaves the panel, and presses the shortcut. The
// saved shortcut changes only on a save of a shortcut the desktop can take;
// the desktop holds it exactly while Snap Shot is on; recording pauses
// captures and ends when the panel closes; and closing setup unfinished
// leaves Snap Shot as setup found it.

#include "Prop.h"

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SnapShotBackend.h"
#include "SnapShotController.h"

namespace prop = halc2::prop;

namespace {

// A chord the user presses, and the portal trigger it saves as (none for one
// the desktop cannot take).
struct Chord {
  int key;
  int modifiers;
  const char* trigger;
};

const Chord kChords[] = {
    {Qt::Key_F9, Qt::ControlModifier | Qt::AltModifier, "CTRL+ALT+F9"},
    {Qt::Key_F8, Qt::ControlModifier | Qt::ShiftModifier, "CTRL+SHIFT+F8"},
    // Shift alone is for typing.
    {Qt::Key_K, Qt::ShiftModifier, ""},
};
constexpr int kChordCount = sizeof(kChords) / sizeof(kChords[0]);

// The desktop: always answers, grants every trigger at once, and counts captures.
class Portal : public SnapShotBackend {
public:
  using SnapShotBackend::SnapShotBackend;

  Session session() const override {
    Session session;
    session.ready = true;
    session.mode = QStringLiteral("portal");
    session.backend = QStringLiteral("screenshot-portal");
    return session;
  }
  Shortcut shortcut() const override {
    Shortcut shortcut;
    shortcut.registered = !bound.isEmpty();
    return shortcut;
  }
  void bind(const QString& trigger) override {
    bound = trigger;
    emit changed();
  }
  void release() override {
    bound.clear();
    emit changed();
  }
  void capture() override { ++captures; }
  void play(const QString&) override {}

  // The desktop only sends a shortcut it holds.
  void press() {
    if (!bound.isEmpty()) emit activated();
  }

  QString bound;
  int captures = 0;
};

[[maybe_unused]] const bool installed = [] {
  QProcessEnvironment env;
  env.insert(QStringLiteral("XDG_SESSION_TYPE"), QStringLiteral("wayland"));
  SnapShotBackend::setEnvironment(env);
  SnapShotBackend::setPortalFactory([](const SnapShotBackend::Platform&, QObject* parent) -> SnapShotBackend* { return new Portal(parent); });
  return true;
}();

struct Model {
  bool panel = false;
  bool enabled = false;
  bool recording = false;
  // Setup is open, and whether Snap Shot was on when it opened.
  std::optional<bool> setup;
  // The saved chord; -1 is the default (both Shift keys), which the portal cannot hold.
  int saved = -1;
  std::optional<int> candidate;
  int captures = 0;

  bool changed() const { return candidate && *candidate != saved; }
  // Recording a new shortcut sets the last one aside until it stops.
  bool canSave() const { return !recording && changed() && *kChords[*candidate].trigger; }
  QString bound() const { return enabled && saved >= 0 ? QString::fromLatin1(kChords[saved].trigger) : QString(); }

  void openSetup() {
    recording = false;
    candidate.reset();
    setup = enabled;
    enabled = true;
  }
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;

  Sut() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
  }

  // A fresh home, so each run starts with Snap Shot off and its default shortcut.
  void reset() {
    native.reset();
    bridge.reset();
    QDir(home.path()).removeRecursively();
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native->isActive() && native->store()->synchronized() && !snapShot().isEmpty(); })) {
      qFatal("the shell did not start");
    }
  }

  SnapShotController* controller() const { return native->controller<SnapShotController>(); }
  Portal* portal() const { return static_cast<Portal*>(controller()->backend()); }
  QVariantMap snapShot() const { return bridge->state()->value(QStringLiteral("snapShot")).toMap(); }
  QVariantMap shortcut() const { return snapShot().value(QStringLiteral("shortcut")).toMap(); }
  QVariant setting(const char* key) const { return native->controller<SettingsController>()->setting(QString::fromLatin1(key)); }
  void dispatch(const char* action, const QVariantMap& payload = {}) {
    bridge->dispatch(QStringLiteral("snapShot.") + QString::fromLatin1(action), payload);
  }

  // The saved shortcut's trigger: empty for the default, which the portal cannot take.
  QString savedTrigger() const {
    QString problem;
    return SnapShotBackend::portalTrigger(QJsonValue::fromVariant(setting("snapShotShortcut")).toObject(), &problem);
  }
};

bool agrees(const Model& model, const Sut& sut) {
  return prop::until([&] {
    const QVariantMap shortcut = sut.shortcut();
    const int saved = model.saved;
    return sut.snapShot().value(QStringLiteral("enabled")).toBool() == model.enabled &&
           sut.setting("snapShotEnabled").toBool() == model.enabled &&
           sut.savedTrigger() == (saved >= 0 ? QString::fromLatin1(kChords[saved].trigger) : QString()) &&
           sut.portal()->bound == model.bound() && shortcut.value(QStringLiteral("recording")).toBool() == model.recording &&
           shortcut.value(QStringLiteral("changed")).toBool() == model.changed() &&
           shortcut.value(QStringLiteral("canSave")).toBool() == model.canSave() &&
           sut.snapShot().value(QStringLiteral("wizard")).isValid() == model.setup.has_value() &&
           sut.portal()->captures == model.captures;
  });
}

using Command = rc::state::Command<Model, Sut>;

// Applies the command to a copy of the model, runs it, and checks the app against the copy.
template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(sut);
    RC_ASSERT(agrees(next, sut));
  }
};

// The window opens the Snap Shot panel, or goes elsewhere in Settings.
struct Panel : Step<Panel> {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.panel = open;
    // Leaving the panel ends recording.
    if (!open) model.recording = false;
  }
  void act(Sut& sut) const {
    sut.native->controller<NavigationController>()->open(
        NavigationController::Route::settings(open ? SnapShotController::kSection : QStringLiteral("/settings/general")));
  }
  void show(std::ostream& os) const override { os << (open ? "OpenPanel" : "LeavePanel"); }
};

struct Enable : Step<Enable> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (on) {
      model.openSetup();
      return;
    }
    model.recording = false;
    model.setup.reset();
    model.enabled = false;
  }
  void act(Sut& sut) const { sut.dispatch("enable", {{QStringLiteral("on"), on}}); }
  void show(std::ostream& os) const override { os << "Enable " << on; }
};

struct OpenSetup : Step<OpenSetup> {
  void apply(Model& model) const override { model.openSetup(); }
  void act(Sut& sut) const { sut.dispatch("setup.open"); }
  void show(std::ostream& os) const override { os << "OpenSetup"; }
};

struct CloseSetup : Step<CloseSetup> {
  bool completed = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (!model.setup) return;
    if (!*model.setup && !completed) model.enabled = false;
    model.setup.reset();
    model.recording = false;
  }
  void act(Sut& sut) const { sut.dispatch("setup.close", {{QStringLiteral("completed"), completed}}); }
  void show(std::ostream& os) const override { os << "CloseSetup completed=" << completed; }
};

// Recording starts from the panel's shortcut row.
struct RecordStart : Step<RecordStart> {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.panel); }
  void apply(Model& model) const override { model.recording = true; }
  void act(Sut& sut) const { sut.dispatch("record.start"); }
  void show(std::ostream& os) const override { os << "RecordStart"; }
};

struct Press : Step<Press> {
  int chord = *rc::gen::inRange(0, kChordCount);
  bool repeat = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});
  void apply(Model& model) const override {
    if (!model.recording || repeat) return;
    model.recording = false;
    model.candidate = chord;
  }
  void act(Sut& sut) const {
    sut.dispatch("record.key",
                 {{QStringLiteral("key"), kChords[chord].key}, {QStringLiteral("modifiers"), kChords[chord].modifiers}, {QStringLiteral("repeat"), repeat}});
  }
  void show(std::ostream& os) const override { os << "Press " << chord << (repeat ? " (repeat)" : ""); }
};

// Escape, or the row's cancel.
struct StopRecording : Step<StopRecording> {
  bool escape = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.recording = false; }
  void act(Sut& sut) const {
    if (escape) sut.dispatch("record.key", {{QStringLiteral("key"), int(Qt::Key_Escape)}, {QStringLiteral("modifiers"), 0}});
    else sut.dispatch("record.cancel");
  }
  void show(std::ostream& os) const override { os << (escape ? "Escape" : "CancelRecording"); }
};

struct Save : Step<Save> {
  void apply(Model& model) const override {
    if (!model.canSave()) return;
    model.saved = *model.candidate;
    model.candidate.reset();
  }
  void act(Sut& sut) const { sut.dispatch("shortcut.save"); }
  void show(std::ostream& os) const override { os << "Save"; }
};

struct Discard : Step<Discard> {
  void apply(Model& model) const override {
    model.recording = false;
    model.candidate.reset();
  }
  void act(Sut& sut) const { sut.dispatch("shortcut.discard"); }
  void show(std::ostream& os) const override { os << "Discard"; }
};

// The user presses the Snap Shot shortcut in another app.
struct Shoot : Step<Shoot> {
  void apply(Model& model) const override {
    if (!model.bound().isEmpty() && !model.recording) ++model.captures;
  }
  void act(Sut& sut) const { sut.portal()->press(); }
  void show(std::ostream& os) const override { os << "Shoot"; }
};

}  // namespace

class SnapShotProp : public QObject {
  Q_OBJECT

private slots:
  void settings() {
    Sut sut;
    QVERIFY(rc::check("the shortcut saves only when asked, is held while Snap Shot is on, and recording pauses it", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Panel, Panel, Enable, OpenSetup, CloseSetup, RecordStart, RecordStart, Press,
                                                         Press, Press, StopRecording, Save, Save, Discard, Shoot, Shoot>());
    }));
  }
};

HAL_C2_PROP_MAIN(SnapShotProp)
#include "tst_SnapShotProp.moc"
