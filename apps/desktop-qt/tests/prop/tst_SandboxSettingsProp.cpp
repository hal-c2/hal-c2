// Settings → Review sandboxes (SandboxSettingsController) against a fake MC
// whose `server.getOpenShellStatus` says OpenShell cannot run on this machine,
// is not installed, is ready, or fails. The user opens and leaves the page and
// refreshes it; the MC's answer changes on its own, and the MC holds its
// answers to give them one by one or all at once, so an answer can land after
// a newer read was asked, or after the page was left. After every step the
// published section is what the model says: the latest read's answer, loading
// while one is out.

#include "Prop.h"

#include <QJsonArray>
#include <QTemporaryDir>

#include <utility>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

const QString kFailure = QStringLiteral("OpenShell's status did not answer within 20 seconds.");

// What the MC's status says when it answers.
enum class Answer { Unsupported, NotInstalled, Ready, Fails };
const char* const kAnswerNames[] = {"unsupported", "not-installed", "ready", "fails"};

struct Model {
  bool open = false;
  Answer mc = Answer::NotInstalled;
  bool holding = false;
  QList<int> held;  // the reads the MC holds, oldest first
  int asked = 0;  // the latest read
  bool loading = false;
  bool landed = false;
  Answer said = Answer::NotInstalled;  // what the latest read's answer said, once landed

  void ask() {
    loading = true;
    ++asked;
    if (holding) held.append(asked);
    else answer(asked);
  }

  // Only the latest read lands.
  void answer(int read) {
    if (read != asked) return;
    loading = false;
    landed = true;
    said = mc;
  }
};

QJsonObject statusJson(Answer answer) {
  const auto problem = [](const char* code, const char* message) {
    return QJsonObject{{QStringLiteral("code"), QLatin1String(code)}, {QStringLiteral("message"), QLatin1String(message)}};
  };
  const bool ready = answer == Answer::Ready;
  QJsonArray problems;
  if (answer == Answer::Unsupported) problems.append(problem("intel-mac", "OpenShell supports Apple Silicon Macs only."));
  if (answer == Answer::NotInstalled) problems.append(problem("not-installed", "Run `hal-c2-service openshell install` to install it."));
  return {{QStringLiteral("supported"), answer != Answer::Unsupported},
          {QStringLiteral("ready"), ready},
          {QStringLiteral("mode"), ready ? QJsonValue(QStringLiteral("managed")) : QJsonValue()},
          {QStringLiteral("version"), ready ? QJsonValue(QStringLiteral("0.1.7")) : QJsonValue()},
          {QStringLiteral("pinnedVersion"), QStringLiteral("0.1.7")},
          {QStringLiteral("problems"), problems}};
}

// The app on a fake MC, on the General settings page, with a home of its own.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  Answer answer = Answer::NotInstalled;
  bool holding = false;
  QList<FakeMc::Rpc> held;
  QSet<QString> reached;

  Shell() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onRpc(QStringLiteral("server.getOpenShellStatus"), [this](const FakeMc::Rpc& rpc) {
      if (holding) held.append(rpc);
      else reply(rpc);
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized(); })) qFatal("the shell did not start");
  }

  // The MC answers with what its status says now.
  void reply(const FakeMc::Rpc& rpc) {
    if (answer == Answer::Fails) mc.refuse(rpc, kFailure, {{QStringLiteral("_tag"), QStringLiteral("ServerOpenShellStatusError")}});
    else mc.reply(rpc, statusJson(answer));
  }

  void release() {
    holding = false;
    for (const FakeMc::Rpc& rpc : std::exchange(held, {})) reply(rpc);
  }

  NavigationController* navigation() const { return native.controller<NavigationController>(); }
  QVariantMap section() const { return bridge.state()->value(QStringLiteral("sandboxSettings")).toMap(); }

  // Waits for whatever the MC has sent so far to reach the page.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // Off the page with the latest read landed and nothing held.
  Model reset() {
    navigation()->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    release();
    answer = Answer::NotInstalled;
    // A read out before the reset lands as the model's own.
    bridge.dispatch(QStringLiteral("sandboxSettings.refresh"), {});
    RC_ASSERT(prop::until([this] { return !section().value(QStringLiteral("loading")).toBool(); }));
    barrier();
    reached.clear();
    Model model;
    model.landed = true;
    return model;
  }
};

// What the section shows, as the model says.
QVariantMap expected(const Model& model) {
  QString state = QStringLiteral("loading");
  QStringList problems;
  if (model.landed) {
    switch (model.said) {
      case Answer::Unsupported: state = QStringLiteral("unsupported"); problems = {QStringLiteral("intel-mac")}; break;
      case Answer::NotInstalled: state = QStringLiteral("attention"); problems = {QStringLiteral("not-installed")}; break;
      case Answer::Ready: state = QStringLiteral("ready"); break;
      case Answer::Fails: state = QStringLiteral("error"); break;
    }
  }
  return {{QStringLiteral("loading"), model.loading},
          {QStringLiteral("state"), state},
          {QStringLiteral("error"), model.landed && model.said == Answer::Fails ? QVariant(kFailure) : QVariant()},
          {QStringLiteral("problems"), problems}};
}

QVariantMap shown(const QVariantMap& section) {
  QStringList problems;
  for (const QVariant& problem : section.value(QStringLiteral("problems")).toList()) {
    problems.append(problem.toMap().value(QStringLiteral("code")).toString());
  }
  const QVariant error = section.value(QStringLiteral("error"));
  return {{QStringLiteral("loading"), section.value(QStringLiteral("loading")).toBool()},
          {QStringLiteral("state"), section.value(QStringLiteral("state")).toString()},
          {QStringLiteral("error"), error.isNull() ? QVariant() : QVariant(error.toString())},
          {QStringLiteral("problems"), problems}};
}

void check(const Model& model, Shell& shell) {
  const QVariantMap want = expected(model);
  RC_ASSERT(prop::until([&] { return shown(shell.section()) == want; }));
  shell.barrier();
  RC_ASSERT(shown(shell.section()) == want);
}

using Command = rc::state::Command<Model, Shell>;

// The user opens Review sandboxes, or leaves for General.
struct Open : Command {
  bool open = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.open == open) return;
    model.open = open;
    if (open) model.ask();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.navigation()->open(NavigationController::Route::settings(open ? QStringLiteral("/settings/sandboxes") : QStringLiteral("/settings/general")));
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Open(" << open << ")"; }
};

struct Refresh : Command {
  void apply(Model& model) const override { model.ask(); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.loading) shell.reached.insert(QStringLiteral("refreshed while reading"));
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.refresh"), {});
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Refresh"; }
};

// What the MC's status would say changes: the user installs OpenShell, the
// gateway stops answering, and so on.
struct Change : Command {
  Answer answer = static_cast<Answer>(*rc::gen::inRange(0, 4));

  void apply(Model& model) const override { model.mc = answer; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.answer = answer;
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Change(" << kAnswerNames[int(answer)] << ")"; }
};

// The MC holds its answers from here on.
struct Hold : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.holding = true;
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers the oldest read it holds, and holds on.
struct AnswerOne : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.held.isEmpty()); }
  void apply(Model& model) const override { model.answer(model.held.takeFirst()); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.held.first() != model.asked) shell.reached.insert(QStringLiteral("stale answer"));
    if (!model.open) shell.reached.insert(QStringLiteral("answer after leaving"));
    shell.reply(shell.held.takeFirst());
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "AnswerOne"; }
};

// The MC answers everything it held, in order, and holds nothing more.
struct Release : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.holding); }
  void apply(Model& model) const override {
    model.holding = false;
    for (const int read : std::exchange(model.held, {})) model.answer(read);
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

class SandboxSettingsProp : public QObject {
  Q_OBJECT

private slots:
  void section() {
    Shell shell;
    QVERIFY(rc::check("the Review sandboxes section is the latest read's answer, however the page, the reads and the MC interleave", [&shell] {
      const Model initial = shell.reset();
      check(initial, shell);
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Open, Open, Refresh, Refresh, Change, Change, Hold, AnswerOne, AnswerOne, Release>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("stale answer")), "an answer to a read a newer one replaced");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answer after leaving")), "an answer after the page was left");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("refreshed while reading")), "a refresh while a read is out");
    }));
  }
};

HAL_C2_PROP_MAIN(SandboxSettingsProp)
#include "tst_SandboxSettingsProp.moc"
