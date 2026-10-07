#pragma once

#include <QJsonObject>
#include <QList>
#include <QMutex>
#include <QObject>
#include <QPair>
#include <QString>
#include <QStringList>

#include <functional>
#include <optional>

class QSqlDatabase;
class QThread;

// What the client keeps of its MC between connections and runs, so it paints
// before the socket is up and is sent only what it lacks.
namespace cache {

// One entity of a thread's stream, as the timeline holds it.
struct Entity {
  QString kind;
  QString id;
  QJsonObject fields;
  // The ordinal of its run, for the kinds a window bounds (turn items and
  // messages of a run); none for the rest, which are held whole.
  std::optional<qint64> run;
};

// Where a copy of a thread stands: the MC log it follows (`handle`), the
// offset it reflects, and the first run of its window (none: it reaches the
// start of the thread). `offset` is negative when there is no copy.
struct Cursor {
  QString handle;
  qint64 offset = -1;
  std::optional<qint64> floor;
};

struct Thread {
  Cursor cursor;
  QList<Entity> entities;
  bool found() const { return cursor.offset >= 0; }
};

// A change to a thread's copy, which lands whole: the entities and the cursor
// that says what they reflect.
struct ThreadUpdate {
  QString key;  // "environmentId:threadId"
  Cursor cursor;
  // After a snapshot: `put` is the whole copy. Otherwise a change to a copy
  // that is there; one the cache no longer holds is left alone.
  bool replace = false;
  QList<Entity> put;
  QList<QPair<QString, QString>> gone;  // kind, id
};

struct ShellRow {
  QString id;
  QString kind;
  QJsonObject fields;
};

// One MC of the sidebar: its environment, its rows, and the version the MC
// gave them (`epoch` empty when it gave none).
struct ShellMc {
  QString mc;
  QString epoch;
  qint64 rev = 0;
  QJsonObject environment;
  QList<ShellRow> rows;
};

// The sidebar as kept, and the origin of the MC it is of (empty: none is kept).
struct Shell {
  QString origin;
  QList<ShellMc> mcs;
};

// A change to one MC of the sidebar.
struct ShellMcUpdate {
  QString mc;
  // The MC left the cluster: it and its rows go.
  bool removed = false;
  // Its rows are replaced by `put`.
  bool reset = false;
  QString epoch;
  qint64 rev = 0;
  QJsonObject environment;
  QList<ShellRow> put;
  QStringList gone;  // row ids
};

}  // namespace cache

// The client's cache: one SQLite database in the cache directory. Deleting it
// is harmless, and so is a schema it does not know, which is started over.
//
//   LocalCache cache;
//   cache.open(storage.cache);
//   cache.shell()                             // the sidebar, at startup
//   cache.loadThread(key, this, [](const cache::Thread& thread) { ... });
//   cache.storeThread(update);                // queued; one transaction per batch
//
// Every statement runs on one worker thread that owns the connection. The
// calling thread only waits for it in shell() and drain(). Work is done in
// the order it was asked for, so a read sees the writes before it.
class LocalCache : public QObject {
  Q_OBJECT

public:
  // Bumped when a table changes: an older or newer database is dropped.
  static constexpr int kSchema = 1;
  // The threads kept, most recently opened first.
  static constexpr int kThreads = 100;

  explicit LocalCache(QObject* parent = nullptr);
  ~LocalCache() override;

  // Opens `<dir>/client-cache.sqlite`, creating it. Without it (no directory, no
  // SQLite driver, a file that cannot be written) nothing is kept and every
  // read comes back empty.
  void open(const QString& dir);
  bool isOpen() const { return m_worker != nullptr; }

  // The sidebar last stored: the one MC's the client was last opened at, or
  // with `origin` that MC's, another's being dropped. Blocks until it is read.
  cache::Shell shell(const QString& origin = {});
  void storeShell(const QString& origin, const QList<cache::ShellMcUpdate>& mcs);

  // `reply` runs on this thread once the thread is read, unless `context` is gone.
  void loadThread(const QString& key, QObject* context, std::function<void(const cache::Thread&)> reply);
  void storeThread(const cache::ThreadUpdate& update);
  // Drops the windowed entities of runs before `floor`, which becomes the
  // copy's floor; a copy that already starts later is left as it is.
  void trimThread(const QString& key, qint64 floor);
  void forgetThread(const QString& key);
  void forgetEnvironment(const QString& environmentId);
  // Starts the database over, so nothing kept stays on disk: the client left
  // its MC for good (NativeShell::close). Blocks until it is done. False when
  // the file could be neither removed nor emptied: what it holds is not read,
  // but is still on disk.
  bool clear();

  // Returns once everything asked for so far is done and every loadThread
  // reply has run. Tests and shutdown wait on this.
  void drain();

private:
  class Worker;
  using Job = std::function<void(QSqlDatabase& db)>;
  void post(Job job);
  // Blocks until the worker has done what was posted.
  void wait();

  QThread* m_thread = nullptr;
  Worker* m_worker = nullptr;
  QMutex m_mutex;
  // Guarded by m_mutex: what the worker takes next, and whether it was told to.
  QList<Job> m_jobs;
  bool m_scheduled = false;
};
