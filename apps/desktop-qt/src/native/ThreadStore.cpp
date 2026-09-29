#include "ThreadStore.h"

#include <QJsonArray>

#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellStore.h"

namespace {
const NativeControllerRegistrar<ThreadStore> registrar(QStringLiteral("threads"), {}, "Threads");
}

ThreadStore::ThreadStore(ShellBridge*, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_client(client), m_store(store) {
  connect(store, &ShellStore::changed, this, &ThreadStore::retry);
  connect(client, &NodeClient::readyChanged, this, [this](bool ready) {
    if (ready) retry();
  });
}

ThreadStore::~ThreadStore() {
  for (Followed& followed : m_threads) unfollow(followed);
}

void ThreadStore::activate() {
  // The open thread is the route's.
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  connect(navigation, &NavigationController::changed, this, [this, navigation] { open(navigation->threadKey()); });
  open(navigation->threadKey());
  retry();
}

QJsonObject ThreadStore::streamShape(const QString& environmentId, const QString& threadId) {
  return {{QStringLiteral("type"), QStringLiteral("stream")},
          {QStringLiteral("environment"), environmentId},
          {QStringLiteral("stream"), threadId}};
}

TimelineModel* ThreadStore::timeline(const QString& threadKey) const {
  return m_threads.value(threadKey).model.data();
}

void ThreadStore::setClock(std::function<QDateTime()> now) {
  m_now = std::move(now);
  for (const Followed& followed : std::as_const(m_threads)) {
    if (followed.model && m_now) followed.model->setClock(m_now);
  }
}

void ThreadStore::open(const QString& threadKey) {
  if (threadKey == m_active) return;
  m_active = threadKey;
  if (!threadKey.isEmpty()) {
    m_recent.removeOne(threadKey);
    m_recent.prepend(threadKey);
    if (!m_threads.contains(threadKey)) {
      Followed& followed = m_threads[threadKey];
      followed.model = new TimelineModel(threadKey, this);
      if (m_now) followed.model->setClock(m_now);
      follow(threadKey);
    }
    evict();
  }
  emit activeThreadChanged();
}

void ThreadStore::close(const QString& threadKey) {
  const auto it = m_threads.find(threadKey);
  if (it == m_threads.end()) return;
  unfollow(*it);
  TimelineModel* model = it->model;
  m_threads.erase(it);
  m_recent.removeOne(threadKey);
  const bool wasActive = threadKey == m_active;
  if (wasActive) {
    m_active.clear();
    emit activeThreadChanged();
  }
  if (model) model->deleteLater();
}

void ThreadStore::reload(const QString& threadKey) {
  const auto it = m_threads.find(threadKey);
  if (it == m_threads.end() || !it->model) return;
  unfollow(*it);
  it->waitOnline = false;
  it->model->setStatus(QStringLiteral("loading"));
  follow(threadKey);
}

void ThreadStore::evict() {
  while (m_recent.size() > warmThreads + 1) close(m_recent.last());
}

void ThreadStore::follow(const QString& threadKey) {
  Followed& followed = m_threads[threadKey];
  if (followed.subscription) return;
  if (!m_store->thread(threadKey)) return;  // not in the sidebar yet: ShellStore::changed retries
  followed.waitOnline = false;
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  followed.subscription = m_client->subscribe(this, streamShape(threadKey.left(colon), threadKey.mid(colon + 1)),
                                              [this, threadKey](const QJsonObject& frame) { onFrame(threadKey, frame); });
}

void ThreadStore::unfollow(Followed& followed) {
  if (followed.subscription) m_client->unsubscribe(std::exchange(followed.subscription, 0));
}

void ThreadStore::onFrame(const QString& threadKey, const QJsonObject& frame) {
  const auto it = m_threads.find(threadKey);
  if (it == m_threads.end() || !it->model) return;
  TimelineModel* model = it->model;
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("snapshot")) {
    model->snapshot(frame.value(QLatin1String("part")).toInt(), frame.value(QLatin1String("rows")).toArray(),
                    frame.value(QLatin1String("done")).toBool());
  } else if (type == QLatin1String("events")) {
    model->events(frame.value(QLatin1String("events")).toArray());
  } else if (type == QLatin1String("live")) {
    model->setStatus(QStringLiteral("live"));
  } else if (type == QLatin1String("error") || type == QLatin1String("end")) {
    // The node ends a refused subscription itself; forget it and retry when
    // the node (or the connection) comes back.
    unfollow(*it);
    it->waitOnline = !m_store->threadOnline(threadKey);
    const QString reason = frame.value(QLatin1String("reason")).toString();
    model->setStatus(QStringLiteral("unreachable"),
                     reason.isEmpty() ? QStringLiteral("The node stopped sending this thread.") : reason);
  }
}

// Follows the open threads that are not: ones the sidebar did not list yet,
// and unreachable ones whose node is online again or whose connection is back.
void ThreadStore::retry() {
  if (!m_client->isReady()) return;
  for (auto it = m_threads.begin(); it != m_threads.end(); ++it) {
    if (it->subscription || !it->model) continue;
    if (it->waitOnline && !m_store->threadOnline(it.key())) continue;
    follow(it.key());
  }
}
