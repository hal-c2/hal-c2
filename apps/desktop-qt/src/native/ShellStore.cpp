#include "ShellStore.h"

#include <QJsonArray>

#include <algorithm>

#include "JsonNumbers.h"
#include "McClient.h"

namespace {

// The MC's rows of `kind`, or nothing for kinds the shell does not fold.
QHash<QString, QJsonObject>* rowsOf(auto& mc, const QString& kind) {
  if (kind == QLatin1String("thread")) return &mc.threads;
  if (kind == QLatin1String("project")) return &mc.projects;
  return nullptr;
}

bool removed(const QJsonObject& row) {
  const QJsonValue deletedAt = row.value(QLatin1String("deletedAt"));
  return row.isEmpty() || (!deletedAt.isUndefined() && !deletedAt.isNull());
}

QString threadKey(const QString& environmentId, const QString& threadId) {
  return environmentId + QLatin1Char(':') + threadId;
}

}  // namespace

ShellStore::ShellStore(McClient* client, QObject* parent) : QObject(parent) {
  m_flushTimer.setSingleShot(true);
  m_flushTimer.setInterval(flushDelayMs);
  connect(&m_flushTimer, &QTimer::timeout, this, &ShellStore::flush);
  client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("shell")}}, [this](const QJsonObject& frame) { onFrame(frame); },
                    [this] { return QJsonObject{{QStringLiteral("have"), have()}}; });
}

ShellStore::~ShellStore() {
  flush();
}

void ShellStore::showKept() {
  if (!m_cache || !m_origin.isEmpty()) return;
  const cache::Shell kept = m_cache->shell();
  if (!kept.origin.isEmpty()) hold(kept, kept.origin);
}

void ShellStore::open(const QUrl& origin) {
  const QString key = origin.adjusted(QUrl::RemoveUserInfo | QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment).toString();
  // The MC whose rows are held, kept or its own, stays as it is.
  if (key == m_origin) return;
  flush();
  const bool another = !m_origin.isEmpty();
  hold(m_cache ? m_cache->shell(key) : cache::Shell(), key);
  // What was shown of the MC it held before is not this one's.
  if (another) emit originChanged();
}

void ShellStore::hold(const cache::Shell& kept, const QString& origin) {
  m_origin = origin;
  const bool held = !m_mcs.isEmpty();
  m_mcs.clear();
  m_synchronized = false;
  m_previewing = false;
  for (const cache::ShellMc& mc : kept.mcs) {
    setEnvironment(mc.mc, mc.environment);
    Mc& entry = m_mcs[mc.mc];
    entry.epoch = mc.epoch;
    entry.rev = mc.rev;
    for (const cache::ShellRow& row : mc.rows) {
      if (auto* rows = rowsOf(entry, row.kind)) rows->insert(row.id, row.fields);
    }
    m_previewing = true;
  }
  // Read, not changed: nothing of it is owed to the cache.
  m_unsaved.clear();
  m_flushTimer.stop();
  if (held || m_previewing) emit changed();
}

QJsonObject ShellStore::have() const {
  QJsonObject have;
  for (auto it = m_mcs.cbegin(); it != m_mcs.cend(); ++it) {
    if (!it->epoch.isEmpty()) have.insert(it.key(), QJsonArray{it->epoch, it->rev});
  }
  return have;
}

ShellStore::Unsaved& ShellStore::unsaved(const QString& mc) {
  if (!m_flushTimer.isActive()) m_flushTimer.start();
  return m_unsaved[mc];
}

void ShellStore::flush() {
  m_flushTimer.stop();
  const QHash<QString, Unsaved> unsaved = std::exchange(m_unsaved, {});
  if (!m_cache || m_origin.isEmpty() || unsaved.isEmpty()) return;
  QList<cache::ShellMcUpdate> updates;
  for (auto it = unsaved.cbegin(); it != unsaved.cend(); ++it) {
    const auto mc = m_mcs.constFind(it.key());
    if (mc == m_mcs.cend()) {
      updates.append({it.key(), true, false, {}, 0, {}, {}, {}});
    } else {
      updates.append({it.key(), false, it->reset, mc->epoch, mc->rev, mc->environment, it->put.values(), it->gone.values()});
    }
  }
  m_cache->storeShell(m_origin, updates);
}

QList<sidebar::Thread> ShellStore::threads() const {
  QList<sidebar::Thread> result;
  for (const Mc& mc : m_mcs) {
    // An MC whose environment is not known yet has no key for its threads.
    if (mc.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : mc.threads) {
      if (lives(row)) result.append(sidebar::threadFromRow(mc.environmentId, row));
    }
  }
  return result;
}

bool ShellStore::lives(const QJsonObject& row) const {
  if (row.value(QLatin1String("movedTo")).isObject()) return false;
  const QJsonObject moving = row.value(QLatin1String("moving")).toObject();
  if (moving.isEmpty()) return true;
  const QString destination = moving.value(QLatin1String("environmentId")).toString();
  const QString id = row.value(QLatin1String("id")).toString();
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != destination) continue;
    const auto arrived = mc.threads.constFind(id);
    return arrived == mc.threads.constEnd() || arrived->value(QLatin1String("movedTo")).isObject();
  }
  return true;
}

QString ShellStore::located(const QString& key) const {
  const QJsonObject row = threadRow(key);
  if (row.isEmpty() || lives(row)) return key;
  const QString id = key.mid(key.indexOf(QLatin1Char(':')) + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId.isEmpty()) continue;
    const auto found = mc.threads.constFind(id);
    if (found != mc.threads.constEnd() && lives(*found)) return threadKey(mc.environmentId, id);
  }
  // Its new machine's rows have not arrived yet: where the record points.
  const QString environmentId = row.value(QLatin1String("movedTo")).toObject().value(QLatin1String("environmentId")).toString();
  return environmentId.isEmpty() ? key : threadKey(environmentId, id);
}

QList<sidebar::Project> ShellStore::projects() const {
  QList<sidebar::Project> result;
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : mc.projects) result.append(sidebar::projectFromRow(mc.environmentId, row));
  }
  // Row hashes have no order; the web app lists projects by creation.
  std::stable_sort(result.begin(), result.end(), [](const sidebar::Project& left, const sidebar::Project& right) {
    if (left.createdAt != right.createdAt) return left.createdAt < right.createdAt;
    return left.key() < right.key();
  });
  return result;
}

std::optional<sidebar::Project> ShellStore::project(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return std::nullopt;
  const QString environmentId = key.left(colon);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    const auto row = mc.projects.constFind(key.mid(colon + 1));
    if (row != mc.projects.constEnd()) return sidebar::projectFromRow(environmentId, *row);
  }
  return std::nullopt;
}

bool ShellStore::servesEnvironment(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return true;
  }
  return false;
}

// Rows as `shell.rows` carries them: each [id, kind, fields].
void ShellStore::putRows(const QString& mc, const QJsonArray& rows) {
  for (const QJsonValue& value : rows) {
    const QJsonArray row = value.toArray();
    putRow(mc, row.at(0).toString(), row.at(1).toString(), row.at(2).toObject());
  }
}

void ShellStore::putRow(const QString& mc, const QString& id, const QString& kind, const QJsonObject& fields) {
  Mc& entry = m_mcs[mc];
  auto* kept = rowsOf(entry, kind);
  if (!kept) return;
  Unsaved& change = unsaved(mc);
  if (removed(fields)) {
    kept->remove(id);
    change.put.remove(id);
    if (!change.reset) change.gone.insert(id);
    // A deleted thread is not coming back to be read.
    if (m_cache && kind == QLatin1String("thread") && !entry.environmentId.isEmpty()) m_cache->forgetThread(threadKey(entry.environmentId, id));
  } else {
    kept->insert(id, fields);
    change.gone.remove(id);
    change.put.insert(id, {id, kind, fields});
  }
}

void ShellStore::setVersion(const QString& mc, const QJsonValue& epoch, const QJsonValue& rev) {
  Mc& entry = m_mcs[mc];
  // A rev that is no whole number in range reads as no rev: the MC is unversioned.
  const std::optional<qint64> number = jsonnumbers::integerOf(rev);
  const bool versioned = epoch.isString() && !epoch.toString().isEmpty() && number;
  entry.epoch = versioned ? epoch.toString() : QString();
  entry.rev = versioned ? *number : 0;
  unsaved(mc);
}

void ShellStore::resetRows(const QString& mc, QSet<QString>& threads) {
  Mc& entry = m_mcs[mc];
  if (!entry.environmentId.isEmpty()) {
    for (auto it = entry.threads.cbegin(); it != entry.threads.cend(); ++it) threads.insert(threadKey(entry.environmentId, it.key()));
  }
  entry.threads.clear();
  entry.projects.clear();
  Unsaved& change = unsaved(mc);
  change.reset = true;
  change.put.clear();
  change.gone.clear();
}

void ShellStore::removeMc(const QString& mc) {
  const QString environmentId = m_mcs.take(mc).environmentId;
  Unsaved& change = unsaved(mc);
  change = {};
  change.reset = true;
  // Its threads go with it, unless another MC serves the environment now
  // (an MC's name changes when it joins a cluster).
  if (m_cache && !environmentId.isEmpty() && !servesEnvironment(environmentId)) m_cache->forgetEnvironment(environmentId);
}

void ShellStore::forgetThreads(const QSet<QString>& threads) {
  if (!m_cache) return;
  for (const QString& key : threads) {
    if (threadRow(key).isEmpty()) m_cache->forgetThread(key);
  }
}

std::optional<sidebar::Thread> ShellStore::thread(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return std::nullopt;
  const QString environmentId = key.left(colon);
  const QString threadId = key.mid(colon + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    const auto row = mc.threads.constFind(threadId);
    if (row != mc.threads.constEnd() && lives(*row)) return sidebar::threadFromRow(environmentId, *row);
  }
  return std::nullopt;
}

QJsonObject ShellStore::threadRow(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return {};
  const QString environmentId = key.left(colon);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.threads.value(key.mid(colon + 1));
  }
  return {};
}

QJsonObject ShellStore::projectRow(const QString& environmentId, const QString& projectId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.projects.value(projectId);
  }
  return {};
}

QList<QJsonObject> ShellStore::projectRows(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.projects.values();
  }
  return {};
}

QStringList ShellStore::environments() const {
  QStringList result;
  for (const Mc& mc : m_mcs) {
    if (!mc.environmentId.isEmpty()) result.append(mc.environmentId);
  }
  return result;
}

QJsonObject ShellStore::environment(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.environment;
  }
  return {};
}

QString ShellStore::mcServing(const QString& environmentId) const {
  for (auto it = m_mcs.cbegin(); it != m_mcs.cend(); ++it) {
    if (it->environmentId == environmentId) return it.key();
  }
  return {};
}

bool ShellStore::threadOnline(const QString& threadKey) const {
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  if (colon <= 0) return false;
  const QString environmentId = threadKey.left(colon);
  const QString threadId = threadKey.mid(colon + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId && mc.threads.contains(threadId)) return mc.online;
  }
  return false;
}

bool ShellStore::environmentOnline(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.online;
  }
  return false;
}

sidebar::Capabilities ShellStore::capabilities(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    return {mc.capabilities.value(QLatin1String("threadSettlement")).toBool(),
            mc.capabilities.value(QLatin1String("threadSnooze")).toBool(),
            mc.capabilities.value(QLatin1String("threadVisitedTracking")).toBool(),
            mc.capabilities.value(QLatin1String("threadPinning")).toBool(),
            mc.capabilities.value(QLatin1String("threadTitleRegeneration")).toBool()};
  }
  return {};
}

bool ShellStore::supports(const QString& environmentId, const QString& capability) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.capabilities.value(capability).toBool();
  }
  return false;
}

void ShellStore::setEnvironment(const QString& mc, const QJsonObject& environment) {
  Mc& entry = m_mcs[mc];
  entry.environmentId = environment.value(QLatin1String("environmentId")).toString();
  entry.capabilities = environment.value(QLatin1String("capabilities")).toObject();
  entry.environment = environment;
  unsaved(mc);
  // An environment is one machine, served by one MC: another listed with it is
  // that machine under a former name (its node name changes when it becomes
  // distributed), and goes, as the MC forgets it (lib/hal_c2/shell.ex
  // forget_former_names). So a thread's key names one row.
  const QString environmentId = entry.environmentId;
  if (environmentId.isEmpty()) return;
  QStringList former;
  for (auto it = m_mcs.cbegin(); it != m_mcs.cend(); ++it) {
    if (it.key() != mc && it->environmentId == environmentId) former.append(it.key());
  }
  for (const QString& name : former) removeMc(name);
}

void ShellStore::takeRows(const QString& mc, const QString& former) {
  if (former.isEmpty() || former == mc) return;
  const Mc old = m_mcs.value(former);
  Mc& entry = m_mcs[mc];
  if (!entry.threads.isEmpty() || !entry.projects.isEmpty()) return;
  entry.threads = old.threads;
  entry.projects = old.projects;
  Unsaved& change = unsaved(mc);
  change.reset = true;
  for (auto it = old.threads.cbegin(); it != old.threads.cend(); ++it) change.put.insert(it.key(), {it.key(), QStringLiteral("thread"), *it});
  for (auto it = old.projects.cbegin(); it != old.projects.cend(); ++it) change.put.insert(it.key(), {it.key(), QStringLiteral("project"), *it});
}

bool ShellStore::clear() {
  // Nothing of it is owed to the cache any more, and nothing is kept there.
  m_flushTimer.stop();
  m_unsaved.clear();
  m_origin.clear();
  m_mcs.clear();
  m_problem.clear();
  m_previewing = false;
  m_synchronized = true;
  // The threads shown go first (ThreadStore), so nothing of theirs is written
  // after the cache is emptied.
  emit originChanged();
  const bool emptied = !m_cache || m_cache->clear();
  emit changed();
  return emptied;
}

void ShellStore::onFrame(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  // Every member, row and change is of an MC by its node name; one that names
  // none is of no member, and changes nothing.
  const QString mc = frame.value(QLatin1String("mc")).toString();
  if (type.startsWith(QLatin1String("shell.")) && mc.isEmpty()) return;
  if (type == QLatin1String("shell")) {
    // The cluster's members, and the rows this client lacks of each: all of
    // them for an MC marked `reset` (or sent by an MC that keeps no versions),
    // else the ones changed since the `have` it was sent.
    QSet<QString> listed;
    QSet<QString> replaced;
    for (const QJsonValue& value : frame.value(QLatin1String("mcs")).toArray()) {
      const QJsonObject member = value.toObject();
      const QString name = member.value(QLatin1String("mc")).toString();
      if (name.isEmpty()) continue;
      listed.insert(name);
      if (member.value(QLatin1String("reset")).toBool(true)) resetRows(name, replaced);
      setEnvironment(name, member.value(QLatin1String("environment")).toObject());
      m_mcs[name].online = member.value(QLatin1String("online")).toBool();
      setVersion(name, member.value(QLatin1String("epoch")), member.value(QLatin1String("rev")));
    }
    for (const QString& name : m_mcs.keys()) {
      if (!listed.contains(name)) removeMc(name);
    }
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      // Rows are of the members listed.
      if (!listed.contains(row.at(0).toString())) continue;
      putRow(row.at(0).toString(), row.at(1).toString(), row.at(2).toString(), row.at(3).toObject());
    }
    forgetThreads(replaced);
    m_synchronized = true;
    m_previewing = false;
    ++m_snapshots;
    m_problem.clear();
    flush();
  } else if (type == QLatin1String("error")) {
    m_problem = frame.value(QLatin1String("reason")).toString(QStringLiteral("The MC did not send its projects and threads."));
  } else if (type == QLatin1String("shell.environment")) {
    const QJsonObject environment = frame.value(QLatin1String("environment")).toObject();
    const QString environmentId = environment.value(QLatin1String("environmentId")).toString();
    if (!environmentId.isEmpty()) takeRows(mc, mcServing(environmentId));
    setEnvironment(mc, environment);
  } else if (type == QLatin1String("shell.mc")) {
    // A machine removed from the cluster takes its rows with it; an offline one keeps them.
    if (frame.value(QLatin1String("removed")).toBool()) {
      removeMc(mc);
    } else {
      m_mcs[mc].online = frame.value(QLatin1String("online")).toBool();
    }
  } else if (type == QLatin1String("shell.rows")) {
    QSet<QString> replaced;
    if (frame.value(QLatin1String("reset")).toBool()) resetRows(mc, replaced);
    putRows(mc, frame.value(QLatin1String("rows")).toArray());
    // They bring the MC's rows to this version; a frame without one leaves none to resume from.
    setVersion(mc, frame.value(QLatin1String("epoch")), frame.value(QLatin1String("rev")));
    forgetThreads(replaced);
  } else {
    return;
  }
  emit changed();
}
