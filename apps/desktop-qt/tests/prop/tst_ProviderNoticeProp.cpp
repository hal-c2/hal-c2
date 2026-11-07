// ProviderNoticeController as a state machine over which thread is open,
// what the MC's config says of each thread's provider, and the notice's
// dismiss. The notice speaks for the open thread's provider only, and for a
// problem only: a ready provider, or a disabled one, has none. Dismissing
// hides that problem of that provider on every thread; the same problem
// reported again stays hidden, a different one shows.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>
#include <QTemporaryDir>

#include <optional>

namespace prop = halc2::prop;

namespace {

// t1 and t3 run on Codex, t2 on Claude.
const QStringList kThreads = {QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3")};
const QStringList kInstances = {QStringLiteral("codex"), QStringLiteral("claudeAgent")};

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }
QString instanceOf(const QString& thread) { return thread == QLatin1String("t2") ? kInstances.at(1) : kInstances.at(0); }
QString nameOf(const QString& instance) { return instance == QLatin1String("codex") ? QStringLiteral("Codex") : QStringLiteral("Claude"); }

// What the MC can say of a provider.
enum State { Ready, SignedOut, NotInstalled, Crashed, Broken, Disabled, kStates };

const char* nameOf(State state) {
  static const char* names[] = {"ready", "signed out", "not installed", "crashed", "broken version", "disabled"};
  return names[state];
}

QJsonObject entry(const QString& instance, State state) {
  QJsonObject provider{{QStringLiteral("instanceId"), instance},
                       {QStringLiteral("driver"), instance},
                       {QStringLiteral("enabled"), state != Disabled},
                       {QStringLiteral("installed"), state != NotInstalled},
                       {QStringLiteral("version"), QStringLiteral("0.9.0")},
                       {QStringLiteral("status"), state == Ready || state == Broken ? QStringLiteral("ready")
                                                  : state == Disabled             ? QStringLiteral("disabled")
                                                                                  : QStringLiteral("error")},
                       {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), state == SignedOut ? QStringLiteral("unauthenticated")
                                                                                                          : QStringLiteral("authenticated")}}},
                       {QStringLiteral("setup"), QJsonObject{{QStringLiteral("canAuthenticate"), true}, {QStringLiteral("canInstall"), true}}}};
  if (state == Crashed) provider.insert(QStringLiteral("message"), QStringLiteral("It exited during startup."));
  if (state == Broken) {
    provider.insert(QStringLiteral("compatibilityAdvisory"), QJsonObject{{QStringLiteral("status"), QStringLiteral("broken")}});
  }
  return provider;
}

// The title the notice wears for a provider in `state`, or empty.
QString title(const QString& instance, State state) {
  const QString name = nameOf(instance);
  switch (state) {
    case SignedOut: return name + QStringLiteral(" is unauthenticated");
    case NotInstalled:
    case Crashed: return name + QStringLiteral(" provider status");
    case Broken: return name + QStringLiteral(" 0.9.0 is known to be broken");
    default: return {};
  }
}

// What it says under the title. Not installed and crashed share a title, so
// the check needs both to know which report the shell shows.
QString message(const QString& instance, State state) {
  switch (state) {
    case SignedOut: return QStringLiteral("Open provider setup to sign in.");
    case NotInstalled: return QStringLiteral("Open provider setup to install %1 on this environment.").arg(nameOf(instance));
    case Crashed: return QStringLiteral("It exited during startup.");
    case Broken: return QStringLiteral("No models are available for this provider.");
    default: return {};
  }
}

struct Model {
  // The open thread, empty when settings are open.
  QString open;
  QMap<QString, State> states;
  QSet<QPair<QString, int>> dismissed;
};

// The open thread's provider state, unless nothing is open.
std::optional<State> openState(const Model& model) {
  if (model.open.isEmpty()) return std::nullopt;
  return model.states.value(instanceOf(model.open), Ready);
}

QString shown(const Model& model) {
  const auto state = openState(model);
  if (!state) return {};
  const QString instance = instanceOf(model.open);
  if (model.dismissed.contains({instance, *state})) return {};
  return title(instance, *state);
}

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QJsonArray providers;

  Shell() {
    for (const QString& instance : kInstances) providers.append(entry(instance, Ready));
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (qsizetype i = 0; i < kThreads.size(); ++i) {
      const QString thread = kThreads.at(i);
      mc.threads.insert(thread, QJsonObject{{QStringLiteral("id"), thread},
                                            {QStringLiteral("projectId"), QStringLiteral("p1")},
                                            {QStringLiteral("title"), QStringLiteral("Thread %1").arg(i + 1)},
                                            {QStringLiteral("modelSelection"),
                                             QJsonObject{{QStringLiteral("instanceId"), instanceOf(thread)}, {QStringLiteral("model"), QStringLiteral("m")}}},
                                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-0%1T09:00:00Z").arg(3 - i)}});
    }
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    // The fake answers `config` with the providers as they are whenever the
    // shell subscribes, so startup waits on the threads only.
    const auto online = [this] {
      QStringList missing;
      for (const QString& thread : kThreads) {
        if (!native.store()->threadOnline(keyOf(thread))) missing.append(thread);
      }
      return missing;
    };
    if (!prop::until([&] { return native.isActive() && online().isEmpty(); }, 15000)) {
      qFatal("the shell did not start: active %d, offline %s", native.isActive(), qPrintable(online().join(u',')));
    }
    native.controller<NavigationController>()->open(NavigationController::Route::settings());
  }

  void report(const QString& instance, State state) {
    for (qsizetype i = 0; i < providers.size(); ++i) {
      if (providers.at(i).toObject().value(QLatin1String("instanceId")) == instance) providers.replace(i, entry(instance, state));
    }
    for (const int id : mc.subscribers(QStringLiteral("config"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers}});
    }
  }

  QVariant notice() const { return bridge.state()->value(QStringLiteral("providerNotice")); }
};

void check(const Model& model, Shell& shell) {
  const QString wanted = shown(model);
  const bool held = prop::until([&] {
    const QVariant now = shell.notice();
    if (wanted.isEmpty()) return now.isNull();
    const QVariantMap map = now.toMap();
    return map.value(QStringLiteral("threadKey")) == keyOf(model.open) && map.value(QStringLiteral("title")) == wanted &&
           map.value(QStringLiteral("message")) == message(instanceOf(model.open), *openState(model)) &&
           map.value(QStringLiteral("instanceId")) == instanceOf(model.open);
  });
  if (!held) {
    RC_LOG() << "wanted \"" << wanted.toStdString() << "\"; shown "
             << QJsonDocument::fromVariant(shell.notice()).toJson(QJsonDocument::Compact).toStdString() << "\n";
  }
  RC_ASSERT(held);
}

using Command = rc::state::Command<Model, Shell>;

// The user opens a thread, or settings.
struct Open : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>{QString(), QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3")});
  void apply(Model& model) const override { model.open = thread; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.native.controller<NavigationController>()->open(thread.isEmpty() ? NavigationController::Route::settings()
                                                                           : NavigationController::Route::thread(keyOf(thread)));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Open(" << (thread.isEmpty() ? "settings" : thread.toStdString()) << ")"; }
};

// The MC's config says what a provider is now, the same as before or not.
struct Report : Command {
  QString instance = *rc::gen::elementOf(std::vector<QString>(kInstances.begin(), kInstances.end()));
  State state = static_cast<State>(*rc::gen::inRange(0, int(kStates)));
  void apply(Model& model) const override { model.states.insert(instance, state); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.report(instance, state);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Report(" << instance.toStdString() << ", " << nameOf(state) << ")"; }
};

// The notice's dismiss.
struct Dismiss : Command {
  void apply(Model& model) const override {
    if (shown(model).isEmpty()) return;
    const QString instance = instanceOf(model.open);
    model.dismissed.insert({instance, model.states.value(instance, Ready)});
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("providerNotice.dismiss"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Dismiss"; }
};

}  // namespace

class ProviderNoticeProp : public QObject {
  Q_OBJECT

private slots:
  void providerNotice() {
    QVERIFY(rc::check("the open thread's provider problem shows until dismissed, and a different one shows again", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Open, Open, Report, Report, Dismiss>());
    }));
  }
};

HAL_C2_PROP_MAIN(ProviderNoticeProp)
#include "tst_ProviderNoticeProp.moc"
