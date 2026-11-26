// PullRequestThreadController's dialog, as a state machine over what the user
// does with it: opening it, typing (resolved once the typing pauses) or
// submitting a reference, letting the MC answer, choosing local or worktree,
// and cancelling. Only Settle and Prepared let the MC's replies in, so a reply
// to a reference the field no longer names arrives late and must be dropped:
// the pull request shown is always the one the field names, and what is being
// prepared cannot be left or replaced.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "PullRequestReference.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QRegularExpression>
#include <QTemporaryDir>

#include <memory>

namespace prop = halc2::prop;

namespace {

// "9999" is a pull request the host does not have, and 7 one the MC cannot prepare.
const QStringList kTexts = {QString(), QStringLiteral("42"), QStringLiteral("#42"), QStringLiteral("gh pr checkout 7"), QStringLiteral("tax"), QStringLiteral("9999")};
const QString kMissing = QStringLiteral("GitHub has no pull request #9999.");

int numberOf(const QString& reference) {
  return QRegularExpression(QStringLiteral("(\\d+)$")).match(reference).captured(1).toInt();
}

rc::Gen<QString> oneOf(const QStringList& values) {
  return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end()));
}

struct Model {
  QString step;  // empty while closed
  QString text;
  QString reference;
  QString error;
  QString mode;
  int number = 0;

  // What the field's text names, as the controller takes it.
  void name(const QString& typed) {
    text = typed;
    number = 0;
    const std::optional<QString> named = pullRequestReference::parse(typed);
    if (!named) {
      step = QStringLiteral("ask");
      reference.clear();
      error = typed.trimmed().isEmpty() ? QStringLiteral("Paste a pull request URL, checkout command, or enter 123 / #123.")
                                        : QStringLiteral("Use a pull request URL, checkout command, 123, or #123.");
      return;
    }
    step = QStringLiteral("resolving");
    reference = *named;
    error.clear();
  }
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};

  Shell() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("Thread")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    mc.onRpc(QStringLiteral("git.resolvePullRequest"), [this](const FakeMc::Rpc& rpc) {
      const QString reference = rpc.payload.value(QLatin1String("reference")).toString();
      if (reference == QLatin1String("9999")) return mc.refuse(rpc, kMissing);
      mc.reply(rpc, QJsonObject{{QStringLiteral("pullRequest"), QJsonObject{{QStringLiteral("number"), numberOf(reference)},
                                                                             {QStringLiteral("title"), QStringLiteral("Add tax to the cart")},
                                                                             {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/%1").arg(numberOf(reference))},
                                                                             {QStringLiteral("baseBranch"), QStringLiteral("main")},
                                                                             {QStringLiteral("headBranch"), QStringLiteral("feature/tax")},
                                                                             {QStringLiteral("state"), QStringLiteral("open")}}}});
    });
    mc.onRpc(QStringLiteral("git.preparePullRequestThread"), [this](const FakeMc::Rpc& rpc) {
      if (numberOf(rpc.payload.value(QLatin1String("reference")).toString()) == 7) return mc.refuse(rpc, QString());
      mc.reply(rpc, QJsonObject{{QStringLiteral("branch"), QStringLiteral("feature/tax")}, {QStringLiteral("worktreePath"), QJsonValue()}, {QStringLiteral("isOnPullRequestHead"), true}});
    });
    mc.onRpc(QStringLiteral("orchestration.launchThread"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue()); });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->threadOnline(QStringLiteral("env-a:t1")); })) qFatal("the shell did not start");
    goHome();
  }

  // Back to the thread in the project, as a started thread moves the window away.
  void goHome() { native.controller<NavigationController>()->open(NavigationController::Route::thread(QStringLiteral("env-a:t1"))); }
  QVariant published() const { return bridge.state()->value(QStringLiteral("pullRequestThread")); }
  QString step() const { return published().toMap().value(QStringLiteral("step")).toString(); }
  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge.dispatch(QStringLiteral("pullRequestThread.") + action, payload); }
};

void check(const Model& model, const Shell& shell) {
  const QVariant published = shell.published();
  RC_ASSERT(published.isNull() == model.step.isEmpty());
  if (model.step.isEmpty()) return;
  const QVariantMap flow = published.toMap();
  RC_ASSERT(flow.value(QStringLiteral("step")).toString() == model.step);
  RC_ASSERT(flow.value(QStringLiteral("text")).toString() == model.text);
  RC_ASSERT(flow.value(QStringLiteral("reference")).toString() == model.reference);
  RC_ASSERT(flow.value(QStringLiteral("error")).toString() == model.error);
  RC_ASSERT(flow.value(QStringLiteral("mode")).toString() == (model.step == QLatin1String("starting") ? model.mode : QString()));
  const QVariant pullRequest = flow.value(QStringLiteral("pullRequest"));
  RC_ASSERT(pullRequest.isNull() == (model.number == 0));
  if (model.number != 0) RC_ASSERT(pullRequest.toMap().value(QStringLiteral("number")).toInt() == model.number);
}

using Command = rc::state::Command<Model, Shell>;

bool editable(const Model& model) {
  return !model.step.isEmpty() && model.step != QLatin1String("starting");
}

struct Open : Command {
  void apply(Model& model) const override {
    if (model.step == QLatin1String("starting")) return;
    model = Model{};
    model.step = QStringLiteral("ask");
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.dispatch(QStringLiteral("open"));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Open"; }
};

// Typing: what the text names waits for the typing to pause.
struct Edit : Command {
  QString text = *oneOf(kTexts);
  void apply(Model& model) const override {
    if (!editable(model) || text == model.text) return;
    const std::optional<QString> named = pullRequestReference::parse(text);
    if (named && *named == model.reference && model.step == QLatin1String("choose")) {
      model.text = text;
      return;
    }
    model.name(text);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.dispatch(QStringLiteral("edit"), {{QStringLiteral("reference"), text}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Edit(" << text.toStdString() << ")"; }
};

// Submitting: resolved at once.
struct Resolve : Command {
  QString text = *oneOf(kTexts);
  void apply(Model& model) const override {
    if (editable(model)) model.name(text);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.dispatch(QStringLiteral("resolve"), {{QStringLiteral("reference"), text}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Resolve(" << text.toStdString() << ")"; }
};

// The MC answers what the field names, after any stale answers.
struct Settle : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.step == QLatin1String("resolving")); }
  void apply(Model& model) const override {
    if (model.reference == QLatin1String("9999")) {
      model.step = QStringLiteral("ask");
      model.error = kMissing;
    } else {
      model.step = QStringLiteral("choose");
      model.number = numberOf(model.reference);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(prop::until([&] { return shell.step() != QLatin1String("resolving"); }));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Settle"; }
};

struct Start : Command {
  QString mode = *oneOf({QStringLiteral("local"), QStringLiteral("worktree")});
  void apply(Model& model) const override {
    if (model.step != QLatin1String("choose")) return;
    model.step = QStringLiteral("starting");
    model.mode = mode;
    model.error.clear();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.dispatch(QStringLiteral("start"), {{QStringLiteral("mode"), mode}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Start(" << mode.toStdString() << ")"; }
};

// The checkout is prepared, and the thread started on it, or it fails.
struct Prepared : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.step == QLatin1String("starting")); }
  void apply(Model& model) const override {
    if (model.number == 7) {
      model.step = QStringLiteral("choose");
      model.error = QStringLiteral("Failed to prepare pull request thread.");
    } else {
      model = Model{};
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(prop::until([&] { return shell.step() != QLatin1String("starting"); }));
    check(expected, shell);
    shell.goHome();
  }
  void show(std::ostream& os) const override { os << "Prepared"; }
};

struct Cancel : Command {
  void apply(Model& model) const override {
    if (model.step != QLatin1String("starting")) model = Model{};
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.dispatch(QStringLiteral("cancel"));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Cancel"; }
};

}  // namespace

class PullRequestThreadProp : public QObject {
  Q_OBJECT

private slots:
  void dialog() {
    QVERIFY(rc::check("the pull request shown is the one the field names, and a checkout is not left", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Open, Open, Edit, Edit, Resolve, Settle, Settle, Start, Prepared, Cancel>());
    }));
  }
};

HAL_C2_PROP_MAIN(PullRequestThreadProp)
#include "tst_PullRequestThreadProp.moc"
