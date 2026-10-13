// Settings → Integrations → Slack (SlackSettingsController) against a fake MC
// whose HalC2.Slack takes good tokens, refuses a bad bot token, forgets the
// tokens on disconnect and hands out its app manifest. The user opens and
// leaves the page, connects (with good, refused or blank tokens),
// disconnects and copies the manifest; the MC drops and regains Slack on its
// own, another client connects or disconnects it, and the MC holds its
// answers to give them one by one or all at once, so a reply can land after
// the page was left and come back to, even while another call is out. A
// status the MC pushes is newer than the page's own error and replaces it.
// After every step the published section, the clipboard and the toasts are
// what the model says, and no token is ever published.

#include "Prop.h"

#include <QClipboard>
#include <QJsonArray>
#include <QTemporaryDir>
#include <QTimeZone>

#include <algorithm>
#include <utility>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QString kBot = QStringLiteral("xoxb-prop-bot");
const QString kApp = QStringLiteral("xapp-prop-app");
const QString kRefusedBot = QStringLiteral("xoxb-refused");
const QString kRefusal = QStringLiteral("Slack refused the bot token: invalid_auth");
const QString kBlank = QStringLiteral("Enter both the bot token and the app token.");
const QString kManifest = QStringLiteral("socket_mode_enabled: true\n");
const QString kCopied = QStringLiteral("Slack app manifest copied");
const QDateTime kEpoch(QDate(2026, 10, 13), QTime(9, 0), QTimeZone::UTC);

// HalC2.Slack's status, as the MC holds it.
struct Status {
  QString state = QStringLiteral("off");
  bool tokensSet = false;
  QString error;
  bool operator==(const Status&) const = default;
};

// What the user asked the MC to do.
enum class Op { Good, Refused, Disconnect, Manifest };

// A call the MC holds, and the page visit it was made in.
struct Held {
  Op op;
  int visit;
};

struct Model {
  Status mc;
  bool open = false;
  int visit = 0;  // bumped on each opening and leaving: answers of another visit are dropped
  QString pending;
  QString error;  // the page's own: the last call's refusal, or blank tokens, until the MC pushes a status
  bool holding = false;
  QList<Held> held;
  QString clipboard;
  int copied = 0;

  // The MC does what it was asked; the page hears the answer if still on the
  // visit, then the status a connect or disconnect pushes.
  void perform(const Held& call) {
    switch (call.op) {
      case Op::Good: mc = {QStringLiteral("connected"), true, {}}; break;
      case Op::Refused: mc = {QStringLiteral("failed"), false, kRefusal}; break;
      case Op::Disconnect: mc = {}; break;
      case Op::Manifest: break;
    }
    if (call.visit == visit) {
      pending.clear();
      if (call.op == Op::Refused) error = kRefusal;
      if (call.op == Op::Manifest) {
        clipboard = kManifest;
        ++copied;
      }
    }
    if (call.op != Op::Manifest) pushed();
  }

  // The MC pushed its status: an open page drops its own error for it.
  void pushed() {
    if (open) error.clear();
  }

  void ask(Op op, const QString& name) {
    pending = name;
    if (op != Op::Manifest) error.clear();
    const Held call{op, visit};
    if (holding) held.append(call);
    else perform(call);
  }
};

// The MC's Slack, held answers and all.
struct FakeSlack {
  Status status;
  bool holding = false;
  QList<std::function<void()>> held;
};

QJsonObject statusJson(const Status& status) {
  const bool up = status.state == QLatin1String("connected");
  return {{QStringLiteral("state"), status.state},
          {QStringLiteral("team"), up ? QJsonValue(QStringLiteral("acme")) : QJsonValue()},
          {QStringLiteral("teamId"), up ? QJsonValue(QStringLiteral("T0ACME")) : QJsonValue()},
          {QStringLiteral("bot"), up ? QJsonValue(QStringLiteral("HAL")) : QJsonValue()},
          {QStringLiteral("botUserId"), up ? QJsonValue(QStringLiteral("UHAL")) : QJsonValue()},
          {QStringLiteral("error"), status.error.isEmpty() ? QJsonValue() : QJsonValue(status.error)},
          {QStringLiteral("tokensSet"), status.tokensSet}};
}

// The app on a fake MC, on the General settings page, with a home of its own
// and toasts on a clock that stands still.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  FakeSlack slack;
  QSet<QString> reached;

  Shell() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("slack"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), statusJson(slack.status)}});
    });
    mc.onRpc(QStringLiteral("slack."), [this](const FakeMc::Rpc& rpc) {
      const auto answer = [this, rpc] {
        if (rpc.method == QLatin1String("slack.manifest")) {
          mc.reply(rpc, QJsonObject{{QStringLiteral("manifest"), kManifest}});
          return;
        }
        if (rpc.method == QLatin1String("slack.connect")) {
          const bool refused = rpc.payload.value(QLatin1String("botToken")).toString() == kRefusedBot;
          slack.status = refused ? Status{QStringLiteral("failed"), false, kRefusal} : Status{QStringLiteral("connected"), true, {}};
          if (refused) mc.refuse(rpc, kRefusal);
          else mc.reply(rpc, statusJson(slack.status));
        } else if (rpc.method == QLatin1String("slack.disconnect")) {
          slack.status = {};
          mc.reply(rpc, statusJson(slack.status));
        } else {
          mc.reply(rpc, statusJson(slack.status));
          return;
        }
        broadcast();
      };
      if (slack.holding) slack.held.append(answer);
      else answer();
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized(); })) qFatal("the shell did not start");
    native.controller<ToastController>()->setClock([] { return kEpoch; });
  }

  void broadcast() {
    for (const int id : mc.subscribers(QStringLiteral("slack"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), statusJson(slack.status)}});
    }
  }

  void answerOne() { slack.held.takeFirst()(); }

  void release() {
    slack.holding = false;
    const QList<std::function<void()>> answers = std::exchange(slack.held, {});
    for (const auto& answer : answers) answer();
  }

  NavigationController* navigation() const { return native.controller<NavigationController>(); }
  QVariantMap section() const { return bridge.state()->value(QStringLiteral("slackSettings")).toMap(); }

  int copied() const {
    int count = 0;
    for (const QVariant& item : bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (item.toMap().value(QStringLiteral("title")) == kCopied) ++count;
    }
    return count;
  }

  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge.dispatch(QStringLiteral("slackSettings.") + action, payload); }

  // Waits for whatever the MC has sent so far to reach the page.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // Off the page, Slack forgotten, nothing held, copied or toasted.
  Model reset() {
    navigation()->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    RC_ASSERT(prop::until([this] { return !section().value(QStringLiteral("open")).toBool(); }));
    release();
    barrier();
    slack.status = {};
    auto* toasts = native.controller<ToastController>();
    for (const QVariant& item : bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      toasts->dismiss(item.toMap().value(QStringLiteral("id")).toString());
    }
    QGuiApplication::clipboard()->clear();
    reached.clear();
    return {};
  }
};

// The section as the model says it shows.
QVariantMap expected(const Model& model) {
  if (!model.open) return {{QStringLiteral("open"), false}};
  const bool up = model.mc.state == QLatin1String("connected");
  return {{QStringLiteral("open"), true},
          {QStringLiteral("loaded"), true},
          {QStringLiteral("editable"), true},
          {QStringLiteral("statusNote"), QString()},
          {QStringLiteral("state"), model.mc.state},
          {QStringLiteral("team"), up ? QStringLiteral("acme") : QString()},
          {QStringLiteral("bot"), up ? QStringLiteral("HAL") : QString()},
          {QStringLiteral("error"), model.error.isEmpty() ? model.mc.error : model.error},
          {QStringLiteral("tokensSet"), model.mc.tokensSet},
          {QStringLiteral("pending"), model.pending}};
}

void check(const Model& model, Shell& shell) {
  const QVariantMap want = expected(model);
  // Opening the page loads it over a round trip or two; anything else has
  // reached it once the MC has answered what was sent before.
  RC_ASSERT(prop::until([&] { return shell.section() == want; }));
  shell.barrier();
  RC_ASSERT(shell.section() == want);
  RC_ASSERT(QGuiApplication::clipboard()->text() == model.clipboard);
  RC_ASSERT(shell.copied() == model.copied);
  const QString shown = QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(shell.section())).toJson());
  RC_ASSERT(!shown.contains(kBot));
  RC_ASSERT(!shown.contains(kApp));
  RC_ASSERT(!shown.contains(kRefusedBot));
}

using Command = rc::state::Command<Model, Shell>;

// The user opens Integrations, or leaves for General.
struct Open : Command {
  bool open = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.open == open) return;
    model.open = open;
    ++model.visit;
    model.pending.clear();
    model.error.clear();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.navigation()->open(NavigationController::Route::settings(open ? QStringLiteral("/settings/integrations") : QStringLiteral("/settings/general")));
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Open(" << open << ")"; }
};

// The user connects with good tokens, a bot token Slack refuses, or a blank one.
struct Connect : Command {
  int kind = *rc::gen::inRange(0, 3);

  bool acts(const Model& model) const { return model.open && model.pending.isEmpty(); }
  void apply(Model& model) const override {
    if (!acts(model)) return;
    if (kind == 2) model.error = kBlank;
    else model.ask(kind == 0 ? Op::Good : Op::Refused, QStringLiteral("connect"));
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (acts(model) && kind == 0 && model.mc.tokensSet) shell.reached.insert(QStringLiteral("replaced"));
    shell.dispatch(QStringLiteral("connect"), {{QStringLiteral("botToken"), kind == 0 ? kBot : kind == 1 ? kRefusedBot : QStringLiteral("  ")},
                                               {QStringLiteral("appToken"), kApp}});
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Connect(" << (kind == 0 ? "good" : kind == 1 ? "refused" : "blank") << ")"; }
};

struct Disconnect : Command {
  bool acts(const Model& model) const { return model.open && model.pending.isEmpty(); }
  void apply(Model& model) const override {
    if (acts(model)) model.ask(Op::Disconnect, QStringLiteral("disconnect"));
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.dispatch(QStringLiteral("disconnect"));
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Disconnect"; }
};

struct CopyManifest : Command {
  bool acts(const Model& model) const { return model.open && model.pending.isEmpty(); }
  void apply(Model& model) const override {
    if (acts(model)) model.ask(Op::Manifest, QStringLiteral("manifest"));
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.dispatch(QStringLiteral("copyManifest"));
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "CopyManifest"; }
};

// The MC's Socket Mode connection drops, or comes back, on its own.
struct Drop : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.tokensSet); }
  void apply(Model& model) const override {
    model.mc.state = model.mc.state == QLatin1String("connected") ? QStringLiteral("reconnecting") : QStringLiteral("connected");
    model.pushed();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.slack.status.state = next.mc.state;
    shell.broadcast();
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

// Another client connects Slack with good tokens, or disconnects it.
struct Elsewhere : Command {
  bool connects = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    model.mc = connects ? Status{QStringLiteral("connected"), true, {}} : Status{};
    model.pushed();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (!model.error.isEmpty() && model.open) shell.reached.insert(QStringLiteral("error replaced"));
    shell.slack.status = next.mc;
    shell.broadcast();
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Elsewhere(" << (connects ? "connect" : "disconnect") << ")"; }
};

// The MC holds its Slack answers from here on.
struct Hold : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.slack.holding = true;
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers the oldest call it holds, and holds on.
struct AnswerOne : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.held.isEmpty()); }
  void apply(Model& model) const override { model.perform(model.held.takeFirst()); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.held.first().visit != model.visit) shell.reached.insert(QStringLiteral("late answer"));
    if (model.held.first().visit != model.visit && !model.pending.isEmpty()) shell.reached.insert(QStringLiteral("late answer while busy"));
    shell.answerOne();
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "AnswerOne"; }
};

// The MC answers everything it held, in order, and holds nothing more.
struct Release : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.holding); }
  void apply(Model& model) const override {
    model.holding = false;
    for (const Held& call : std::exchange(model.held, {})) model.perform(call);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.release();
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Release"; }
};

}  // namespace

class SlackSettingsProp : public QObject {
  Q_OBJECT

private slots:
  void section() {
    Shell shell;
    QVERIFY(rc::check("the Slack section is what the model says, however the page, the calls and the MC interleave", [&shell] {
      const Model initial = shell.reset();
      check(initial, shell);
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Open, Open, Open, Connect, Connect, Disconnect, CopyManifest, Drop, Elsewhere, Hold, Hold, AnswerOne, AnswerOne, Release>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("late answer")), "an answer after the page was left");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("late answer while busy")), "a late answer while another call is out");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("replaced")), "tokens replaced");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("error replaced")), "an error replaced by a newer status");
    }));
  }
};

HAL_C2_PROP_MAIN(SlackSettingsProp)
#include "tst_SlackSettingsProp.moc"
