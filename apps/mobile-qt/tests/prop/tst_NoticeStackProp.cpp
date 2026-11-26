// NoticeStackController as a state machine over which of the open thread's
// notices its own controllers are showing (their published states), the
// stack's expand and collapse, and changing threads. One notice is in front
// at a time, most pressing first: the thread's error, a usage limit, what
// its provider says, the answer to "/usage-limits", background work, then a
// settled thread. Asking for the others only holds while there are others;
// going to another thread, whose controllers show nothing, collapses the
// stack and empties it.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QJsonArray>
#include <QTemporaryDir>

namespace prop = halc2::prop;

namespace {

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

struct Model {
  QString open;  // "", "t1" or "t2"
  bool error = false;
  bool limit = false;
  bool provider = false;
  bool usageLimits = false;
  int notice = 0;  // ThreadNoticeController's: 0 none, 1 background, 2 settled
  bool expanded = false;
};

QStringList orderOf(const Model& model) {
  QStringList order;
  if (model.error) order.append(QStringLiteral("error"));
  if (model.limit) order.append(QStringLiteral("limit"));
  if (model.provider) order.append(QStringLiteral("provider"));
  if (model.usageLimits) order.append(QStringLiteral("usageLimits"));
  if (model.notice == 1) order.append(QStringLiteral("activity"));
  if (model.notice == 2) order.append(QStringLiteral("settled"));
  return order;
}

void settle(Model& model) {
  if (orderOf(model).size() < 2) model.expanded = false;
}

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
    for (const QString& thread : {QStringLiteral("t1"), QStringLiteral("t2")}) {
      mc.threads.insert(thread, QJsonObject{{QStringLiteral("id"), thread},
                                            {QStringLiteral("projectId"), QStringLiteral("p1")},
                                            {QStringLiteral("title"), QStringLiteral("Thread ") + thread},
                                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    }
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->threadOnline(keyOf(QStringLiteral("t1"))); })) {
      qFatal("the shell did not start");
    }
    native.controller<NavigationController>()->open(NavigationController::Route::settings());
    if (!prop::until([this] { return bridge.state()->value(QStringLiteral("noticeStack")).toMap().contains(QStringLiteral("front")); })) {
      qFatal("the stack did not publish");
    }
  }

  // What one of the notices' controllers shows, as it publishes it.
  void show(const QString& key, bool on, const QVariantMap& value = {{QStringLiteral("title"), QStringLiteral("Shown")}}) {
    bridge.publish(key, on ? QVariant(value) : QVariant::fromValue(nullptr));
  }

  QVariant stack() const { return bridge.state()->value(QStringLiteral("noticeStack")); }
};

void check(const Model& model, Shell& shell) {
  const QStringList order = orderOf(model);
  const QVariant wanted(QVariantMap{{QStringLiteral("front"), order.isEmpty() ? QString() : order.first()},
                                    {QStringLiteral("behind"), int(order.isEmpty() ? 0 : order.size() - 1)},
                                    {QStringLiteral("expanded"), model.expanded},
                                    {QStringLiteral("order"), order}});
  const bool held = prop::until([&] { return shell.stack() == wanted; });
  if (!held) {
    RC_LOG() << "wanted " << prop::debug(wanted) << "; shown " << prop::debug(shell.stack()) << "\n";
  }
  RC_ASSERT(held);
}

using Command = rc::state::Command<Model, Shell>;

// One notice's controller starts or stops showing it.
struct Show : Command {
  int which = *rc::gen::inRange(0, 5);
  bool on = *rc::gen::arbitrary<bool>();
  int notice = *rc::gen::inRange(0, 3);
  void apply(Model& model) const override {
    switch (which) {
      case 0: model.error = on; break;
      case 1: model.limit = on; break;
      case 2: model.provider = on; break;
      case 3: model.usageLimits = on; break;
      default: model.notice = on ? notice : 0; break;
    }
    settle(model);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    switch (which) {
      case 0: shell.show(QStringLiteral("threadError"), on, {{QStringLiteral("message"), QStringLiteral("Rate limited")}}); break;
      case 1: shell.show(QStringLiteral("limitRecovery"), on); break;
      case 2: shell.show(QStringLiteral("providerNotice"), on); break;
      case 3:
        shell.bridge.publish(QStringLiteral("composer"),
                             QVariantMap{{QStringLiteral("usageLimits"),
                                          on ? QVariant(QVariantMap{{QStringLiteral("accounts"), QVariantList()}}) : QVariant::fromValue(nullptr)}});
        break;
      default:
        shell.show(QStringLiteral("threadNotice"), on && notice > 0,
                   {{QStringLiteral("kind"), notice == 1 ? QStringLiteral("background") : QStringLiteral("settled")}});
        break;
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Show(" << which << ", " << (on ? "on" : "off") << ", notice " << notice << ")"; }
};

// The user asks for the other notices.
struct Expand : Command {
  void apply(Model& model) const override { model.expanded = orderOf(model).size() > 1; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("noticeStack.expand"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Expand"; }
};

// Escape: only the front one again.
struct Collapse : Command {
  void apply(Model& model) const override { model.expanded = false; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("noticeStack.collapse"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Collapse"; }
};

// Another thread (or settings): its controllers show nothing, and the stack
// starts collapsed. Opening what is already open changes nothing.
struct Open : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>{QString(), QStringLiteral("t1"), QStringLiteral("t2")});
  void apply(Model& model) const override {
    if (thread == model.open) return;
    model.open = thread;
    model.error = model.limit = model.provider = model.usageLimits = false;
    model.notice = 0;
    model.expanded = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (thread != model.open) {
      shell.native.controller<NavigationController>()->open(thread.isEmpty() ? NavigationController::Route::settings()
                                                                             : NavigationController::Route::thread(keyOf(thread)));
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Open(" << (thread.isEmpty() ? "settings" : thread.toStdString()) << ")"; }
};

}  // namespace

class NoticeStackProp : public QObject {
  Q_OBJECT

private slots:
  void noticeStack() {
    QVERIFY(rc::check("notices above the composer show one at a time, most pressing first", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Show, Show, Show, Expand, Collapse, Open>());
    }));
  }
};

HAL_C2_PROP_MAIN(NoticeStackProp)
#include "tst_NoticeStackProp.moc"
