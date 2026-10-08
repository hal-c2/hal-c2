// The client's cache (src/native/LocalCache) against a model of what it was
// told: thread copies and the sidebar's rows, across reopening the same file
// and a process that died part-way through writing it.

#include "Prop.h"

#include <QDir>
#include <QFile>

#include <map>
#include <memory>
#include <optional>

#include "LocalCache.h"

namespace {

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

// A thread's copy as kept: its cursor, and its entities by "kind/id".
struct Entity {
  std::optional<qint64> run;
  int n = 0;
  bool operator==(const Entity&) const = default;
};
struct ThreadCopy {
  std::string handle;
  qint64 offset = 0;
  std::optional<qint64> floor;
  std::map<std::string, Entity> entities;
  bool operator==(const ThreadCopy&) const = default;
};
struct Row {
  std::string kind;
  int n = 0;
  bool operator==(const Row&) const = default;
};
struct McCopy {
  std::string epoch;
  qint64 rev = 0;
  int environment = 0;
  std::map<std::string, Row> rows;
  bool operator==(const McCopy&) const = default;
};
using ShellCopy = std::map<std::string, McCopy>;  // by mc

struct Model {
  std::map<std::string, ThreadCopy> threads;      // by key
  std::map<std::string, ShellCopy> shells;        // by origin
};

const std::vector<std::string> kKeys{"env-a:t1", "env-a:t2", "env-b:t1"};
const std::vector<std::string> kEnvironments{"env-a", "env-b"};
const std::vector<std::string> kOrigins{"http://a", "http://b"};
const std::vector<std::string> kMcs{"mc-a", "mc-b"};
const std::vector<std::string> kRowIds{"r1", "r2", "r3"};

void show(const std::optional<qint64>& value, std::ostream& os) {
  if (value) {
    os << *value;
  } else {
    os << "-";
  }
}

cache::Entity toCache(const std::string& slot, const Entity& entity) {
  const QString key = q(slot);
  const qsizetype slash = key.indexOf(QLatin1Char('/'));
  return {key.left(slash), key.mid(slash + 1), {{QStringLiteral("n"), entity.n}}, entity.run};
}

ThreadCopy fromCache(const cache::Thread& thread) {
  ThreadCopy copy{thread.cursor.handle.toStdString(), thread.cursor.offset, thread.cursor.floor, {}};
  for (const cache::Entity& entity : thread.entities) {
    copy.entities[(entity.kind + QLatin1Char('/') + entity.id).toStdString()] = {entity.run, entity.fields.value(QLatin1String("n")).toInt()};
  }
  return copy;
}

ShellCopy fromCache(const cache::Shell& shell) {
  ShellCopy copy;
  for (const cache::ShellMc& mc : shell.mcs) {
    McCopy& kept = copy[mc.mc.toStdString()];
    kept.epoch = mc.epoch.toStdString();
    kept.rev = mc.rev;
    kept.environment = mc.environment.value(QLatin1String("n")).toInt();
    for (const cache::ShellRow& row : mc.rows) kept.rows[row.id.toStdString()] = {row.kind.toStdString(), row.fields.value(QLatin1String("n")).toInt()};
  }
  return copy;
}

std::ostream& operator<<(std::ostream& os, const ThreadCopy& copy) {
  os << "{" << copy.handle << "@" << copy.offset << " floor ";
  show(copy.floor, os);
  for (const auto& [slot, entity] : copy.entities) {
    os << " " << slot << "(run ";
    show(entity.run, os);
    os << ", " << entity.n << ")";
  }
  return os << "}";
}

std::ostream& operator<<(std::ostream& os, const ShellCopy& copy) {
  os << "{";
  for (const auto& [mc, kept] : copy) {
    os << " " << mc << "[" << kept.epoch << "," << kept.rev << ", env " << kept.environment << "]";
    for (const auto& [id, row] : kept.rows) os << " " << id << ":" << row.kind << "=" << row.n;
  }
  return os << " }";
}

// The cache under test, on a directory of its own, and what it was handed.
struct Sut {
  QTemporaryDir root;
  int generation = 0;
  QString dir;
  std::unique_ptr<LocalCache> cache;

  Sut() { reopenAt(fresh()); }

  QString fresh() {
    const QString path = root.filePath(QString::number(generation++));
    QDir().mkpath(path);
    return path;
  }
  QString file(const char* suffix = "") const { return QDir(dir).filePath(QStringLiteral("client-cache.sqlite") + QLatin1String(suffix)); }
  void reopenAt(const QString& path) {
    cache.reset();
    dir = path;
    cache = std::make_unique<LocalCache>();
    cache->open(dir);
  }
  cache::Thread load(const QString& key) {
    cache::Thread found;
    cache->loadThread(key, cache.get(), [&found](const cache::Thread& thread) { found = thread; });
    cache->drain();
    return found;
  }
};

// What the cache reads back equals the model: every thread of the pool, and
// the sidebar it shows at startup (the first origin's, read without dropping
// the others).
void expectSame(const Model& model, Sut& sut) {
  for (const std::string& key : kKeys) {
    const cache::Thread thread = sut.load(q(key));
    const auto expected = model.threads.find(key);
    if (expected == model.threads.end()) {
      RC_ASSERT_FALSE(thread.found());
    } else {
      RC_ASSERT(thread.found());
      const ThreadCopy actual = fromCache(thread);
      if (!(actual == expected->second)) {
        RC_FAIL("thread " + key + ": kept " + rc::toString(actual) + ", told " + rc::toString(expected->second));
      }
    }
  }
  const cache::Shell shell = sut.cache->shell();
  if (model.shells.empty()) {
    RC_ASSERT(shell.origin.isEmpty());
    RC_ASSERT(shell.mcs.isEmpty());
    return;
  }
  const auto& [origin, expected] = *model.shells.begin();
  RC_ASSERT(shell.origin.toStdString() == origin);
  const ShellCopy actual = fromCache(shell);
  if (!(actual == expected)) RC_FAIL("shell of " + origin + ": kept " + rc::toString(actual) + ", told " + rc::toString(expected));
}

using Command = rc::state::Command<Model, Sut>;

Entity genEntity(const std::string& slot) {
  // Turn items carry the run they are of; runs are held whole.
  const bool windowed = slot.starts_with("turn-item/");
  return {windowed ? std::optional<qint64>(*rc::gen::inRange<qint64>(1, 4)) : std::nullopt, *rc::gen::inRange(0, 50)};
}

std::string genSlot() {
  return *rc::gen::elementOf(std::vector<std::string>{"run/r1", "run/r2", "turn-item/i1", "turn-item/i2", "turn-item/i3"});
}

struct StoreThread : Command {
  std::string key = *rc::gen::elementOf(kKeys);
  bool replace = *rc::gen::arbitrary<bool>();
  std::string handle = *rc::gen::elementOf(std::vector<std::string>{"log-1", "log-2"});
  qint64 offset = *rc::gen::inRange<qint64>(0, 100);
  std::optional<qint64> floor = *rc::gen::arbitrary<bool>() ? std::optional<qint64>(*rc::gen::inRange<qint64>(1, 4)) : std::nullopt;
  std::map<std::string, Entity> put;
  std::vector<std::string> gone;

  explicit StoreThread(const Model&) {
    for (int i = *rc::gen::inRange(0, 4); i > 0; --i) {
      const std::string slot = genSlot();
      put[slot] = genEntity(slot);
    }
    if (!replace) gone = *rc::gen::container<std::vector<std::string>>(*rc::gen::inRange(0, 3), rc::gen::exec(genSlot));
  }

  void apply(Model& model) const override {
    if (replace) {
      model.threads[key] = {handle, offset, floor, put};
      return;
    }
    const auto it = model.threads.find(key);
    // A change to a copy the cache no longer holds is left alone.
    if (it == model.threads.end()) return;
    it->second.handle = handle;
    it->second.offset = offset;
    it->second.floor = floor;
    for (const std::string& slot : gone) it->second.entities.erase(slot);
    for (const auto& [slot, entity] : put) it->second.entities[slot] = entity;
  }

  cache::ThreadUpdate update() const {
    cache::ThreadUpdate update{q(key), {q(handle), offset, floor}, replace, {}, {}};
    for (const auto& [slot, entity] : put) update.put.append(toCache(slot, entity));
    for (const std::string& slot : gone) {
      const QString text = q(slot);
      update.gone.append({text.section(QLatin1Char('/'), 0, 0), text.section(QLatin1Char('/'), 1)});
    }
    return update;
  }

  void run(const Model& model, Sut& sut) const override {
    sut.cache->storeThread(update());
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override {
    os << "StoreThread(" << key << (replace ? " replace " : " change ") << handle << "@" << offset << " floor ";
    ::show(floor, os);
    os << " put";
    for (const auto& [slot, entity] : put) {
      os << " " << slot << "(run ";
      ::show(entity.run, os);
      os << ", " << entity.n << ")";
    }
    os << " gone";
    for (const std::string& slot : gone) os << " " << slot;
    os << ")";
  }
};

struct TrimThread : Command {
  std::string key = *rc::gen::elementOf(kKeys);
  qint64 floor = *rc::gen::inRange<qint64>(1, 5);

  explicit TrimThread(const Model&) {}

  void apply(Model& model) const override {
    const auto it = model.threads.find(key);
    if (it == model.threads.end() || (it->second.floor && *it->second.floor >= floor)) return;
    it->second.floor = floor;
    std::erase_if(it->second.entities, [this](const auto& entry) { return entry.second.run && *entry.second.run < floor; });
  }

  void run(const Model& model, Sut& sut) const override {
    sut.cache->trimThread(q(key), floor);
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override { os << "TrimThread(" << key << ", " << floor << ")"; }
};

struct ForgetThread : Command {
  std::string key = *rc::gen::elementOf(kKeys);

  explicit ForgetThread(const Model&) {}

  void apply(Model& model) const override { model.threads.erase(key); }

  void run(const Model& model, Sut& sut) const override {
    sut.cache->forgetThread(q(key));
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override { os << "ForgetThread(" << key << ")"; }
};

struct ForgetEnvironment : Command {
  std::string environment = *rc::gen::elementOf(kEnvironments);

  explicit ForgetEnvironment(const Model&) {}

  void apply(Model& model) const override {
    std::erase_if(model.threads, [this](const auto& entry) { return entry.first.starts_with(environment + ":"); });
  }

  void run(const Model& model, Sut& sut) const override {
    sut.cache->forgetEnvironment(q(environment));
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override { os << "ForgetEnvironment(" << environment << ")"; }
};

struct McChange {
  std::string mc;
  bool removed = false;
  bool reset = false;
  std::string epoch;
  qint64 rev = 0;
  int environment = 0;
  std::map<std::string, Row> put;
  std::vector<std::string> gone;
};

McChange genMcChange() {
  McChange change;
  change.mc = *rc::gen::elementOf(kMcs);
  change.removed = *rc::gen::weightedElement<bool>({{1, true}, {5, false}});
  if (change.removed) return change;
  change.reset = *rc::gen::arbitrary<bool>();
  change.epoch = *rc::gen::elementOf(std::vector<std::string>{"", "e1", "e2"});
  change.rev = *rc::gen::inRange<qint64>(0, 20);
  change.environment = *rc::gen::inRange(0, 3);
  for (int i = *rc::gen::inRange(0, 3); i > 0; --i) {
    change.put[*rc::gen::elementOf(kRowIds)] = {*rc::gen::elementOf(std::vector<std::string>{"thread", "project"}), *rc::gen::inRange(0, 50)};
  }
  change.gone = *rc::gen::container<std::vector<std::string>>(*rc::gen::inRange(0, 2), rc::gen::elementOf(kRowIds));
  return change;
}

struct StoreShell : Command {
  std::string origin = *rc::gen::elementOf(kOrigins);
  std::vector<McChange> changes;

  explicit StoreShell(const Model&) {
    for (int i = *rc::gen::inRange(1, 3); i > 0; --i) changes.push_back(genMcChange());
  }

  void apply(Model& model) const override {
    ShellCopy& shell = model.shells[origin];
    for (const McChange& change : changes) {
      if (change.removed) {
        shell.erase(change.mc);
        continue;
      }
      if (!change.reset && !shell.contains(change.mc)) continue;
      McCopy& mc = shell[change.mc];
      if (change.reset) mc.rows.clear();
      mc.epoch = change.epoch;
      mc.rev = change.rev;
      mc.environment = change.environment;
      for (const std::string& id : change.gone) mc.rows.erase(id);
      for (const auto& [id, row] : change.put) mc.rows[id] = row;
    }
    if (shell.empty()) model.shells.erase(origin);
  }

  void run(const Model& model, Sut& sut) const override {
    QList<cache::ShellMcUpdate> updates;
    for (const McChange& change : changes) {
      cache::ShellMcUpdate update{q(change.mc), change.removed, change.reset, q(change.epoch), change.rev,
                                  {{QStringLiteral("n"), change.environment}}, {}, {}};
      for (const auto& [id, row] : change.put) update.put.append({q(id), q(row.kind), {{QStringLiteral("n"), row.n}}});
      for (const std::string& id : change.gone) update.gone.append(q(id));
      updates.append(update);
    }
    sut.cache->storeShell(q(origin), updates);
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override {
    os << "StoreShell(" << origin;
    for (const McChange& change : changes) {
      os << " " << change.mc;
      if (change.removed) {
        os << " removed;";
        continue;
      }
      os << (change.reset ? " reset" : "") << " [" << change.epoch << "," << change.rev << "] env " << change.environment << " put";
      for (const auto& [id, row] : change.put) os << " " << id << ":" << row.kind << "=" << row.n;
      os << " gone";
      for (const std::string& id : change.gone) os << " " << id;
      os << ";";
    }
    os << ")";
  }
};

// The client opened at `origin`: its sidebar is read, and every other
// origin's is dropped.
struct OpenAt : Command {
  std::string origin = *rc::gen::elementOf(kOrigins);

  explicit OpenAt(const Model&) {}

  void apply(Model& model) const override {
    std::erase_if(model.shells, [this](const auto& entry) { return entry.first != origin; });
  }

  void run(const Model& model, Sut& sut) const override {
    const cache::Shell shell = sut.cache->shell(q(origin));
    Model next = model;
    apply(next);
    const auto expected = next.shells.find(origin);
    RC_ASSERT(fromCache(shell) == (expected == next.shells.end() ? ShellCopy() : expected->second));
    RC_ASSERT(shell.origin == (expected == next.shells.end() ? QString() : q(origin)));
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override { os << "OpenAt(" << origin << ")"; }
};

struct Reopen : Command {
  explicit Reopen(const Model&) {}

  void apply(Model&) const override {}

  void run(const Model& model, Sut& sut) const override {
    sut.reopenAt(sut.dir);
    RC_ASSERT(sut.cache->isOpen());
    expectSame(model, sut);
  }

  void show(std::ostream& os) const override { os << "Reopen"; }
};

// The process dies while a change is being written: the file is as the disk
// had it, the last transaction's frames cut `torn` bytes short of its end (0:
// it landed whole). The next run reads it back.
struct DieWhileStoring : Command {
  StoreThread store;
  int torn;

  explicit DieWhileStoring(const Model& model) : store(model), torn(*rc::gen::weightedElement<int>({{1, 0}, {3, 1}, {3, 0}})) {
    if (torn) torn = *rc::gen::inRange(1, 8192);
  }

  void apply(Model& model) const override {
    if (!torn) store.apply(model);
  }

  static QByteArray read(const QString& path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
  }

  void run(const Model& model, Sut& sut) const override {
    sut.cache->drain();
    const QByteArray database = read(sut.file());
    const QByteArray before = read(sut.file("-wal"));
    sut.cache->storeThread(store.update());
    sut.cache->drain();
    const QByteArray after = read(sut.file("-wal"));
    // What a power cut leaves: the main file as it was (WAL mode writes only
    // the log until a checkpoint), and the log up to where the write got.
    QByteArray wal = after;
    if (torn) {
      const qsizetype written = after.size() - before.size();
      RC_PRE(written > 0 && after.startsWith(before));
      wal = after.left(before.size() + std::max<qsizetype>(0, written - torn));
    }
    const QString dir = sut.fresh();
    for (const auto& [suffix, bytes] : {std::pair{"", database}, std::pair{"-wal", wal}}) {
      QFile file(QDir(dir).filePath(QStringLiteral("client-cache.sqlite") + QLatin1String(suffix)));
      RC_ASSERT(file.open(QIODevice::WriteOnly));
      file.write(bytes);
    }
    sut.reopenAt(dir);
    RC_ASSERT(sut.cache->isOpen());
    Model next = model;
    apply(next);
    expectSame(next, sut);
  }

  void show(std::ostream& os) const override {
    os << "DieWhileStoring(";
    store.show(os);
    os << ", torn " << torn << ")";
  }
};

struct Clear : Command {
  explicit Clear(const Model&) {}

  void apply(Model& model) const override { model = {}; }

  void run(const Model&, Sut& sut) const override {
    RC_ASSERT(sut.cache->clear());
    expectSame({}, sut);
  }

  void show(std::ostream& os) const override { os << "Clear"; }
};

}  // namespace

class SyncCacheProp : public QObject {
  Q_OBJECT

private slots:
  void keptEqualsTold() {
    QVERIFY(rc::check("the cache reads back what it was told, across reopening and a write cut short", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<StoreThread, StoreThread, TrimThread, ForgetThread, ForgetEnvironment,
                                                         StoreShell, StoreShell, OpenAt, Reopen, DieWhileStoring, Clear>());
    }));
  }
};

HAL_C2_PROP_MAIN(SyncCacheProp)
#include "tst_SyncCacheProp.moc"
