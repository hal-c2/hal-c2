#include "LocalCache.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QPointer>
#include <QSet>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QThread>
#include <QUuid>
#include <QVariant>
#include <QtLogging>

#include <utility>

namespace {

const char* const kTables[] = {
    // The sidebar, by the origin the client was opened at.
    "CREATE TABLE shell_mcs(origin TEXT NOT NULL, mc TEXT NOT NULL, epoch TEXT, rev INTEGER, environment BLOB NOT NULL,"
    " PRIMARY KEY(origin, mc)) WITHOUT ROWID",
    "CREATE TABLE shell_rows(origin TEXT NOT NULL, mc TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL, row BLOB NOT NULL,"
    " PRIMARY KEY(origin, mc, id)) WITHOUT ROWID",
    // Threads by "environmentId:threadId"; `used` orders them by when they were last opened.
    "CREATE TABLE threads(key TEXT PRIMARY KEY, handle TEXT NOT NULL, cursor INTEGER NOT NULL, floor INTEGER, used INTEGER NOT NULL)"
    " WITHOUT ROWID",
    "CREATE TABLE entities(thread TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, run_ord INTEGER, json BLOB NOT NULL,"
    " PRIMARY KEY(thread, kind, id)) WITHOUT ROWID",
};

QByteArray json(const QJsonObject& object) {
  return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

QJsonObject object(const QVariant& value) {
  return QJsonDocument::fromJson(value.toByteArray()).object();
}

QVariant ordinal(const std::optional<qint64>& value) {
  return value ? QVariant(*value) : QVariant(QMetaType::fromType<qlonglong>());
}

// Prepares and runs one statement; a failure is logged and false.
bool run(QSqlQuery& query, const QString& sql, const QVariantList& values = {}) {
  if (!query.prepare(sql)) {
    qWarning("[cache] %s: %s", qPrintable(sql), qPrintable(query.lastError().text()));
    return false;
  }
  for (const QVariant& value : values) query.addBindValue(value);
  if (query.exec()) return true;
  qWarning("[cache] %s: %s", qPrintable(sql), qPrintable(query.lastError().text()));
  return false;
}

bool run(QSqlDatabase& db, const QString& sql, const QVariantList& values = {}) {
  QSqlQuery query(db);
  return run(query, sql, values);
}

// Runs `change` so that it lands whole or not at all; `otherwise` then tidies
// up what a half-applied change would have left wrong.
void whole(QSqlDatabase& db, const std::function<bool()>& change, const std::function<void()>& otherwise) {
  run(db, QStringLiteral("SAVEPOINT change"));
  if (!change()) {
    run(db, QStringLiteral("ROLLBACK TO change"));
    otherwise();
  }
  run(db, QStringLiteral("RELEASE change"));
}

// A copy is what its cursor says it is, so the cursor goes first: rows left
// without one are no copy, while a cursor left without its rows would pass
// for a whole one. False when the cursor could not be taken away.
bool dropThread(QSqlDatabase& db, const QString& key) {
  if (!run(db, QStringLiteral("DELETE FROM threads WHERE key = ?"), {key})) return false;
  run(db, QStringLiteral("DELETE FROM entities WHERE thread = ?"), {key});
  return true;
}

// The thread list kept of one MC goes the same way: its versions first.
bool dropShell(QSqlDatabase& db, const QString& origin) {
  if (!run(db, QStringLiteral("DELETE FROM shell_mcs WHERE origin = ?"), {origin})) return false;
  run(db, QStringLiteral("DELETE FROM shell_rows WHERE origin = ?"), {origin});
  return true;
}

// What can no longer be vouched for: a copy that missed a change and could
// not be dropped either. It is not read, and not changed, until it can be
// dropped. One record per worker thread, which is one per cache.
struct Lost {
  QSet<QString> threads;  // by key
  QSet<QString> shells;   // by origin
  // After a commit that failed: every copy, until all of them are dropped.
  bool everything = false;
};

Lost& lost() {
  thread_local Lost record;
  return record;
}

// Every copy goes, cursors and versions first; whether all of them did.
bool dropEverything(QSqlDatabase& db) {
  const bool threads = run(db, QStringLiteral("DELETE FROM threads"));
  if (threads) run(db, QStringLiteral("DELETE FROM entities"));
  const bool shells = run(db, QStringLiteral("DELETE FROM shell_mcs"));
  if (shells) run(db, QStringLiteral("DELETE FROM shell_rows"));
  if (!threads || !shells) return false;
  lost() = {};
  return true;
}

// Whether the cache holds anything to read or to bring up to date: always,
// but after a failed commit only once everything it held is dropped.
bool usable(QSqlDatabase& db) {
  return !lost().everything || dropEverything(db);
}

QVariant nextUse(QSqlDatabase& db) {
  QSqlQuery query(db);
  if (run(query, QStringLiteral("SELECT COALESCE(MAX(used), 0) + 1 FROM threads")) && query.next()) return query.value(0);
  return 1;
}

bool applyThread(QSqlDatabase& db, const cache::ThreadUpdate& update) {
  const QVariant floor = ordinal(update.cursor.floor);
  if (update.replace) {
    if (!run(db, QStringLiteral("DELETE FROM entities WHERE thread = ?"), {update.key})) return false;
    if (!run(db, QStringLiteral("INSERT OR REPLACE INTO threads(key, handle, cursor, floor, used) VALUES(?, ?, ?, ?, ?)"),
             {update.key, update.cursor.handle, update.cursor.offset, floor, nextUse(db)})) {
      return false;
    }
  } else {
    QSqlQuery cursor(db);
    if (!run(cursor, QStringLiteral("UPDATE threads SET handle = ?, cursor = ?, floor = ? WHERE key = ?"),
             {update.cursor.handle, update.cursor.offset, floor, update.key})) {
      return false;
    }
    // Forgotten since (its thread was deleted, or others pushed it out):
    // there is no copy for the change to bring up to date.
    if (cursor.numRowsAffected() == 0) return true;
  }
  QSqlQuery gone(db);
  if (!gone.prepare(QStringLiteral("DELETE FROM entities WHERE thread = ? AND kind = ? AND id = ?"))) return false;
  for (const auto& [kind, id] : update.gone) {
    gone.addBindValue(update.key);
    gone.addBindValue(kind);
    gone.addBindValue(id);
    if (!gone.exec()) return false;
  }
  QSqlQuery put(db);
  if (!put.prepare(QStringLiteral("INSERT OR REPLACE INTO entities(thread, kind, id, run_ord, json) VALUES(?, ?, ?, ?, ?)"))) return false;
  for (const cache::Entity& entity : update.put) {
    put.addBindValue(update.key);
    put.addBindValue(entity.kind);
    put.addBindValue(entity.id);
    put.addBindValue(ordinal(entity.run));
    put.addBindValue(json(entity.fields));
    if (!put.exec()) return false;
  }
  if (!update.replace) return true;
  // A thread just stored may push the least recently opened ones out.
  QSqlQuery old(db);
  if (!run(old, QStringLiteral("SELECT key FROM threads ORDER BY used DESC LIMIT -1 OFFSET ?"), {LocalCache::kThreads})) return false;
  QStringList evicted;
  while (old.next()) evicted.append(old.value(0).toString());
  for (const QString& key : std::as_const(evicted)) dropThread(db, key);
  return true;
}

cache::Thread readThread(QSqlDatabase& db, const QString& key) {
  cache::Thread thread;
  QSqlQuery cursor(db);
  if (!run(cursor, QStringLiteral("SELECT handle, cursor, floor FROM threads WHERE key = ?"), {key}) || !cursor.next()) return thread;
  thread.cursor.handle = cursor.value(0).toString();
  thread.cursor.offset = cursor.value(1).toLongLong();
  if (!cursor.value(2).isNull()) thread.cursor.floor = cursor.value(2).toLongLong();
  run(db, QStringLiteral("UPDATE threads SET used = ? WHERE key = ?"), {nextUse(db), key});
  QSqlQuery rows(db);
  rows.setForwardOnly(true);
  if (!run(rows, QStringLiteral("SELECT kind, id, run_ord, json FROM entities WHERE thread = ?"), {key})) return {};
  while (rows.next()) {
    cache::Entity entity{rows.value(0).toString(), rows.value(1).toString(), object(rows.value(3)), std::nullopt};
    if (!rows.value(2).isNull()) entity.run = rows.value(2).toLongLong();
    thread.entities.append(std::move(entity));
  }
  return thread;
}

bool applyShell(QSqlDatabase& db, const QString& origin, const QList<cache::ShellMcUpdate>& mcs) {
  QSqlQuery put(db);
  if (!put.prepare(QStringLiteral("INSERT OR REPLACE INTO shell_rows(origin, mc, id, kind, row) VALUES(?, ?, ?, ?, ?)"))) return false;
  QSqlQuery gone(db);
  if (!gone.prepare(QStringLiteral("DELETE FROM shell_rows WHERE origin = ? AND mc = ? AND id = ?"))) return false;
  for (const cache::ShellMcUpdate& mc : mcs) {
    if ((mc.removed || mc.reset) && !run(db, QStringLiteral("DELETE FROM shell_rows WHERE origin = ? AND mc = ?"), {origin, mc.mc})) return false;
    if (mc.removed) {
      if (!run(db, QStringLiteral("DELETE FROM shell_mcs WHERE origin = ? AND mc = ?"), {origin, mc.mc})) return false;
      continue;
    }
    const QVariant epoch = mc.epoch.isEmpty() ? QVariant(QMetaType::fromType<QString>()) : QVariant(mc.epoch);
    if (mc.reset) {
      if (!run(db, QStringLiteral("INSERT OR REPLACE INTO shell_mcs(origin, mc, epoch, rev, environment) VALUES(?, ?, ?, ?, ?)"),
               {origin, mc.mc, epoch, mc.rev, json(mc.environment)})) {
        return false;
      }
    } else {
      QSqlQuery version(db);
      if (!run(version, QStringLiteral("UPDATE shell_mcs SET epoch = ?, rev = ?, environment = ? WHERE origin = ? AND mc = ?"),
               {epoch, mc.rev, json(mc.environment), origin, mc.mc})) {
        return false;
      }
      // Only the rows that changed, for an MC whose rows are not kept (they
      // were dropped): kept, they would pass for all of its rows.
      if (version.numRowsAffected() == 0) continue;
    }
    for (const QString& id : mc.gone) {
      gone.addBindValue(origin);
      gone.addBindValue(mc.mc);
      gone.addBindValue(id);
      if (!gone.exec()) return false;
    }
    for (const cache::ShellRow& row : mc.put) {
      put.addBindValue(origin);
      put.addBindValue(mc.mc);
      put.addBindValue(row.id);
      put.addBindValue(row.kind);
      put.addBindValue(json(row.fields));
      if (!put.exec()) return false;
    }
  }
  return true;
}

cache::Shell readShell(QSqlDatabase& db, QString origin) {
  if (origin.isEmpty()) {
    QSqlQuery last(db);
    if (!run(last, QStringLiteral("SELECT origin FROM shell_mcs LIMIT 1")) || !last.next()) return {};
    origin = last.value(0).toString();
  } else {
    // One MC's sidebar is kept: the one the client was last opened at.
    if (run(db, QStringLiteral("DELETE FROM shell_mcs WHERE origin <> ?"), {origin})) {
      run(db, QStringLiteral("DELETE FROM shell_rows WHERE origin <> ?"), {origin});
    }
  }
  if (lost().shells.contains(origin)) return {};
  cache::Shell shell;
  QSqlQuery members(db);
  if (!run(members, QStringLiteral("SELECT mc, epoch, rev, environment FROM shell_mcs WHERE origin = ?"), {origin})) return {};
  while (members.next()) {
    shell.mcs.append({members.value(0).toString(), members.value(1).toString(), members.value(2).toLongLong(), object(members.value(3)), {}});
  }
  QSqlQuery rows(db);
  rows.setForwardOnly(true);
  if (!run(rows, QStringLiteral("SELECT mc, id, kind, row FROM shell_rows WHERE origin = ?"), {origin})) return {};
  while (rows.next()) {
    const QString name = rows.value(0).toString();
    for (cache::ShellMc& mc : shell.mcs) {
      if (mc.mc == name) mc.rows.append({rows.value(1).toString(), rows.value(2).toString(), object(rows.value(3))});
    }
  }
  if (!shell.mcs.isEmpty()) shell.origin = origin;
  return shell;
}

}  // namespace

// Owns the connection, on the cache's thread.
class LocalCache::Worker : public QObject {
public:
  explicit Worker(LocalCache* cache) : m_cache(cache), m_connection(QStringLiteral("hal-c2-cache-") + QUuid::createUuid().toString(QUuid::Id128)) {}

  // A database of another schema, or one SQLite cannot read, is started over.
  bool open(const QString& path) {
    m_path = path;
    return ready(path) || startOver();
  }

  // An empty database in place of the file, and of its journal: nothing of
  // what was kept stays on disk. A file that cannot be removed is emptied
  // where it is, its freed pages overwritten. False when neither could be
  // done: what it still holds is then not read, and is dropped as soon as it
  // can be.
  bool startOver() {
    close();
    for (const char* suffix : {"", "-wal", "-shm"}) QFile::remove(m_path + QLatin1String(suffix));
    lost() = {};
    if (!QFile::exists(m_path)) {
      if (ready(m_path)) return true;
      close();
      return false;
    }
    if (ready(m_path)) {
      QSqlDatabase db = QSqlDatabase::database(m_connection, false);
      run(db, QStringLiteral("PRAGMA secure_delete = ON"));
      if (dropEverything(db)) {
        run(db, QStringLiteral("PRAGMA wal_checkpoint(TRUNCATE)"));
        return true;
      }
    }
    qWarning("[cache] %s could not be removed or emptied", qPrintable(m_path));
    lost().everything = true;
    return false;
  }

  void close() {
    if (!QSqlDatabase::contains(m_connection)) return;
    QSqlDatabase::database(m_connection, false).close();
    QSqlDatabase::removeDatabase(m_connection);
  }

  // Everything asked for since the last time, in one transaction.
  void flush() {
    QList<Job> jobs;
    {
      const QMutexLocker lock(&m_cache->m_mutex);
      jobs = std::exchange(m_cache->m_jobs, {});
      m_cache->m_scheduled = false;
    }
    if (jobs.isEmpty()) return;
    QSqlDatabase db = QSqlDatabase::database(m_connection, false);
    // Without a transaction each change still lands whole or not at all: it
    // is a savepoint of its own (whole()).
    const bool transaction = db.transaction();
    for (const Job& job : std::as_const(jobs)) job(db);
    if (!transaction || db.commit()) return;
    qWarning("[cache] not saved: %s", qPrintable(db.lastError().text()));
    // A commit that failed is still open, and would swallow every later one.
    // What it held is lost, and the changes that follow build on it: nothing
    // kept can be trusted to match its cursor, so nothing is kept.
    db.rollback();
    lost().everything = true;
    usable(db);
  }

private:
  bool ready(const QString& path) {
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connection);
    db.setDatabaseName(path);
    if (!db.open()) {
      qWarning("[cache] %s: %s", qPrintable(path), qPrintable(db.lastError().text()));
      return false;
    }
    run(db, QStringLiteral("PRAGMA journal_mode = WAL"));
    run(db, QStringLiteral("PRAGMA synchronous = NORMAL"));
    run(db, QStringLiteral("PRAGMA busy_timeout = 2000"));
    if (!run(db, QStringLiteral("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID"))) return false;
    QSqlQuery schema(db);
    if (!run(schema, QStringLiteral("SELECT value FROM meta WHERE key = 'schema'"))) return false;
    if (schema.next()) return schema.value(0).toInt() == LocalCache::kSchema;
    schema.finish();
    if (!db.transaction()) return false;
    for (const char* table : kTables) {
      if (!run(db, QString::fromLatin1(table))) return false;
    }
    return run(db, QStringLiteral("INSERT INTO meta(key, value) VALUES('schema', ?)"), {LocalCache::kSchema}) && db.commit();
  }

  LocalCache* m_cache;
  QString m_connection;
  QString m_path;
};

LocalCache::LocalCache(QObject* parent) : QObject(parent) {}

LocalCache::~LocalCache() {
  if (!m_worker) return;
  drain();
  QMetaObject::invokeMethod(m_worker, [worker = m_worker] { worker->close(); }, Qt::BlockingQueuedConnection);
  m_thread->quit();
  m_thread->wait();
  delete m_worker;
  delete m_thread;
}

void LocalCache::open(const QString& dir) {
  if (m_worker || dir.isEmpty() || !QDir().mkpath(dir)) return;
  auto* thread = new QThread;
  thread->setObjectName(QStringLiteral("hal-c2-cache"));
  auto* worker = new Worker(this);
  worker->moveToThread(thread);
  thread->start();
  bool opened = false;
  const QString path = QDir(dir).filePath(QStringLiteral("client-cache.sqlite"));
  QMetaObject::invokeMethod(worker, [worker, path, &opened] { opened = worker->open(path); }, Qt::BlockingQueuedConnection);
  if (opened) {
    m_thread = thread;
    m_worker = worker;
    return;
  }
  thread->quit();
  thread->wait();
  delete worker;
  delete thread;
}

void LocalCache::post(Job job) {
  if (!m_worker) return;
  const QMutexLocker lock(&m_mutex);
  m_jobs.append(std::move(job));
  if (m_scheduled) return;
  m_scheduled = true;
  QMetaObject::invokeMethod(m_worker, [worker = m_worker] { worker->flush(); }, Qt::QueuedConnection);
}

void LocalCache::wait() {
  if (m_worker) QMetaObject::invokeMethod(m_worker, [] {}, Qt::BlockingQueuedConnection);
}

void LocalCache::drain() {
  wait();
  // The replies the worker posted back.
  QCoreApplication::sendPostedEvents(this, QEvent::MetaCall);
}

cache::Shell LocalCache::shell(const QString& origin) {
  cache::Shell shell;
  post([&shell, origin](QSqlDatabase& db) {
    if (usable(db)) shell = readShell(db, origin);
  });
  wait();
  return shell;
}

void LocalCache::storeShell(const QString& origin, const QList<cache::ShellMcUpdate>& mcs) {
  post([origin, mcs](QSqlDatabase& db) {
    if (!usable(db)) return;
    if (lost().shells.contains(origin)) {
      if (!dropShell(db, origin)) return;
      lost().shells.remove(origin);
    }
    // A sidebar that missed a change would be resumed from the wrong version.
    whole(db, [&] { return applyShell(db, origin, mcs); }, [&] {
      if (!dropShell(db, origin)) lost().shells.insert(origin);
    });
  });
}

void LocalCache::loadThread(const QString& key, QObject* context, std::function<void(const cache::Thread&)> reply) {
  if (!m_worker) {
    // Never synchronous, so callers see one order either way.
    QMetaObject::invokeMethod(this, [context = QPointer<QObject>(context), reply = std::move(reply)] {
      if (context) reply({});
    }, Qt::QueuedConnection);
    return;
  }
  post([this, key, context = QPointer<QObject>(context), reply = std::move(reply)](QSqlDatabase& db) {
    QMetaObject::invokeMethod(this, [context, reply, thread = !usable(db) || lost().threads.contains(key) ? cache::Thread() : readThread(db, key)] {
      if (context) reply(thread);
    }, Qt::QueuedConnection);
  });
}

void LocalCache::storeThread(const cache::ThreadUpdate& update) {
  post([update](QSqlDatabase& db) {
    if (!usable(db)) return;
    if (lost().threads.contains(update.key)) {
      if (!dropThread(db, update.key)) return;
      lost().threads.remove(update.key);
    }
    // A copy that missed a change no longer matches its cursor.
    whole(db, [&] { return applyThread(db, update); }, [&] {
      if (!dropThread(db, update.key)) lost().threads.insert(update.key);
    });
  });
}

void LocalCache::trimThread(const QString& key, qint64 floor) {
  post([key, floor](QSqlDatabase& db) {
    if (!usable(db) || lost().threads.contains(key)) return;
    QSqlQuery raised(db);
    if (!run(raised, QStringLiteral("UPDATE threads SET floor = ? WHERE key = ? AND (floor IS NULL OR floor < ?)"), {floor, key, floor}) ||
        raised.numRowsAffected() == 0) {
      return;
    }
    run(db, QStringLiteral("DELETE FROM entities WHERE thread = ? AND run_ord < ?"), {key, floor});
  });
}

void LocalCache::forgetThread(const QString& key) {
  post([key](QSqlDatabase& db) {
    if (usable(db) && !dropThread(db, key)) lost().threads.insert(key);
  });
}

bool LocalCache::clear() {
  if (!m_worker) return true;
  bool cleared = false;
  // After what was asked for so far, which the worker takes first.
  QMetaObject::invokeMethod(m_worker, [worker = m_worker, &cleared] { cleared = worker->startOver(); }, Qt::BlockingQueuedConnection);
  return cleared;
}

void LocalCache::forgetEnvironment(const QString& environmentId) {
  const QString prefix = environmentId + QLatin1Char(':');
  post([prefix](QSqlDatabase& db) {
    // Their cursors first; while those stay, so do the copies they vouch for.
    if (!usable(db) || !run(db, QStringLiteral("DELETE FROM threads WHERE substr(key, 1, ?) = ?"), {prefix.size(), prefix})) return;
    run(db, QStringLiteral("DELETE FROM entities WHERE substr(thread, 1, ?) = ?"), {prefix.size(), prefix});
  });
}
