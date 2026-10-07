// The client's cache (src/native/LocalCache): what it keeps of a thread and of
// the thread list, the bounds on it, and starting over when the file is of no use.

#include <QDir>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTest>

#include <memory>

#include "LocalCache.h"

namespace {

cache::Entity item(const QString& id, qint64 run, const QString& text = {}) {
  return {QStringLiteral("turn-item"), id, {{QStringLiteral("id"), id}, {QStringLiteral("text"), text}}, run};
}

cache::Entity run(qint64 ordinal) {
  const QString id = QStringLiteral("run-%1").arg(ordinal);
  return {QStringLiteral("run"), id, {{QStringLiteral("id"), id}, {QStringLiteral("ordinal"), ordinal}}, std::nullopt};
}

QStringList ids(const cache::Thread& thread) {
  QStringList found;
  for (const cache::Entity& entity : thread.entities) found.append(entity.id);
  found.sort();
  return found;
}

}  // namespace

class tst_LocalCache : public QObject {
  Q_OBJECT

private:
  std::unique_ptr<LocalCache> open() {
    auto cache = std::make_unique<LocalCache>();
    cache->open(m_dir->path());
    return cache;
  }
  static cache::Thread load(LocalCache& cache, const QString& key) {
    cache::Thread found;
    cache.loadThread(key, &cache, [&found](const cache::Thread& thread) { found = thread; });
    cache.drain();
    return found;
  }
  // A whole copy of one run of two items, as a snapshot leaves it.
  static cache::ThreadUpdate copy(const QString& key, qint64 offset = 10) {
    return {key, {QStringLiteral("log-1"), offset, std::nullopt}, true, {run(1), item(QStringLiteral("a"), 1, QStringLiteral("one")), item(QStringLiteral("b"), 1)}, {}};
  }

  // Runs statements on the cache's file from outside it, as a disk that
  // starts refusing writes would change what it accepts.
  void tamper(const QStringList& statements) {
    {
      QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("tamper"));
      db.setDatabaseName(QDir(m_dir->path()).filePath(QStringLiteral("client-cache.sqlite")));
      QVERIFY(db.open());
      QSqlQuery query(db);
      for (const QString& statement : statements) QVERIFY2(query.exec(statement), qPrintable(statement));
      db.close();
    }
    QSqlDatabase::removeDatabase(QStringLiteral("tamper"));
  }

  std::unique_ptr<QTemporaryDir> m_dir;

private slots:
  void init() { m_dir = std::make_unique<QTemporaryDir>(); }
  void cleanup() { m_dir.reset(); }

  void aThreadIsKeptAsOfItsCursor() {
    const QString key = QStringLiteral("env-a:thread-1");
    {
      auto cache = open();
      QVERIFY(cache->isOpen());
      QVERIFY(!load(*cache, key).found());
      cache->storeThread(copy(key));
      // A change lands with the cursor that says what it reflects.
      cache->storeThread({key, {QStringLiteral("log-1"), 12, 4}, false, {item(QStringLiteral("a"), 1, QStringLiteral("two")), item(QStringLiteral("c"), 1)}, {{QStringLiteral("turn-item"), QStringLiteral("b")}}});
    }
    // Another run of the app reads what the last one kept.
    auto cache = open();
    const cache::Thread thread = load(*cache, key);
    QVERIFY(thread.found());
    QCOMPARE(thread.cursor.handle, QStringLiteral("log-1"));
    QCOMPARE(thread.cursor.offset, 12);
    QCOMPARE(thread.cursor.floor, std::optional<qint64>(4));
    QCOMPARE(ids(thread), QStringList({QStringLiteral("a"), QStringLiteral("c"), QStringLiteral("run-1")}));
    for (const cache::Entity& entity : thread.entities) {
      if (entity.id == QLatin1String("a")) {
        QCOMPARE(entity.fields.value(QLatin1String("text")).toString(), QStringLiteral("two"));
        QCOMPARE(entity.run, std::optional<qint64>(1));
      }
      if (entity.id == QLatin1String("run-1")) QVERIFY(!entity.run.has_value());
    }
  }

  void aSnapshotReplacesTheCopy() {
    const QString key = QStringLiteral("env-a:thread-1");
    auto cache = open();
    cache->storeThread(copy(key));
    cache->storeThread({key, {QStringLiteral("log-2"), 3, std::nullopt}, true, {item(QStringLiteral("z"), 1)}, {}});
    const cache::Thread thread = load(*cache, key);
    QCOMPARE(thread.cursor.handle, QStringLiteral("log-2"));
    QCOMPARE(ids(thread), QStringList({QStringLiteral("z")}));
  }

  void aChangeToAForgottenThreadIsLeftAlone() {
    const QString key = QStringLiteral("env-a:thread-1");
    auto cache = open();
    cache->storeThread(copy(key));
    cache->forgetThread(key);
    // Half a copy would pass for a whole one at its cursor.
    cache->storeThread({key, {QStringLiteral("log-1"), 14, std::nullopt}, false, {item(QStringLiteral("c"), 1)}, {}});
    QVERIFY(!load(*cache, key).found());
  }

  void aClosedThreadIsTrimmedToItsNewestRuns() {
    const QString key = QStringLiteral("env-a:thread-1");
    auto cache = open();
    cache::ThreadUpdate whole{key, {QStringLiteral("log-1"), 10, std::nullopt}, true, {}, {}};
    for (qint64 ordinal = 1; ordinal <= 6; ++ordinal) {
      whole.put.append(run(ordinal));
      whole.put.append(item(QStringLiteral("item-%1").arg(ordinal), ordinal));
    }
    // One of no run, which no window leaves out.
    whole.put.append({QStringLiteral("turn-item"), QStringLiteral("loose"), {}, std::nullopt});
    cache->storeThread(whole);
    cache->trimThread(key, 5);
    cache::Thread thread = load(*cache, key);
    QCOMPARE(thread.cursor.floor, std::optional<qint64>(5));
    QCOMPARE(thread.cursor.offset, 10);
    // The runs themselves are held whole; their items from the floor on.
    QCOMPARE(thread.entities.size(), 6 + 2 + 1);
    QVERIFY(ids(thread).contains(QStringLiteral("item-5")) && ids(thread).contains(QStringLiteral("loose")) && !ids(thread).contains(QStringLiteral("item-4")));
    // A window that already starts later is not widened by a trim.
    cache->trimThread(key, 3);
    thread = load(*cache, key);
    QCOMPARE(thread.cursor.floor, std::optional<qint64>(5));
    QCOMPARE(thread.entities.size(), 6 + 2 + 1);
  }

  void theMostRecentlyOpenedThreadsAreKept() {
    auto cache = open();
    const auto key = [](int n) { return QStringLiteral("env-a:thread-%1").arg(n); };
    for (int n = 0; n < LocalCache::kThreads; ++n) cache->storeThread(copy(key(n)));
    // Opening the oldest makes it the most recent.
    QVERIFY(load(*cache, key(0)).found());
    cache->storeThread(copy(key(LocalCache::kThreads)));
    QVERIFY(load(*cache, key(0)).found());
    QVERIFY(load(*cache, key(LocalCache::kThreads)).found());
    // The one opened longest ago made room, with everything it held.
    const cache::Thread evicted = load(*cache, key(1));
    QVERIFY(!evicted.found());
    QVERIFY(evicted.entities.isEmpty());
    QVERIFY(load(*cache, key(2)).found());
  }

  void anEnvironmentIsForgottenWithItsThreads() {
    auto cache = open();
    cache->storeThread(copy(QStringLiteral("env-a:thread-1")));
    cache->storeThread(copy(QStringLiteral("env-a:thread-2")));
    cache->storeThread(copy(QStringLiteral("env-ab:thread-1")));
    cache->forgetEnvironment(QStringLiteral("env-a"));
    QVERIFY(!load(*cache, QStringLiteral("env-a:thread-1")).found());
    QVERIFY(!load(*cache, QStringLiteral("env-a:thread-2")).found());
    QVERIFY(load(*cache, QStringLiteral("env-ab:thread-1")).found());
  }

  void theThreadListIsKeptByOriginWithItsVersions() {
    const QString origin = QStringLiteral("http://127.0.0.1:3780");
    const auto row = [](const QString& id, const QString& title) {
      return cache::ShellRow{id, QStringLiteral("thread"), {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}}};
    };
    {
      auto cache = open();
      QVERIFY(cache->shell(origin).mcs.isEmpty());
      QVERIFY(cache->shell().origin.isEmpty());
      cache->storeShell(origin, {{QStringLiteral("mc-a"), false, true, QStringLiteral("epoch-1"), 2, {{QStringLiteral("environmentId"), QStringLiteral("env-a")}},
                                  {row(QStringLiteral("t1"), QStringLiteral("One")), row(QStringLiteral("t2"), QStringLiteral("Two"))}, {}},
                                 {QStringLiteral("mc-b"), false, true, {}, 0, {}, {row(QStringLiteral("t9"), QStringLiteral("Nine"))}, {}}});
      // The rows changed since, and the version they bring it to.
      cache->storeShell(origin, {{QStringLiteral("mc-a"), false, false, QStringLiteral("epoch-1"), 4, {{QStringLiteral("environmentId"), QStringLiteral("env-a")}},
                                  {row(QStringLiteral("t2"), QStringLiteral("Two again")), row(QStringLiteral("t3"), QStringLiteral("Three"))}, {QStringLiteral("t1")}},
                                 {QStringLiteral("mc-b"), true, false, {}, 0, {}, {}, {}}});
    }
    auto cache = open();
    // Before the client knows its MC, the one it was last opened at.
    QCOMPARE(cache->shell().origin, origin);
    QList<cache::ShellMc> shell = cache->shell(origin).mcs;
    QCOMPARE(shell.size(), 1);
    QCOMPARE(shell.first().mc, QStringLiteral("mc-a"));
    QCOMPARE(shell.first().epoch, QStringLiteral("epoch-1"));
    QCOMPARE(shell.first().rev, 4);
    QCOMPARE(shell.first().environment.value(QLatin1String("environmentId")).toString(), QStringLiteral("env-a"));
    QStringList titles;
    for (const cache::ShellRow& kept : shell.first().rows) titles.append(kept.fields.value(QLatin1String("title")).toString());
    titles.sort();
    QCOMPARE(titles, QStringList({QStringLiteral("Three"), QStringLiteral("Two again")}));
    // A reset replaces the MC's rows.
    cache->storeShell(origin, {{QStringLiteral("mc-a"), false, true, QStringLiteral("epoch-2"), 1, {}, {row(QStringLiteral("t7"), QStringLiteral("Seven"))}, {}}});
    shell = cache->shell(origin).mcs;
    QCOMPARE(shell.first().rows.size(), 1);
    QCOMPARE(shell.first().epoch, QStringLiteral("epoch-2"));
    // Opened at another MC, the client holds nothing of this one any more.
    QVERIFY(cache->shell(QStringLiteral("http://127.0.0.1:3781")).mcs.isEmpty());
    QVERIFY(cache->shell(origin).mcs.isEmpty());
    QVERIFY(cache->shell().origin.isEmpty());
  }

  // A change that cannot be written leaves a copy that no longer matches its
  // cursor. It is dropped; one that cannot even be dropped is never read, and
  // never changed, until it can be.
  void aCopyThatMissedAChangeIsNeverRead() {
    const QString key = QStringLiteral("env-a:thread-1");
    auto cache = open();
    cache->storeThread(copy(key));
    QVERIFY(load(*cache, key).found());

    // The disk refuses one row, and refuses to give the cursor up.
    tamper({QStringLiteral("CREATE TRIGGER refuse_put BEFORE INSERT ON entities WHEN NEW.id = 'c' BEGIN SELECT RAISE(ABORT, 'refused'); END"),
            QStringLiteral("CREATE TRIGGER refuse_drop BEFORE DELETE ON threads BEGIN SELECT RAISE(ABORT, 'refused'); END")});
    cache->storeThread({key, {QStringLiteral("log-1"), 11, std::nullopt}, false, {item(QStringLiteral("c"), 1)}, {}});
    // Its cursor still says 10 and its rows are whole as of 10, but what
    // follows was built on 11: it is not handed out.
    QVERIFY(!load(*cache, key).found());

    // Nor brought forward by a later change while it cannot be dropped.
    cache->storeThread({key, {QStringLiteral("log-1"), 12, std::nullopt}, false, {item(QStringLiteral("d"), 1)}, {}});
    QVERIFY(!load(*cache, key).found());

    // Once it can be dropped it is, and a snapshot makes a copy again.
    tamper({QStringLiteral("DROP TRIGGER refuse_drop")});
    cache->storeThread({key, {QStringLiteral("log-1"), 13, std::nullopt}, false, {item(QStringLiteral("e"), 1)}, {}});
    QVERIFY(!load(*cache, key).found());
    cache->storeThread(copy(key, 14));
    const cache::Thread again = load(*cache, key);
    QCOMPARE(again.cursor.offset, 14);
    QCOMPARE(ids(again), QStringList({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("run-1")}));
  }

  // The thread list goes the same way: one that missed a change is not read,
  // and the rows that changed afterwards do not pass for all of an MC's rows.
  void aThreadListThatMissedAChangeIsNeverRead() {
    const QString origin = QStringLiteral("http://127.0.0.1:3780");
    const QJsonObject environment{{QStringLiteral("environmentId"), QStringLiteral("env-a")}};
    const auto change = [&](bool reset, qint64 rev, const QString& id) {
      const cache::ShellRow row{id, QStringLiteral("thread"), {{QStringLiteral("id"), id}}};
      return QList<cache::ShellMcUpdate>{{QStringLiteral("mc-a"), false, reset, QStringLiteral("epoch-1"), rev, environment, {row}, {}}};
    };
    auto cache = open();
    cache->storeShell(origin, change(true, 2, QStringLiteral("t1")));
    QCOMPARE(cache->shell(origin).mcs.size(), 1);

    tamper({QStringLiteral("CREATE TRIGGER refuse_put BEFORE INSERT ON shell_rows WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'refused'); END"),
            QStringLiteral("CREATE TRIGGER refuse_drop BEFORE DELETE ON shell_mcs BEGIN SELECT RAISE(ABORT, 'refused'); END")});
    cache->storeShell(origin, change(false, 3, QStringLiteral("bad")));
    // Its version still says 2 and its rows are whole as of 2, but the MC
    // was told the client holds 3.
    QVERIFY(cache->shell(origin).mcs.isEmpty());
    cache->storeShell(origin, change(false, 4, QStringLiteral("t4")));
    QVERIFY(cache->shell(origin).mcs.isEmpty());

    // Once it can be dropped it is. One changed row is not the MC's rows.
    tamper({QStringLiteral("DROP TRIGGER refuse_drop")});
    cache->storeShell(origin, change(false, 5, QStringLiteral("t5")));
    QVERIFY(cache->shell(origin).mcs.isEmpty());
    // All of its rows are.
    cache->storeShell(origin, change(true, 6, QStringLiteral("t6")));
    const QList<cache::ShellMc> shell = cache->shell(origin).mcs;
    QCOMPARE(shell.size(), 1);
    QCOMPARE(shell.first().rev, 6);
    QCOMPARE(shell.first().rows.size(), 1);
  }

  void anotherSchemaStartsOver() {
    const QString key = QStringLiteral("env-a:thread-1");
    {
      auto cache = open();
      cache->storeThread(copy(key));
    }
    {
      QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("tamper"));
      db.setDatabaseName(QDir(m_dir->path()).filePath(QStringLiteral("client-cache.sqlite")));
      QVERIFY(db.open());
      QSqlQuery query(db);
      QVERIFY(query.exec(QStringLiteral("UPDATE meta SET value = '%1' WHERE key = 'schema'").arg(LocalCache::kSchema + 1)));
      // A table this version knows nothing of goes too.
      QVERIFY(query.exec(QStringLiteral("CREATE TABLE later(id TEXT)")));
      db.close();
    }
    QSqlDatabase::removeDatabase(QStringLiteral("tamper"));
    auto cache = open();
    QVERIFY(cache->isOpen());
    QVERIFY(!load(*cache, key).found());
    cache->storeThread(copy(key));
    QVERIFY(load(*cache, key).found());
  }

  void aFileThatIsNoDatabaseStartsOver() {
    QFile file(QDir(m_dir->path()).filePath(QStringLiteral("client-cache.sqlite")));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QByteArray(4096, 'x'));
    file.close();
    auto cache = open();
    QVERIFY(cache->isOpen());
    cache->storeThread(copy(QStringLiteral("env-a:thread-1")));
    QVERIFY(load(*cache, QStringLiteral("env-a:thread-1")).found());
  }

  void withoutADirectoryNothingIsKept() {
    LocalCache cache;
    cache.open({});
    QVERIFY(!cache.isOpen());
    cache.storeThread(copy(QStringLiteral("env-a:thread-1")));
    bool answered = false;
    cache.loadThread(QStringLiteral("env-a:thread-1"), &cache, [&answered](const cache::Thread& thread) { answered = !thread.found(); });
    // Never from inside the call, with or without a database.
    QVERIFY(!answered);
    cache.drain();
    QVERIFY(answered);
    QVERIFY(cache.shell(QStringLiteral("http://127.0.0.1:3780")).mcs.isEmpty());
  }

  void aReplyIsNotGivenToAContextThatIsGone() {
    auto cache = open();
    auto context = std::make_unique<QObject>();
    bool answered = false;
    cache->loadThread(QStringLiteral("env-a:thread-1"), context.get(), [&answered](const cache::Thread&) { answered = true; });
    context.reset();
    cache->drain();
    QVERIFY(!answered);
  }
};

QTEST_GUILESS_MAIN(tst_LocalCache)
#include "tst_LocalCache.moc"
