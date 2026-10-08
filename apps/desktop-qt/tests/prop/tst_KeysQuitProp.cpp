// QuitController as a state machine over what the user's hands do: mod and Q
// going down and up, Q auto-repeating (with X11's paired releases), Q's
// release going unseen (macOS swallows it while Command is down), other keys,
// the palette's Quit, `confirmQuit` changing, and time passing on the
// controller's own clock. The model is the Electron shell's handler
// (apps/desktop/src/window/QuitHold.ts) with its settings read answered at
// once, plus the hold hint lingering after a release. After every step the
// quits, the windows concealed, the hint, and which presses the window saw
// are the model's.

#include "Prop.h"

#include "KeybindingController.h"
#include "NativeShell.h"
#include "QuitController.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QKeyEvent>
#include <QTemporaryDir>
#include <QWindow>

#include <optional>
#include <vector>

namespace {

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

const QString kHold = QStringLiteral("hold");
const QString kDoublePress = QStringLiteral("double-click");
const QString kDirect = QStringLiteral("direct");
// Time moves in steps of this; every deadline falls on one.
constexpr qint64 kTick = 10;

// What runs when the watchdog fires.
enum class Watch { None, Release, Quit };

struct Model {
  // `confirmQuit` as set: a mode, or the old boolean.
  QVariant setting = kHold;
  qint64 now = 100000;
  // The user's hands.
  bool mod = false;
  bool q = false;
  // QuitHold.ts's state.
  bool holding = false;
  QString mode;
  bool notified = false;
  bool armed = false;
  bool quitOnRelease = false;
  qint64 heldSince = 0;
  qint64 lastPressAt = 0;
  qint64 lastRepeatAt = 0;
  qint64 repeatCadence = 0;
  qint64 watchAt = 0;
  Watch watch = Watch::None;
  // The hint: which mode's, while it shows, and when a released hold's goes.
  QString hint;
  qint64 lingerAt = 0;
  int quits = 0;
  int conceals = 0;

  QString resolvedMode() const {
    if (setting.typeId() == QMetaType::Bool) return setting.toBool() ? kHold : kDirect;
    const QString value = setting.toString();
    return value == kDirect || value == kDoublePress ? value : kHold;
  }
  void startWatch(qint64 ms, Watch what) {
    watchAt = now + ms;
    watch = what;
  }
  void showHint(const QString& hintMode) {
    lingerAt = 0;
    hint = hintMode;
  }
  void hideHint() {
    if (hint == kDoublePress) {
      hint.clear();
    } else {
      lingerAt = now + QuitController::kHintLingerMs;
    }
  }
  void release(bool keepDoublePressHint = false) {
    if (!holding && !notified) return;
    const bool keepHint = keepDoublePressHint && mode == kDoublePress && notified;
    holding = false;
    armed = false;
    quitOnRelease = false;
    lastRepeatAt = 0;
    repeatCadence = 0;
    if (keepHint) return;
    mode.clear();
    watchAt = 0;
    watch = Watch::None;
    if (notified) {
      notified = false;
      hideHint();
    }
  }
  void quitNow() {
    release();
    lastPressAt = 0;
    ++quits;
  }
  void quitAfterQuietPeriod() {
    startWatch(std::max<qint64>(QuitController::kReleaseGraceMs, repeatCadence * 2), Watch::Quit);
  }

  // A key press; whether the window never sees it.
  bool keyDown(int key, bool modDown, bool shift, bool autoRepeat) {
    const bool isQ = key == Qt::Key_Q;
    if (autoRepeat && modDown && isQ) {
      repeatCadence = now - (lastRepeatAt == 0 ? heldSince : lastRepeatAt);
      lastRepeatAt = now;
    }
    if (quitOnRelease) {
      if (isQ) quitAfterQuietPeriod();
      return true;
    }
    if (!modDown || shift || !isQ) {
      if (key == Qt::Key_Control && !shift) return false;
      if (!autoRepeat) {
        lastPressAt = 0;
        release();
      }
      return false;
    }
    if (autoRepeat) {
      if (mode == kHold && armed && now - heldSince >= QuitController::kHoldMs) {
        armed = false;
        quitOnRelease = true;
        ++conceals;
        quitAfterQuietPeriod();
      }
      return true;
    }
    const qint64 previousPressAt = lastPressAt;
    lastPressAt = now;
    if (holding || notified) release();
    if (previousPressAt != 0 && now - previousPressAt <= QuitController::kDoublePressMs) {
      quitNow();
      return true;
    }
    const QString resolved = resolvedMode();
    if (resolved == kDirect) {
      quitNow();
      return true;
    }
    holding = true;
    heldSince = now;
    mode = resolved;
    notified = true;
    showHint(resolved);
    if (resolved == kDoublePress) {
      startWatch(QuitController::kDoublePressMs, Watch::Release);
    } else {
      armed = true;
      startWatch(QuitController::kHoldMs + QuitController::kReleaseGraceMs, Watch::Release);
    }
    return true;
  }
  void keyUp(int key) {
    if (key == Qt::Key_Q) {
      const bool shouldQuit = quitOnRelease;
      release(true);
      if (shouldQuit) ++quits;
    } else if (key == Qt::Key_Control) {
      if (quitOnRelease) {
        quitAfterQuietPeriod();
      } else {
        release(true);
      }
    }
  }
  // One tick: the watchdog, then the hint, if due.
  void tick() {
    now += kTick;
    if (watchAt != 0 && watchAt <= now) {
      const Watch what = std::exchange(watch, Watch::None);
      watchAt = 0;
      if (what == Watch::Release) release();
      if (what == Watch::Quit) quitNow();
    }
    if (lingerAt != 0 && lingerAt <= now) {
      lingerAt = 0;
      hint.clear();
    }
  }
};

void showValue(const Model& model, std::ostream& os) {
  os << "{now " << model.now << (model.mod ? " mod" : "") << (model.q ? " Q" : "") << " mode "
     << model.mode.toStdString() << (model.quitOnRelease ? " quitOnRelease" : "") << " hint " << model.hint.toStdString()
     << " quits " << model.quits << "}";
}

// Records the key presses that reach the window, past the application's filters.
class Reached : public QObject {
public:
  int presses = 0;

protected:
  bool eventFilter(QObject*, QEvent* event) override {
    if (event->type() == QEvent::KeyPress) ++presses;
    return false;
  }
};

struct Shell {
  QTemporaryDir home;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QuitController* quit = nullptr;
  QWindow window;
  Reached reached;
  qint64 now = 100000;
  int quits = 0;
  int conceals = 0;

  Shell() {
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    quit = native.shared<QuitController>();
    if (!quit) qFatal("no QuitController");
    quit->setClock([this] { return now; });
    QObject::connect(quit, &QuitController::quitRequested, quit, [this] { ++quits; });
    QObject::connect(quit, &QuitController::concealRequested, quit, [this] { ++conceals; });
    window.installEventFilter(&reached);
  }

  void setMode(const QVariant& value) {
    native.controller<SettingsController>()->set(QStringLiteral("confirmQuit"), value);
  }

  // Sends a key to the window as the platform would; whether it got there.
  bool send(QEvent::Type type, int key, Qt::KeyboardModifiers modifiers, bool autoRepeat = false) {
    const int before = reached.presses;
    QKeyEvent event(type, key, modifiers, QString(), autoRepeat);
    QCoreApplication::sendEvent(&window, &event);
    return reached.presses > before;
  }

  QString hint() const {
    return bridge.state()->value(QStringLiteral("quitHint")).toMap().value(QStringLiteral("message")).toString();
  }
};

void check(const Model& model, Shell& shell) {
  RC_ASSERT(shell.quits == model.quits);
  RC_ASSERT(shell.conceals == model.conceals);
  const QString key = shell.native.controller<KeybindingController>()->keyLabel(QStringLiteral("mod+q"));
  const QString hint = model.hint.isEmpty() ? QString()
                       : model.hint == kHold ? QStringLiteral("Hold %1 or press twice to quit").arg(key)
                                             : QStringLiteral("Press %1 again to quit").arg(key);
  RC_ASSERT(shell.hint() == hint);
}

Qt::KeyboardModifiers held(const Model& model, bool shift = false) {
  Qt::KeyboardModifiers modifiers;
  if (model.mod) modifiers |= Qt::ControlModifier;
  if (shift) modifiers |= Qt::ShiftModifier;
  return modifiers;
}

using Command = rc::state::Command<Model, Shell>;

struct ModDown : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.mod); }
  void apply(Model& model) const override {
    model.mod = true;
    model.keyDown(Qt::Key_Control, true, false, false);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    const bool consumed = expected.keyDown(Qt::Key_Control, true, false, false);
    expected.mod = true;
    RC_ASSERT(shell.send(QEvent::KeyPress, Qt::Key_Control, Qt::ControlModifier) == !consumed);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ModDown"; }
};

struct ModUp : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mod); }
  void apply(Model& model) const override {
    model.mod = false;
    model.keyUp(Qt::Key_Control);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.send(QEvent::KeyRelease, Qt::Key_Control, Qt::NoModifier);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ModUp"; }
};

// Q goes down, with Shift held or not.
struct QDown : Command {
  bool shift = *rc::gen::weightedElement<bool>({{5, false}, {1, true}});

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.q); }
  void apply(Model& model) const override {
    model.keyDown(Qt::Key_Q, model.mod, shift, false);
    model.q = true;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    const bool consumed = expected.keyDown(Qt::Key_Q, model.mod, shift, false);
    expected.q = true;
    RC_ASSERT(shell.send(QEvent::KeyPress, Qt::Key_Q, held(model, shift)) == !consumed);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "QDown" << (shift ? " shift" : ""); }
};

// A held Q's auto-repeat: on X11 a release and a press, both marked repeats.
struct QRepeat : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.q); }
  void apply(Model& model) const override { model.keyDown(Qt::Key_Q, model.mod, false, true); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    const bool consumed = expected.keyDown(Qt::Key_Q, model.mod, false, true);
    shell.send(QEvent::KeyRelease, Qt::Key_Q, held(model), true);
    RC_ASSERT(shell.send(QEvent::KeyPress, Qt::Key_Q, held(model), true) == !consumed);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "QRepeat"; }
};

// Q pressed if it is not down, then kept down: the platform's first repeat
// after `delay`, then one every `cadence`, until `duration` has passed.
struct HoldQ : Command {
  int delay = *rc::gen::inRange(20, 61) * int(kTick);
  int cadence = *rc::gen::weightedOneOf<int>({{4, rc::gen::inRange(3, 6)}, {1, rc::gen::inRange(6, 41)}}) * int(kTick);
  int duration = *rc::gen::inRange(0, 251) * int(kTick);

  // Ticks to wait, then a repeat, in turn.
  QList<int> waits() const {
    QList<int> list;
    for (int at = delay, last = 0; at <= duration; last = at, at += cadence) list.append((at - last) / int(kTick));
    return list;
  }
  void apply(Model& model) const override {
    if (!model.q) model.keyDown(Qt::Key_Q, model.mod, false, false);
    model.q = true;
    for (const int wait : waits()) {
      for (int tick = 0; tick < wait; ++tick) model.tick();
      model.keyDown(Qt::Key_Q, model.mod, false, true);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    if (!model.q) {
      const bool consumed = expected.keyDown(Qt::Key_Q, model.mod, false, false);
      RC_ASSERT(shell.send(QEvent::KeyPress, Qt::Key_Q, held(model)) == !consumed);
      check(expected, shell);
    }
    expected.q = true;
    for (const int wait : waits()) {
      for (int tick = 0; tick < wait; ++tick) {
        expected.tick();
        shell.now += kTick;
        shell.quit->poll();
      }
      const bool consumed = expected.keyDown(Qt::Key_Q, expected.mod, false, true);
      shell.send(QEvent::KeyRelease, Qt::Key_Q, held(expected), true);
      RC_ASSERT(shell.send(QEvent::KeyPress, Qt::Key_Q, held(expected), true) == !consumed);
      check(expected, shell);
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "HoldQ " << duration << "ms, repeating from " << delay << "ms every " << cadence << "ms";
  }
};

// Q comes up, seen or (macOS, with Command down) not.
struct QUp : Command {
  bool unseen = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});

  void checkPreconditions(const Model& model) const override { RC_PRE(model.q); }
  void apply(Model& model) const override {
    model.q = false;
    if (!unseen) model.keyUp(Qt::Key_Q);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (!unseen) shell.send(QEvent::KeyRelease, Qt::Key_Q, held(model));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "QUp" << (unseen ? " unseen" : ""); }
};

// Some other key, typed or repeating, with whatever is held.
struct Other : Command {
  int key = *rc::gen::element<int>(Qt::Key_A, Qt::Key_W, Qt::Key_Shift);
  bool autoRepeat = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});

  void apply(Model& model) const override { model.keyDown(key, model.mod, key == Qt::Key_Shift, autoRepeat); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    const bool consumed = expected.keyDown(key, model.mod, key == Qt::Key_Shift, autoRepeat);
    RC_ASSERT(shell.send(QEvent::KeyPress, key, held(model, key == Qt::Key_Shift), autoRepeat) == !consumed);
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "Other " << (key == Qt::Key_A ? "A" : key == Qt::Key_W ? "W" : "Shift") << (autoRepeat ? " repeat" : "");
  }
};

struct Advance : Command {
  int ticks = *rc::gen::weightedOneOf<int>({{3, rc::gen::inRange(1, 10)}, {2, rc::gen::inRange(10, 70)},
                                           {1, rc::gen::inRange(70, 200)}});

  void apply(Model& model) const override {
    for (int tick = 0; tick < ticks; ++tick) model.tick();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    // Tick by tick, so each deadline is met on its own.
    for (int tick = 0; tick < ticks; ++tick) {
      shell.now += kTick;
      shell.quit->poll();
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Advance " << ticks * kTick << "ms"; }
};

struct SetMode : Command {
  QVariant value = *rc::gen::weightedOneOf<QVariant>({{3, rc::gen::element<QVariant>(kHold, kDoublePress, kDirect)},
                                                       {1, rc::gen::element<QVariant>(true, false)}});

  void apply(Model& model) const override { model.setting = value; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.setMode(value);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetMode " << value.toString().toStdString(); }
};

// The palette's Quit, or the system menu's.
struct PaletteQuit : Command {
  void apply(Model& model) const override { model.quitNow(); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.quit->quit();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "PaletteQuit"; }
};

}  // namespace

class KeysQuitProp : public QObject {
  Q_OBJECT

private slots:
  void quitShortcut() {
    Shell shell;
    QVERIFY(rc::check("the quit shortcut quits, conceals and hints as QuitHold.ts does", [&shell] {
      // The hands come off the keys and time moves past whatever was waiting.
      shell.send(QEvent::KeyRelease, Qt::Key_Q, Qt::NoModifier);
      shell.send(QEvent::KeyRelease, Qt::Key_Control, Qt::NoModifier);
      shell.send(QEvent::KeyPress, Qt::Key_A, Qt::NoModifier);
      shell.now += 10000;
      shell.quit->poll();
      shell.now = 100000;
      shell.setMode(kHold);
      shell.quits = 0;
      shell.conceals = 0;
      RC_ASSERT(shell.hint().isEmpty());
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<ModDown, ModDown, ModUp, QDown, QDown, QRepeat, HoldQ, HoldQ,
                                                         QUp, Other, Advance, Advance, SetMode, PaletteQuit>());
      RC_CLASSIFY(shell.conceals > 0, "held to quit");
      RC_CLASSIFY(shell.quits > 0, "quit");
    }));
  }
};

HAL_C2_PROP_MAIN(KeysQuitProp)
#include "tst_KeysQuitProp.moc"
