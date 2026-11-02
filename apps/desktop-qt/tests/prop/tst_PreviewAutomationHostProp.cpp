// The desktop as the browser agents drive (PreviewAutomationHost) against a
// fake MC. The MC ends the host's registration (as when it answered late),
// the connection drops and comes back, the window gains and loses focus, and
// agents ask for actions: quick ones, ones the page never finishes, a status
// while another action waits, actions on a tab the user closes meanwhile, and
// one naming no tab beside one naming the tab that is current.
// After every step the host is registered exactly once under the same client
// id, knows the connection the MC gave it last, has told that connection
// whether the window has focus, and every request was answered once, on the
// connection it came on, before its deadline. One page runs one action at a
// time. And the client id is the same for one HAL-C2 home, another for another.

#include "Prop.h"

#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonObject>

#include "FakeMc.h"
#include "McClient.h"
#include "PreviewAutomationHost.h"
#include "PreviewAutomationPage.h"

namespace prop = halc2::prop;

namespace {

const QString kClientId = QStringLiteral("desktop-prop");
const QString kTab = QStringLiteral("tab-1");
const QString kThread = QStringLiteral("thread-1");

// A page whose scripts answer at once, or never while it hangs.
class FakePage : public PreviewAutomationPage {
public:
  bool hanging = false;
  // Scripts it was given while hanging, never answered.
  int held = 0;

  void runJavaScript(const QString& script, World world, ScriptDone done) override {
    if (hanging) {
      ++held;
      return;
    }
    const QString answer = world == PageWorld ? QStringLiteral(R"({"done":true,"value":"42"})")
                                              : QStringLiteral(R"({"ok":true,"value":{}})");
    QTimer::singleShot(0, this, [done, answer] { done(answer); });
    Q_UNUSED(script);
  }
  void grab(ImageDone done) override {
    QImage image(8, 8, QImage::Format_RGB32);
    image.fill(Qt::white);
    QTimer::singleShot(0, this, [done, image] { done(image); });
  }
  QUrl url() const override { return QUrl(QStringLiteral("http://localhost:5173/")); }
  QString title() const override { return QStringLiteral("Page"); }
  bool loading() const override { return false; }
  void load(const QUrl&) override {}
  bool devToolsOpen() const override { return false; }
  bool onScreen() const override { return true; }
  QSize viewport() const override { return {1280, 800}; }
  void setViewport(const QSize&) override {}
  bool click(const QPointF&) override { return false; }
  bool key(int, Qt::KeyboardModifiers, const QString&) override { return false; }
  void setColorScheme(const QString&) override {}
};

struct Model {
  bool focused = false;
  int connections = 0;
};

struct Answer {
  QJsonObject response;
  qint64 elapsedMs = 0;
};

struct Sut {
  FakeMc mc;
  McClient client;
  PreviewAutomationHost host{&client, kClientId};
  std::unique_ptr<FakePage> page = std::make_unique<FakePage>();
  QObject barrier;
  // The connection the MC gave each subscription, newest last.
  QHash<int, QString> connections;
  QString current;
  int nextConnection = 0;
  int nextRequest = 0;
  QHash<QString, QElapsedTimer> sent;
  QHash<QString, QList<Answer>> answers;
  QList<QJsonObject> focusCalls;

  Sut() {
    mc.onShape(QStringLiteral("previewAutomation"), [this](int id, const QJsonObject&) {
      // Answered after the subscription is in place, as the MC's socket does.
      QTimer::singleShot(0, &barrier, [this, id] {
        if (!mc.subscribers(QStringLiteral("previewAutomation")).contains(id)) return;
        current = QStringLiteral("connection-%1").arg(++nextConnection);
        connections.insert(id, current);
        mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("event"),
                  QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")}, {QStringLiteral("connectionId"), current}}}});
      });
    });
    mc.onRpc(QStringLiteral("previewAutomation.respond"), [this](const FakeMc::Rpc& rpc) {
      const QString id = rpc.payload.value(QLatin1String("requestId")).toString();
      answers[id].append({rpc.payload, sent.value(id).elapsed()});
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(QStringLiteral("previewAutomation.focusHost"), [this](const FakeMc::Rpc& rpc) {
      focusCalls.append(rpc.payload);
      mc.reply(rpc, QJsonValue::Null);
    });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    if (!prop::until([this] { return client.isReady(); })) qFatal("the client did not connect");
    host.setMcs({{mc.name, mc.environmentId}});
    host.attach(mc.environmentId, kThread, kTab, page.get());
    if (!registered()) qFatal("the host did not register");
  }

  int live() const {
    const QList<int> ids = mc.subscribers(QStringLiteral("previewAutomation"));
    return ids.isEmpty() ? -1 : ids.last();
  }

  // Registered, and told which connection it has.
  bool registered() {
    return prop::until([this] {
      return mc.subscribers(QStringLiteral("previewAutomation")).size() == 1 && connections.contains(live()) &&
             host.connectionId(mc.name) == connections.value(live());
    });
  }

  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
    return prop::until([&] { return *answered; });
  }

  QString ask(const QString& operation, int timeoutMs, const QString& tab = kTab) {
    const QString id = QStringLiteral("preview-%1").arg(++nextRequest);
    sent[id].start();
    QJsonObject request{{QStringLiteral("requestId"), id},
                        {QStringLiteral("threadId"), kThread},
                        {QStringLiteral("tabId"), tab},
                        {QStringLiteral("tabIdExplicit"), !tab.isEmpty()},
                        {QStringLiteral("operation"), operation},
                        {QStringLiteral("input"), operation == QLatin1String("evaluate")
                                                      ? QJsonObject{{QStringLiteral("expression"), QStringLiteral("6 * 7")}}
                                                      : QJsonObject{}},
                        {QStringLiteral("timeoutMs"), timeoutMs}};
    mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
             {QStringLiteral("id"), live()},
             {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                                                   {QStringLiteral("connectionId"), current},
                                                   {QStringLiteral("request"), request}}}});
    return id;
  }

  bool answered(const QString& id) {
    return prop::until([&] { return !answers.value(id).isEmpty(); }, 5000);
  }
};

// An answer that came once, on the connection the request came on, in time.
void checkAnswer(Sut& sut, const QString& id, const QString& connection, int timeoutMs, bool ok,
                 const QString& tag = {}) {
  RC_ASSERT(sut.answered(id));
  RC_ASSERT(sut.sync());
  const QList<Answer> answers = sut.answers.value(id);
  RC_ASSERT(answers.size() == 1);
  const QJsonObject response = answers.first().response;
  RC_ASSERT(response.value(QLatin1String("clientId")).toString() == kClientId);
  RC_ASSERT(response.value(QLatin1String("connectionId")).toString() == connection);
  RC_ASSERT(response.value(QLatin1String("ok")).toBool() == ok);
  RC_ASSERT(answers.first().elapsedMs < timeoutMs);
  if (!tag.isEmpty()) {
    RC_ASSERT(response.value(QLatin1String("error")).toObject().value(QLatin1String("_tag")).toString() == tag);
  }
}

void check(const Model& model, Sut& sut) {
  RC_ASSERT(sut.registered());
  RC_ASSERT(sut.sync());
  const QJsonObject shape = sut.mc.shapeOf(sut.live());
  const QJsonObject host = shape.value(QLatin1String("host")).toObject();
  RC_ASSERT(host.value(QLatin1String("clientId")).toString() == kClientId);
  RC_ASSERT(host.value(QLatin1String("environmentId")).toString() == sut.mc.environmentId);
  RC_ASSERT(host.value(QLatin1String("supportedOperations")).toArray().contains(QStringLiteral("snapshot")));
  // The connection hears the window's focus as it is now.
  RC_ASSERT(prop::until([&] {
    for (qsizetype i = sut.focusCalls.size() - 1; i >= 0; --i) {
      const QJsonObject call = sut.focusCalls.at(i);
      if (call.value(QLatin1String("connectionId")).toString() != sut.current) continue;
      return call.value(QLatin1String("focused")).toBool() == model.focused;
    }
    return false;
  }));
  RC_ASSERT(sut.host.focused() == model.focused);
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(expected, sut);
  }
};

struct Focus : Step<Focus> {
  bool focused = *rc::gen::arbitrary<bool>();
  explicit Focus(const Model&) {}
  void apply(Model& model) const override { model.focused = focused; }
  void act(const Model&, Sut& sut) const { sut.host.setFocused(focused); }
  void show(std::ostream& os) const override { os << (focused ? "focus" : "blur"); }
};

// The MC lets the host go: it registers again, and gets a new connection.
struct End : Step<End> {
  explicit End(const Model&) {}
  void apply(Model& model) const override { ++model.connections; }
  void act(const Model&, Sut& sut) const {
    const int id = sut.live();
    sut.mc.forget(id);
    sut.mc.send({{QStringLiteral("t"), QStringLiteral("end")}, {QStringLiteral("id"), id}});
    RC_ASSERT(prop::until([&] { return sut.live() != -1 && sut.live() != id && sut.connections.contains(sut.live()); }));
  }
  void show(std::ostream& os) const override { os << "the MC ends the registration"; }
};

// The socket drops and the client connects again.
struct Drop : Step<Drop> {
  explicit Drop(const Model&) {}
  void apply(Model& model) const override { ++model.connections; }
  void act(const Model&, Sut& sut) const {
    const QString before = sut.current;
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return sut.client.isReady() && sut.current != before && sut.connections.contains(sut.live()); }));
  }
  void show(std::ostream& os) const override { os << "the connection drops"; }
};

struct Quick : Step<Quick> {
  QString operation = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("status"), QStringLiteral("evaluate"),
                                                                QStringLiteral("snapshot"), QStringLiteral("scroll")});
  explicit Quick(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    const QString id = sut.ask(operation, 15000);
    checkAnswer(sut, id, connection, 15000, true);
  }
  void show(std::ostream& os) const override { os << "the agent asks for " << operation.toStdString(); }
};

// The page never answers: the host gives up before the MC would.
struct Hang : Step<Hang> {
  int timeoutMs = *rc::gen::inRange(350, 600);
  explicit Hang(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    sut.page->hanging = true;
    const QString slow = sut.ask(QStringLiteral("evaluate"), timeoutMs);
    // A status does not wait behind it.
    const QString status = sut.ask(QStringLiteral("status"), 500);
    checkAnswer(sut, status, connection, 500, true);
    RC_ASSERT(sut.answers.value(slow).isEmpty());
    checkAnswer(sut, slow, connection, timeoutMs, false, QStringLiteral("PreviewAutomationTimeoutError"));
    sut.page->hanging = false;
  }
  void show(std::ostream& os) const override { os << "the page hangs past " << timeoutMs << "ms"; }
};

// Two actions on one tab run one after the other, both in time.
struct Queue : Step<Queue> {
  explicit Queue(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    const QString first = sut.ask(QStringLiteral("evaluate"), 15000);
    const QString second = sut.ask(QStringLiteral("scroll"), 15000);
    checkAnswer(sut, first, connection, 15000, true);
    checkAnswer(sut, second, connection, 15000, true);
  }
  void show(std::ostream& os) const override { os << "two actions on one tab"; }
};

// The user closes the tab while the agent's action waits on it.
struct Close : Step<Close> {
  explicit Close(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    sut.page->hanging = true;
    const QString id = sut.ask(QStringLiteral("evaluate"), 15000);
    const int held = sut.page->held;
    RC_ASSERT(prop::until([&] { return sut.page->held > held; }));
    sut.host.detach(sut.page.get());
    checkAnswer(sut, id, connection, 15000, false, QStringLiteral("PreviewAutomationTabUnavailableError"));
    sut.page->hanging = false;
    sut.host.attach(sut.mc.environmentId, kThread, kTab, sut.page.get());
  }
  void show(std::ostream& os) const override { os << "the user closes the tab mid-action"; }
};

// An action naming no tab (on the current one, kTab) and one naming kTab, in
// either order: the later waits for the earlier, which the page never finishes.
struct Current : Step<Current> {
  bool namedFirst = *rc::gen::arbitrary<bool>();
  int timeoutMs = *rc::gen::inRange(350, 600);
  explicit Current(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    sut.page->hanging = true;
    const int held = sut.page->held;
    const QString first = sut.ask(QStringLiteral("evaluate"), timeoutMs, namedFirst ? kTab : QString());
    const QString second = sut.ask(QStringLiteral("evaluate"), 15000, namedFirst ? QString() : kTab);
    RC_ASSERT(prop::until([&] { return sut.page->held > held; }));
    RC_ASSERT(sut.sync());
    // Only the first is on the page.
    RC_ASSERT(sut.page->held == held + 1);
    sut.page->hanging = false;
    checkAnswer(sut, first, connection, timeoutMs, false, QStringLiteral("PreviewAutomationTimeoutError"));
    checkAnswer(sut, second, connection, 15000, true);
  }
  void show(std::ostream& os) const override {
    os << (namedFirst ? "an action on the tab, then one naming none" : "an action naming no tab, then one on it") << " (" << timeoutMs << "ms)";
  }
};

// A tab with no page: the browser is asked to show it, and the host waits.
struct Missing : Step<Missing> {
  explicit Missing(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    const QString connection = sut.current;
    const QString id = sut.ask(QStringLiteral("evaluate"), 400, QStringLiteral("tab-gone"));
    checkAnswer(sut, id, connection, 400, false, QStringLiteral("PreviewAutomationWebviewRegistrationTimeoutError"));
  }
  void show(std::ostream& os) const override { os << "an action on a tab with no page"; }
};

class tst_PreviewAutomationHostProp : public QObject {
  Q_OBJECT

private slots:
  void host() {
    QVERIFY(rc::check("the host stays registered once, reports focus, and answers every request in time", [] {
      Sut sut;
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<Focus, End, Drop, Quick, Quick, Hang, Queue, Close, Missing, Current>());
    }));
  }

  void clientId() {
    QVERIFY(rc::check("one HAL-C2 home is one client id, every run; two are two", [] {
      const QString name = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("hal-c2"), QStringLiteral("hal-c2-dev"), QStringLiteral("home")});
      const QString other = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("hal-c2"), QStringLiteral("hal-c2-dev"), QStringLiteral("home")});
      const QString home = QStringLiteral("/home/user/.local/state/") + name;
      const QString id = PreviewAutomationHost::machineClientId(home);
      RC_ASSERT(id.startsWith(QStringLiteral("desktop-")));
      RC_ASSERT(PreviewAutomationHost::machineClientId(home) == id);
      RC_ASSERT(PreviewAutomationHost::machineClientId(home + QStringLiteral("/")) == id);
      RC_ASSERT((PreviewAutomationHost::machineClientId(QStringLiteral("/home/user/.local/state/") + other) == id) == (other == name));
    }));
  }
};

}  // namespace

HAL_C2_PROP_MAIN(tst_PreviewAutomationHostProp)

#include "tst_PreviewAutomationHostProp.moc"
