// Alerts (AlertController) as threads change under them, against a fake MC:
// runs started, completed, failed or stopped at the usage limit, approval
// and input asked for and answered, threads archived and unarchived, and a
// thread arriving mid-case; the window focused and not, the device's
// notification mode and in-app alerts changed, the system's permission given
// and taken back, threads muted (directly or from the palette for the thread
// shown), threads shown, and the in-app alert's "Open thread" and a system
// notification clicked. After every step the sounds played, the system
// notifications on screen, the badge, the toasts, the route, the muted
// threads (and what this device keeps of them), the mode in effect and the
// palette's mute command are what the model says.
//
// The model follows threads only while some alert is on, and starts afresh
// when one turns on: what changed while every alert was off stays quiet.

#include "Prop.h"

#include <QJsonArray>
#include <QTemporaryDir>
#include <QTimeZone>

#include <vector>

#include "AlertController.h"
#include "FakeMc.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

const QStringList kThreadIds{QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3")};
const QStringList kModes{QStringLiteral("off"), QStringLiteral("notifications"), QStringLiteral("sound"),
                         QStringLiteral("notifications-and-sound")};
const QString kOpenThread = QStringLiteral("Open thread");
const QDateTime kEpoch(QDate(2026, 9, 23), QTime(9, 0), QTimeZone::UTC);

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }
QString iso(int minute) { return kEpoch.addSecs(qint64(minute) * 60).toString(Qt::ISODate); }

// A thread's row, as the MC sends it.
struct Thread {
  QString title;
  int runs = 0;
  QString status;   // the latest run's: empty before any, running, completed, failed
  QString pending;  // what it waits on: approval, input, or nothing
  QString errorClass;
  std::optional<int> completedAt;  // minutes after kEpoch
  bool archived = false;
  int updatedAt = 0;

  QString runId() const { return runs > 0 ? QStringLiteral("run-%1").arg(runs) : QString(); }

  // What the sidebar calls it (sidebar::status, then evaluate()'s failed).
  QString shown() const {
    if (pending == QLatin1String("approval")) return QStringLiteral("approval");
    if (pending == QLatin1String("input")) return QStringLiteral("input");
    if (status == QLatin1String("running")) return QStringLiteral("working");
    if (status == QLatin1String("failed")) {
      return errorClass == QLatin1String("usage_limit") ? QStringLiteral("limited") : QStringLiteral("failed");
    }
    return QStringLiteral("ready");
  }

  QJsonObject row(const QString& id) const {
    QJsonObject row{{QStringLiteral("id"), id},
                    {QStringLiteral("projectId"), QStringLiteral("p1")},
                    {QStringLiteral("title"), title},
                    {QStringLiteral("createdAt"), iso(0)},
                    {QStringLiteral("updatedAt"), iso(updatedAt)}};
    if (runs > 0) {
      row.insert(QStringLiteral("latestRunId"), runId());
      row.insert(QStringLiteral("latestRunStartedAt"), iso(updatedAt));
      row.insert(QStringLiteral("status"), status);
    }
    if (completedAt) row.insert(QStringLiteral("latestRunCompletedAt"), iso(*completedAt));
    if (!errorClass.isEmpty()) row.insert(QStringLiteral("lastErrorClass"), errorClass);
    if (!pending.isEmpty()) {
      const QString kind = pending == QLatin1String("input") ? QStringLiteral("user_input") : QStringLiteral("command_approval");
      row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), kind}});
    }
    if (archived) row.insert(QStringLiteral("archivedAt"), iso(updatedAt));
    return row;
  }
};

struct Seen {
  QString attention;
  std::optional<int> completion;
};

struct Toast {
  QString type;
  QString title;
  QString description;
  QString key;  // the thread "Open thread" shows; empty for any other toast
  bool operator==(const Toast& other) const {
    return type == other.type && title == other.title && description == other.description;
  }
};

struct Model {
  QMap<QString, Thread> threads;
  // The thread that may arrive in this case.
  QString late;
  // What the alerts follow, by thread; empty while every alert is off.
  QMap<QString, Seen> seen;
  QString mode = QStringLiteral("off");
  bool inApp = false;
  bool focused = true;
  bool allowed = true;
  QSet<QString> muted;
  QString route;
  int minute = 0;

  // What the user was shown and heard.
  QStringList sounds;
  QMap<QString, QStringList> notifications;
  int badge = -1;
  int unseen = 0;
  QList<Toast> toasts;

  bool active() const { return mode != QLatin1String("off") || inApp; }

  // No toast is dropped for lack of room; the brick stacks them.
  void toast(const Toast& next) { toasts.prepend(next); }

  void alert(const QString& id, const QString& kind, const QString& status) {
    const QString key = keyOf(id);
    const QString title = kind == QLatin1String("completion") ? QStringLiteral("Thread completed")
                          : status == QLatin1String("approval") ? QStringLiteral("Approval needed")
                          : status == QLatin1String("limited")  ? QStringLiteral("Usage limit reached")
                          : status == QLatin1String("failed")   ? QStringLiteral("Thread failed")
                                                                : QStringLiteral("Input needed");
    if (AlertController::hasSound(mode)) sounds.append(kind);
    if (kind == QLatin1String("completion") && !focused) badge = ++unseen;
    if (inApp && focused && key != route) {
      const QString type = kind == QLatin1String("completion") ? QStringLiteral("success")
                           : status == QLatin1String("failed") ? QStringLiteral("error")
                                                               : QStringLiteral("warning");
      toast({type, title, threads.value(id).title, key});
      return;
    }
    if (!AlertController::hasSystemNotifications(mode) || focused || !allowed) return;
    notifications.insert(key, {title, threads.value(id).title});
  }

  // What the threads are now against what was followed: a change of a
  // thread followed before, neither archived nor muted, alerts.
  void evaluate() {
    if (!active()) {
      seen.clear();
      return;
    }
    QMap<QString, Seen> next;
    for (auto it = threads.cbegin(); it != threads.cend(); ++it) {
      const Thread& thread = it.value();
      const QString status = thread.shown();
      const auto prior = seen.constFind(it.key());
      Seen now;
      if (QStringList{QStringLiteral("input"), QStringLiteral("approval"), QStringLiteral("failed"), QStringLiteral("limited")}.contains(status)) {
        now.attention = thread.runId() + u':' + status;
      }
      if (status == QLatin1String("ready") && thread.status == QLatin1String("completed") && thread.completedAt) {
        now.completion = thread.completedAt;
      } else if (prior != seen.constEnd()) {
        now.completion = prior->completion;
      }
      next.insert(it.key(), now);
      if (prior == seen.constEnd() || thread.archived || muted.contains(keyOf(it.key()))) continue;
      if (!now.attention.isEmpty() && now.attention != prior->attention) {
        alert(it.key(), QStringLiteral("input"), status);
      } else if (now.completion && (!prior->completion || *now.completion > *prior->completion)) {
        alert(it.key(), QStringLiteral("completion"), status);
      }
    }
    seen = std::move(next);
  }

  // An alert turned on starts from the threads as they are; all off forgets them.
  void settle() {
    if (!active() || seen.isEmpty()) evaluate();
  }

  void change(const QString& id, const std::function<void(Thread&)>& edit) {
    Thread& thread = threads[id];
    thread.updatedAt = ++minute;
    edit(thread);
    evaluate();
  }

  void focus(bool next) {
    if (focused == next) return;
    focused = next;
    if (!focused) return;
    notifications.clear();
    if (unseen > 0) badge = unseen = 0;
  }

  // The device's mode set to `next`.
  void choose(const QString& next) {
    if (next == mode) return;
    if (AlertController::hasSystemNotifications(next) && !AlertController::hasSystemNotifications(mode) && !allowed) {
      toast({QStringLiteral("warning"), QStringLiteral("Notifications are not allowed"),
             QStringLiteral("Allow notifications for HAL-C2 in your system settings, then choose this option again. "
                            "Sound only is still available."),
             {}});
      return;
    }
    mode = next;
    notifications.clear();
    settle();
  }

  void toggleMute(const QString& key) {
    if (key.isEmpty()) return;
    if (!muted.remove(key)) muted.insert(key);
  }
};

// The desktop's notification service and sound.
struct Presenter {
  bool allowed = true;
  bool enabled = false;
  QMap<QString, QStringList> shown;
  QStringList sounds;
  int badge = -1;
};

// The app on a fake MC with one project and three threads, its alerts shown
// by the fake above and its toasts on a clock that stands still; stores in a
// home of its own. A case's late thread arrives under a name of its own, as
// the threads of earlier cases stay.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  AlertController* alerts = nullptr;
  CommandRegistry* registry = nullptr;
  Presenter presenter;
  QMap<QString, Thread> threads;
  int minute = 0;
  int lates = 0;
  // What a case reached.
  QSet<QString> reached;

  Shell() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), iso(0)},
                                                         {QStringLiteral("updatedAt"), iso(0)},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    const QStringList titles{QStringLiteral("Login"), QStringLiteral("Cart"), QStringLiteral("Checkout")};
    for (int index = 0; index < kThreadIds.size(); ++index) {
      threads.insert(kThreadIds.at(index), Thread{titles.at(index)});
      mc.threads.insert(kThreadIds.at(index), threads.value(kThreadIds.at(index)).row(kThreadIds.at(index)));
    }
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized() && native.store()->thread(keyOf(QStringLiteral("t3"))); })) {
      qFatal("the shell did not start");
    }
    native.controller<ToastController>()->setClock([] { return kEpoch; });
    registry = native.controller<KeybindingController>()->commands();
    alerts = native.controller<AlertController>();
    alerts->setPresenter({
        [this](const QString& key, const QString& title, const QString& body, bool) {
          if (!presenter.enabled || !presenter.allowed) return false;
          presenter.shown.insert(key, {title, body});
          return true;
        },
        [this] { presenter.shown.clear(); },
        [this](bool enabled) {
          presenter.enabled = enabled;
          if (!enabled) presenter.shown.clear();
        },
        [this](const QString& kind) { presenter.sounds.append(kind); },
        [this] { return presenter.allowed; },
        [this](int count) { presenter.badge = count; },
    });
  }

  SettingsController* settings() const { return native.controller<SettingsController>(); }
  NavigationController* navigation() const { return native.controller<NavigationController>(); }

  // The MC sends what the model has of thread `id`, and the shell has read it.
  void put(const Model& model, const QString& id) {
    minute = model.minute;
    threads.insert(id, model.threads.value(id));
    const QJsonObject row = model.threads.value(id).row(id);
    mc.threads.insert(id, row);
    mc.sendRow(id, row);
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
    RC_ASSERT(native.store()->thread(keyOf(id)).has_value());
  }

  QList<Toast> toasts() const {
    QList<Toast> list;
    const QVariantList items = bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    for (const QVariant& item : items) {
      const QVariantMap toast = item.toMap();
      list.append({toast.value(QStringLiteral("type")).toString(), toast.value(QStringLiteral("title")).toString(),
                   toast.value(QStringLiteral("description")).toString(), {}});
    }
    return list;
  }

  // The palette's mute command: its title, and whether it is listed.
  std::pair<QString, bool> muteCommand() const {
    for (int row = 0; row < registry->rowCount(); ++row) {
      const QModelIndex at = registry->index(row);
      if (at.data(CommandRegistry::CommandRole).toString() != AlertController::kToggleMute) continue;
      return {at.data(CommandRegistry::TitleRole).toString(), at.data(CommandRegistry::ListedRole).toBool()};
    }
    return {};
  }

  // Every alert off, the window focused, nothing muted, no thread shown and
  // no toast; the threads stay as they are.
  Model reset() {
    presenter.allowed = true;
    settings()->set(QStringLiteral("notificationMode"), QStringLiteral("off"));
    settings()->set(QStringLiteral("inAppNotificationsEnabled"), false);
    alerts->setFocused(true);
    const QStringList muted = settings()->deviceSettings().value(AlertController::kMutedKey).toVariant().toStringList();
    for (const QString& key : muted) alerts->setMuted(key, false);
    navigation()->open(NavigationController::Route::of(QStringLiteral("usage")));
    auto* toasts = native.controller<ToastController>();
    const QVariantList items = bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    for (const QVariant& item : items) toasts->dismiss(item.toMap().value(QStringLiteral("id")).toString());
    presenter.shown.clear();
    presenter.sounds.clear();
    reached.clear();
    Model model;
    model.threads = threads;
    model.late = QStringLiteral("late%1").arg(++lates);
    model.minute = minute;
    model.badge = presenter.badge;
    return model;
  }
};

void check(const Model& model, Shell& shell) {
  RC_ASSERT(shell.presenter.sounds == model.sounds);
  RC_ASSERT(shell.presenter.shown == model.notifications);
  RC_ASSERT(shell.presenter.badge == model.badge);
  RC_ASSERT(shell.toasts() == model.toasts);
  RC_ASSERT(shell.navigation()->threadKey() == model.route);
  RC_ASSERT(shell.alerts->focused() == model.focused);
  RC_ASSERT(shell.settings()->setting(QStringLiteral("notificationMode")).toString() == model.mode);
  RC_ASSERT(shell.settings()->setting(QStringLiteral("inAppNotificationsEnabled")).toBool() == model.inApp);
  RC_ASSERT(shell.presenter.enabled == AlertController::hasSystemNotifications(model.mode));
  for (auto it = model.threads.cbegin(); it != model.threads.cend(); ++it) {
    RC_ASSERT(shell.alerts->isMuted(keyOf(it.key())) == model.muted.contains(keyOf(it.key())));
  }
  QStringList muted(model.muted.cbegin(), model.muted.cend());
  muted.sort();
  RC_ASSERT(shell.settings()->deviceSettings().value(AlertController::kMutedKey).toVariant().toStringList() == muted);
  const auto [title, listed] = shell.muteCommand();
  RC_ASSERT(listed == !model.route.isEmpty());
  const QString expected = model.muted.contains(model.route) ? QStringLiteral("Unmute alerts for this thread")
                                                             : QStringLiteral("Mute alerts for this thread");
  RC_ASSERT(title == expected);
}

using Command = rc::state::Command<Model, Shell>;

// One of the case's threads, the late one once it has arrived.
QString anyThread(const Model& model) {
  QStringList ids = kThreadIds;
  if (model.threads.contains(model.late)) ids.append(model.late);
  return pick(ids);
}

// A change to a thread's row, sent by the MC.
struct Change : Command {
  enum Kind { Start, Complete, Ask, Answer, Fail, Archive };
  Kind kind = *rc::gen::element(Start, Start, Complete, Complete, Ask, Answer, Fail, Archive);
  QString pending = pick(QStringList{QStringLiteral("approval"), QStringLiteral("input")});
  QString error = pick(QStringList{QStringLiteral("provider_error"), QStringLiteral("usage_limit")});
  QString id;

  explicit Change(const Model& model) : id(anyThread(model)) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.threads.contains(id));
    const Thread& thread = model.threads.value(id);
    const bool running = thread.status == QLatin1String("running");
    if (kind == Complete || kind == Ask || kind == Fail) RC_PRE(running);
    if (kind == Answer) RC_PRE(!thread.pending.isEmpty());
  }
  void apply(Model& model) const override {
    model.change(id, [this, &model](Thread& thread) {
      switch (kind) {
        case Start:
          ++thread.runs;
          thread.status = QStringLiteral("running");
          thread.pending.clear();
          thread.errorClass.clear();
          thread.completedAt.reset();
          break;
        case Complete:
          thread.status = QStringLiteral("completed");
          thread.pending.clear();
          thread.completedAt = model.minute;
          break;
        case Ask:
          thread.pending = pending;
          break;
        case Answer:
          thread.pending.clear();
          break;
        case Fail:
          thread.status = QStringLiteral("failed");
          thread.pending.clear();
          thread.errorClass = error;
          thread.completedAt = model.minute;
          break;
        case Archive:
          thread.archived = !thread.archived;
          break;
      }
    });
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.put(expected, id);
    if (expected.sounds.size() + expected.toasts.size() > model.sounds.size() + model.toasts.size() ||
        expected.notifications != model.notifications) {
      shell.reached.insert(QStringLiteral("alerted"));
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    static const char* names[] = {"Start", "Complete", "Ask", "Answer", "Fail", "Archive"};
    os << names[kind] << "(" << id.toStdString();
    if (kind == Ask) os << ", " << pending.toStdString();
    if (kind == Fail) os << ", " << error.toStdString();
    os << ")";
  }
};

// The case's late thread arrives, perhaps with a run already done: what it
// did before it was seen stays quiet.
struct Arrive : Command {
  QString status = pick(QStringList{QString(), QStringLiteral("running"), QStringLiteral("completed"), QStringLiteral("failed")});

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.threads.contains(model.late)); }
  void apply(Model& model) const override {
    model.change(model.late, [this, &model](Thread& thread) {
      thread.title = QStringLiteral("Late");
      if (status.isEmpty()) return;
      thread.runs = 1;
      thread.status = status;
      if (status != QLatin1String("running")) thread.completedAt = model.minute;
      if (status == QLatin1String("failed")) thread.errorClass = QStringLiteral("provider_error");
    });
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.put(expected, model.late);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Arrive(" << (status.isEmpty() ? "no run" : status.toStdString()) << ")"; }
};

struct Focus : Command {
  bool focused = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override { model.focus(focused); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.alerts->setFocused(focused);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Focus(" << focused << ")"; }
};

struct Mode : Command {
  QString mode = pick(kModes);

  void apply(Model& model) const override { model.choose(mode); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (expected.mode != mode) shell.reached.insert(QStringLiteral("refused"));
    shell.settings()->set(QStringLiteral("notificationMode"), mode);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Mode(" << mode.toStdString() << ")"; }
};

struct InApp : Command {
  bool inApp = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.inApp == inApp) return;
    model.inApp = inApp;
    model.settle();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.settings()->set(QStringLiteral("inAppNotificationsEnabled"), inApp);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "InApp(" << inApp << ")"; }
};

// The system allows the app to notify, or no longer does.
struct Allow : Command {
  bool allowed = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override { model.allowed = allowed; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.presenter.allowed = allowed;
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Allow(" << allowed << ")"; }
};

struct Mute : Command {
  QString id;

  explicit Mute(const Model& model) : id(anyThread(model)) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.threads.contains(id)); }
  void apply(Model& model) const override { model.toggleMute(keyOf(id)); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.alerts->setMuted(keyOf(id), expected.muted.contains(keyOf(id)));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Mute(" << id.toStdString() << ")"; }
};

// The palette's "Mute alerts for this thread", run whatever is shown.
struct MuteShown : Command {
  void apply(Model& model) const override { model.toggleMute(model.route); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.registry->run(AlertController::kToggleMute));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "MuteShown"; }
};

// The window shows a thread, or the usage page.
struct Navigate : Command {
  QString id;

  explicit Navigate(const Model& model) : id(*rc::gen::arbitrary<bool>() ? anyThread(model) : QString()) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(id.isEmpty() || model.threads.contains(id)); }
  void apply(Model& model) const override { model.route = id.isEmpty() ? QString() : keyOf(id); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.navigation()->open(id.isEmpty() ? NavigationController::Route::of(QStringLiteral("usage"))
                                          : NavigationController::Route::thread(keyOf(id)));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Navigate(" << (id.isEmpty() ? "usage" : id.toStdString()) << ")"; }
};

// "Open thread" on the newest in-app alert.
struct ClickToast : Command {
  void apply(Model& model) const override {
    for (qsizetype index = 0; index < model.toasts.size(); ++index) {
      if (model.toasts.at(index).key.isEmpty()) continue;
      model.route = model.toasts.at(index).key;
      model.toasts.removeAt(index);
      return;
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    const bool offered = std::any_of(model.toasts.cbegin(), model.toasts.cend(), [](const Toast& toast) { return !toast.key.isEmpty(); });
    if (offered) shell.reached.insert(QStringLiteral("toast clicked"));
    RC_ASSERT(shell.native.controller<ToastController>()->runAction(kOpenThread) == offered);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ClickToast"; }
};

// A system notification for the thread is clicked, shown or not.
struct ClickNotification : Command {
  QString id;

  explicit ClickNotification(const Model& model) : id(anyThread(model)) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.threads.contains(id)); }
  bool opens(const Model& model) const { return AlertController::hasSystemNotifications(model.mode); }
  void apply(Model& model) const override {
    if (opens(model)) model.route = keyOf(id);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (model.notifications.contains(keyOf(id))) shell.reached.insert(QStringLiteral("notification clicked"));
    RC_ASSERT(shell.alerts->openThread(keyOf(id)) == opens(model));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ClickNotification(" << id.toStdString() << ")"; }
};

}  // namespace

class KeysAlertProp : public QObject {
  Q_OBJECT

private slots:
  void alerts() {
    Shell shell;
    QVERIFY(rc::check("alerts are what the model says, however the threads, focus and settings change", [&shell] {
      Model initial = shell.reset();
      // Each case starts with alerts on as often as not.
      const QString mode = pick(kModes);
      const bool inApp = *rc::gen::arbitrary<bool>();
      shell.settings()->set(QStringLiteral("notificationMode"), mode);
      shell.settings()->set(QStringLiteral("inAppNotificationsEnabled"), inApp);
      initial.choose(mode);
      initial.inApp = inApp;
      initial.settle();
      check(initial, shell);
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Change, Change, Change, Change, Arrive, Focus, Mode, InApp,
                                                         Allow, Mute, MuteShown, Navigate, ClickToast, ClickNotification>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("alerted")), "alerted");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("refused")), "a mode refused");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("toast clicked")), "an in-app alert clicked");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("notification clicked")), "a system notification clicked");
    }));
  }
};

HAL_C2_PROP_MAIN(KeysAlertProp)
#include "tst_KeysAlertProp.moc"
