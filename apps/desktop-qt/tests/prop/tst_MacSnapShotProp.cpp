// Snap Shot on macOS (MacSnapShot, MacPermissionHelper) on a fake Mac. The user
// grants and revokes permissions behind the app's back, checks of them fail,
// shortcuts are bound, tried, refused and lost, captures finish in order, and
// the permission panel opens and closes. A shortcut is held exactly when it is
// asked for, what the app last read allows it and the system lets it; it is
// never taken twice without letting go; one capture runs at a time and each
// ends once; the panel is open only while its permission was missing.

#include "Prop.h"

#include <QJsonDocument>

#include <deque>
#include <memory>
#include <optional>

#include "MacPermissionHelper.h"
#include "MacPlatform.h"
#include "MacSnapShot.h"

namespace {

using Permissions = SnapShotBackend::Permissions;

const QJsonObject& shortcutAt(int index) {
  static const QJsonObject shortcuts[] = {
      {{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}},
      {{QStringLiteral("kind"), QStringLiteral("modifier-pair")}, {QStringLiteral("modifier"), QStringLiteral("alt")}},
      {{QStringLiteral("key"), QStringLiteral("k")}, {QStringLiteral("metaKey"), true}},
  };
  return shortcuts[index];
}

QString triggerAt(int index) {
  return QString::fromUtf8(QJsonDocument(shortcutAt(index)).toJson(QJsonDocument::Compact));
}

class FakeMac : public MacPlatform {
public:
  using MacPlatform::MacPlatform;

  std::optional<Permissions> permissions() override {
    if (!readable) return std::nullopt;
    return allowed;
  }
  void request(const QString&) override {}
  void openSettings(const QString&) override {}
  bool watchPair(const QString&) override { return take(); }
  bool holdChord(const QJsonObject&) override { return take(); }
  void letGo() override {
    if (!held) wrong = true;
    held = false;
  }
  void capture(bool, std::function<void(const Capture&)> done) override { pending.push_back(std::move(done)); }
  std::optional<SettingsWindow> settingsWindow() override { return SettingsWindow{true, true, QRect(0, 0, 1000, 700)}; }
  void showHelper(const QRect&, const QString&) override { panel = true; }
  void hideHelper() override { panel = false; }
  void closeHelper() override { panel = false; }
  bool helperFocused() override { return false; }
  void revealApp() override {}
  void focusApp() override {}

  bool take() {
    if (held) wrong = true;
    if (refuses) return false;
    held = true;
    return true;
  }

  Permissions allowed;
  bool readable = true;
  bool refuses = false;
  bool held = false;
  // Took a shortcut while holding one, or let go of nothing.
  bool wrong = false;
  bool panel = false;
  std::deque<std::function<void(const Capture&)>> pending;
};

struct Model {
  Permissions allowed;
  bool readable = true;
  bool refuses = false;

  bool probed = false;
  std::optional<Permissions> seen;
  bool readFailed = false;
  bool includeText = true;
  std::optional<int> asked;
  bool held = false;
  bool watching = false;

  // Oldest first: true for a test capture, false for a real one.
  std::deque<bool> pending;
  bool capturing = false;
  int ended = 0;
  int tested = 0;
  int presses = 0;

  std::optional<QString> panel;

  bool missing() const {
    if (!asked || !seen) return false;
    return !seen->screenRecording || (includeText && !seen->accessibility);
  }
  void read() {
    readFailed = !readable;
    if (readable) seen = allowed;
  }
  // What an unforced pass over the shortcut leaves.
  void settle() {
    if (!asked || missing()) held = false;
    else if (!held) held = !refuses;
  }
  // The shortcut is taken again even if held.
  void retake() {
    held = asked && !missing() && !refuses;
  }
  void refresh() {
    probed = true;
    read();
    settle();
  }
  bool has(const QString& permission) const {
    if (!readable) return false;
    return permission == MacPlatform::kScreenRecording ? allowed.screenRecording : allowed.accessibility;
  }
};

struct Sut {
  FakeMac* mac = nullptr;
  std::unique_ptr<MacSnapShot> snapShot;
  int ended = 0;
  int tested = 0;
  int presses = 0;

  void reset() {
    snapShot.reset();
    mac = new FakeMac;
    snapShot = std::make_unique<MacSnapShot>(mac, nullptr);
    ended = tested = presses = 0;
    QObject::connect(snapShot.get(), &SnapShotBackend::captured, snapShot.get(), [this] { ++ended; });
    QObject::connect(snapShot.get(), &SnapShotBackend::failed, snapShot.get(), [this](const QString& message) {
      // The shortcut being lost says so through the same signal.
      if (!message.contains(QLatin1String("not available")) && !message.contains(QLatin1String("already used"))) ++ended;
    });
    QObject::connect(snapShot.get(), &SnapShotBackend::tested, snapShot.get(), [this] { ++tested; });
    QObject::connect(snapShot.get(), &SnapShotBackend::activated, snapShot.get(), [this] { ++presses; });
  }
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& model, const Sut& sut) {
  RC_ASSERT(!sut.mac->wrong);
  RC_ASSERT(sut.mac->held == model.held);
  const auto session = sut.snapShot->session();
  const auto shortcut = sut.snapShot->shortcut();
  RC_ASSERT(session.ready == model.probed);
  RC_ASSERT(session.permissionsError.isEmpty() == !model.readFailed);
  RC_ASSERT(bool(session.message.isEmpty() == !model.missing()));
  if (model.probed) {
    RC_ASSERT(session.permissions.has_value());
    RC_ASSERT(bool(*session.permissions == model.seen.value_or(Permissions{})));
  }
  RC_ASSERT(shortcut.registered == model.held);
  // A shortcut wanted, allowed and not held says why.
  if (model.asked && !model.missing() && !model.held) RC_ASSERT(!shortcut.message.isEmpty());
  RC_ASSERT(sut.mac->pending.size() == model.pending.size());
  RC_ASSERT(sut.ended == model.ended);
  RC_ASSERT(sut.tested == model.tested);
  RC_ASSERT(sut.presses == model.presses);
  RC_ASSERT(sut.snapShot->helper()->open() == model.panel.has_value());
  RC_ASSERT(bool(sut.snapShot->helper()->permission() == model.panel.value_or(QString())));
  RC_ASSERT(sut.mac->panel == model.panel.has_value());
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

// The user changes a permission in System Settings; the app has not looked yet.
struct SetPermissions : Step<SetPermissions> {
  bool screen = *rc::gen::arbitrary<bool>();
  bool accessibility = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.allowed = {screen, accessibility}; }
  void act(Sut& sut) const { sut.mac->allowed = {screen, accessibility}; }
  void show(std::ostream& os) const override { os << "SetPermissions(" << screen << ", " << accessibility << ")"; }
};

struct SetReadable : Step<SetReadable> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.readable = on; }
  void act(Sut& sut) const { sut.mac->readable = on; }
  void show(std::ostream& os) const override { os << "SetReadable(" << on << ")"; }
};

struct SetRefuses : Step<SetRefuses> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refuses = on; }
  void act(Sut& sut) const { sut.mac->refuses = on; }
  void show(std::ostream& os) const override { os << "SetRefuses(" << on << ")"; }
};

struct Refresh : Step<Refresh> {
  void apply(Model& model) const override { model.refresh(); }
  void act(Sut& sut) const { sut.snapShot->refresh(); }
  void show(std::ostream& os) const override { os << "Refresh"; }
};

struct Watch : Step<Watch> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    // Starting to watch looks at once.
    if (on && !model.watching) model.refresh();
    model.watching = on;
  }
  void act(Sut& sut) const { sut.snapShot->watchPermissions(on); }
  void show(std::ostream& os) const override { os << "Watch(" << on << ")"; }
};

struct IncludeText : Step<IncludeText> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (on == model.includeText) return;
    model.includeText = on;
    if (model.probed) model.settle();
  }
  void act(Sut& sut) const { sut.snapShot->setIncludeAccessibility(on); }
  void show(std::ostream& os) const override { os << "IncludeText(" << on << ")"; }
};

struct Bind : Step<Bind> {
  int index = *rc::gen::inRange(0, 3);
  void apply(Model& model) const override {
    if (model.asked == index) return;
    model.asked = index;
    model.retake();
  }
  void act(Sut& sut) const { sut.snapShot->bind(triggerAt(index)); }
  void show(std::ostream& os) const override { os << "Bind(" << index << ")"; }
};

struct Release : Step<Release> {
  void apply(Model& model) const override {
    model.asked.reset();
    model.settle();
  }
  void act(Sut& sut) const { sut.snapShot->release(); }
  void show(std::ostream& os) const override { os << "Release"; }
};

struct Configure : Step<Configure> {
  void apply(Model& model) const override { model.retake(); }
  void act(Sut& sut) const { sut.snapShot->configure(); }
  void show(std::ostream& os) const override { os << "Configure"; }
};

// Setup tries a shortcut: whatever is held comes back afterwards if it can.
struct Try : Step<Try> {
  int index = *rc::gen::inRange(0, 3);
  void apply(Model& model) const override {
    if (model.held) model.held = !model.refuses;
  }
  void act(Sut& sut) const {
    QString message;
    const bool ok = sut.snapShot->available(shortcutAt(index), &message);
    RC_ASSERT(ok == !sut.mac->refuses);
    RC_ASSERT(bool(ok ? !message.contains(QLatin1String("not available")) : !message.isEmpty()));
  }
  void show(std::ostream& os) const override { os << "Try(" << index << ")"; }
};

// The system stops letting the app watch; the next look tries again.
struct Lost : Step<Lost> {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.held); }
  void apply(Model& model) const override { model.held = false; }
  void act(Sut& sut) const {
    sut.mac->held = false;
    emit sut.mac->watchLost();
  }
  void show(std::ostream& os) const override { os << "Lost"; }
};

struct Press : Step<Press> {
  void apply(Model& model) const override { ++model.presses; }
  void act(Sut& sut) const { emit sut.mac->pressed(); }
  void show(std::ostream& os) const override { os << "Press"; }
};

struct Shoot : Step<Shoot> {
  void apply(Model& model) const override {
    if (model.capturing) return;
    model.capturing = true;
    model.pending.push_back(false);
  }
  void act(Sut& sut) const { sut.snapShot->capture(); }
  void show(std::ostream& os) const override { os << "Shoot"; }
};

struct TestCapture : Step<TestCapture> {
  void apply(Model& model) const override { model.pending.push_back(true); }
  void act(Sut& sut) const { sut.snapShot->test(); }
  void show(std::ostream& os) const override { os << "TestCapture"; }
};

struct Finish : Step<Finish> {
  bool ok = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.pending.empty()); }
  void apply(Model& model) const override {
    const bool isTest = model.pending.front();
    model.pending.pop_front();
    if (isTest) {
      ++model.tested;
    } else {
      model.capturing = false;
      ++model.ended;
    }
  }
  void act(Sut& sut) const {
    MacPlatform::Capture result;
    if (ok) {
      result.image = QImage(4, 4, QImage::Format_RGB32);
    } else {
      result.step = QStringLiteral("find-window");
      result.status = QStringLiteral("missing");
    }
    const auto done = std::move(sut.mac->pending.front());
    sut.mac->pending.pop_front();
    done(result);
  }
  void show(std::ostream& os) const override { os << "Finish(" << ok << ")"; }
};

struct Allow : Step<Allow> {
  bool screen = *rc::gen::arbitrary<bool>();
  QString permission() const { return screen ? MacPlatform::kScreenRecording : MacPlatform::kAccessibility; }
  void apply(Model& model) const override {
    model.panel.reset();
    if (!model.has(permission())) model.panel = permission();
    model.refresh();
  }
  void act(Sut& sut) const { sut.snapShot->allow(permission()); }
  void show(std::ostream& os) const override { os << "Allow(" << (screen ? "screen" : "accessibility") << ")"; }
};

// The panel's once-a-second look at its permission.
struct PanelCheck : Step<PanelCheck> {
  void apply(Model& model) const override {
    if (model.panel && model.has(*model.panel)) model.panel.reset();
  }
  void act(Sut& sut) const { sut.snapShot->helper()->check(); }
  void show(std::ostream& os) const override { os << "PanelCheck"; }
};

struct PanelDismissed : Step<PanelDismissed> {
  void apply(Model& model) const override { model.panel.reset(); }
  void act(Sut& sut) const { emit sut.mac->helperDismissed(); }
  void show(std::ostream& os) const override { os << "PanelDismissed"; }
};

}  // namespace

class MacSnapShotProp : public QObject {
  Q_OBJECT

private slots:
  void macos() {
    Sut sut;
    QVERIFY(rc::check("a shortcut is held only while asked for and allowed, captures run one at a time, the panel follows its permission", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<SetPermissions, SetPermissions, SetReadable, SetRefuses, Refresh, Refresh, Watch,
                                                         IncludeText, Bind, Bind, Release, Configure, Try, Lost, Press, Shoot, TestCapture,
                                                         Finish, Allow, PanelCheck, PanelDismissed>());
    }));
  }
};

HAL_C2_PROP_MAIN(MacSnapShotProp)
#include "tst_MacSnapShotProp.moc"
