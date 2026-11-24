// Settings → Review sandboxes (SandboxSettingsController) against a fake MC
// whose `server.getOpenShellStatus` says OpenShell cannot run on this machine,
// is not installed, is ready, or fails. The user opens and leaves the page and
// refreshes it; the MC's answer changes on its own, and the MC holds its
// answers to give them one by one or all at once, so an answer can land after
// a newer read was asked, or after the page was left. The user runs what the
// status offers (`server.runOpenShellOperation`), another device starts an
// operation of its own, an operation ends well, badly or with this MC's
// reviews in the way, and the user agrees to stop them or not; the MC runs
// one operation at a time and refuses a second, and the user may press an
// action again before the first run's frame lands (before or after its
// reply, or after a frame from before the run), which runs nothing more; and
// the connection may drop between a run's reply and its first frame, the run
// ending before the page follows the shape again; and the MC may restart, while
// a run this page asked for goes (before its first frame or after) or not,
// losing what it ran: it then shows no operation, numbered above every run
// before, or below every one when its clock went back; and another device may
// run an operation to its end while the connection is down, the status it reads
// changing with it. After every step the
// published section is what the model says: the latest read's answer, loading
// while one is out; the operation as the openShell shape last said while the
// page was open; and a question only about an outcome this page asked for.

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
const QString kBusy = QStringLiteral("OpenShell's install is already running on this MC.");
const QString kRestarted = QStringLiteral("The MC lost track of the run; check the status before trying again.");

// How an operation ends.
enum class Outcome { None, Ok, Stops, Fails };
const char* const kOutcomeNames[] = {"none", "ok", "stops-reviews", "fails"};
const char* const kOperations[] = {"install", "check", "uninstall"};

// The openShell shape's state: the operation running or last run.
struct Operation {
  QString name;  // "" before any
  bool running = false;
  Outcome outcome = Outcome::None;
  int run = 0;  // the MC's number for it, larger for each run; the model's are 0
  bool operator==(const Operation&) const = default;
};

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
  Operation mcOperation;  // the MC's
  Operation shown;        // the page's: the MC's while open, as it was when left
  QString askedFor;       // the operation this page asked for, until its outcome
  QString confirm;        // the operation a yes reruns with drain
  QString refusal;

  bool offers(const QString& operation) const {
    if (!landed) return false;
    if (said == Answer::NotInstalled) return operation == QLatin1String("install");
    if (said == Answer::Ready) return operation == QLatin1String("check") || operation == QLatin1String("uninstall");
    return false;
  }

  // The user's, or a yes': the MC refuses while one runs.
  void run(const QString& operation) {
    askedFor = operation;
    refusal.clear();
    confirm.clear();
    if (mcOperation.running) {
      askedFor.clear();
      refusal = kBusy;
      return;
    }
    mcOperation = {operation, true, Outcome::None};
    if (open) shown = mcOperation;
  }

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
  const auto action = [](const char* operation, const char* label) {
    return QJsonObject{{QStringLiteral("operation"), QLatin1String(operation)}, {QStringLiteral("label"), QLatin1String(label)}};
  };
  QJsonArray actions;
  if (answer == Answer::NotInstalled) actions.append(action("install", "Install"));
  if (ready) actions = {action("check", "Check"), action("uninstall", "Uninstall")};
  QJsonArray problems;
  if (answer == Answer::Unsupported) problems.append(problem("intel-mac", "OpenShell supports Apple Silicon Macs only."));
  if (answer == Answer::NotInstalled) problems.append(problem("not-installed", "Run `hal-c2-service openshell install` to install it."));
  return {{QStringLiteral("supported"), answer != Answer::Unsupported},
          {QStringLiteral("ready"), ready},
          {QStringLiteral("mode"), ready ? QJsonValue(QStringLiteral("managed")) : QJsonValue()},
          {QStringLiteral("version"), ready ? QJsonValue(QStringLiteral("0.1.7")) : QJsonValue()},
          {QStringLiteral("pinnedVersion"), QStringLiteral("0.1.7")},
          {QStringLiteral("problems"), problems},
          {QStringLiteral("actions"), actions},
          {QStringLiteral("canManage"), true},
          {QStringLiteral("manageReason"), QJsonValue()}};
}

QJsonObject operationJson(const Operation& operation) {
  QJsonValue result;
  if (operation.outcome == Outcome::Ok) {
    result = QJsonObject{{QStringLiteral("ok"), true}, {QStringLiteral("code"), QJsonValue()}, {QStringLiteral("message"), QStringLiteral("Done.")},
                         {QStringLiteral("sandboxes"), QJsonValue()}};
  } else if (operation.outcome == Outcome::Stops) {
    result = QJsonObject{{QStringLiteral("ok"), false}, {QStringLiteral("code"), QStringLiteral("sandboxes-running")},
                         {QStringLiteral("message"), QStringLiteral("1 of this MC's review sandboxes is on the gateway.")},
                         {QStringLiteral("sandboxes"), 1}};
  } else if (operation.outcome == Outcome::Fails) {
    result = QJsonObject{{QStringLiteral("ok"), false}, {QStringLiteral("code"), QStringLiteral("failed")},
                         {QStringLiteral("message"), QStringLiteral("It failed.")}, {QStringLiteral("sandboxes"), QJsonValue()}};
  }
  return {{QStringLiteral("operation"), operation.name.isEmpty() ? QJsonValue() : QJsonValue(operation.name)},
          {QStringLiteral("run"), operation.run},
          {QStringLiteral("running"), operation.running},
          {QStringLiteral("steps"), QJsonArray()},
          {QStringLiteral("result"), result}};
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
  Operation operation;  // the MC's
  // The MC's number for the latest run, or when it started if it ran none since,
  // and the smallest it has given: an MC whose clock went back starts below it.
  int lastRun = 1'000'000'000;
  int lowest = lastRun;
  QList<QJsonObject> runs;
  // The MC holds its openShell frames from here on (`releaseFrames`).
  bool holdingFrames = false;
  QList<QJsonObject> heldFrames;

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
    mc.onShape(QStringLiteral("openShell"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), operationJson(operation)}});
    });
    mc.onRpc(QStringLiteral("server.runOpenShellOperation"), [this](const FakeMc::Rpc& rpc) {
      runs.append(rpc.payload);
      if (operation.running) return mc.refuse(rpc, kBusy);
      const Operation next = start(rpc.payload.value(QLatin1String("operation")).toString());
      mc.reply(rpc, operationJson(next));
      emitOperation(next);
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

  // A run the MC starts, with the next number.
  Operation start(const QString& name) { return {name, true, Outcome::None, ++lastRun}; }

  // The MC's operation changes, and everyone following the shape hears it.
  void emitOperation(const Operation& next) {
    operation = next;
    for (const int id : mc.subscribers(QStringLiteral("openShell"))) {
      const QJsonObject frame{{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), operationJson(next)}};
      if (holdingFrames) heldFrames.append(frame);
      else mc.send(frame);
    }
  }

  void releaseFrames() {
    holdingFrames = false;
    for (const QJsonObject& frame : std::exchange(heldFrames, {})) mc.send(frame);
  }

  void release() {
    holding = false;
    for (const FakeMc::Rpc& rpc : std::exchange(held, {})) reply(rpc);
  }

  NavigationController* navigation() const { return native.controller<NavigationController>(); }
  QVariantMap section() const { return bridge.state()->value(QStringLiteral("sandboxSettings")).toMap(); }

  // The connection drops; the app connects again and follows the shapes again.
  void reconnect() {
    mc.drop();
    RC_ASSERT(prop::until([this] { return !native.client()->isReady(); }));
    RC_ASSERT(prop::until([this] { return native.client()->isReady() && !mc.subscribers(QStringLiteral("openShell")).isEmpty(); }));
  }

  // Waits for whatever the MC has sent so far to reach the page.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // Off the page with the latest read landed, nothing held, and no operation
  // run or shown.
  Model reset() {
    navigation()->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    release();
    answer = Answer::NotInstalled;
    operation = {QString(), false, Outcome::None, lastRun};
    // Through the page once, so what it shows of an operation is the MC's.
    navigation()->open(NavigationController::Route::settings(QStringLiteral("/settings/sandboxes")));
    RC_ASSERT(prop::until([this] { return section().value(QStringLiteral("operation")).isNull() && !section().value(QStringLiteral("loading")).toBool(); }));
    barrier();
    navigation()->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    runs.clear();
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
  QVariant operation;
  if (!model.shown.name.isEmpty()) {
    operation = QVariantMap{{QStringLiteral("operation"), model.shown.name},
                            {QStringLiteral("running"), model.shown.running},
                            {QStringLiteral("ok"), model.shown.running || model.shown.outcome == Outcome::None
                                                       ? QVariant()
                                                       : QVariant(model.shown.outcome == Outcome::Ok)}};
  }
  return {{QStringLiteral("loading"), model.loading},
          {QStringLiteral("state"), state},
          {QStringLiteral("error"), model.landed && model.said == Answer::Fails ? QVariant(kFailure) : QVariant()},
          {QStringLiteral("problems"), problems},
          {QStringLiteral("busy"), model.shown.running},
          {QStringLiteral("operation"), operation},
          {QStringLiteral("confirm"), !model.confirm.isEmpty()},
          {QStringLiteral("refusal"), model.refusal.isEmpty() ? QVariant() : QVariant(model.refusal)}};
}

QVariantMap shown(const QVariantMap& section) {
  QStringList problems;
  for (const QVariant& problem : section.value(QStringLiteral("problems")).toList()) {
    problems.append(problem.toMap().value(QStringLiteral("code")).toString());
  }
  const QVariant error = section.value(QStringLiteral("error"));
  const QVariant refusal = section.value(QStringLiteral("refusal"));
  QVariant operation;
  if (const QVariant value = section.value(QStringLiteral("operation")); !value.isNull()) {
    const QVariantMap map = value.toMap();
    const QVariant result = map.value(QStringLiteral("result"));
    operation = QVariantMap{{QStringLiteral("operation"), map.value(QStringLiteral("operation")).toString()},
                            {QStringLiteral("running"), map.value(QStringLiteral("running")).toBool()},
                            {QStringLiteral("ok"), result.isNull() ? QVariant() : QVariant(result.toMap().value(QStringLiteral("ok")).toBool())}};
  }
  return {{QStringLiteral("loading"), section.value(QStringLiteral("loading")).toBool()},
          {QStringLiteral("state"), section.value(QStringLiteral("state")).toString()},
          {QStringLiteral("error"), error.isNull() ? QVariant() : QVariant(error.toString())},
          {QStringLiteral("problems"), problems},
          {QStringLiteral("busy"), section.value(QStringLiteral("busy")).toBool()},
          {QStringLiteral("operation"), operation},
          {QStringLiteral("confirm"), !section.value(QStringLiteral("confirm")).isNull()},
          {QStringLiteral("refusal"), refusal.isNull() ? QVariant() : QVariant(refusal.toString())}};
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
    if (open) {
      model.shown = model.mcOperation;
      model.ask();
    } else {
      model.askedFor.clear();
      model.confirm.clear();
      model.refusal.clear();
    }
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

// The user presses one of the page's actions, or dispatches one it does not
// offer: only what the status offers runs, on the page, while none runs.
struct Run : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);

  void apply(Model& model) const override {
    if (model.open && model.offers(operation) && !model.shown.running) model.run(operation);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const bool runs = model.open && model.offers(operation) && !model.shown.running;
    if (!runs) shell.reached.insert(QStringLiteral("an action not offered"));
    const qsizetype before = shell.runs.size();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), operation}});
    check(next, shell);
    // Nothing but the operation goes to the MC.
    RC_ASSERT(shell.runs.size() == before + (runs ? 1 : 0));
    if (runs) RC_ASSERT(shell.runs.last() == (QJsonObject{{QStringLiteral("operation"), operation}}));
  }
  void show(std::ostream& os) const override { os << "Run(" << operation.toStdString() << ")"; }
};

// The user presses an action twice before the first run's frame lands: at
// once, or once its reply has landed. The second press runs nothing; a second
// run would be refused as busy, and the page would forget it had asked.
struct Twice : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);
  bool afterReply = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.open && model.offers(operation) && !model.shown.running) model.run(operation);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const bool runs = model.open && model.offers(operation) && !model.shown.running;
    if (runs) shell.reached.insert(afterReply ? QStringLiteral("pressed again after the reply") : QStringLiteral("pressed twice at once"));
    const qsizetype before = shell.runs.size();
    const QVariantMap payload{{QStringLiteral("operation"), operation}};
    shell.holdingFrames = true;
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), payload);
    // The MC answers in order, so the barrier's reply follows the run's.
    if (afterReply) shell.barrier();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), payload);
    shell.barrier();
    shell.releaseFrames();
    check(next, shell);
    RC_ASSERT(shell.runs.size() == before + (runs ? 1 : 0));
  }
  void show(std::ostream& os) const override { os << "Twice(" << operation.toStdString() << (afterReply ? ", after its reply" : "") << ")"; }
};

// A frame from before the run lands after the press and before the run's own:
// the shape's first frame, or another device's last, that ended any way. The
// user presses again once it has landed. It neither reopens the actions nor
// answers the run, so the second press runs nothing and no question comes of it.
struct Stale : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);
  Operation frame{QLatin1String(kOperations[*rc::gen::inRange(0, 3)]), false, static_cast<Outcome>(*rc::gen::inRange(1, 4))};

  void apply(Model& model) const override {
    if (model.open && model.offers(operation) && !model.shown.running) model.run(operation);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const bool runs = model.open && model.offers(operation) && !model.shown.running;
    const qsizetype before = shell.runs.size();
    const QVariantMap payload{{QStringLiteral("operation"), operation}};
    if (runs) {
      shell.reached.insert(QStringLiteral("a frame from before the run"));
      // Numbered as the MC's operation then; an MC that ran none since it started
      // shows none.
      Operation old = frame;
      if (shell.operation.name.isEmpty()) old = {};
      old.run = shell.lastRun;
      shell.holdingFrames = true;
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), payload);
      shell.barrier();
      for (const int id : shell.mc.subscribers(QStringLiteral("openShell"))) {
        shell.mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), operationJson(old)}});
      }
      shell.barrier();
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), payload);
      shell.barrier();
      shell.releaseFrames();
    } else {
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), payload);
    }
    check(next, shell);
    RC_ASSERT(shell.runs.size() == before + (runs ? 1 : 0));
  }
  void show(std::ostream& os) const override {
    os << "Stale(" << operation.toStdString() << ", after " << frame.name.toStdString() << " " << kOutcomeNames[int(frame.outcome)] << ")";
  }
};

// The user runs an action, its reply lands, and the connection drops before
// its first frame; the run ends before the app follows the shape again. The
// first frame after reconnecting, the run ended, settles it: the actions come
// back, the status is read again, and an outcome that stops reviews asks.
struct Dropped : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);
  Outcome outcome = static_cast<Outcome>(*rc::gen::inRange(1, 4));

  // A read out would be lost with the connection.
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override {
    if (!(model.open && model.offers(operation) && !model.shown.running)) return;
    model.run(operation);
    model.mcOperation.running = false;
    model.mcOperation.outcome = outcome;
    model.shown = model.mcOperation;
    model.askedFor.clear();
    if (outcome == Outcome::Stops) model.confirm = operation;
    model.ask();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const bool runs = model.open && model.offers(operation) && !model.shown.running;
    const qsizetype before = shell.runs.size();
    if (runs) {
      shell.reached.insert(QStringLiteral("dropped between a run's reply and its frame"));
      shell.holdingFrames = true;
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), operation}});
      // The MC answers in order, so the barrier's reply follows the run's.
      shell.barrier();
      shell.heldFrames.clear();
      shell.holdingFrames = false;
      shell.mc.drop();
      shell.operation.running = false;
      shell.operation.outcome = outcome;
      shell.reconnect();
      shell.barrier();
    } else {
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), operation}});
    }
    check(next, shell);
    RC_ASSERT(shell.runs.size() == before + (runs ? 1 : 0));
  }
  void show(std::ostream& os) const override { os << "Dropped(" << operation.toStdString() << ", " << kOutcomeNames[int(outcome)] << ")"; }
};

// The MC restarts and loses what it ran: it shows no operation, numbered
// when it started, above every run before. Before that the user may run an
// action, its reply landing and its first frame too, or not. A run this page
// asked for that had not told how it went settles: the actions come back, the
// status is read again, and the page says the MC restarted. With its clock gone
// back it numbers below every run before, and the page tells the restart by its
// number going below the last frame's.
struct Restarted : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);
  bool press = *rc::gen::arbitrary<bool>();
  bool seen = *rc::gen::arbitrary<bool>();
  bool back = *rc::gen::arbitrary<bool>();

  // A read out would be lost with the connection.
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  bool runs(const Model& model) const { return press && model.open && model.offers(operation) && !model.shown.running; }
  void apply(Model& model) const override {
    if (runs(model)) model.run(operation);
    model.mcOperation = {};
    if (!model.open) return;
    const bool ended = model.shown.running;
    model.shown = model.mcOperation;
    if (!model.askedFor.isEmpty()) {
      model.askedFor.clear();
      model.refusal = kRestarted;
    }
    if (ended) model.ask();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (runs(model)) {
      shell.reached.insert(seen ? QStringLiteral("restarted while a run went") : QStringLiteral("restarted before a run's frame"));
      shell.holdingFrames = true;
      shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), operation}});
      // The MC answers in order, so the barrier's reply follows the run's.
      shell.barrier();
      if (seen) {
        shell.releaseFrames();
        shell.barrier();
      }
    } else if (!model.askedFor.isEmpty()) {
      shell.reached.insert(QStringLiteral("restarted while a run went"));
    }
    shell.heldFrames.clear();
    shell.holdingFrames = false;
    if (back) {
      shell.reached.insert(QStringLiteral("restarted with the clock back"));
      shell.lastRun = shell.lowest -= 1000;
    } else {
      shell.lastRun += 1000;
    }
    shell.operation = {QString(), false, Outcome::None, shell.lastRun};
    if (model.open) {
      shell.reconnect();
    } else {
      shell.mc.drop();
      RC_ASSERT(prop::until([&shell] { return !shell.native.client()->isReady(); }));
      RC_ASSERT(prop::until([&shell] { return shell.native.client()->isReady(); }));
    }
    shell.barrier();
    check(next, shell);
  }
  void show(std::ostream& os) const override {
    os << "Restarted(";
    if (press) os << operation.toStdString() << (seen ? ", its frame seen" : ", before its frame") << (back ? ", " : "");
    os << (back ? "its clock back" : "") << ")";
  }
};

// Another device starts an operation on the MC.
struct Elsewhere : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.mcOperation.running); }
  void apply(Model& model) const override {
    model.mcOperation = {operation, true, Outcome::None};
    if (model.open) model.shown = model.mcOperation;
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.emitOperation(shell.start(operation));
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Elsewhere(" << operation.toStdString() << ")"; }
};

// Another device runs an operation to its end while the connection is down,
// and what the status says changes with it. The first frame after reconnecting
// shows it ended, and the page reads the status again, once.
struct Missed : Command {
  QString operation = QLatin1String(kOperations[*rc::gen::inRange(0, 3)]);
  Outcome outcome = static_cast<Outcome>(*rc::gen::inRange(1, 4));
  Answer answer = static_cast<Answer>(*rc::gen::inRange(0, 4));

  // A read out would be lost with the connection.
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding && !model.mcOperation.running); }
  void apply(Model& model) const override {
    model.mc = answer;
    model.mcOperation = {operation, false, outcome};
    if (!model.open) return;
    model.shown = model.mcOperation;
    model.ask();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.open) shell.reached.insert(QStringLiteral("ended elsewhere while the connection was down"));
    shell.answer = answer;
    shell.operation = {operation, false, outcome, ++shell.lastRun};
    if (model.open) shell.reconnect();
    shell.barrier();
    check(next, shell);
    // Again, as the same run: the status was read for it once.
    if (model.open) {
      shell.emitOperation(shell.operation);
      check(next, shell);
    }
  }
  void show(std::ostream& os) const override {
    os << "Missed(" << operation.toStdString() << " " << kOutcomeNames[int(outcome)] << ", then " << kAnswerNames[int(answer)] << ")";
  }
};

// The MC's operation ends; the page reads the status again if it saw it run,
// and asks about an outcome it asked for that stops reviews.
struct Finish : Command {
  Outcome outcome = static_cast<Outcome>(*rc::gen::inRange(1, 4));

  void checkPreconditions(const Model& model) const override { RC_PRE(model.mcOperation.running); }
  void apply(Model& model) const override {
    model.mcOperation.running = false;
    model.mcOperation.outcome = outcome;
    if (!model.open) return;
    model.shown = model.mcOperation;
    if (!model.askedFor.isEmpty() && model.askedFor == model.mcOperation.name) {
      model.askedFor.clear();
      if (outcome == Outcome::Stops) model.confirm = model.mcOperation.name;
    }
    model.ask();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (!model.open) shell.reached.insert(QStringLiteral("ended while away"));
    if (!next.confirm.isEmpty()) shell.reached.insert(QStringLiteral("asked to stop reviews"));
    Operation ended = shell.operation;
    ended.running = false;
    ended.outcome = outcome;
    shell.emitOperation(ended);
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Finish(" << kOutcomeNames[int(outcome)] << ")"; }
};

// The user agrees to stop the reviews: the operation runs again, drained.
struct Confirm : Command {
  void apply(Model& model) const override {
    if (model.confirm.isEmpty()) return;
    const QString operation = model.confirm;
    model.run(operation);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (!model.confirm.isEmpty() && model.mcOperation.running) shell.reached.insert(QStringLiteral("agreed while another ran"));
    const qsizetype before = shell.runs.size();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.confirm"), {});
    check(next, shell);
    if (!model.confirm.isEmpty()) {
      RC_ASSERT(shell.runs.size() == before + 1);
      RC_ASSERT(shell.runs.last() == (QJsonObject{{QStringLiteral("operation"), model.confirm}, {QStringLiteral("drain"), true}}));
    } else {
      RC_ASSERT(shell.runs.size() == before);
    }
  }
  void show(std::ostream& os) const override { os << "Confirm"; }
};

struct Cancel : Command {
  void apply(Model& model) const override { model.confirm.clear(); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.cancel"), {});
    check(next, shell);
  }
  void show(std::ostream& os) const override { os << "Cancel"; }
};

}  // namespace

class SandboxSettingsProp : public QObject {
  Q_OBJECT

private slots:
  void section() {
    Shell shell;
    QVERIFY(rc::check("the Review sandboxes section is the latest read's answer and the MC's operation, however the page, the reads, the "
                      "operations and the MC interleave",
                      [&shell] {
      const Model initial = shell.reset();
      check(initial, shell);
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Open, Open, Refresh, Refresh, Change, Change, Hold, AnswerOne, AnswerOne, Release,
                                                         Run, Run, Twice, Stale, Dropped, Restarted, Missed, Elsewhere, Finish, Finish, Confirm, Cancel>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("asked to stop reviews")), "asked before stopping reviews");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("agreed while another ran")), "agreed while another device's operation ran");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("ended while away")), "an operation that ended while the page was left");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("stale answer")), "an answer to a read a newer one replaced");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answer after leaving")), "an answer after the page was left");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("refreshed while reading")), "a refresh while a read is out");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("pressed twice at once")), "an action pressed twice before its run's reply");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("pressed again after the reply")), "an action pressed again after its run's reply, before its frame");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("a frame from before the run")), "a frame from before a run, then a second press");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("dropped between a run's reply and its frame")), "the connection dropped between a run's reply and its frame");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("restarted before a run's frame")), "the MC restarted between a run's reply and its frame");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("restarted while a run went")), "the MC restarted while a run this page asked for went");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("restarted with the clock back")), "the MC restarted with its clock gone back");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("ended elsewhere while the connection was down")), "another device's operation ended while the connection was down");
    }));
  }
};

HAL_C2_PROP_MAIN(SandboxSettingsProp)
#include "tst_SandboxSettingsProp.moc"
