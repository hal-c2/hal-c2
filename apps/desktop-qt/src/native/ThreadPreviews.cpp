#include "ThreadPreviews.h"

#include <QDateTime>
#include <QHostAddress>
#include <QJsonArray>
#include <QSet>

#include <algorithm>
#include <optional>
#include <utility>

#include "McClient.h"
#include "ThisMachine.h"

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

// The snapshot's `updatedAt` on the MC's clock, 0 without one.
qint64 stampOf(const QJsonObject& snapshot) {
  const QDateTime at = QDateTime::fromString(snapshot.value(QLatin1String("updatedAt")).toString(), Qt::ISODateWithMs);
  return at.isValid() ? at.toMSecsSinceEpoch() : 0;
}

// When the snapshot's page loaded: its `updatedAt`, else now.
qint64 loadedAt(const QJsonObject& snapshot) {
  const qint64 at = stampOf(snapshot);
  return at > 0 ? at : QDateTime::currentMSecsSinceEpoch();
}

// The page the snapshot shows loaded, "" while none has.
QString loadedUrl(const QJsonObject& snapshot) {
  const QJsonObject nav = navOf(snapshot);
  return nav.value(QLatin1String("_tag")).toString() == QLatin1String("Success") ? nav.value(QLatin1String("url")).toString() : QString();
}

// A dev server's address on the machine it names: one only that machine reaches.
bool loopback(const QUrl& url) {
  if (url.scheme() != QLatin1String("http") && url.scheme() != QLatin1String("https")) return false;
  return thisMachine::loopbackHost(url.host());
}

int portOf(const QUrl& url) {
  return url.port(url.scheme() == QLatin1String("https") ? 443 : 80);
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
  // Another MC's clock: a removal falls back to the kept page's time until this one's stamps arrive.
  if (environmentId != m_environment || mc != m_mc) m_newestStamp = 0;
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
    // Not ready before the rows go: what follows the tabs keeps them until
    // the new thread's are listed.
    setStatus(QStringLiteral("idle"));
    if (!m_rows.isEmpty()) {
      const QList<QJsonObject> gone = m_rows;
      beginResetModel();
      m_rows.clear();
      endResetModel();
      emit countChanged();
      for (const QJsonObject& row : gone) emit tabChanged(row.value(QLatin1String("tabId")).toString());
    }
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

void ThreadPreviews::setEmbedded(bool embedded) {
  if (embedded == m_embedded) return;
  m_embedded = embedded;
  if (wantsServers()) {
    followServers();
  } else {
    unfollowServers();
  }
}

void ThreadPreviews::setSuggesting(bool suggesting) {
  if (suggesting == m_suggesting) return;
  m_suggesting = suggesting;
  if (wantsServers()) {
    followServers();
  } else {
    unfollowServers();
  }
}

void ThreadPreviews::follow() {
  if (wantsServers()) followServers();
  if (m_subscription >= 0 || m_mc.isEmpty()) return;
  m_subscription = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("preview")}, {QStringLiteral("mc"), m_mc}},
                                       [this](const QJsonObject& frame) {
                                         onEvent(frame.value(QLatin1String("event")).toObject());
                                       });
}

void ThreadPreviews::followServers() {
  if (m_servers >= 0 || m_mc.isEmpty()) return;
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
}

void ThreadPreviews::unfollowServers() {
  if (m_servers < 0) return;
  m_client->unsubscribe(m_servers);
  m_servers = -1;
}

void ThreadPreviews::unfollow() {
  unfollowServers();
  if (m_subscription < 0) return;
  m_client->unsubscribe(m_subscription);
  m_subscription = -1;
}

void ThreadPreviews::setConfigured(const QStringList& urls) {
  if (urls == m_configured) return;
  m_configured = urls;
  emit suggestionsChanged();
}

void ThreadPreviews::setHistory(History read, Keep write) {
  m_readHistory = std::move(read);
  m_writeHistory = std::move(write);
}

void ThreadPreviews::setProject(const QString& project) {
  if (project == m_project) return;
  m_project = project;
  emit suggestionsChanged();
}

void ThreadPreviews::keep(const std::function<bool(PreviewHistory&)>& change) {
  if (!m_readHistory || !m_writeHistory || m_project.isEmpty()) return;
  PreviewHistory history = PreviewHistory::fromVariant(m_readHistory());
  if (!change(history)) return;
  m_writeHistory(history.toVariant());
  emit suggestionsChanged();
}

void ThreadPreviews::remember(const QList<QJsonObject>& snapshots, bool loaded) {
  for (const QJsonObject& snapshot : snapshots) m_newestStamp = std::max(m_newestStamp, stampOf(snapshot));
  keep([&](PreviewHistory& history) {
    bool changed = false;
    for (const QJsonObject& snapshot : snapshots) {
      const QJsonObject nav = navOf(snapshot);
      if (nav.value(QLatin1String("_tag")).toString() != QLatin1String("Success")) continue;
      const QString url = nav.value(QLatin1String("url")).toString();
      const QString title = nav.value(QLatin1String("title")).toString();
      changed |= loaded ? history.visit(m_project, url, title, loadedAt(snapshot)) : history.seen(m_project, url, title, loadedAt(snapshot));
    }
    return changed;
  });
}

void ThreadPreviews::forget(const QString& url) {
  // Timed on the MC's clock, as visits are: a later load brings the page back
  // whatever this device's clock says, and nothing the MC said so far does.
  keep([&](PreviewHistory& history) { return history.remove(m_project, url, m_newestStamp); });
}

QVariantList ThreadPreviews::suggestions() const {
  QVariantList list;
  QSet<QString> seen;
  // A page is one suggestion whatever its anchor: the first one's.
  const auto add = [&](const QString& url, const QString& label, const QString& kind, const QString& title, QVariantMap more = {}) {
    QUrl page(PreviewHistory::tidy(url));
    page.setFragment(QString());
    const QString key = page.isEmpty() ? url : page.toString();
    if (url.isEmpty() || seen.contains(key)) return;
    seen.insert(key);
    const QString shown = PreviewHistory::shown(PreviewHistory::tidy(url).isEmpty() ? url : PreviewHistory::tidy(url));
    more.insert({{QStringLiteral("url"), url}, {QStringLiteral("label"), label}, {QStringLiteral("kind"), kind},
                 {QStringLiteral("title"), title.isEmpty() ? shown : title}, {QStringLiteral("detail"), shown}});
    list.append(more);
  };
  for (const QJsonObject& server : m_serverList) {
    const QString process = server.value(QLatin1String("processName")).toString();
    add(server.value(QLatin1String("url")).toString(), process, QStringLiteral("server"), process.isEmpty() ? QStringLiteral("Listening") : process);
  }
  for (const QString& url : m_configured) add(url, QString(), QStringLiteral("configured"), QString());
  if (m_readHistory && !m_project.isEmpty()) {
    const QList<PreviewHistory::Page> pages = PreviewHistory::fromVariant(m_readHistory()).pages(m_project);
    for (qsizetype at = 0; at < pages.size() && at < maxRecents; ++at) {
      const PreviewHistory::Page& page = pages.at(at);
      add(page.url, QString(), QStringLiteral("recent"), page.title, page.at >= PreviewHistory::timedSince ? QVariantMap{{QStringLiteral("visitedAt"), page.at}} : QVariantMap{});
    }
  }
  return list;
}

void ThreadPreviews::newTab() {
  if (m_thread.isEmpty()) return;
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("preview.open"), QJsonObject{{QStringLiteral("threadId"), m_thread}},
                 [this, generation, environmentId = m_environment, threadId = m_thread](const QJsonValue& result,
                                                                                        const std::optional<QString>& error) {
                   if (environmentId != m_environment || threadId != m_thread) return;
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open a browser tab"), *error);
                     return;
                   }
                   // Its `opened` event may be behind the answer; a list read since has it.
                   if (generation == m_generation && result.isObject() && m_status == QLatin1String("ready")) upsert(result.toObject());
                   if (m_embedded && result.isObject()) emit showRequested(result.toObject().value(QLatin1String("tabId")).toString());
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
                 [this, generation, url, target, environmentId = m_environment, threadId = m_thread, mc = m_mc](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                     return;
                   }
                   if (generation == m_generation && result.isObject() && m_status == QLatin1String("ready")) upsert(result.toObject());
                   // Remembered as the user went there, though the page never loads here (opened in the user's browser).
                   if (environmentId == m_environment && threadId == m_thread) {
                     const QJsonObject snapshot = result.toObject();
                     m_newestStamp = std::max(m_newestStamp, stampOf(snapshot));
                     keep([&](PreviewHistory& history) {
                       return history.visit(m_project, target, QString(), loadedAt(snapshot));
                     });
                   }
                   // The thread it was asked for, though another may show by now;
                   // embedded, the tab's own page loads it.
                   if (!m_embedded) openFor(url, environmentId, threadId, mc);
                 });
}

void ThreadPreviews::openPage(const QUrl& url) {
  openThroughTab(url, m_environment, m_thread, m_mc, m_rows);
}

void ThreadPreviews::openAddress(const QString& address) {
  const QUrl url(address);
  // Embedded, a dev server on the thread's machine opens in a tab here: the
  // one showing it, else a new one. Another MC's machine's goes through its
  // forward to the user's browser, as below.
  if (m_embedded && loopback(url) && !m_thread.isEmpty() && !forwards(url, m_environment, m_thread, m_mc)) {
    // Rows being listed again (after a reconnect, say), or that a list failed
    // to read again, may be tabs the MC no longer has.
    const bool listed = m_status == QLatin1String("ready") && !m_listing;
    for (const QJsonObject& snapshot : std::as_const(m_rows)) {
      if (listed && QUrl(navOf(snapshot).value(QLatin1String("url")).toString()).matches(url, QUrl::StripTrailingSlash)) {
        emit showRequested(snapshot.value(QLatin1String("tabId")).toString());
        return;
      }
    }
    const int generation = m_generation;
    m_client->call(this, m_environment, QStringLiteral("preview.open"),
                   QJsonObject{{QStringLiteral("threadId"), m_thread}, {QStringLiteral("url"), url.toString()}},
                   [this, generation, environmentId = m_environment, threadId = m_thread](const QJsonValue& result,
                                                                                          const std::optional<QString>& error) {
                     if (error) {
                       m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                       return;
                     }
                     // Shown while its thread is, though the list was read again meanwhile.
                     if (environmentId != m_environment || threadId != m_thread || !result.isObject()) return;
                     if (generation == m_generation && m_status == QLatin1String("ready")) upsert(result.toObject());
                     emit showRequested(result.toObject().value(QLatin1String("tabId")).toString());
                   });
    return;
  }
  if (!forwards(url, m_environment, m_thread, m_mc)) {
    m_open(url);
    return;
  }
  // The rows are the thread's tabs only while they are followed; otherwise
  // the MC says which there are.
  if (m_active && !m_listing && m_status == QLatin1String("ready")) {
    openThroughTab(url, m_environment, m_thread, m_mc, m_rows);
    return;
  }
  m_client->call(this, m_environment, QStringLiteral("preview.list"), QJsonObject{{QStringLiteral("threadId"), m_thread}},
                 [this, url, environmentId = m_environment, threadId = m_thread, mc = m_mc](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                     return;
                   }
                   QList<QJsonObject> tabs;
                   for (const QJsonValue& session : result.toObject().value(QLatin1String("sessions")).toArray()) tabs.append(session.toObject());
                   openThroughTab(url, environmentId, threadId, mc, tabs);
                 });
}

void ThreadPreviews::openThroughTab(const QUrl& url, const QString& environmentId, const QString& threadId, const QString& mc,
                                    const QList<QJsonObject>& tabs) {
  // The thread's MC forwards only a port one of its tabs names, so a link
  // from elsewhere (a reply) gets a tab first.
  for (const QJsonObject& snapshot : tabs) {
    const QUrl at(navOf(snapshot).value(QLatin1String("url")).toString());
    if (loopback(at) && portOf(at) == portOf(url)) {
      openFor(url, environmentId, threadId, mc);
      return;
    }
  }
  const int generation = m_generation;
  m_client->call(this, environmentId, QStringLiteral("preview.open"),
                 QJsonObject{{QStringLiteral("threadId"), threadId}, {QStringLiteral("url"), url.toString()}},
                 [this, generation, url, environmentId, threadId, mc](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                     return;
                   }
                   // A row only for the thread shown: the list this follows may
                   // have come after the user went to another.
                   if (generation == m_generation && environmentId == m_environment && threadId == m_thread && result.isObject() &&
                       m_status == QLatin1String("ready")) {
                     upsert(result.toObject());
                   }
                   openFor(url, environmentId, threadId, mc);
                 });
}

bool ThreadPreviews::forwards(const QUrl& url, const QString& environmentId, const QString& threadId, const QString& mc) const {
  const QString connected = m_client->environment();
  // A thread on the connected MC, or on none the cluster knows, opens as it is,
  // and so does any when the connected MC is on another machine: its forward
  // would listen there.
  return loopback(url) && !threadId.isEmpty() && !mc.isEmpty() && !connected.isEmpty() && environmentId != connected &&
         (!m_connectedHere || m_connectedHere());
}

void ThreadPreviews::openFor(const QUrl& url, const QString& environmentId, const QString& threadId, const QString& mc) {
  if (!forwards(url, environmentId, threadId, mc)) {
    m_open(url);
    return;
  }
  const int port = portOf(url);
  m_client->call(this, m_client->environment(), QStringLiteral("preview.forward"),
                 QJsonObject{{QStringLiteral("environmentId"), environmentId}, {QStringLiteral("threadId"), threadId}, {QStringLiteral("port"), port}},
                 [this, url, port](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     m_notify(QStringLiteral("error"), QStringLiteral("Could not open the page"), *error);
                     return;
                   }
                   QUrl forwarded = url;
                   forwarded.setPort(result.toObject().value(QLatin1String("port")).toInt(port));
                   // The forward listens at 127.0.0.1, and at ::1 only where
                   // this machine has IPv6, never at 127.0.0.1's aliases.
                   if (!QHostAddress(forwarded.host()).isNull()) forwarded.setHost(QStringLiteral("127.0.0.1"));
                   m_open(forwarded);
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
                     if (revision <= m_revision) continue;
                     if (m_closing.contains(tabId)) {
                       if (event.value(QLatin1String("type")).toString() == QLatin1String("closed")) m_closing.remove(tabId);
                       continue;
                     }
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
                     QSet<QString> touched;
                     for (const QJsonObject& row : std::as_const(m_rows)) touched.insert(row.value(QLatin1String("tabId")).toString());
                     for (const QJsonObject& row : std::as_const(rows)) touched.insert(row.value(QLatin1String("tabId")).toString());
                     beginResetModel();
                     m_rows = rows;
                     endResetModel();
                     if (counted) emit countChanged();
                     for (const QString& tabId : std::as_const(touched)) emit tabChanged(tabId);
                   }
                   setStatus(QStringLiteral("ready"));
                   remember(m_rows, false);
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
  if (m_closing.contains(tabId)) {
    // Closed on the MC: a refusal of the user's close does not bring it back.
    if (event.value(QLatin1String("type")).toString() == QLatin1String("closed")) m_closing.remove(tabId);
    return;
  }
  const int row = rowOf(tabId);
  const auto before = row < 0 ? std::nullopt : std::optional(m_rows.at(row));
  const auto next = after(event, before);
  if (next) {
    // A visit when the tab loads a page, not when the tab showing it is
    // resized or its back and forward change (the MC restamps those too).
    const bool loaded = !before || loadedUrl(*before) != loadedUrl(*next);
    upsert(*next);
    remember({*next}, loaded);
  } else {
    remove(tabId);
  }
  // A tab someone opened just now (an agent, another window), not one listed.
  if (m_embedded && next && row < 0 && event.value(QLatin1String("type")).toString() == QLatin1String("opened")) emit showRequested(tabId);
}

void ThreadPreviews::open(const QString& tabId) {
  const int row = rowOf(tabId);
  if (row < 0) return;
  const QString url = navOf(m_rows.at(row)).value(QLatin1String("url")).toString();
  if (!url.isEmpty()) openAddress(url);
}

bool ThreadPreviews::opensHere(const QUrl& url) {
  return loopback(url);
}

void ThreadPreviews::show(const QString& tabId) {
  if (rowOf(tabId) >= 0) emit showRequested(tabId);
}

QJsonObject ThreadPreviews::tab(const QString& tabId) const {
  const int row = rowOf(tabId);
  return row < 0 ? QJsonObject() : m_rows.at(row);
}

void ThreadPreviews::report(const QString& tabId, const QJsonObject& navStatus, bool canGoBack, bool canGoForward, std::function<void()> unheard) {
  if (rowOf(tabId) < 0 || m_thread.isEmpty() || m_closing.contains(tabId)) return;
  // The MC's event says it back.
  m_client->call(this, m_environment, QStringLiteral("preview.reportStatus"),
                 QJsonObject{{QStringLiteral("threadId"), m_thread},
                             {QStringLiteral("tabId"), tabId},
                             {QStringLiteral("navStatus"), navStatus},
                             {QStringLiteral("canGoBack"), canGoBack},
                             {QStringLiteral("canGoForward"), canGoForward}},
                 [unheard](const QJsonValue&, const std::optional<QString>& error) {
                   if (error && unheard) unheard();
                 });
}

void ThreadPreviews::resizeTab(const QString& tabId, const QJsonObject& viewport, std::function<void(const std::optional<QString>&)> done) {
  if (rowOf(tabId) < 0 || m_thread.isEmpty()) {
    if (done) done(QStringLiteral("no such tab"));
    return;
  }
  // The tab's new size comes in the MC's `resized` event, in order with the
  // rest; the answer's snapshot may be older than an event read before it.
  m_client->call(this, m_environment, QStringLiteral("preview.resize"),
                 QJsonObject{{QStringLiteral("threadId"), m_thread}, {QStringLiteral("tabId"), tabId}, {QStringLiteral("viewport"), viewport}},
                 [this, done](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) m_notify(QStringLiteral("error"), QStringLiteral("Unable to resize browser viewport"), *error);
                   if (done) done(error);
                 });
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
                     emit tabChanged(tabId);
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
    emit tabChanged(snapshot.value(QLatin1String("tabId")).toString());
    return;
  }
  beginInsertRows({}, int(m_rows.size()), int(m_rows.size()));
  m_rows.append(snapshot);
  endInsertRows();
  emit countChanged();
  emit tabChanged(snapshot.value(QLatin1String("tabId")).toString());
}

void ThreadPreviews::remove(const QString& tabId) {
  const int row = rowOf(tabId);
  if (row < 0) return;
  beginRemoveRows({}, row, row);
  m_rows.removeAt(row);
  endRemoveRows();
  emit countChanged();
  emit tabChanged(tabId);
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
