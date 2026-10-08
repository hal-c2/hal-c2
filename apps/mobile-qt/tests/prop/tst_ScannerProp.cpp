// The pairing-code scanner (src/Scanner) against a model of its camera: opened
// and closed, the user's answer to the camera question and the system's
// settings, the app going behind another and back, the preview's sink coming
// and going, a camera that does not start or stops by itself, and frames: with
// a pairing code, another code or none, several at once, and one read across a
// stop of the camera. A pairing code is paired with once, and nothing read off
// a camera that has stopped since is.

#include "Prop.h"

#include <QThreadPool>
#include <QVideoSink>
#include <qpa/qwindowsysteminterface.h>

#include <memory>
#include <optional>

#include "FakeCamera.h"
#include "Scanner.h"
#include "ShellBridge.h"

namespace {

using Access = ScanCamera::Access;
using Failure = ScanCamera::Failure;

const QString kLink = QStringLiteral("https://devbox.tailnet.ts.net/pair#token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA");

enum class Said { Nothing, NotAPairingCode, NoCamera, Stopped };
// What a frame shows.
enum class Shows { PairingCode, OtherCode, Nothing };
// What happens to the camera while a frame is read: nothing, the scanner is
// closed and opened again, the app goes behind another and comes back, the
// camera stops by itself and the user tries again.
enum class Meanwhile { Nothing, Reopened, Backgrounded, Failed };

const char* name(Access access) {
  switch (access) {
    case Access::Undetermined: return "undetermined";
    case Access::Granted: return "granted";
    case Access::Denied: return "denied";
  }
  return "?";
}
const char* name(Shows shows) {
  switch (shows) {
    case Shows::PairingCode: return "pairing code";
    case Shows::OtherCode: return "other code";
    case Shows::Nothing: return "no code";
  }
  return "?";
}
const char* name(Meanwhile meanwhile) {
  switch (meanwhile) {
    case Meanwhile::Nothing: return "";
    case Meanwhile::Reopened: return ", reopened meanwhile";
    case Meanwhile::Backgrounded: return ", backgrounded meanwhile";
    case Meanwhile::Failed: return ", failed and retried meanwhile";
  }
  return "?";
}

void appState(Qt::ApplicationState state) {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(state);
}

// The pictures a camera is shown, drawn once.
const QImage& picture(Shows shows) {
  static const QSize size(640, 480);
  static const QImage pairing = camera::sees(kLink, size, 300, 9);
  static const QImage other = camera::sees(QStringLiteral("https://example.com/menu"), size, 300, 9);
  static const QImage desk = camera::desk(size);
  switch (shows) {
    case Shows::PairingCode: return pairing;
    case Shows::OtherCode: return other;
    case Shows::Nothing: break;
  }
  return desk;
}

struct Model {
  bool open = false;
  // The scanner's own word on the camera, and what the system holds.
  Access access = Access::Undetermined;
  Access held = Access::Undetermined;
  // The system's question is on screen.
  bool asking = false;
  bool sink = false;
  bool active = true;
  bool failed = false;
  Said said = Said::Nothing;
  // What starting the camera comes to.
  std::optional<Failure> fault;
  // The camera is started and not stopped, and how often it was started.
  bool on = false;
  int attempts = 0;
  int paired = 0;
  int settingsOpened = 0;
};

// Starts or stops the camera for what holds now (Scanner::update), and lets a
// camera that does not start say so.
void update(Model& m) {
  const bool wanted = m.open && !m.failed && m.access == Access::Granted && m.sink && m.active;
  if (!wanted) {
    m.on = false;
  } else if (!m.on) {
    ++m.attempts;
    m.on = !m.fault;
    if (m.fault) {
      m.failed = true;
      m.said = *m.fault == Failure::NoCamera ? Said::NoCamera : Said::Stopped;
    }
  }
}

void open(Model& m) {
  if (m.open) return;
  m.open = true;
  m.access = m.held;
  if (m.access != Access::Granted) m.asking = true;
  update(m);
}

void close(Model& m) {
  if (!m.open) return;
  m.open = false;
  m.failed = false;
  m.said = Said::Nothing;
  update(m);
}

void toFront(Model& m, bool active) {
  if (m.active == active) return;
  m.active = active;
  if (active && m.open && !m.asking) m.access = m.held;
  update(m);
}

void fail(Model& m) {
  m.on = false;
  m.failed = true;
  m.said = Said::Stopped;
}

void retry(Model& m) {
  if (!m.open || !m.failed) return;
  m.failed = false;
  m.said = Said::Nothing;
  update(m);
}

// A device at the pairing screen, as tst_Scanner's: the scanner, the camera
// the test scripts, the preview's sink, and what was asked to be paired with.
struct Sut {
  Sut() : camera(std::make_shared<FakeCamera>()), sink(std::make_unique<QVideoSink>()) {
    appState(Qt::ApplicationActive);
    bridge.addInterceptor([this](const QString& action, const QVariant& payload) {
      if (action != QLatin1String("pairing.pair")) return false;
      paired.append(payload.toMap().value(QStringLiteral("link")).toString());
      return true;
    });
    scanner = std::make_unique<Scanner>(&bridge, camera);
  }
  ~Sut() {
    scanner.reset();
    QThreadPool::globalInstance()->waitForDone();
    halc2::prop::settle();
    appState(Qt::ApplicationActive);
  }

  QVariantMap state() const { return bridge.state()->value(QStringLiteral("scanner")).toMap(); }
  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge.dispatch(action, payload); }
  // Whatever is being read is read, and what it found handed over.
  void drain() {
    QThreadPool::globalInstance()->waitForDone();
    halc2::prop::settle();
  }

  void check(const Model& m) const {
    const QVariantMap state = this->state();
    RC_ASSERT(state.value(QStringLiteral("open")).toBool() == m.open);
    const QString access = m.asking                     ? QStringLiteral("asking")
                           : m.access == Access::Granted ? QStringLiteral("granted")
                           : m.access == Access::Denied  ? QStringLiteral("denied")
                                                         : QStringLiteral("unknown");
    RC_ASSERT(state.value(QStringLiteral("access")).toString() == access);
    RC_ASSERT(state.value(QStringLiteral("failed")).toBool() == m.failed);
    const QString message = state.value(QStringLiteral("message")).toString();
    switch (m.said) {
      case Said::Nothing: RC_ASSERT(message.isEmpty()); break;
      case Said::NotAPairingCode: RC_ASSERT(message.startsWith(QStringLiteral("That is not a HAL-C2 pairing code."))); break;
      case Said::NoCamera: RC_ASSERT(message.startsWith(QStringLiteral("This device has no camera."))); break;
      case Said::Stopped: RC_ASSERT(message.startsWith(QStringLiteral("The camera cannot be used right now."))); break;
    }
    RC_ASSERT(camera->inUse() == m.on);
    RC_ASSERT(camera->running() == m.on);
    RC_ASSERT(camera->attempts == m.attempts);
    RC_ASSERT(camera->asking() == m.asking);
    RC_ASSERT(camera->settingsOpened == m.settingsOpened);
    RC_ASSERT(paired.size() == m.paired);
    for (const QString& link : paired) RC_ASSERT(link == kLink);
  }

  ShellBridge bridge;
  std::shared_ptr<FakeCamera> camera;
  std::unique_ptr<QVideoSink> sink;
  QStringList paired;
  std::unique_ptr<Scanner> scanner;
};

using Command = rc::state::Command<Model, Sut>;

// Each command does its thing and lets what it posted be delivered: a
// camera's word that it did not start, the system's answer.
template <class Self>
struct Step : Command {
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    static_cast<const Self*>(this)->apply(next);
    static_cast<const Self*>(this)->act(m, s);
    halc2::prop::settle();
    s.check(next);
  }
};

struct Open : Step<Open> {
  explicit Open(const Model&) {}
  void apply(Model& m) const override { open(m); }
  void act(const Model&, Sut& s) const { s.dispatch(QStringLiteral("scanner.open")); }
  void show(std::ostream& os) const override { os << "Open"; }
};

struct Close : Step<Close> {
  explicit Close(const Model&) {}
  void apply(Model& m) const override { close(m); }
  void act(const Model&, Sut& s) const { s.dispatch(QStringLiteral("scanner.close")); }
  void show(std::ostream& os) const override { os << "Close"; }
};

struct Retry : Step<Retry> {
  explicit Retry(const Model&) {}
  void apply(Model& m) const override { retry(m); }
  void act(const Model&, Sut& s) const { s.dispatch(QStringLiteral("scanner.retry")); }
  void show(std::ostream& os) const override { os << "Retry"; }
};

struct Settings : Step<Settings> {
  explicit Settings(const Model&) {}
  void apply(Model& m) const override { ++m.settingsOpened; }
  void act(const Model&, Sut& s) const { s.dispatch(QStringLiteral("scanner.settings")); }
  void show(std::ostream& os) const override { os << "Settings"; }
};

// The user answers the system's question.
struct Answer : Step<Answer> {
  Access given = *rc::gen::element(Access::Granted, Access::Denied);
  explicit Answer(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.asking); }
  void apply(Model& m) const override {
    m.held = given;
    m.asking = false;
    m.access = given;
    update(m);
  }
  void act(const Model&, Sut& s) const { s.camera->reply(given); }
  void show(std::ostream& os) const override { os << "Answer(" << name(given) << ")"; }
};

// The user changes the app's camera access in the system's settings.
struct Allow : Step<Allow> {
  Access held = *rc::gen::element(Access::Granted, Access::Denied, Access::Undetermined);
  explicit Allow(const Model&) {}
  void apply(Model& m) const override { m.held = held; }
  void act(const Model&, Sut& s) const { s.camera->held = held; }
  void show(std::ostream& os) const override { os << "Allow(" << name(held) << ")"; }
};

struct Front : Step<Front> {
  bool active = *rc::gen::arbitrary<bool>();
  explicit Front(const Model&) {}
  void apply(Model& m) const override { toFront(m, active); }
  void act(const Model&, Sut&) const { appState(active ? Qt::ApplicationActive : Qt::ApplicationInactive); }
  void show(std::ostream& os) const override { os << (active ? "Front" : "Behind"); }
};

// The screen hands its sink over, takes it back, or goes with it.
struct Preview : Step<Preview> {
  // 0: the sink, 1: none, 2: the sink is destroyed and a new one made, not handed over
  int what = *rc::gen::inRange(0, 3);
  explicit Preview(const Model&) {}
  void apply(Model& m) const override {
    m.sink = what == 0;
    update(m);
  }
  void act(const Model&, Sut& s) const {
    if (what == 2) {
      s.sink = std::make_unique<QVideoSink>();
      return;
    }
    s.dispatch(QStringLiteral("scanner.preview"), {{QStringLiteral("sink"), QVariant::fromValue<QObject*>(what == 0 ? s.sink.get() : nullptr)}});
  }
  void show(std::ostream& os) const override { os << (what == 0 ? "Preview(sink)" : what == 1 ? "Preview(none)" : "Preview(sink destroyed)"); }
};

// Whether the next start of the camera works.
struct Fault : Step<Fault> {
  // 0: it starts, 1: it does not, 2: there is none
  int what = *rc::gen::element(0, 0, 1, 2);
  explicit Fault(const Model&) {}
  std::optional<Failure> fault() const {
    if (what == 1) return Failure::Stopped;
    if (what == 2) return Failure::NoCamera;
    return std::nullopt;
  }
  void apply(Model& m) const override { m.fault = fault(); }
  void act(const Model&, Sut& s) const { s.camera->fault = fault(); }
  void show(std::ostream& os) const override { os << (what == 0 ? "Fault(none)" : what == 1 ? "Fault(stops)" : "Fault(no camera)"); }
};

// The running camera stops by itself.
struct Stop : Step<Stop> {
  explicit Stop(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.on); }
  void apply(Model& m) const override { fail(m); }
  void act(const Model&, Sut& s) const { s.camera->fail(); }
  void show(std::ostream& os) const override { os << "Stop"; }
};

// The running camera delivers frames of one picture, one after another, and
// something may happen to it before they are read.
struct Frames : Command {
  Shows shows = *rc::gen::element(Shows::PairingCode, Shows::OtherCode, Shows::Nothing);
  int count = *rc::gen::inRange(1, 4);
  Meanwhile meanwhile = *rc::gen::element(Meanwhile::Nothing, Meanwhile::Nothing, Meanwhile::Reopened, Meanwhile::Backgrounded, Meanwhile::Failed);

  explicit Frames(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.on); }

  void apply(Model& m) const override {
    switch (meanwhile) {
      case Meanwhile::Nothing:
        // At most one pairing, after which the scanner is gone.
        if (shows == Shows::PairingCode) {
          close(m);
          ++m.paired;
        } else if (shows == Shows::OtherCode) {
          m.said = Said::NotAPairingCode;
        }
        return;
      // What was read pairs with nothing: the camera stopped since.
      case Meanwhile::Reopened:
        close(m);
        open(m);
        return;
      case Meanwhile::Backgrounded:
        toFront(m, false);
        toFront(m, true);
        return;
      case Meanwhile::Failed:
        fail(m);
        retry(m);
        return;
    }
  }

  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    for (int i = 0; i < count; ++i) s.camera->show(picture(shows));
    switch (meanwhile) {
      case Meanwhile::Nothing:
        break;
      case Meanwhile::Reopened:
        s.dispatch(QStringLiteral("scanner.close"));
        s.dispatch(QStringLiteral("scanner.open"));
        break;
      case Meanwhile::Backgrounded:
        appState(Qt::ApplicationInactive);
        appState(Qt::ApplicationActive);
        break;
      case Meanwhile::Failed:
        s.camera->fail();
        s.dispatch(QStringLiteral("scanner.retry"));
        break;
    }
    s.drain();
    s.check(next);
  }

  void show(std::ostream& os) const override { os << "Frames(" << name(shows) << " x" << count << name(meanwhile) << ")"; }
};

// A frame reaches the sink while the camera is not running: one the camera
// had on its way as it stopped.
struct LateFrame : Command {
  Shows shows = *rc::gen::element(Shows::PairingCode, Shows::OtherCode);
  explicit LateFrame(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.sink && !m.on); }
  void apply(Model&) const override {}
  void run(const Model& m, Sut& s) const override {
    s.sink->setVideoFrame(camera::nv12(picture(shows)));
    s.drain();
    s.check(m);
  }
  void show(std::ostream& os) const override { os << "LateFrame(" << name(shows) << ")"; }
};

}  // namespace

class ScannerProp : public QObject {
  Q_OBJECT

private slots:
  void scanner() {
    QVERIFY(rc::check("the scanner agrees with the model of its camera", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<Open, Open, Close, Retry, Settings, Answer, Allow, Front, Preview, Preview, Fault, Stop,
                                                         Frames, Frames, Frames, LateFrame>());
    }));
  }
};

HAL_C2_PROP_MAIN(ScannerProp)
#include "tst_ScannerProp.moc"
