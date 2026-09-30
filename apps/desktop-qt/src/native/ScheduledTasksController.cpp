// Settings → Scheduled Tasks, natively (the web's ScheduledTasksSettings):
// each environment's tasks (HalC2.ScheduledTasks), in the settings scope
// (SettingsScopeController), and the editor that creates and edits them.
// A cluster environment's list is followed live (`scheduledTasks` shape);
// a linked one's is listed when shown and after each change.
//
// Publishes `scheduledTasks`: {open, canCreate, environments [{id, label, heading (several shown), status:
// disconnected | loading | error | ready, message, linkMissing, tasks [{id,
// title, prompt, schedule ("Weekdays at 09:00"), when ("Next run in 5m",
// "Paused"), enabled, lastRunStatus (never | running | succeeded | failed),
// lastRun ("Succeeded", "Failed", "Running", empty before the first run),
// lastRunError, busy}]}], editor: null | {environmentId, environments [{id,
// label}], seq (a new one with each editor opened), editing, connected,
// saving, missing (the task edited is gone), error (the list could not
// load), legacyInterval (the task runs more often than once a minute),
// draft (below), projects [{id, title}], models [{key, label}], branches
// [{name, current, isDefault, isRemote}] with branchesTotal and
// branchesLoading}}.
//
// A draft is {title, prompt, enabled, scheduleMode: fixed | interval,
// intervalMinutes, timeOfDay, weekdays [0-6, Sunday first], projectId,
// threadId, workspaceMode: worktree | root | existing_worktree, baseRef,
// startFromOrigin, checkoutPath, modelKey ("instance:model")}.
//
// Actions: `scheduledTasks.new`, `.edit {environmentId, id}`, `.editorEnvironment
// {id}` (a new task only), `.close`, `.save {draft}`, `.branches {projectId,
// query}` (the editor's base branch choices, from vcs.listRefs), `.enable {environmentId, id,
// enabled}`, `.run {environmentId, id}`, `.delete {environmentId, id}`, and
// `.open {environmentId, taskId}` (a link to a task: its editor, or "Task
// unavailable").

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QVariantMap>

#include <algorithm>
#include <cmath>

#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("scheduledTasks");
const QString kSection = QStringLiteral("/settings/scheduled-tasks");

QString at(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

// "Weekdays at 09:00", "Every 15 min" (scheduleLabel).
QString scheduleLabel(const QJsonObject& schedule) {
  if (at(schedule, "type") == QLatin1String("interval")) {
    const double everyMs = schedule.value(QLatin1String("everyMs")).toDouble();
    const double minutes = everyMs / 60000.0;
    return minutes == std::floor(minutes) ? QStringLiteral("Every %1 min").arg(qint64(minutes))
                                          : QStringLiteral("Every %1 sec").arg(qint64(std::lround(everyMs / 1000.0)));
  }
  static const QStringList names{QStringLiteral("Sun"), QStringLiteral("Mon"), QStringLiteral("Tue"), QStringLiteral("Wed"),
                                 QStringLiteral("Thu"), QStringLiteral("Fri"), QStringLiteral("Sat")};
  QList<int> weekdays;
  for (const QJsonValue& day : schedule.value(QLatin1String("weekdays")).toArray()) weekdays.append(day.toInt());
  QString days;
  if (weekdays.isEmpty()) {
    days = QStringLiteral("Daily");
  } else if (weekdays.size() == 5 && std::all_of(weekdays.cbegin(), weekdays.cend(), [](int day) { return day >= 1 && day <= 5; })) {
    days = QStringLiteral("Weekdays");
  } else {
    QStringList labels;
    for (const int day : weekdays) labels.append(names.value(day));
    days = labels.join(QStringLiteral(", "));
  }
  return QStringLiteral("%1 at %2").arg(days, at(schedule, "timeOfDay"));
}

// "in 5m" for a coming run, "5m ago" for a past one (relativeLabel).
QString relativeLabel(const QString& iso, const QDateTime& now) {
  const QDateTime when = QDateTime::fromString(iso, Qt::ISODateWithMs);
  if (!when.isValid()) return QStringLiteral("Not scheduled");
  const qint64 diffMs = now.msecsTo(when);
  if (diffMs <= 0) {
    const qint64 minutes = -diffMs / 60000;
    if (minutes < 1) return QStringLiteral("just now");
    if (minutes < 60) return QStringLiteral("%1m ago").arg(minutes);
    if (minutes < 60 * 24) return QStringLiteral("%1h ago").arg(minutes / 60);
    return QStringLiteral("%1d ago").arg(minutes / (60 * 24));
  }
  const qint64 minutes = (diffMs + 59999) / 60000;
  if (minutes < 2) return QStringLiteral("in under a minute");
  if (minutes < 60) return QStringLiteral("in %1m").arg(minutes);
  const qint64 hours = std::llround(minutes / 60.0);
  if (hours < 24) return QStringLiteral("in %1h").arg(hours);
  return QStringLiteral("in %1d").arg(std::llround(hours / 24.0));
}

// The providers a task can run on (scheduledTaskDefaultModel's `available`).
QJsonArray usable(const QJsonArray& providers) {
  QJsonArray result;
  for (const QJsonValue& value : providers) {
    const QJsonObject entry = value.toObject();
    if (!entry.value(QLatin1String("enabled")).toBool(true) || !entry.value(QLatin1String("installed")).toBool(true)) continue;
    if (at(entry, "availability") == QLatin1String("unavailable")) continue;
    if (at(entry.value(QLatin1String("auth")).toObject(), "status") == QLatin1String("unauthenticated")) continue;
    result.append(entry);
  }
  return result;
}

bool offers(const QJsonArray& entries, const QJsonObject& selection) {
  for (const QJsonValue& value : entries) {
    const QJsonObject entry = value.toObject();
    if (at(entry, "instanceId") != at(selection, "instanceId")) continue;
    for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
      if (at(model.toObject(), "slug") == at(selection, "model")) return !model.toObject().value(QLatin1String("isLegacy")).toBool();
    }
  }
  return false;
}

// The badge for a task's last run; none before its first.
QString lastRunLabel(const QString& status) {
  if (status == QLatin1String("succeeded")) return QStringLiteral("Succeeded");
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("running")) return QStringLiteral("Running");
  return {};
}

QString keyOf(const QJsonObject& selection) {
  return selection.isEmpty() ? QString() : at(selection, "instanceId") + QLatin1Char(':') + at(selection, "model");
}

}  // namespace

class ScheduledTasksController : public QObject, public NativeController {
public:
  ScheduledTasksController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
    // Relative times move on while the section shows.
    m_tick.setInterval(60000);
    connect(&m_tick, &QTimer::timeout, this, &ScheduledTasksController::publish);
  }

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    connect(navigation, &NavigationController::changed, this, [this, navigation] {
      const NavigationController::Route& route = navigation->route();
      const bool open = route.kind == QLatin1String("settings") && route.section == kSection;
      if (open == m_open) return;
      m_open = open;
      if (!open) {
        m_editor = {};
        m_link = {};
      }
      follow();
    });
    connect(scope(), &SettingsScopeController::changed, this, &ScheduledTasksController::follow);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("scheduledTasks."))) return false;
    const QVariantMap input = payload.toMap();
    const QString environmentId = input.value(QStringLiteral("environmentId")).toString();
    const QString id = input.value(QStringLiteral("id")).toString();
    if (action == QLatin1String("scheduledTasks.new")) {
      const QString environment = defaultEnvironment();
      if (!environment.isEmpty()) openEditor(environment, {});
    } else if (action == QLatin1String("scheduledTasks.edit")) {
      const QJsonObject task = find(environmentId, id);
      if (!task.isEmpty()) openEditor(environmentId, task);
    } else if (action == QLatin1String("scheduledTasks.editorEnvironment")) {
      if (m_editor.open && m_editor.task.isEmpty()) openEditor(input.value(QStringLiteral("id")).toString(), {});
    } else if (action == QLatin1String("scheduledTasks.close")) {
      if (!m_editor.saving) m_editor = {};
    } else if (action == QLatin1String("scheduledTasks.branches")) {
      branches(input.value(QStringLiteral("projectId")).toString(), input.value(QStringLiteral("query")).toString());
    } else if (action == QLatin1String("scheduledTasks.save")) {
      save(input.value(QStringLiteral("draft")).toMap());
    } else if (action == QLatin1String("scheduledTasks.enable")) {
      act(environmentId, id, QStringLiteral("scheduledTasks.setEnabled"),
          {{QStringLiteral("id"), id}, {QStringLiteral("enabled"), input.value(QStringLiteral("enabled")).toBool()}});
    } else if (action == QLatin1String("scheduledTasks.run")) {
      act(environmentId, id, QStringLiteral("scheduledTasks.runNow"), {{QStringLiteral("id"), id}});
    } else if (action == QLatin1String("scheduledTasks.delete")) {
      act(environmentId, id, QStringLiteral("scheduledTasks.delete"), {{QStringLiteral("id"), id}});
    } else if (action == QLatin1String("scheduledTasks.open")) {
      m_link = {environmentId, input.value(QStringLiteral("taskId")).toString(), false};
      NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::settings(kSection));
      follow();
    }
    publish();
    return true;
  }

private:
  struct Listing {
    int subscription = -1;
    bool listed = false;
    QJsonArray tasks;
    QString error;
  };
  struct Editor {
    bool open = false;
    QString environmentId;
    QJsonObject task;  // the task edited, empty for a new one
    QVariantMap draft;
    bool saving = false;
    QJsonArray branches;  // the project's refs matching the base branch typed
    int branchesTotal = 0;
    bool branchesLoading = false;
  };
  struct Link {
    QString environmentId, taskId;
    bool shown = false;
  };

  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The environments whose tasks are fetched: the scope's connected ones.
  QStringList fetched() const { return m_open ? scope()->targets() : QStringList(); }

  void follow() {
    const QStringList wanted = fetched();
    for (auto it = m_listings.begin(); it != m_listings.end();) {
      if (wanted.contains(it.key())) {
        ++it;
        continue;
      }
      if (it->subscription >= 0) m_client->unsubscribe(it->subscription);
      it = m_listings.erase(it);
    }
    for (const QString& environmentId : wanted) {
      if (m_listings.contains(environmentId)) continue;
      m_listings.insert(environmentId, Listing{});
      const QString node = m_store->nodeServing(environmentId);
      if (!node.isEmpty()) {
        m_listings[environmentId].subscription = m_client->subscribe(this, 
            {{QStringLiteral("type"), QStringLiteral("scheduledTasks")}, {QStringLiteral("node"), node}},
            [this, environmentId](const QJsonObject& frame) {
              auto found = m_listings.find(environmentId);
              if (found == m_listings.end()) return;
              if (frame.value(QLatin1String("t")) == QLatin1String("scheduledTasks")) {
                found->tasks = frame.value(QLatin1String("tasks")).toArray();
                found->listed = true;
                found->error.clear();
              } else if (frame.value(QLatin1String("t")) == QLatin1String("error")) {
                found->error = frame.value(QLatin1String("reason")).toString();
              }
              publish();
            });
      } else {
        list(environmentId);
      }
    }
    if (m_open) {
      m_tick.start();
    } else {
      m_tick.stop();
    }
    publish();
  }

  void list(const QString& environmentId) {
    const QPointer<ScheduledTasksController> self(this);
    m_client->call(this, environmentId, QStringLiteral("scheduledTasks.list"), QJsonObject{},
                   [self, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!self) return;
                     auto found = self->m_listings.find(environmentId);
                     if (found == self->m_listings.end()) return;
                     if (error) {
                       found->error = *error;
                     } else {
                       found->tasks = result.toObject().value(QLatin1String("tasks")).toArray();
                       found->listed = true;
                       found->error.clear();
                     }
                     self->publish();
                   });
  }

  // The environment's tasks in the scope.
  QList<QJsonObject> tasksOf(const QString& environmentId) const {
    QList<QJsonObject> tasks;
    for (const QJsonValue& value : m_listings.value(environmentId).tasks) {
      const QJsonObject task = value.toObject();
      if (scope()->covers(environmentId, at(task, "projectId"))) tasks.append(task);
    }
    return tasks;
  }

  QJsonObject find(const QString& environmentId, const QString& id) const {
    for (const QJsonObject& task : tasksOf(environmentId)) {
      if (at(task, "id") == id) return task;
    }
    return {};
  }

  QString defaultEnvironment() const {
    const QStringList targets = scope()->targets();
    return targets.isEmpty() ? QString() : targets.first();
  }

  QString label(const QString& environmentId) const { return scope()->label(environmentId); }

  // The projects a task on the environment can run in.
  QVariantList projects(const QString& environmentId) const {
    QVariantList result;
    for (const QJsonObject& row : m_store->projectRows(environmentId)) {
      if (!scope()->covers(environmentId, at(row, "id"))) continue;
      result.append(QVariantMap{{QStringLiteral("id"), at(row, "id")}, {QStringLiteral("title"), at(row, "title")}});
    }
    return result;
  }

  // scheduledTaskDefaultModel: the project's, then the environment's default
  // model where it can run, then the providers' own default.
  QString defaultModel(const QString& environmentId, const QString& projectId) const {
    const QJsonArray entries = usable(scope()->providers(environmentId));
    const QJsonObject settings = scope()->settings(environmentId).value_or(QJsonObject());
    QJsonObject configured = SettingsScopeController::overrideOf(settings, projectId, QStringLiteral("defaultModelSelection")).toObject();
    if (configured.isEmpty()) configured = m_store->projectRow(environmentId, projectId).value(QLatin1String("defaultModelSelection")).toObject();
    if (configured.isEmpty()) configured = settings.value(QLatin1String("defaultModelSelection")).toObject();
    for (const QJsonObject& selection : {configured, settings.value(QLatin1String("defaultModelSelection")).toObject()}) {
      if (!selection.isEmpty() && offers(entries, selection)) return keyOf(selection);
    }
    QString first;
    for (const QJsonValue& value : entries) {
      for (const QJsonValue& model : value.toObject().value(QLatin1String("models")).toArray()) {
        if (model.toObject().value(QLatin1String("isLegacy")).toBool()) continue;
        const QString key = at(value.toObject(), "instanceId") + QLatin1Char(':') + at(model.toObject(), "slug");
        if (model.toObject().value(QLatin1String("isDefault")).toBool()) return key;
        if (first.isEmpty()) first = key;
      }
    }
    return first;
  }

  QVariantList models(const QString& environmentId, const QString& keep) const {
    QVariantList result;
    bool kept = keep.isEmpty();
    for (const QJsonValue& value : usable(scope()->providers(environmentId))) {
      const QJsonObject entry = value.toObject();
      const QString provider = at(entry, "displayName").isEmpty() ? at(entry, "instanceId") : at(entry, "displayName");
      for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
        if (model.toObject().value(QLatin1String("isLegacy")).toBool()) continue;
        const QString key = at(entry, "instanceId") + QLatin1Char(':') + at(model.toObject(), "slug");
        const QString name = at(model.toObject(), "name").isEmpty() ? at(model.toObject(), "slug") : at(model.toObject(), "name");
        result.append(QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("label"), provider + QStringLiteral(" · ") + name}});
        kept = kept || key == keep;
      }
    }
    // The task's own model stays choosable where it cannot run now.
    if (!kept) result.append(QVariantMap{{QStringLiteral("key"), keep}, {QStringLiteral("label"), keep + QStringLiteral(" (Unavailable)")}});
    return result;
  }

  void openEditor(const QString& environmentId, const QJsonObject& task) {
    QVariantMap draft;
    if (task.isEmpty()) {
      const QVariantList choices = projects(environmentId);
      const QString projectId = choices.isEmpty() ? QString() : choices.first().toMap().value(QStringLiteral("id")).toString();
      draft = {{QStringLiteral("title"), QString()},
               {QStringLiteral("prompt"), QString()},
               {QStringLiteral("enabled"), true},
               {QStringLiteral("scheduleMode"), QStringLiteral("fixed")},
               {QStringLiteral("intervalMinutes"), QStringLiteral("15")},
               {QStringLiteral("timeOfDay"), QStringLiteral("09:00")},
               {QStringLiteral("weekdays"), QVariantList{1, 2, 3, 4, 5}},
               {QStringLiteral("projectId"), projectId},
               {QStringLiteral("threadId"), QString()},
               {QStringLiteral("workspaceMode"), QStringLiteral("worktree")},
               {QStringLiteral("baseRef"), QStringLiteral("main")},
               {QStringLiteral("startFromOrigin"), true},
               {QStringLiteral("checkoutPath"), QString()},
               {QStringLiteral("modelKey"), defaultModel(environmentId, projectId)}};
    } else {
      const QJsonObject schedule = task.value(QLatin1String("schedule")).toObject();
      const QJsonObject workspace = task.value(QLatin1String("workspaceStrategy")).toObject();
      const bool interval = at(schedule, "type") == QLatin1String("interval");
      QVariantList weekdays = schedule.value(QLatin1String("weekdays")).toArray().toVariantList();
      if (interval || weekdays.isEmpty()) weekdays = {0, 1, 2, 3, 4, 5, 6};
      const QString mode = at(workspace, "type").isEmpty() ? QStringLiteral("worktree") : at(workspace, "type");
      draft = {{QStringLiteral("title"), at(task, "title")},
               {QStringLiteral("prompt"), at(task, "prompt")},
               {QStringLiteral("enabled"), task.value(QLatin1String("enabled")).toBool()},
               {QStringLiteral("scheduleMode"), interval ? QStringLiteral("interval") : QStringLiteral("fixed")},
               {QStringLiteral("intervalMinutes"),
                interval ? QString::number(std::max(1.0, schedule.value(QLatin1String("everyMs")).toDouble() / 60000.0)) : QStringLiteral("15")},
               {QStringLiteral("timeOfDay"), interval ? QStringLiteral("09:00") : at(schedule, "timeOfDay")},
               {QStringLiteral("weekdays"), weekdays},
               {QStringLiteral("projectId"), at(task, "projectId")},
               {QStringLiteral("threadId"), at(task, "threadId")},
               {QStringLiteral("workspaceMode"), mode},
               {QStringLiteral("baseRef"), mode == QLatin1String("worktree") ? at(workspace, "baseRef") : QStringLiteral("main")},
               {QStringLiteral("startFromOrigin"),
                mode == QLatin1String("worktree") ? workspace.value(QLatin1String("startFromOrigin")).toBool(false) : true},
               {QStringLiteral("checkoutPath"), mode == QLatin1String("existing_worktree") ? at(workspace, "worktreePath") : QString()},
               {QStringLiteral("modelKey"), keyOf(task.value(QLatin1String("modelSelection")).toObject())}};
    }
    m_editor = {true, environmentId, task, draft, false};
    ++m_editorSeq;
  }

  void fail(const QString& title, const QString& description) {
    NativeShell::of(this)->controller<ToastController>()->error(title, description);
  }

  void save(const QVariantMap& draft) {
    if (!m_editor.open || m_editor.saving) return;
    m_editor.draft = draft;
    const QString environmentId = m_editor.environmentId;
    if (!scope()->online(environmentId) || !m_listings.value(environmentId).listed) {
      fail(QStringLiteral("Reconnect this environment before saving"), QStringLiteral("The task was not saved."));
      return;
    }
    const QString title = draft.value(QStringLiteral("title")).toString().trimmed();
    const QString prompt = draft.value(QStringLiteral("prompt")).toString().trimmed();
    const QString projectId = draft.value(QStringLiteral("projectId")).toString();
    const QString modelKey = draft.value(QStringLiteral("modelKey")).toString();
    const qsizetype colon = modelKey.indexOf(QLatin1Char(':'));
    const bool knownProject = std::any_of(projects(environmentId).cbegin(), projects(environmentId).cend(), [&](const QVariant& project) {
      return project.toMap().value(QStringLiteral("id")) == projectId;
    });
    if (title.isEmpty() || prompt.isEmpty() || !knownProject || colon <= 0 || colon == modelKey.size() - 1) {
      fail(QStringLiteral("Scheduled task is incomplete"), QStringLiteral("Add a title, prompt, project, and model."));
      return;
    }
    QJsonObject schedule;
    if (draft.value(QStringLiteral("scheduleMode")) == QLatin1String("interval")) {
      bool number = false;
      const double minutes = draft.value(QStringLiteral("intervalMinutes")).toString().toDouble(&number);
      const double everyMs = std::round(minutes * 60000.0);
      if (!number || !std::isfinite(everyMs) || everyMs < 60000.0 || everyMs > 9007199254740991.0) {
        fail(QStringLiteral("Invalid interval"), QStringLiteral("Enter an interval of at least one minute."));
        return;
      }
      schedule = {{QStringLiteral("type"), QStringLiteral("interval")}, {QStringLiteral("everyMs"), everyMs}};
    } else {
      QList<int> weekdays;
      for (const QVariant& day : draft.value(QStringLiteral("weekdays")).toList()) {
        if (!weekdays.contains(day.toInt())) weekdays.append(day.toInt());
      }
      std::sort(weekdays.begin(), weekdays.end());
      const QString time = draft.value(QStringLiteral("timeOfDay")).toString();
      schedule = {{QStringLiteral("type"), QStringLiteral("fixed_time")}, {QStringLiteral("timeOfDay"), time.isEmpty() ? QStringLiteral("09:00") : time}};
      if (!weekdays.isEmpty() && weekdays.size() != 7) {
        QJsonArray days;
        for (const int day : weekdays) days.append(day);
        schedule.insert(QStringLiteral("weekdays"), days);
      }
    }
    const QString mode = draft.value(QStringLiteral("workspaceMode")).toString();
    QJsonObject workspace;
    if (mode == QLatin1String("root")) {
      workspace = {{QStringLiteral("type"), QStringLiteral("root")}};
    } else if (mode == QLatin1String("existing_worktree")) {
      const QString path = draft.value(QStringLiteral("checkoutPath")).toString().trimmed();
      if (path.isEmpty()) {
        fail(QStringLiteral("Checkout path is required"), QStringLiteral("Enter the path of the checkout to run in."));
        return;
      }
      workspace = {{QStringLiteral("type"), QStringLiteral("existing_worktree")}, {QStringLiteral("worktreePath"), path}};
    } else {
      const QString base = draft.value(QStringLiteral("baseRef")).toString().trimmed();
      workspace = {{QStringLiteral("type"), QStringLiteral("worktree")},
                   {QStringLiteral("baseRef"), base.isEmpty() ? QStringLiteral("main") : base},
                   {QStringLiteral("startFromOrigin"), draft.value(QStringLiteral("startFromOrigin")).toBool()}};
    }
    // The task's own selection keeps its options while its model is kept.
    QJsonObject selection = m_editor.task.value(QLatin1String("modelSelection")).toObject();
    if (keyOf(selection) != modelKey) {
      selection = {{QStringLiteral("instanceId"), modelKey.left(colon)}, {QStringLiteral("model"), modelKey.mid(colon + 1)}};
    }
    const QString threadId = draft.value(QStringLiteral("threadId")).toString();
    QJsonObject input{
        {QStringLiteral("title"), title},
        {QStringLiteral("prompt"), prompt},
        {QStringLiteral("enabled"), draft.value(QStringLiteral("enabled")).toBool()},
        {QStringLiteral("schedule"), schedule},
        {QStringLiteral("projectId"), projectId},
        {QStringLiteral("threadId"), threadId.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(threadId)},
        {QStringLiteral("workspaceStrategy"), workspace},
        {QStringLiteral("modelSelection"), selection},
        {QStringLiteral("runtimeMode"), m_editor.task.value(QLatin1String("runtimeMode")).toString(QStringLiteral("full-access"))},
        {QStringLiteral("interactionMode"), m_editor.task.value(QLatin1String("interactionMode")).toString(QStringLiteral("default"))},
        {QStringLiteral("creationSource"), QStringLiteral("web")},
    };
    if (!m_editor.task.isEmpty()) {
      input.insert(QStringLiteral("id"), at(m_editor.task, "id"));
      input.insert(QStringLiteral("requireExisting"), true);
    }
    m_editor.saving = true;
    const QPointer<ScheduledTasksController> self(this);
    // The reply belongs to this editor; one opened since keeps its draft.
    const int seq = m_editorSeq;
    m_client->call(this, environmentId, QStringLiteral("scheduledTasks.upsert"), input,
                   [self, environmentId, seq](const QJsonValue&, const std::optional<QString>& error) {
                     if (!self) return;
                     const bool current = self->m_editor.open && self->m_editorSeq == seq;
                     if (current) self->m_editor.saving = false;
                     if (error) {
                       self->fail(QStringLiteral("Could not save scheduled task"), *error);
                     } else {
                       if (current) self->m_editor = {};
                       if (self->m_listings.contains(environmentId)) self->list(environmentId);
                     }
                     self->publish();
                   });
  }

  // The branches of the editor's project a new worktree can start from, as
  // the header's branch picker lists them.
  void branches(const QString& projectId, const QString& query) {
    if (!m_editor.open) return;
    const QString environmentId = m_editor.environmentId;
    const QString cwd = at(m_store->projectRow(environmentId, projectId), "workspaceRoot");
    const int seq = m_editorSeq;
    const int request = ++m_branchesRequest;
    if (cwd.isEmpty()) {
      m_editor.branches = {};
      m_editor.branchesTotal = 0;
      return;
    }
    m_editor.branchesLoading = true;
    QJsonObject input{{QStringLiteral("cwd"), cwd}, {QStringLiteral("limit"), 20}};
    if (!query.trimmed().isEmpty()) input.insert(QStringLiteral("query"), query.trimmed());
    const QPointer<ScheduledTasksController> self(this);
    m_client->call(this, environmentId, QStringLiteral("vcs.listRefs"), input,
                   [self, seq, request](const QJsonValue& result, const std::optional<QString>&) {
                     if (!self || self->m_editorSeq != seq || self->m_branchesRequest != request || !self->m_editor.open) return;
                     const QJsonObject list = result.toObject();
                     self->m_editor.branchesLoading = false;
                     self->m_editor.branches = list.value(QLatin1String("refs")).toArray();
                     self->m_editor.branchesTotal = list.value(QLatin1String("totalCount")).toInt(int(self->m_editor.branches.size()));
                     self->publish();
                   });
  }

  void act(const QString& environmentId, const QString& id, const QString& method, const QJsonObject& payload) {
    const QString busy = environmentId + QLatin1Char('\n') + id;
    if (m_busy.contains(busy) || find(environmentId, id).isEmpty()) return;
    m_busy.insert(busy);
    const QPointer<ScheduledTasksController> self(this);
    m_client->call(this, environmentId, method, payload, [self, environmentId, busy](const QJsonValue&, const std::optional<QString>& error) {
      if (!self) return;
      self->m_busy.remove(busy);
      if (error) self->fail(QStringLiteral("Could not update scheduled task"), *error);
      if (self->m_listings.contains(environmentId)) self->list(environmentId);
      self->publish();
    });
  }

  void publish() {
    if (!m_active) return;
    SettingsScopeController* scope = this->scope();
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const QString kind = scope->kind();
    QVariantList environments;
    const QStringList shown = kind == QLatin1String("unavailable") || !m_open ? QStringList() : scope->environments();
    for (const QString& environmentId : shown) {
      QVariantMap entry{{QStringLiteral("id"), environmentId},
                        {QStringLiteral("label"), label(environmentId)},
                        {QStringLiteral("heading"), shown.size() > 1}};
      const auto listing = m_listings.constFind(environmentId);
      QVariantList rows;
      if (!scope->online(environmentId) || listing == m_listings.cend()) {
        entry.insert(QStringLiteral("status"), QStringLiteral("disconnected"));
        // Connections is where a link is repaired.
        entry.insert(QStringLiteral("message"), QStringLiteral("Reconnect %1 to view its scheduled tasks.").arg(label(environmentId)));
      } else if (!listing->error.isEmpty() && !listing->listed) {
        entry.insert(QStringLiteral("status"), QStringLiteral("error"));
        entry.insert(QStringLiteral("message"), listing->error);
      } else if (!listing->listed) {
        entry.insert(QStringLiteral("status"), QStringLiteral("loading"));
      } else {
        entry.insert(QStringLiteral("status"), QStringLiteral("ready"));
        bool linked = false;
        for (const QJsonObject& task : tasksOf(environmentId)) {
          const QString id = at(task, "id");
          linked = linked || id == m_link.taskId;
          const bool enabled = task.value(QLatin1String("enabled")).toBool();
          const QString next = at(task, "nextRunAt");
          rows.append(QVariantMap{
              {QStringLiteral("id"), id},
              {QStringLiteral("title"), at(task, "title")},
              {QStringLiteral("prompt"), at(task, "prompt")},
              {QStringLiteral("schedule"), scheduleLabel(task.value(QLatin1String("schedule")).toObject())},
              {QStringLiteral("when"), !enabled         ? QStringLiteral("Paused")
                                       : next.isEmpty() ? QStringLiteral("Not scheduled")
                                                        : QStringLiteral("Next run %1").arg(relativeLabel(next, now))},
              {QStringLiteral("enabled"), enabled},
              {QStringLiteral("lastRunStatus"), task.value(QLatin1String("lastRunStatus")).toString(QStringLiteral("never"))},
              {QStringLiteral("lastRun"), lastRunLabel(task.value(QLatin1String("lastRunStatus")).toString())},
              {QStringLiteral("lastRunError"), at(task, "lastRunError")},
              {QStringLiteral("busy"), m_busy.contains(environmentId + QLatin1Char('\n') + id)},
          });
        }
        // A link to a task opens it, once; one gone says so.
        const bool linkHere = !m_link.taskId.isEmpty() &&
                              (m_link.environmentId.isEmpty() ? environmentId == defaultEnvironment() : m_link.environmentId == environmentId);
        entry.insert(QStringLiteral("linkMissing"), linkHere && !linked);
        if (linkHere && linked && !m_link.shown) {
          m_link.shown = true;
          openEditor(environmentId, find(environmentId, m_link.taskId));
        }
      }
      entry.insert(QStringLiteral("tasks"), rows);
      environments.append(entry);
    }
    QVariant editor;
    if (m_editor.open) {
      QVariantList choices;
      for (const QString& environmentId : scope->targets()) {
        choices.append(QVariantMap{{QStringLiteral("id"), environmentId}, {QStringLiteral("label"), label(environmentId)}});
      }
      const QString environmentId = m_editor.environmentId;
      const Listing listing = m_listings.value(environmentId);
      const QString taskId = at(m_editor.task, "id");
      const QJsonObject schedule = m_editor.task.value(QLatin1String("schedule")).toObject();
      QVariantList refs;
      for (const QJsonValue& ref : m_editor.branches) {
        const QJsonObject entry = ref.toObject();
        refs.append(QVariantMap{{QStringLiteral("name"), at(entry, "name")},
                                {QStringLiteral("current"), entry.value(QLatin1String("current")).toBool()},
                                {QStringLiteral("isDefault"), entry.value(QLatin1String("isDefault")).toBool()},
                                {QStringLiteral("isRemote"), entry.value(QLatin1String("isRemote")).toBool()}});
      }
      editor = QVariantMap{
          {QStringLiteral("seq"), m_editorSeq},
          {QStringLiteral("environmentId"), environmentId},
          {QStringLiteral("environmentLabel"), label(environmentId)},
          {QStringLiteral("environments"), choices},
          {QStringLiteral("editing"), !m_editor.task.isEmpty()},
          {QStringLiteral("connected"), scope->online(environmentId) && m_listings.value(environmentId).listed},
          {QStringLiteral("saving"), m_editor.saving},
          {QStringLiteral("missing"), !taskId.isEmpty() && listing.listed && std::none_of(listing.tasks.cbegin(), listing.tasks.cend(), [&](const QJsonValue& task) {
                                        return at(task.toObject(), "id") == taskId;
                                      })},
          {QStringLiteral("error"), listing.error},
          {QStringLiteral("legacyInterval"), at(schedule, "type") == QLatin1String("interval") &&
                                                 schedule.value(QLatin1String("everyMs")).toDouble() < 60000.0},
          {QStringLiteral("branches"), refs},
          {QStringLiteral("branchesTotal"), m_editor.branchesTotal},
          {QStringLiteral("branchesLoading"), m_editor.branchesLoading},
          {QStringLiteral("draft"), m_editor.draft},
          {QStringLiteral("projects"), projects(environmentId)},
          {QStringLiteral("models"), models(environmentId, m_editor.draft.value(QStringLiteral("modelKey")).toString())},
      };
    }
    m_bridge->publish(kKey, QVariantMap{
                                {QStringLiteral("open"), m_open},
                                {QStringLiteral("canCreate"), !defaultEnvironment().isEmpty()},
                                {QStringLiteral("environments"), environments},
                                {QStringLiteral("editor"), editor},
                            });
  }

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QHash<QString, Listing> m_listings;
  QSet<QString> m_busy;
  Editor m_editor;
  Link m_link;
  int m_editorSeq = 0;  // which editor the dialog's draft belongs to
  int m_branchesRequest = 0;  // the latest branch listing asked for
  QTimer m_tick;
};

namespace {
const NativeControllerRegistrar<ScheduledTasksController> registrar(QStringLiteral("scheduledTasks"), {QStringLiteral("scheduledTasks")});
}  // namespace
