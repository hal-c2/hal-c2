#include "ArchivedThreadsController.h"

#include <QDateTime>
#include <QJsonObject>

#include <algorithm>

#include "CommandRegistry.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ArchivedThreadsController> registrar(QStringLiteral("archivedThreads"),
                                                                     {QStringLiteral("archivedThreads")});

const QString kKey = QStringLiteral("archivedThreads");

// The web's formatRelativeTime: "just now", then minutes, hours and days ago.
QString ago(const QString& iso) {
  const QDateTime at = QDateTime::fromString(iso, Qt::ISODateWithMs);
  if (!at.isValid()) return {};
  const qint64 seconds = std::max<qint64>(0, at.secsTo(QDateTime::currentDateTimeUtc()));
  if (seconds < 60) return QStringLiteral("just now");
  if (seconds < 3600) return QStringLiteral("%1m ago").arg(seconds / 60);
  if (seconds < 86400) return QStringLiteral("%1h ago").arg(seconds / 3600);
  return QStringLiteral("%1d ago").arg(seconds / 86400);
}

QString archivedAt(const QJsonObject& thread) {
  const QString at = thread.value(QLatin1String("archivedAt")).toString();
  return at.isEmpty() ? thread.value(QLatin1String("createdAt")).toString() : at;
}

}  // namespace

ArchivedThreadsController::ArchivedThreadsController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                                     QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

void ArchivedThreadsController::activate() {
  if (m_active) return;
  m_active = true;
  m_bridge->claimKey(kKey);
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  const auto section = NavigationController::Route::settings(NavigationController::kArchivedSection);
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("archivedThreads.open"),
                          keybindings::commandLabel(QStringLiteral("archivedThreads.open")),
                          [navigation, section] { navigation->open(section); });
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation, section] { setOpen(navigation->route() == section); });
  // An environment that comes or goes changes whose archive can be listed.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (m_open && online() != m_asked) load();
  });
  setOpen(navigation->route() == section);
  publish();
}

bool ArchivedThreadsController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("archivedThreads."))) return false;
  const QVariantMap input = payload.toMap();
  const QString environmentId = input.value(QStringLiteral("environmentId")).toString();
  const QString threadId = input.value(QStringLiteral("threadId")).toString();
  if (action == QLatin1String("archivedThreads.refresh")) {
    load();
  } else if (environmentId.isEmpty() || threadId.isEmpty()) {
    return true;
  } else if (action == QLatin1String("archivedThreads.unarchive")) {
    act(environmentId, threadId, QStringLiteral("thread.unarchive"), QStringLiteral("Failed to unarchive thread"));
  } else if (action == QLatin1String("archivedThreads.delete")) {
    const auto* settings = NativeShell::of(this)->controller<SettingsController>();
    auto* menu = NativeShell::of(this)->controller<MenuController>();
    const auto remove = [this, environmentId, threadId] {
      act(environmentId, threadId, QStringLiteral("thread.delete"), QStringLiteral("Failed to delete thread"));
    };
    if (menu && settings && settings->setting(QStringLiteral("confirmThreadDelete")).toBool()) {
      QString title = threadId;
      for (const QJsonValue& thread : m_threads.value(environmentId)) {
        if (thread.toObject().value(QLatin1String("id")).toString() == threadId) {
          title = thread.toObject().value(QLatin1String("title")).toString();
        }
      }
      menu->confirm(QStringLiteral("Delete thread \"%1\"?").arg(title),
                    QStringLiteral("This permanently clears conversation history for this thread."),
                    QStringLiteral("Delete"), true, remove);
    } else {
      remove();
    }
  }
  return true;
}

void ArchivedThreadsController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  if (open) {
    load();
  } else {
    // Nothing is kept for a section nobody sees; it is fetched fresh next time.
    ++m_generation;
    m_asked.clear();
    m_pending.clear();
    m_projects.clear();
    m_threads.clear();
    m_error.clear();
    publish();
  }
}

// The environments whose archive can be asked for: reachable and online.
QStringList ArchivedThreadsController::online() const {
  QStringList ids;
  for (const QString& id : m_store->environments()) {
    if ((id == m_client->environment() || m_store->reaches(id)) && m_store->environmentOnline(id) && !ids.contains(id)) {
      ids.append(id);
    }
  }
  return ids;
}

void ArchivedThreadsController::load() {
  if (!m_open) return;
  const int generation = ++m_generation;
  m_asked = online();
  m_pending = QSet<QString>(m_asked.cbegin(), m_asked.cend());
  m_error.clear();
  for (const QString& environmentId : std::as_const(m_asked)) {
    m_client->call(environmentId, QStringLiteral("orchestration.getArchivedShellSnapshot"), QJsonObject{},
                   [this, generation, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation) return;
                     m_pending.remove(environmentId);
                     if (error) {
                       m_error = *error;
                     } else {
                       m_projects.insert(environmentId, result.toObject().value(QLatin1String("projects")).toArray());
                       m_threads.insert(environmentId, result.toObject().value(QLatin1String("threads")).toArray());
                     }
                     publish();
                   });
  }
  publish();
}

void ArchivedThreadsController::act(const QString& environmentId, const QString& threadId, const QString& type,
                                    const QString& failure) {
  const QString key = environmentId + QLatin1Char(':') + threadId;
  if (m_busy.contains(key)) return;
  m_busy.insert(key);
  publish();
  m_client->dispatchCommand(environmentId, {{QStringLiteral("type"), type}, {QStringLiteral("threadId"), threadId}},
                            [this, key, failure](const QJsonValue&, const std::optional<QString>& error) {
                              m_busy.remove(key);
                              if (error) {
                                if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                                  toasts->error(failure, *error);
                                }
                                publish();
                              } else {
                                load();
                              }
                            });
}

void ArchivedThreadsController::publish() {
  if (!m_active) return;
  QVariantList groups;
  if (m_open) {
    for (const QString& environmentId : std::as_const(m_asked)) {
      QList<QJsonObject> threads;
      for (const QJsonValue& value : m_threads.value(environmentId)) threads.append(value.toObject());
      // Newest archived first.
      std::sort(threads.begin(), threads.end(), [](const QJsonObject& a, const QJsonObject& b) {
        const QString left = archivedAt(a);
        const QString right = archivedAt(b);
        if (left != right) return left > right;
        return a.value(QLatin1String("id")).toString() > b.value(QLatin1String("id")).toString();
      });
      // One group per project, in the environment's project order; a thread
      // whose project is gone groups under its id.
      QStringList order;
      QHash<QString, QString> titles;
      for (const QJsonValue& value : m_projects.value(environmentId)) {
        const QJsonObject project = value.toObject();
        const QString id = project.value(QLatin1String("id")).toString();
        order.append(id);
        titles.insert(id, project.value(QLatin1String("title")).toString(id));
      }
      QHash<QString, QVariantList> rows;
      for (const QJsonObject& thread : std::as_const(threads)) {
        const QString projectId = thread.value(QLatin1String("projectId")).toString();
        if (!order.contains(projectId)) order.append(projectId);
        const QString threadId = thread.value(QLatin1String("id")).toString();
        const QString key = environmentId + QLatin1Char(':') + threadId;
        rows[projectId].append(QVariantMap{
            {QStringLiteral("key"), key},
            {QStringLiteral("environmentId"), environmentId},
            {QStringLiteral("threadId"), threadId},
            {QStringLiteral("title"), thread.value(QLatin1String("title")).toString()},
            {QStringLiteral("description"), QStringLiteral("Archived %1 · Created %2")
                                                .arg(ago(archivedAt(thread)), ago(thread.value(QLatin1String("createdAt")).toString()))},
            {QStringLiteral("busy"), m_busy.contains(key)},
        });
      }
      for (const QString& projectId : std::as_const(order)) {
        if (!rows.contains(projectId)) continue;
        groups.append(QVariantMap{{QStringLiteral("key"), environmentId + QLatin1Char(':') + projectId},
                                  {QStringLiteral("title"), titles.value(projectId, projectId)},
                                  {QStringLiteral("threads"), rows.value(projectId)}});
      }
    }
  }
  QString status = QStringLiteral("ready");
  QString title;
  QString description;
  // A reload keeps what was listed until the answers come.
  if (groups.isEmpty() && (!m_pending.isEmpty() || (m_open && !m_store->synchronized()))) {
    status = QStringLiteral("loading");
    title = QStringLiteral("Loading archived threads");
    description = QStringLiteral("Checking connected environments.");
  } else if (!m_error.isEmpty()) {
    status = QStringLiteral("error");
    title = QStringLiteral("Could not load archived threads");
    description = m_error;
  } else if (groups.isEmpty()) {
    status = QStringLiteral("empty");
    title = QStringLiteral("No archived threads");
    description = QStringLiteral("Archived threads will appear here.");
  }
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("open"), m_open},
                              {QStringLiteral("status"), status},
                              {QStringLiteral("title"), title},
                              {QStringLiteral("description"), description},
                              {QStringLiteral("groups"), groups},
                          });
}
