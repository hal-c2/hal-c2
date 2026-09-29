#include "ThreadPreviews.h"

#include <QJsonArray>

#include "NodeClient.h"

namespace {

QJsonObject navOf(const QJsonObject& snapshot) {
  return snapshot.value(QLatin1String("navStatus")).toObject();
}

}  // namespace

ThreadPreviews::ThreadPreviews(NodeClient* client, Notify notify, Open open, QObject* parent)
    : QAbstractListModel(parent), m_client(client), m_notify(std::move(notify)), m_open(std::move(open)) {}

ThreadPreviews::~ThreadPreviews() {
  unfollow();
}

void ThreadPreviews::setThread(const QString& environmentId, const QString& threadId, const QString& node) {
  if (environmentId == m_environment && threadId == m_thread && node == m_node) return;
  const bool threadMoved = environmentId != m_environment || threadId != m_thread;
  m_environment = environmentId;
  m_thread = threadId;
  if (node != m_node) {
    unfollow();
    m_node = node;
  }
  if (threadMoved) {
    ++m_generation;
    m_closing.clear();
    if (!m_rows.isEmpty()) {
      beginResetModel();
      m_rows.clear();
      endResetModel();
      emit countChanged();
    }
    setStatus(QStringLiteral("idle"));
  }
  if (m_active) {
    follow();
    if (threadMoved) reload();
  }
}

void ThreadPreviews::setActive(bool active) {
  if (active == m_active) return;
  m_active = active;
  if (active) {
    follow();
    reload();
  } else {
    unfollow();
  }
}

void ThreadPreviews::follow() {
  if (m_subscription >= 0 || m_node.isEmpty()) return;
  m_subscription = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("preview")}, {QStringLiteral("node"), m_node}},
                                       [this](const QJsonObject& frame) {
                                         onEvent(frame.value(QLatin1String("event")).toObject());
                                       });
}

void ThreadPreviews::unfollow() {
  if (m_subscription < 0) return;
  m_client->unsubscribe(m_subscription);
  m_subscription = -1;
}

void ThreadPreviews::reload() {
  if (m_thread.isEmpty()) return;
  const int generation = ++m_generation;
  if (m_rows.isEmpty()) setStatus(QStringLiteral("loading"));
  m_client->call(this, m_environment, QStringLiteral("preview.list"), QJsonObject{{QStringLiteral("threadId"), m_thread}},
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     // What was listed stays; the failure says why it may be stale.
                     setStatus(QStringLiteral("failed"), *error);
                     return;
                   }
                   const QJsonObject list = result.toObject();
                   QList<QJsonObject> rows;
                   for (const QJsonValue& session : list.value(QLatin1String("sessions")).toArray()) {
                     const QJsonObject snapshot = session.toObject();
                     if (!m_closing.contains(snapshot.value(QLatin1String("tabId")).toString())) rows.append(snapshot);
                   }
                   m_epoch = list.value(QLatin1String("serverEpoch")).toString();
                   m_revision = list.value(QLatin1String("revision")).toInteger(-1);
                   if (rows != m_rows) {
                     const bool counted = rows.size() != m_rows.size();
                     beginResetModel();
                     m_rows = rows;
                     endResetModel();
                     if (counted) emit countChanged();
                   }
                   setStatus(QStringLiteral("ready"));
                 });
}

void ThreadPreviews::onEvent(const QJsonObject& event) {
  if (event.value(QLatin1String("threadId")).toString() != m_thread || m_status != QLatin1String("ready")) return;
  const QString epoch = event.value(QLatin1String("serverEpoch")).toString();
  const qint64 revision = event.value(QLatin1String("revision")).toInteger(-1);
  if (epoch != m_epoch) {
    // The node restarted: its tabs are whatever it lists now.
    reload();
    return;
  }
  if (revision <= m_revision) return;
  m_revision = revision;
  const QString tabId = event.value(QLatin1String("tabId")).toString();
  if (m_closing.contains(tabId)) return;
  const QString type = event.value(QLatin1String("type")).toString();
  if (type == QLatin1String("closed")) {
    remove(tabId);
  } else if (type == QLatin1String("failed")) {
    const int row = rowOf(tabId);
    if (row < 0) return;
    QJsonObject failed = event;
    for (const QString& drop : {QStringLiteral("type"), QStringLiteral("threadId"), QStringLiteral("tabId"),
                                QStringLiteral("createdAt"), QStringLiteral("serverEpoch"), QStringLiteral("revision")}) {
      failed.remove(drop);
    }
    failed.insert(QStringLiteral("_tag"), QStringLiteral("LoadFailed"));
    QJsonObject snapshot = m_rows.at(row);
    snapshot.insert(QStringLiteral("navStatus"), failed);
    upsert(snapshot);
  } else if (event.value(QLatin1String("snapshot")).isObject()) {
    upsert(event.value(QLatin1String("snapshot")).toObject());
  }
}

void ThreadPreviews::open(const QString& tabId) {
  const int row = rowOf(tabId);
  if (row < 0) return;
  const QString url = navOf(m_rows.at(row)).value(QLatin1String("url")).toString();
  if (!url.isEmpty()) m_open(QUrl(url));
}

void ThreadPreviews::close(const QString& tabId) {
  const int row = rowOf(tabId);
  if (row < 0 || m_thread.isEmpty()) return;
  const QJsonObject snapshot = m_rows.at(row);
  m_closing.insert(tabId);
  remove(tabId);
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("preview.close"),
                 QJsonObject{{QStringLiteral("threadId"), m_thread}, {QStringLiteral("tabId"), tabId}},
                 [this, generation, row, snapshot, tabId](const QJsonValue&, const std::optional<QString>& error) {
                   if (!m_closing.remove(tabId) || generation != m_generation) return;
                   if (!error) return;
                   // It is still open on the node: it comes back where it was.
                   if (rowOf(tabId) < 0) {
                     const int at = std::min(row, int(m_rows.size()));
                     beginInsertRows({}, at, at);
                     m_rows.insert(at, snapshot);
                     endInsertRows();
                     emit countChanged();
                   }
                   m_notify(QStringLiteral("error"), QStringLiteral("Could not close the browser tab"), *error);
                 });
}

void ThreadPreviews::setStatus(const QString& status, const QString& message) {
  if (status == m_status && message == m_message) return;
  m_status = status;
  m_message = message;
  emit statusChanged();
}

int ThreadPreviews::rowOf(const QString& tabId) const {
  for (qsizetype row = 0; row < m_rows.size(); ++row) {
    if (m_rows.at(row).value(QLatin1String("tabId")).toString() == tabId) return int(row);
  }
  return -1;
}

void ThreadPreviews::upsert(const QJsonObject& snapshot) {
  const int row = rowOf(snapshot.value(QLatin1String("tabId")).toString());
  if (row >= 0) {
    if (m_rows.at(row) == snapshot) return;
    m_rows[row] = snapshot;
    emit dataChanged(index(row), index(row));
    return;
  }
  beginInsertRows({}, int(m_rows.size()), int(m_rows.size()));
  m_rows.append(snapshot);
  endInsertRows();
  emit countChanged();
}

void ThreadPreviews::remove(const QString& tabId) {
  const int row = rowOf(tabId);
  if (row < 0) return;
  beginRemoveRows({}, row, row);
  m_rows.removeAt(row);
  endRemoveRows();
  emit countChanged();
}

int ThreadPreviews::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant ThreadPreviews::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const QJsonObject& snapshot = m_rows.at(index.row());
  const QJsonObject nav = navOf(snapshot);
  const QString tag = nav.value(QLatin1String("_tag")).toString();
  switch (role) {
    case TabIdRole:
      return snapshot.value(QLatin1String("tabId")).toString();
    case UrlRole:
      return nav.value(QLatin1String("url")).toString();
    case TitleRole: {
      const QString title = nav.value(QLatin1String("title")).toString();
      if (!title.isEmpty()) return title;
      const QString url = nav.value(QLatin1String("url")).toString();
      return url.isEmpty() ? QStringLiteral("New tab") : url;
    }
    case StatusRole:
      if (tag == QLatin1String("Loading")) return QStringLiteral("loading");
      if (tag == QLatin1String("Success")) return QStringLiteral("loaded");
      if (tag == QLatin1String("LoadFailed")) return QStringLiteral("failed");
      return QStringLiteral("idle");
    case ProblemRole:
      if (tag != QLatin1String("LoadFailed")) return QString();
      return nav.value(QLatin1String("description")).toString(QStringLiteral("The page did not load."));
    default:
      return {};
  }
}

QHash<int, QByteArray> ThreadPreviews::roleNames() const {
  return {{TabIdRole, "tabId"}, {UrlRole, "url"}, {TitleRole, "title"}, {StatusRole, "status"}, {ProblemRole, "problem"}};
}
