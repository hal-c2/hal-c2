#include "PlanController.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUuid>

#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadMenuController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<PlanController> registrar(QStringLiteral("plan"));

// The plan's title and filename, from its markdown.
const QString kImplementPrefix = QStringLiteral("PLEASE IMPLEMENT THIS PLAN:\n");

QString titleOf(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"), QRegularExpression::MultilineOption);
  return heading.match(markdown).captured(1).trimmed();
}

// normalizePlanMarkdownForExport.
QString exported(const QString& markdown) {
  QString text = markdown;
  while (!text.isEmpty() && text.back().isSpace()) text.chop(1);
  return text + QLatin1Char('\n');
}

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

PlanController::PlanController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

// sanitizePlanFileSegment: lower case, anything else a dash.
QString PlanController::fileName(const QString& markdown) {
  QString segment = titleOf(markdown).toLower();
  segment.remove(QRegularExpression(QStringLiteral("[`'\".,!?()\\[\\]{}]+")));
  segment.replace(QRegularExpression(QStringLiteral("[^a-z0-9]+")), QStringLiteral("-"));
  segment.remove(QRegularExpression(QStringLiteral("^-+|-+$")));
  return (segment.isEmpty() ? QStringLiteral("plan") : segment) + QStringLiteral(".md");
}

bool PlanController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("plan."))) return false;
  auto* shell = NativeShell::of(this);
  const QString threadKey = shell->controller<NavigationController>()->threadKey();
  const QVariantMap turn = m_bridge->state()->value(QStringLiteral("turn")).toMap();
  const QVariantMap plan = turn.value(QStringLiteral("plan")).toMap();
  // Only the plan the open thread offers.
  if (threadKey.isEmpty() || turn.value(QStringLiteral("threadKey")) != threadKey || plan.isEmpty()) return true;
  const QString markdown = plan.value(QStringLiteral("markdown")).toString();
  if (action == QLatin1String("plan.implementInNewThread")) {
    implementInNewThread(threadKey, plan);
  } else if (action == QLatin1String("plan.copy")) {
    shell->controller<ThreadMenuController>()->copy(exported(markdown), QStringLiteral("Plan copied"), QStringLiteral("Could not copy plan"));
  } else if (action == QLatin1String("plan.download")) {
    download(plan);
  } else if (action == QLatin1String("plan.save")) {
    save(threadKey, plan, payload.toMap().value(QStringLiteral("path")).toString());
  }
  return true;
}

void PlanController::implementInNewThread(const QString& threadKey, const QVariantMap& plan) {
  if (m_starting) return;
  auto* shell = NativeShell::of(this);
  auto* toasts = shell->controller<ToastController>();
  const QJsonObject row = m_store->threadRow(threadKey);
  const QString environmentId = threadKey.left(threadKey.indexOf(QLatin1Char(':')));
  const QString planThread = row.value(QLatin1String("id")).toString();
  const QString markdown = plan.value(QStringLiteral("markdown")).toString();
  const QString heading = titleOf(markdown);
  // The same checkout as the planning thread.
  const QString branch = row.value(QLatin1String("branch")).toString();
  const QString worktree = row.value(QLatin1String("worktreePath")).toString();
  QJsonObject strategy{{QStringLiteral("type"), worktree.isEmpty() ? QStringLiteral("root") : QStringLiteral("existing_worktree")}};
  if (!worktree.isEmpty()) strategy.insert(QStringLiteral("worktreePath"), worktree);
  if (!branch.isEmpty()) strategy.insert(QStringLiteral("branch"), branch);
  const QString threadId = newId();
  const QString runtimeMode = row.value(QLatin1String("runtimeMode")).toString(QStringLiteral("full-access"));
  QJsonObject launch{
      {QStringLiteral("commandId"), newId()},
      {QStringLiteral("creationSource"), QStringLiteral("web")},
      {QStringLiteral("threadId"), threadId},
      {QStringLiteral("projectId"), row.value(QLatin1String("projectId"))},
      {QStringLiteral("title"), heading.isEmpty() ? QStringLiteral("Implement plan") : QStringLiteral("Implement %1").arg(heading)},
      {QStringLiteral("runtimeMode"), runtimeMode},
      {QStringLiteral("interactionMode"), QStringLiteral("default")},
      {QStringLiteral("workspaceStrategy"), strategy},
  };
  const QJsonValue model = row.value(QLatin1String("modelSelection"));
  if (model.isObject()) launch.insert(QStringLiteral("modelSelection"), model);
  QJsonObject message{
      {QStringLiteral("type"), QStringLiteral("message.dispatch")},
      {QStringLiteral("createdBy"), QStringLiteral("user")},
      {QStringLiteral("creationSource"), QStringLiteral("web")},
      {QStringLiteral("threadId"), threadId},
      {QStringLiteral("messageId"), newId()},
      {QStringLiteral("text"), kImplementPrefix + markdown.trimmed()},
      {QStringLiteral("attachments"), QJsonArray()},
      {QStringLiteral("titleSeed"), launch.value(QLatin1String("title"))},
      {QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("start_immediately")}}},
      // The MC marks the plan carried out in the thread that proposed it.
      {QStringLiteral("sourcePlanRef"), QJsonObject{{QStringLiteral("threadId"), planThread}, {QStringLiteral("planId"), plan.value(QStringLiteral("id")).toString()}}},
  };
  if (model.isObject()) message.insert(QStringLiteral("modelSelection"), model);
  m_starting = true;
  const auto failed = [this, toasts](const QString& reason) {
    m_starting = false;
    toasts->show(QStringLiteral("error"), QStringLiteral("Could not start implementation thread"),
                 reason.isEmpty() ? QStringLiteral("An error occurred while creating the new thread.") : reason);
  };
  m_client->call(this, environmentId, QStringLiteral("orchestration.launchThread"), launch,
                 [this, environmentId, threadId, message, failed](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) return failed(*error);
                   m_client->dispatchCommand(this, environmentId, message,
                                             [this, environmentId, threadId, failed](const QJsonValue&, const std::optional<QString>& error) {
                                               if (error) {
                                                 // A thread with nothing in it is not left behind.
                                                 m_client->dispatchCommand(this, environmentId,
                                                                           {{QStringLiteral("type"), QStringLiteral("thread.delete")},
                                                                            {QStringLiteral("threadId"), threadId}},
                                                                           [](const QJsonValue&, const std::optional<QString>&) {});
                                                 return failed(*error);
                                               }
                                               m_starting = false;
                                               NativeShell::of(this)->controller<NavigationController>()->open(
                                                   NavigationController::Route::thread(environmentId + QLatin1Char(':') + threadId));
                                             });
                 });
}

void PlanController::download(const QVariantMap& plan) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const QString markdown = plan.value(QStringLiteral("markdown")).toString();
  const QDir folder(m_downloads.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::DownloadLocation) : m_downloads);
  const QString name = fileName(markdown);
  // Never over a file that is already there: "tax-line (2).md".
  QString path = folder.filePath(name);
  for (int n = 2; QFile::exists(path); ++n) {
    path = folder.filePath(QStringLiteral("%1 (%2).md").arg(name.chopped(3)).arg(n));
  }
  QFile file(path);
  if (!folder.mkpath(QStringLiteral(".")) || !file.open(QIODevice::WriteOnly) || file.write(exported(markdown).toUtf8()) < 0) {
    toasts->error(QStringLiteral("Could not download plan"), file.errorString());
    return;
  }
  file.close();
  toasts->show(QStringLiteral("success"), QStringLiteral("Plan downloaded"), path);
}

void PlanController::save(const QString& threadKey, const QVariantMap& plan, const QString& path) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const QJsonObject row = m_store->threadRow(threadKey);
  const QString environmentId = threadKey.left(threadKey.indexOf(QLatin1Char(':')));
  QString root = row.value(QLatin1String("worktreePath")).toString();
  if (root.isEmpty()) {
    root = m_store->projectRow(environmentId, row.value(QLatin1String("projectId")).toString()).value(QLatin1String("workspaceRoot")).toString();
  }
  if (root.isEmpty()) {
    toasts->show(QStringLiteral("error"), QStringLiteral("Workspace path is unavailable"),
                 QStringLiteral("This thread does not have a workspace path to save into."));
    return;
  }
  const QString markdown = plan.value(QStringLiteral("markdown")).toString();
  const QString relativePath = path.trimmed().isEmpty() ? fileName(markdown) : path.trimmed();
  m_client->call(this, environmentId, QStringLiteral("projects.writeFile"),
                 QJsonObject{{QStringLiteral("cwd"), root}, {QStringLiteral("relativePath"), relativePath}, {QStringLiteral("contents"), exported(markdown)}},
                 [toasts, relativePath](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     toasts->show(QStringLiteral("error"), QStringLiteral("Could not save plan"),
                                  error->isEmpty() ? QStringLiteral("An error occurred while saving.") : *error);
                     return;
                   }
                   const QString saved = result.toObject().value(QLatin1String("relativePath")).toString(relativePath);
                   toasts->show(QStringLiteral("success"), QStringLiteral("Plan saved to workspace"), saved);
                 });
}
