#include "PullRequestThreadLinks.h"

#include <QJsonArray>
#include <QJsonObject>

#include <algorithm>

#include "McClient.h"
#include "ShellStore.h"

PullRequestThreadLinks::PullRequestThreadLinks(McClient* client, ShellStore* store, Notify notify, Search search, QObject* parent)
    : QObject(parent), m_client(client), m_store(store), m_notify(std::move(notify)), m_search(std::move(search)) {
  // Whether this thread or a picker's thread links it follows their rows.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (m_number > 0) emit changed();
  });
}

void PullRequestThreadLinks::setTarget(const QString& environmentId, const QString& threadId, const QString& host, const QString& repository,
                                       int number, const QString& url) {
  if (environmentId == m_environment && threadId == m_thread && host == m_host && repository == m_repository && number == m_number &&
      url == m_url) {
    return;
  }
  const bool same = environmentId == m_environment && host == m_host && repository == m_repository && number == m_number;
  m_environment = environmentId;
  m_thread = threadId;
  m_host = host;
  m_repository = repository;
  m_number = number;
  m_url = url;
  if (!same) {
    ++m_generation;
    m_count = -1;
    m_pending = false;
    m_pickerOpen = false;
    m_query.clear();
  }
  emit changed();
  if (!same) refresh();
}

void PullRequestThreadLinks::clear() {
  setTarget({}, {}, {}, {}, 0, {});
}

bool PullRequestThreadLinks::available() const {
  return m_number > 0 && m_store->supports(m_environment, QStringLiteral("threadPullRequests"));
}

QString PullRequestThreadLinks::label() const {
  if (m_count <= 0) return QStringLiteral("Linked threads");
  return m_count == 1 ? QStringLiteral("Linked from 1 thread") : QStringLiteral("Linked from %1 threads").arg(m_count);
}

bool PullRequestThreadLinks::links(const QString& threadId) const {
  if (threadId.isEmpty() || m_number <= 0) return false;
  const QJsonObject row = m_store->threadRow(m_environment + QLatin1Char(':') + threadId);
  for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
    const QJsonObject link = value.toObject();
    // A dismissed stack layer is the thread's no more.
    if (link.value(QLatin1String("source")).toString() == QLatin1String("stack-dismissed")) continue;
    if (link.value(QLatin1String("number")).toInt() == m_number &&
        link.value(QLatin1String("repository")).toString().compare(m_repository, Qt::CaseInsensitive) == 0 &&
        link.value(QLatin1String("host")).toString().compare(m_host, Qt::CaseInsensitive) == 0) {
      return true;
    }
  }
  return false;
}

bool PullRequestThreadLinks::linkedHere() const {
  return links(m_thread);
}

QString PullRequestThreadLinks::menuLabel() const {
  if (linkedHere()) return QStringLiteral("Unlink from this thread");
  return m_thread.isEmpty() ? QStringLiteral("Link to thread") : QStringLiteral("Link to this thread");
}

void PullRequestThreadLinks::setPickerOpen(bool open) {
  if (open == m_pickerOpen || (open && !available())) return;
  m_pickerOpen = open;
  m_query.clear();
  emit changed();
}

void PullRequestThreadLinks::setQuery(const QString& query) {
  if (query == m_query) return;
  m_query = query;
  emit changed();
}

QVariantList PullRequestThreadLinks::candidates() const {
  if (!m_pickerOpen) return {};
  QHash<QString, QString> projects;
  for (const QJsonObject& project : m_store->projectRows(m_environment)) {
    projects.insert(project.value(QLatin1String("id")).toString(), project.value(QLatin1String("title")).toString());
  }
  const QString search = m_query.trimmed().toLower();
  QList<sidebar::Thread> threads;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.environmentId != m_environment || thread.archivedAt.has_value()) continue;
    if (!(thread.title + QLatin1Char(' ') + projects.value(thread.projectId)).toLower().contains(search)) continue;
    threads.append(thread);
  }
  std::stable_sort(threads.begin(), threads.end(), [](const sidebar::Thread& a, const sidebar::Thread& b) { return a.updatedAt > b.updatedAt; });
  QVariantList rows;
  for (const sidebar::Thread& thread : std::as_const(threads)) {
    rows.append(QVariantMap{{QStringLiteral("id"), thread.id},
                            {QStringLiteral("title"), thread.title.isEmpty() ? QStringLiteral("Untitled thread") : thread.title},
                            {QStringLiteral("project"), projects.value(thread.projectId)},
                            {QStringLiteral("linked"), links(thread.id)}});
  }
  return rows;
}

void PullRequestThreadLinks::refresh() {
  if (!available()) return;
  const quint64 generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("pullRequests.linkedThreads"),
                 QJsonObject{{QStringLiteral("host"), m_host}, {QStringLiteral("repository"), m_repository}, {QStringLiteral("number"), m_number}},
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   // A failed read keeps the last count, as the web's polling does.
                   if (generation != m_generation || error) return;
                   m_count = int(result.toObject().value(QLatin1String("threads")).toArray().size());
                   emit changed();
                 });
}

void PullRequestThreadLinks::search() {
  if (m_search && !m_url.isEmpty()) m_search(m_url);
}

void PullRequestThreadLinks::toggleHere() {
  if (m_thread.isEmpty()) {
    setPickerOpen(true);
    return;
  }
  change(m_thread, !linkedHere());
}

void PullRequestThreadLinks::choose(const QString& threadId) {
  if (links(threadId)) return;
  change(threadId, true);
}

void PullRequestThreadLinks::change(const QString& threadId, bool link) {
  if (!available() || m_pending || threadId.isEmpty() || m_url.isEmpty()) return;
  m_pending = true;
  emit changed();
  QJsonObject command{{QStringLiteral("type"), link ? QStringLiteral("thread.pull-request.link") : QStringLiteral("thread.pull-request.unlink")},
                      {QStringLiteral("threadId"), threadId},
                      {QStringLiteral("host"), m_host},
                      {QStringLiteral("repository"), m_repository},
                      {QStringLiteral("number"), m_number}};
  if (link) {
    command.insert(QStringLiteral("url"), m_url);
    command.insert(QStringLiteral("source"), QStringLiteral("manual"));
  }
  const quint64 generation = m_generation;
  m_client->dispatchCommand(this, m_environment, command, [this, generation, link](const QJsonValue&, const std::optional<QString>& error) {
    if (generation != m_generation) return;
    m_pending = false;
    if (error) {
      m_notify(QStringLiteral("error"), link ? QStringLiteral("Could not link the pull request") : QStringLiteral("Could not unlink the pull request"),
               *error);
      emit changed();
      return;
    }
    m_pickerOpen = false;
    m_query.clear();
    emit changed();
    refresh();
  });
}
