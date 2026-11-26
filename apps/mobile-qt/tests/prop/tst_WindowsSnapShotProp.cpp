// Snap Shot on Windows (WindowsSnapShot) on a fake Windows. Shortcuts are bound,
// refused, released and lost; the shortcut is pressed with and without a window
// and over a cue; grabs answer, fail, overrun their deadline and answer late. At
// most one shortcut is held, and only while asked for; at most one grab runs;
// every press that starts or refuses a capture is answered exactly once, a late
// answer is never attached, and a capture plays only the cue the user chose.

#include "Prop.h"

#include <memory>
#include <optional>

#include "WindowsSnapShot.h"

namespace {

const QJsonObject& shortcutAt(int index) {
  static const QJsonObject shortcuts[] = {
      {{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}},
      {{QStringLiteral("kind"), QStringLiteral("modifier-pair")}, {QStringLiteral("modifier"), QStringLiteral("alt")}},
      {{QStringLiteral("key"), QStringLiteral("k")}, {QStringLiteral("ctrlKey"), true}},
  };
  return shortcuts[index];
}

class FakeWindows : public WindowsSystem {
public:
  using WindowsSystem::WindowsSystem;

  std::optional<Window> foreground() override {
    if (!hasWindow) return std::nullopt;
    return Window{1, QStringLiteral("t"), QRect(0, 0, 10, 10), QStringLiteral("C:\\a.exe")};
  }
  void grab(const QRect&) override {
    if (running) wrong = true;
    running = true;
    cancelled = false;
  }
  bool grabbing() const override { return running; }
  void cancelGrab() override { cancelled = true; }
  bool holdHotKey(uint, uint) override { return take(); }
  void releaseHotKey() override { hotKey = false; }
  bool canHoldHotKey(uint, uint) override { return !refuses; }
  bool watchPair(uint, uint) override {
    const bool taken = take();
    if (taken) {
      hotKey = false;
      watching = true;
    }
    return taken;
  }
  void stopWatching() override { watching = false; }
  bool canWatchPair(uint, uint) override { return !refuses; }
  bool animationsEnabled() const override { return animations; }
  void flash(const QRect&, bool) override { ++flashes; }
  void fly(const QImage&, const QRect&, bool) override { ++flights; }
  bool cueShowing() const override { return cue; }

  bool take() {
    if (hotKey || watching) wrong = true;
    if (refuses) return false;
    hotKey = true;
    return true;
  }
  // The grab ends; what the native one drops once cancelled is dropped here too.
  void answer(bool ok, bool big) {
    running = false;
    if (cancelled) return;
    if (!ok) {
      emit grabFailed(QStringLiteral("no"));
      return;
    }
    QImage image(big ? 5000 : 10, 10, QImage::Format_RGB32);
    image.fill(Qt::black);
    emit grabbed(image);
  }

  bool hasWindow = true;
  bool refuses = false;
  bool animations = true;
  bool cue = false;
  bool running = false;
  bool cancelled = false;
  bool hotKey = false;
  bool watching = false;
  bool wrong = false;
  int flashes = 0;
  int flights = 0;
};

struct Model {
  bool hasWindow = true;
  bool refuses = false;
  bool systemAnimations = true;
  bool cue = false;
  bool flash = true;
  bool animations = true;

  std::optional<int> bound;
  bool held = false;

  bool capturing = false;
  bool running = false;
  int attached = 0;
  int failed = 0;
  int flashes = 0;
  int flights = 0;
};

struct Sut {
  FakeWindows* windows = nullptr;
  std::unique_ptr<WindowsSnapShot> snapShot;
  int attached = 0;
  int failed = 0;
  int tooBig = 0;

  void reset() {
    snapShot.reset();
    windows = new FakeWindows;
    snapShot = std::make_unique<WindowsSnapShot>(windows, nullptr);
    attached = failed = tooBig = 0;
    QObject::connect(snapShot.get(), &SnapShotBackend::captured, snapShot.get(), [this](const QImage& image) {
      ++attached;
      if (image.width() > WindowsSnapShot::kMaxWidth || image.height() > WindowsSnapShot::kMaxHeight) ++tooBig;
    });
    QObject::connect(snapShot.get(), &SnapShotBackend::failed, snapShot.get(), [this] { ++failed; });
  }
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& model, const Sut& sut) {
  RC_ASSERT(!sut.windows->wrong);
  RC_ASSERT(sut.tooBig == 0);
  RC_ASSERT((sut.windows->hotKey || sut.windows->watching) == model.held);
  RC_ASSERT(sut.snapShot->shortcut().registered == model.held);
  // A shortcut wanted and not held says why.
  if (model.bound && !model.held) RC_ASSERT(!sut.snapShot->shortcut().message.isEmpty());
  RC_ASSERT(sut.snapShot->capturing() == model.capturing);
  RC_ASSERT(sut.windows->running == model.running);
  RC_ASSERT(sut.attached == model.attached);
  RC_ASSERT(sut.failed == model.failed);
  RC_ASSERT(sut.windows->flashes == model.flashes);
  RC_ASSERT(sut.windows->flights == model.flights);
}

template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(sut);
    check(next, sut);
  }
};

struct SetWindow : Step<SetWindow> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.hasWindow = on; }
  void act(Sut& sut) const { sut.windows->hasWindow = on; }
  void show(std::ostream& os) const override { os << "SetWindow(" << on << ")"; }
};

struct SetRefuses : Step<SetRefuses> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refuses = on; }
  void act(Sut& sut) const { sut.windows->refuses = on; }
  void show(std::ostream& os) const override { os << "SetRefuses(" << on << ")"; }
};

struct SetSystem : Step<SetSystem> {
  bool animations = *rc::gen::arbitrary<bool>();
  bool cue = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.systemAnimations = animations;
    model.cue = cue;
  }
  void act(Sut& sut) const {
    sut.windows->animations = animations;
    sut.windows->cue = cue;
  }
  void show(std::ostream& os) const override { os << "SetSystem(" << animations << ", " << cue << ")"; }
};

struct SetCues : Step<SetCues> {
  bool flash = *rc::gen::arbitrary<bool>();
  bool animations = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.flash = flash;
    model.animations = animations;
  }
  void act(Sut& sut) const { sut.snapShot->setCues(flash, animations); }
  void show(std::ostream& os) const override { os << "SetCues(" << flash << ", " << animations << ")"; }
};

struct Bind : Step<Bind> {
  int index = *rc::gen::inRange(0, 3);
  void apply(Model& model) const override {
    model.bound = index;
    model.held = !model.refuses;
  }
  void act(Sut& sut) const { sut.snapShot->bind(sut.snapShot->trigger(shortcutAt(index), nullptr)); }
  void show(std::ostream& os) const override { os << "Bind(" << index << ")"; }
};

struct Release : Step<Release> {
  void apply(Model& model) const override {
    model.bound.reset();
    model.held = false;
  }
  void act(Sut& sut) const { sut.snapShot->release(); }
  void show(std::ostream& os) const override { os << "Release"; }
};

// The hook stops; a chord is not held by one.
struct Lost : Step<Lost> {
  void apply(Model& model) const override {
    if (model.bound && *model.bound != 2) model.held = false;
  }
  void act(Sut& sut) const { emit sut.windows->watchLost(); }
  void show(std::ostream& os) const override { os << "Lost"; }
};

struct Press : Step<Press> {
  void apply(Model& model) const override {
    if (model.capturing || model.cue) return;
    if (!model.hasWindow || model.running) {
      ++model.failed;
      return;
    }
    model.capturing = model.running = true;
  }
  void act(Sut& sut) const { sut.snapShot->capture(); }
  void show(std::ostream& os) const override { os << "Press"; }
};

struct Expire : Step<Expire> {
  void apply(Model& model) const override {
    if (!model.capturing) return;
    model.capturing = false;
    ++model.failed;
  }
  void act(Sut& sut) const { sut.snapShot->expire(); }
  void show(std::ostream& os) const override { os << "Expire"; }
};

struct Answer : Step<Answer> {
  bool ok = *rc::gen::arbitrary<bool>();
  bool big = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.running); }
  void apply(Model& model) const override {
    model.running = false;
    // Without a capture waiting, the answer is a late one.
    if (!model.capturing) return;
    model.capturing = false;
    if (!ok) {
      ++model.failed;
      return;
    }
    ++model.attached;
    if (model.animations && model.systemAnimations) ++model.flights;
    else if (model.flash) ++model.flashes;
  }
  void act(Sut& sut) const { sut.windows->answer(ok, big); }
  void show(std::ostream& os) const override { os << "Answer(" << ok << ", " << big << ")"; }
};

}  // namespace

class WindowsSnapShotProp : public QObject {
  Q_OBJECT

private slots:
  void windows() {
    Sut sut;
    QVERIFY(rc::check("one shortcut held while asked for, one grab at a time, each capture answered once", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<SetWindow, SetRefuses, SetSystem, SetCues, Bind, Bind, Release, Lost, Press, Press, Press,
                                                         Expire, Answer, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(WindowsSnapShotProp)
#include "tst_WindowsSnapShotProp.moc"
