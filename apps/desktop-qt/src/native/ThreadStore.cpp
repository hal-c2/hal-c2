#include "ThreadStore.h"

#include <QJsonArray>

#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellStore.h"

namespace {
const NativeControllerRegistrar<ThreadStore> registrar(QStringLiteral("threads"), {}, "Threads");
}

ThreadStore::ThreadStore(ShellBridge*, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_client(client), m_store(store) {
  connect(store, &ShellStore::changed, this, &ThreadStore::retry);
  connect(client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready) return retry();
    // What was loaded stays, without passing for live; the resubscription
    // that follows the reconnect says `live` again.
    for (const Followed& followed : std::as_const(m_threads)) {
      if (followed.subscription && followed.model) {
        followed.model->setStatus(QStringLiteral("unreachable"), tr("The connection to its environment dropped."));
      }
    }
  });
  m_idleTimer.setSingleShot(true);
  connect(&m_idleTimer, &QTimer::timeout, this, &ThreadStore::evictIdle);
}

QDateTime ThreadStore::now() const {
  return m_now ? m_now() : QDateTime::currentDateTimeUtc();
}

ThreadStore::~ThreadStore() {
  for (Followed& followed : m_threads) unfollow(followed);
}

void ThreadStore::activate() {
  // The open thread is the route's.
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  connect(navigation, &NavigationController::changed, this, [this, navigation] { open(navigation->threadKey()); });
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, &ThreadStore::readSettings);
  }
  readSettings();
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
  evictIdle();
}

void ThreadStore::setLocale(const QLocale& locale) {
  m_locale = locale;
  for (const Followed& followed : std::as_const(m_threads)) {
    if (followed.model) configure(followed.model);
  }
}

void ThreadStore::readSettings() {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  const QJsonValue format = settings ? settings->deviceSettings().value(QLatin1String("timestampFormat")) : QJsonValue();
  m_timestampFormat = format.isString() && !format.toString().isEmpty() ? format.toString() : QStringLiteral("locale");
  for (const Followed& followed : std::as_const(m_threads)) {
    if (followed.model) configure(followed.model);
  }
}

void ThreadStore::configure(TimelineModel* model) const {
  model->setTimestampFormat(m_timestampFormat);
  model->setLocale(m_locale);
  // The other threads of its environment, by the titles the shell lists.
  const QString key = model->threadKey();
  const QString environment = key.left(key.indexOf(QLatin1Char(':')) + 1);
  model->setThreadTitles([store = m_store, environment](const QString& threadId) {
    return store->threadRow(environment + threadId).value(QLatin1String("title")).toString();
  });
}

void ThreadStore::open(const QString& threadKey) {
  if (threadKey == m_active) return;
  if (!m_active.isEmpty() && m_threads.contains(m_active)) m_leftAt.insert(m_active, now());
  // One left too long ago is loaded again, the one being opened included.
  m_active.clear();
  evictIdle();
  m_active = threadKey;
  m_leftAt.remove(threadKey);
  if (!threadKey.isEmpty()) {
    m_recent.removeOne(threadKey);
    m_recent.prepend(threadKey);
    if (!m_threads.contains(threadKey)) {
      Followed& followed = m_threads[threadKey];
      followed.model = new TimelineModel(threadKey, this);
      if (m_now) followed.model->setClock(m_now);
      configure(followed.model);
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
  m_leftAt.remove(threadKey);
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

void ThreadStore::forgetRemoved() {
  if (!m_store->synchronized()) return;
  for (const QString& key : m_threads.keys()) {
    if (m_threads.value(key).listed && !m_store->reaches(key.left(key.indexOf(QLatin1Char(':'))))) close(key);
  }
}

void ThreadStore::evictIdle() {
  const QDateTime time = now();
  qint64 next = -1;
  for (const QString& key : m_leftAt.keys()) {
    const qint64 left = idleSeconds - m_leftAt.value(key).secsTo(time);
    if (left <= 0) {
      close(key);
    } else if (next < 0 || left < next) {
      next = left;
    }
  }
  if (next > 0) {
    m_idleTimer.start(int(next) * 1000);
  } else {
    m_idleTimer.stop();
  }
}

void ThreadStore::follow(const QString& threadKey) {
  Followed& followed = m_threads[threadKey];
  if (followed.subscription) return;
  if (!m_store->thread(threadKey)) return;  // not in the sidebar yet: ShellStore::changed retries
  followed.waitOnline = false;
  followed.listed = true;
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
    // The MC ends a refused subscription itself; forget it and retry when
    // the MC (or the connection) comes back.
    unfollow(*it);
    it->waitOnline = !m_store->threadOnline(threadKey);
    const QString reason = frame.value(QLatin1String("reason")).toString();
    model->setStatus(QStringLiteral("unreachable"),
                     reason.isEmpty() ? QStringLiteral("The MC stopped sending this thread.") : reason);
  }
}

// Follows the open threads that are not: ones the sidebar did not list yet,
// and unreachable ones whose MC is online again or whose connection is back.
void ThreadStore::retry() {
  forgetRemoved();
  if (!m_client->isReady()) return;
  for (auto it = m_threads.begin(); it != m_threads.end(); ++it) {
    if (it->subscription || !it->model) continue;
    if (it->waitOnline && !m_store->threadOnline(it.key())) continue;
    follow(it.key());
  }
}
