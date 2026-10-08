#include "ThreadPreviews.h"

#include <QJsonArray>
#include <QSet>

#include <algorithm>
#include <optional>
#include <utility>

#include "McClient.h"

namespace {

QJsonObject navOf(const QJsonObject& snapshot) {
  return snapshot.value(QLatin1String("navStatus")).toObject();
}

// What a row of `snapshot` shows as `role`.
QVariant shown(const QJsonObject& snapshot, int role) {
  const QJsonObject nav = navOf(snapshot);
  const QString tag = nav.value(QLatin1String("_tag")).toString();
  switch (role) {
    case ThreadPreviews::TabIdRole:
      return snapshot.value(QLatin1String("tabId")).toString();
    case ThreadPreviews::UrlRole:
      return nav.value(QLatin1String("url")).toString();
    case ThreadPreviews::TitleRole: {
      const QString title = nav.value(QLatin1String("title")).toString();
      if (!title.isEmpty()) return title;
      const QString url = nav.value(QLatin1String("url")).toString();
      return url.isEmpty() ? QStringLiteral("New tab") : url;
    }
    case ThreadPreviews::StatusRole:
      if (tag == QLatin1String("Loading")) return QStringLiteral("loading");
      if (tag == QLatin1String("Success")) return QStringLiteral("loaded");
      if (tag == QLatin1String("LoadFailed")) return QStringLiteral("failed");
      return QStringLiteral("idle");
    case ThreadPreviews::ProblemRole:
      if (tag != QLatin1String("LoadFailed")) return QString();
      return nav.value(QLatin1String("description")).toString(QStringLiteral("The page did not load."));
    default:
      return {};
  }
}

// The tab `event` leaves behind, given the tab as it was; none when it closed or never was.
std::optional<QJsonObject> after(const QJsonObject& event, const std::optional<QJsonObject>& current) {
  const QString type = event.value(QLatin1String("type")).toString();
  if (type == QLatin1String("closed")) return std::nullopt;
  if (type == QLatin1String("failed")) {
    if (!current) return std::nullopt;
    QJsonObject failed = event;
    for (const QString& drop : {QStringLiteral("type"), QStringLiteral("threadId"), QStringLiteral("tabId"),
                                QStringLiteral("createdAt"), QStringLiteral("serverEpoch"), QStringLiteral("revision")}) {
      failed.remove(drop);
    }
    failed.insert(QStringLiteral("_tag"), QStringLiteral("LoadFailed"));
    QJsonObject snapshot = *current;
    snapshot.insert(QStringLiteral("navStatus"), failed);
    return snapshot;
  }
  if (event.value(QLatin1String("snapshot")).isObject()) return event.value(QLatin1String("snapshot")).toObject();
  return current;
}

}  // namespace

ThreadPreviews::ThreadPreviews(McClient* client, Notify notify, Open open, QObject* parent)
    : QAbstractListModel(parent), m_client(client), m_notify(std::move(notify)), m_open(std::move(open)) {
  for (const auto changed : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
    connect(this, changed, this, &ThreadPreviews::emptyTabChanged);
  }
  connect(this, &QAbstractItemModel::modelReset, this, &ThreadPreviews::emptyTabChanged);
  connect(this, &QAbstractItemModel::dataChanged, this, &ThreadPreviews::emptyTabChanged);
  // Events sent while the connection was down are lost, and a restarted MC sends none for what it no longer has.
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready && m_active) reload();
  });
}

QString ThreadPreviews::emptyTab() const {
  for (const QJsonObject& snapshot : m_rows) {
    if (navOf(snapshot).value(QLatin1String("url")).toString().isEmpty()) return snapshot.value(QLatin1String("tabId")).toString();
  }
  return {};
}

ThreadPreviews::~ThreadPreviews() {
  unfollow();
}

void ThreadPreviews::setThread(const QString& environmentId, const QString& threadId, const QString& mc) {
  if (environmentId == m_environment && threadId == m_thread && mc == m_mc) return;
  const bool threadMoved = environmentId != m_environment || threadId != m_thread;
  m_environment = environmentId;
  m_thread = threadId;
  if (mc != m_mc) {
    unfollow();
    m_mc = mc;
    if (!m_serverList.isEmpty()) {
      m_serverList.clear();
      emit suggestionsChanged();
    }
  }
  if (threadMoved) {
    ++m_generation;
    m_closing.clear();
    m_listing = false;
    m_early.clear();
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
  if (m_subscription >= 0 || m_mc.isEmpty()) return;
  // The servers on the MC's machine, not this one's: the MC scans while someone watches.
  m_servers = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("localServers")}, {QStringLiteral("mc"), m_mc}},
                                  [this](const QJsonObject& frame) {
                                    if (frame.value(QLatin1String("t")) != QLatin1String("localServers")) return;
                                    QList<QJsonObject> servers;
                                    for (const QJsonValue& server : frame.value(QLatin1String("list")).toObject().value(QLatin1String("servers")).toArray()) {
                                      servers.append(server.toObject());
                                    }
                                    if (servers == m_serverList) return;
                                    m_serverList = servers;
                                    emit suggestionsChanged();
                                  });
  m_subscription = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("preview")}, {QStringLiteral("mc"), m_mc}},
                                       [this](const QJsonObject& frame) {
                                         onEvent(frame.value(QLatin1String("event")).toObject());
                                       });
}

void ThreadPreviews::unfollow() {
  if (m_servers >= 0) {
    m_client->unsubscribe(m_servers);
    m_servers = -1;
  }
  if (m_subscription < 0) return;
  m_client->unsubscribe(m_subscription);
  m_subscription = -1;
}

void ThreadPreviews::setConfigured(const QStringList& urls) {
  if (urls == m_configured) return;
  m_configured = urls;
  emit suggestionsChanged();
}

void ThreadPreviews::setRecents(Recents read, Remember write) {
  m_readRecents = std::move(read);
  m_writeRecents = std::move(write);
}

QVariantList ThreadPreviews::suggestions() const {
  QVariantList list;
  QSet<QString> seen;
  const auto add = [&](const QString& url, const QString& label, const QString& kind) {
    if (url.isEmpty() || seen.contains(url)) return;
    seen.insert(url);
    list.append(QVariantMap{{QStringLiteral("url"), url}, {QStringLiteral("label"), label}, {QStringLiteral("kind"), kind}});
  };
  for (const QJsonObject& server : m_serverList) {
    add(server.value(QLatin1String("url")).toString(), server.value(QLatin1String("processName")).toString(), QStringLiteral("server"));
  }
  for (const QString& url : m_configured) add(url, QString(), QStringLiteral("configured"));
  int recents = 0;
  for (const QString& url : m_readRecents ? m_readRecents() : QStringList()) {
    if (recents++ == maxRecents) break;
    add(url, QString(), QStringLiteral("recent"));
  }
  return list;
}

void ThreadPreviews::newTab() {
  if (m_thread.isEmpty()) return;
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("preview.open"), QJsonObject{{QStringLiteral("threadId"), m_thread}},
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open a browser tab"), *error);
                     return;
                   }
                   // Its `opened` event may be behind the answer.
                   if (result.isObject() && m_status == QLatin1String("ready")) upsert(result.toObject());
                 });
}

void ThreadPreviews::navigate(const QString& tabId, const QString& address) {
  const QUrl url = QUrl::fromUserInput(address.trimmed());
  if (rowOf(tabId) < 0 || m_thread.isEmpty() || !url.isValid() || (url.scheme() != QLatin1String("http") && url.scheme() != QLatin1String("https"))) {
    m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), QStringLiteral("\"%1\" is not a web address.").arg(address.trimmed()));
    return;
  }
  const QString target = url.toString();
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("preview.navigate"),
                 QJsonObject{{QStringLiteral("threadId"), m_thread}, {QStringLiteral("tabId"), tabId}, {QStringLiteral("url"), target}},
                 [this, generation, url, target](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                     return;
                   }
                   if (generation == m_generation && result.isObject() && m_status == QLatin1String("ready")) upsert(result.toObject());
                   if (m_writeRecents) {
                     QStringList recents = m_readRecents ? m_readRecents() : QStringList();
                     recents.removeAll(target);
                     recents.prepend(target);
                     m_writeRecents(recents.mid(0, maxRecents));
                     emit suggestionsChanged();
                   }
                   m_open(url);
                 });
}

void ThreadPreviews::reload() {
  if (m_thread.isEmpty()) return;
  const int generation = ++m_generation;
  m_listing = true;
  // The list reads everything before it.
  m_early.clear();
  if (m_rows.isEmpty()) setStatus(QStringLiteral("loading"));
  m_client->call(this, m_environment, QStringLiteral("preview.list"), QJsonObject{{QStringLiteral("threadId"), m_thread}},
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   m_listing = false;
                   if (error) {
                     // What was listed stays; the failure says why it may be stale.
                     m_early.clear();
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
                   // What changed while the list was on its way, if the list is older: a tab already gone does not come back.
                   bool restarted = false;
                   for (const QJsonObject& event : std::exchange(m_early, {})) {
                     const qint64 revision = event.value(QLatin1String("revision")).toInteger(-1);
                     if (event.value(QLatin1String("serverEpoch")).toString() != m_epoch) {
                       restarted = true;
                       continue;
                     }
                     const QString tabId = event.value(QLatin1String("tabId")).toString();
                     if (revision <= m_revision || m_closing.contains(tabId)) continue;
                     m_revision = revision;
                     const auto at = std::find_if(rows.begin(), rows.end(), [&](const QJsonObject& row) {
                       return row.value(QLatin1String("tabId")).toString() == tabId;
                     });
                     const auto next = after(event, at == rows.end() ? std::nullopt : std::optional(*at));
                     if (!next && at != rows.end()) {
                       rows.erase(at);
                     } else if (next && at != rows.end()) {
                       *at = *next;
                     } else if (next) {
                       rows.append(*next);
                     }
                   }
                   const auto tabIds = [](const QList<QJsonObject>& rows) {
                     QStringList ids;
                     for (const QJsonObject& row : rows) ids.append(row.value(QLatin1String("tabId")).toString());
                     return ids;
                   };
                   if (tabIds(rows) == tabIds(m_rows)) {
                     // The same tabs: only those that read differently repaint.
                     for (const QJsonObject& row : std::as_const(rows)) upsert(row);
                   } else {
                     const bool counted = rows.size() != m_rows.size();
                     beginResetModel();
                     m_rows = rows;
                     endResetModel();
                     if (counted) emit countChanged();
                   }
                   setStatus(QStringLiteral("ready"));
                   if (restarted) reload();
                 });
}

void ThreadPreviews::onEvent(const QJsonObject& event) {
  if (event.value(QLatin1String("threadId")).toString() != m_thread) return;
  if (m_listing) m_early.append(event);
  if (m_status != QLatin1String("ready")) return;
  const QString epoch = event.value(QLatin1String("serverEpoch")).toString();
  const qint64 revision = event.value(QLatin1String("revision")).toInteger(-1);
  if (epoch != m_epoch) {
    // The MC restarted: its tabs are whatever it lists now.
    reload();
    return;
  }
  if (revision <= m_revision) return;
  m_revision = revision;
  const QString tabId = event.value(QLatin1String("tabId")).toString();
  if (m_closing.contains(tabId)) return;
  const int row = rowOf(tabId);
  const auto next = after(event, row < 0 ? std::nullopt : std::optional(m_rows.at(row)));
  if (next) {
    upsert(*next);
  } else {
    remove(tabId);
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
  m_client->call(this, m_environment, QStringLiteral("preview.close"),
                 QJsonObject{{QStringLiteral("threadId"), m_thread}, {QStringLiteral("tabId"), tabId}},
                 [this, row, snapshot, tabId](const QJsonValue&, const std::optional<QString>& error) {
                   // Another thread, opened since, forgot what it was closing.
                   if (!m_closing.remove(tabId)) return;
                   if (!error) return;
                   // It is still open on the MC: it comes back where it was.
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
    // Fields no role shows change without a repaint.
    const QHash<int, QByteArray> roles = roleNames();
    const bool redraw =
        std::any_of(roles.keyBegin(), roles.keyEnd(), [&](int role) { return shown(m_rows.at(row), role) != shown(snapshot, role); });
    m_rows[row] = snapshot;
    if (redraw) emit dataChanged(index(row), index(row));
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
  return shown(m_rows.at(index.row()), role);
}

QHash<int, QByteArray> ThreadPreviews::roleNames() const {
  return {{TabIdRole, "tabId"}, {UrlRole, "url"}, {TitleRole, "title"}, {StatusRole, "status"}, {ProblemRole, "problem"}};
}
