// ThreadErrorController as a state machine over which thread is open, the
// MC's rows saying each thread's last error, errors this client reports on a
// thread (a refused stop), and the banner's dismiss. The banner speaks for the
// open thread only: what this client reported on it, else its row's last
// error; a usage limit the thread's failed run stopped on is left to the
// timeline. Dismissing hides that error of that run on that thread, and only
// that error: the same one again stays hidden, a different one, or the same
// one from a later run, shows.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadErrorController.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>
#include <QTemporaryDir>

#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kThreads = {QStringLiteral("t1"), QStringLiteral("t2")};
const std::vector<QString> kMessages = {QString(), QStringLiteral("Rate limited"), QStringLiteral("Provider crashed")};

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

struct Row {
  QString lastError;
  bool limit = false;
  bool failed = false;
  // The thread's latest run, numbered.
  int run = 1;
};

struct Model {
  // The open thread, empty when settings are open.
  QString open;
  QMap<QString, Row> rows;
  // What this client reported on each thread.
  QMap<QString, QString> local;
  // Errors dismissed: thread, its latest run then, NUL, message.
  QSet<QPair<QString, QString>> dismissed;
};

struct Shown {
  QString message;
  bool warning = false;
};

Shown shown(const Model& model, const QString& thread) {
  if (thread.isEmpty()) return {};
  const Row row = model.rows.value(thread);
  const bool fromRow = !model.local.contains(thread);
  const QString message = fromRow ? row.lastError : model.local.value(thread);
  if (message.isEmpty() || model.dismissed.contains({thread, QString::number(row.run) + QChar(0) + message})) return {};
  if (fromRow && row.limit && row.failed) return {};
  return {message, fromRow && row.limit};
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
    for (qsizetype i = 0; i < kThreads.size(); ++i) {
      mc.threads.insert(kThreads.at(i), QJsonObject{{QStringLiteral("id"), kThreads.at(i)},
                                                    {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                    {QStringLiteral("title"), QStringLiteral("Thread %1").arg(i + 1)},
                                                    {QStringLiteral("latestRunId"), QStringLiteral("run-1")},
                                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-0%1T09:00:00Z").arg(2 - i)}});
    }
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] {
          return native.isActive() && native.store()->threadOnline(keyOf(QStringLiteral("t1"))) && native.store()->threadOnline(keyOf(QStringLiteral("t2")));
        })) {
      qFatal("the shell did not start");
    }
    native.controller<NavigationController>()->open(NavigationController::Route::settings());
  }

  void setRow(const QString& thread, const Row& error) {
    QJsonObject row = mc.threads.value(thread);
    row.insert(QStringLiteral("lastError"), error.lastError.isEmpty() ? QJsonValue() : QJsonValue(error.lastError));
    row.insert(QStringLiteral("lastErrorClass"), error.limit ? QJsonValue(QStringLiteral("usage_limit")) : QJsonValue());
    row.insert(QStringLiteral("status"), error.failed ? QStringLiteral("failed") : QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-%1").arg(error.run));
    mc.threads.insert(thread, row);
    mc.sendRow(thread, row);
  }

  // Whether the shell holds `thread`'s row as `error` says.
  bool holds(const QString& thread, const Row& error) {
    const QJsonObject row = native.store()->threadRow(keyOf(thread));
    return row.value(QLatin1String("lastError")).toString() == error.lastError &&
           (row.value(QLatin1String("lastErrorClass")).toString() == QLatin1String("usage_limit")) == error.limit &&
           (row.value(QLatin1String("status")).toString() == QLatin1String("failed")) == error.failed &&
           row.value(QLatin1String("latestRunId")).toString() == QStringLiteral("run-%1").arg(error.run);
  }

  QVariant error() const { return bridge.state()->value(QStringLiteral("threadError")); }
};

void check(const Model& model, Shell& shell) {
  const Shown wanted = shown(model, model.open);
  const bool held = prop::until([&] {
    for (auto it = model.rows.cbegin(); it != model.rows.cend(); ++it) {
      if (!shell.holds(it.key(), it.value())) return false;
    }
    const QVariant now = shell.error();
    if (wanted.message.isEmpty()) return now.isNull();
    return now == QVariant(QVariantMap{{QStringLiteral("threadKey"), keyOf(model.open)},
                                       {QStringLiteral("message"), wanted.message},
                                       {QStringLiteral("warning"), wanted.warning}});
  });
  if (!held) {
    for (auto it = model.rows.cbegin(); it != model.rows.cend(); ++it) {
      RC_LOG() << it.key().toStdString() << " row: " << QJsonDocument(shell.native.store()->threadRow(keyOf(it.key()))).toJson(QJsonDocument::Compact).toStdString()
               << "\n";
    }
    RC_LOG() << "wanted \"" << wanted.message.toStdString() << "\"; shown " << shell.error().toMap().value(QStringLiteral("message")).toString().toStdString()
             << "\n";
  }
  RC_ASSERT(held);
}

using Command = rc::state::Command<Model, Shell>;

// The user opens a thread, or settings.
struct Open : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>{QString(), QStringLiteral("t1"), QStringLiteral("t2")});
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

// The MC's row says a thread's last error: none, a usage limit, and whether
// its latest run, the same or a later one, failed on it.
struct McError : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>(kThreads.begin(), kThreads.end()));
  QString message = *rc::gen::elementOf(kMessages);
  bool limit = *rc::gen::arbitrary<bool>();
  bool failed = *rc::gen::arbitrary<bool>();
  bool later = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.rows.insert(thread, {message, limit && !message.isEmpty(), failed, model.rows.value(thread).run + (later ? 1 : 0)});
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.setRow(thread, expected.rows.value(thread));
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "McError(" << thread.toStdString() << ", \"" << message.toStdString() << "\"" << (limit ? ", limit" : "") << (failed ? ", failed" : "") << (later ? ", later run" : "") << ")";
  }
};

// This client could not do something on a thread (a stop the MC refused).
struct Report : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>(kThreads.begin(), kThreads.end()));
  QString message = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("Rate limited"), QStringLiteral("Failed to stop background work.")});
  void apply(Model& model) const override { model.local.insert(thread, message); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.native.controller<ThreadErrorController>()->report(keyOf(thread), message);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Report(" << thread.toStdString() << ", \"" << message.toStdString() << "\")"; }
};

// The banner's dismiss, clicked twice: the second hides the row's error a
// reported one was covering.
struct Dismiss : Command {
  static void once(Model& model) {
    const Shown error = shown(model, model.open);
    if (error.message.isEmpty()) return;
    model.local.remove(model.open);
    model.dismissed.insert({model.open, QString::number(model.rows.value(model.open).run) + QChar(0) + error.message});
  }
  void apply(Model& model) const override {
    once(model);
    once(model);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("threadError.dismiss"), {});
    shell.bridge.dispatch(QStringLiteral("threadError.dismiss"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Dismiss x2"; }
};

}  // namespace

class ThreadErrorProp : public QObject {
  Q_OBJECT

private slots:
  void threadError() {
    QVERIFY(rc::check("the open thread's error shows until dismissed, and only that error is hidden", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Open, Open, McError, McError, Report, Dismiss>());
    }));
  }
};

HAL_C2_PROP_MAIN(ThreadErrorProp)
#include "tst_ThreadErrorProp.moc"
