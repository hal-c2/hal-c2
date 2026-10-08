// WorkspaceFiles: the Files tab against a fake MC that holds every listing,
// search and read and answers them in any order, as the MC (which runs each
// RPC on its own) may. Meanwhile the user switches workspace, shows and hides
// the tab, opens and closes folders and files, searches, retries, and the
// agent changes the files and the tree is listed again.
//
// The model is what the user should see: each folder's listing from the
// newest request for it that was answered (an older answer landing later is
// stale), the newest search's matches, the open file as the newest read of it
// found it, and nothing at all from a workspace the user already left. The MC
// reads the disk when the request comes in, so each request's answer is fixed
// when it is asked.

#include "Prop.h"
#include "WorkspaceModels.h"

#include <QJsonArray>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"

namespace {

using Entry = FileTreeModel::Entry;

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

const QStringList kRoots{QStringLiteral("/w1"), QStringLiteral("/w2"), QString()};
const QStringList kFolders{QStringLiteral("d"), QStringLiteral("d/e")};
const QStringList kQueries{QString(), QStringLiteral("w"), QStringLiteral("md"), QStringLiteral("zz")};

QString parentOf(const QString& path) {
  const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
  return slash < 0 ? QString() : path.left(slash);
}

// A workspace's disk at a version: `d/e` deep, a file in each folder, the
// top's and the deepest's named after the version so a stale listing shows.
QList<Entry> listingOf(const QString& root, int version, const QString& folder) {
  const QString tag = root.mid(1);
  const QString v = QString::number(version);
  if (folder.isEmpty()) return {{QStringLiteral("d"), true, false}, {tag + QLatin1Char('-') + v + QStringLiteral(".txt"), false, false}};
  if (folder == QLatin1String("d")) return {{QStringLiteral("d/e"), true, false}, {QStringLiteral("d/") + tag + QStringLiteral(".md"), false, false}};
  return {{QStringLiteral("d/e/") + tag + QLatin1Char('-') + v + QStringLiteral(".txt"), false, false}};
}

QStringList filesOf(const QString& root, int version) {
  QStringList files;
  for (const QString& folder : {QString(), QStringLiteral("d"), QStringLiteral("d/e")}) {
    for (const Entry& entry : listingOf(root, version, folder)) {
      if (!entry.directory) files.append(entry.path);
    }
  }
  return files;
}

QStringList matchesOf(const QString& root, int version, const QString& query) {
  QStringList matches;
  for (const QString& file : filesOf(root, version)) {
    if (file.contains(query)) matches.append(file);
  }
  return matches;
}

QString contentsOf(const QString& root, int version, const QString& path) {
  return root + QLatin1Char(':') + path + QLatin1Char('@') + QString::number(version);
}

QJsonArray toJson(const QList<Entry>& entries) {
  QJsonArray array;
  for (const Entry& entry : entries) {
    array.append(QJsonObject{{QStringLiteral("path"), entry.path},
                             {QStringLiteral("kind"), entry.directory ? QStringLiteral("directory") : QStringLiteral("file")}});
  }
  return array;
}

enum class State { Unloaded, Loading, Loaded, Failed };

// One request the MC holds: what it is for, and its answer as the disk was.
struct Request {
  QString kind;  // list, search or read
  QString key;   // the folder, the query or the file
  QString root;
  int seq = 0;
  QList<Entry> entries;
  QString contents;
  bool operator==(const Request& other) const { return kind == other.kind && key == other.key && root == other.root; }
};

struct Model {
  QString root;
  bool active = false;
  QHash<QString, int> versions;

  struct Folder {
    State state = State::Unloaded;
    QList<Entry> children;
    bool expanded = false;
  };
  // The user's tree; empty until the top folder is first asked for.
  QMap<QString, Folder> tree;
  QString selected;
  QString revealing;

  QString query;
  bool searching = false;
  // The tree shows the search's matches.
  bool searchShown = false;
  QStringList matches;

  QString openPath;
  QString fileStatus = QStringLiteral("none");
  QString text;

  QList<Request> pending;
  int seq = 0;
  // The newest request of each folder, search and read of this workspace.
  QHash<QString, int> latestList;
  int latestSearch = -1;
  int latestRead = -1;

  int version() const { return versions.value(root); }

  int ask(const QString& kind, const QString& key) {
    Request request{kind, key, root, ++seq, {}, {}};
    if (kind == QLatin1String("list")) {
      request.entries = listingOf(root, version(), key);
      latestList[key] = request.seq;
    } else if (kind == QLatin1String("search")) {
      for (const QString& match : matchesOf(root, version(), key)) request.entries.append({match, false, false});
      latestSearch = request.seq;
    } else {
      request.contents = contentsOf(root, version(), key);
      latestRead = request.seq;
    }
    pending.append(request);
    return request.seq;
  }

  // FileTreeModel::reload: a search on screen stays.
  void reloadTree() {
    tree.clear();
    if (!searchShown) selected.clear();
    tree[QString()] = {State::Loading, {}, true};
    ask(QStringLiteral("list"), QString());
  }

  void expand(const QString& folder) {
    Folder& entry = tree[folder];
    if (entry.expanded) return;
    entry.expanded = true;
    if (entry.state != State::Unloaded) return;
    entry.state = State::Loading;
    ask(QStringLiteral("list"), folder);
  }

  // WorkspaceFiles::walkReveal: opens the folders above the file, and selects
  // it once they are listed.
  void walk() {
    if (revealing.isEmpty() || tree.value(QString()).state != State::Loaded) return;
    const QStringList parts = revealing.split(QLatin1Char('/'));
    QString folder;
    for (qsizetype i = 0; i + 1 < parts.size(); ++i) {
      folder = folder.isEmpty() ? parts.at(i) : folder + QLatin1Char('/') + parts.at(i);
      expand(folder);
      if (tree.value(folder).state != State::Loaded) return;
    }
    selected = std::exchange(revealing, QString());
  }

  void setQuery(const QString& next) {
    if (next == query) return;
    query = next;
    // Whatever is on its way answers an older query.
    latestSearch = -1;
    if (query.isEmpty()) {
      searching = false;
      searchShown = false;
      matches.clear();
      return;
    }
    revealing.clear();
    if (root.isEmpty()) return;
    searching = true;
    ask(QStringLiteral("search"), query);
  }

  void close() {
    openPath.clear();
    fileStatus = QStringLiteral("none");
    text.clear();
    latestRead = -1;
  }

  void setTarget(const QString& next) {
    if (next == root) return;
    root = next;
    tree.clear();
    selected.clear();
    revealing.clear();
    latestList.clear();
    query.clear();
    searching = false;
    searchShown = false;
    matches.clear();
    latestSearch = -1;
    close();
    setActive(active);
  }

  void setActive(bool next) {
    active = next;
    if (active && !root.isEmpty() && tree.value(QString()).state == State::Unloaded) reloadTree();
  }

  void open(const QString& path) {
    if (root.isEmpty()) return;
    if (path != openPath || fileStatus != QLatin1String("ready")) {
      openPath = path;
      fileStatus = QStringLiteral("loading");
      ask(QStringLiteral("read"), path);
    }
    setQuery({});
    revealing = path;
    if (tree.value(QString()).state == State::Unloaded) {
      reloadTree();
      return;
    }
    walk();
  }

  // The MC answers the request, the `rank`-th like it (oldest first).
  void answer(const Request& like, int rank, bool ok) {
    qsizetype at = 0;
    for (int seen = rank; at < pending.size(); ++at) {
      if (pending.at(at) == like && seen-- == 0) break;
    }
    const Request request = pending.takeAt(at);
    if (request.root != root) return;
    if (request.kind == QLatin1String("list")) {
      if (latestList.value(request.key) != request.seq) return;
      Folder& folder = tree[request.key];
      folder.state = ok ? State::Loaded : State::Failed;
      folder.children = ok ? request.entries : QList<Entry>();
      walk();
    } else if (request.kind == QLatin1String("search")) {
      if (latestSearch != request.seq) return;
      searching = false;
      searchShown = true;
      matches.clear();
      if (ok) {
        for (const Entry& entry : request.entries) matches.append(entry.path);
      }
    } else {
      if (latestRead != request.seq) return;
      fileStatus = ok ? QStringLiteral("ready") : QStringLiteral("error");
      text = ok ? request.contents : QString();
    }
  }

  void rowsUnder(const QString& path, QStringList& rows) const {
    const Folder folder = tree.value(path);
    switch (folder.state) {
      case State::Loading:
        rows.append(path + QStringLiteral(" loading"));
        break;
      case State::Failed:
        rows.append(path + QStringLiteral(" error"));
        break;
      case State::Loaded:
        for (const Entry& child : folder.children) {
          rows.append(child.path + (child.directory ? QStringLiteral(" directory") : QStringLiteral(" file")));
          if (child.directory && tree.value(child.path).expanded) rowsUnder(child.path, rows);
        }
        break;
      case State::Unloaded:
        break;
    }
  }

  // The tree's rows as "path kind".
  QStringList rows() const {
    QStringList rows;
    if (!searchShown) {
      if (tree.value(QString()).expanded) rowsUnder(QString(), rows);
      return rows;
    }
    // The matches under their folders, folders first: the fixed disk's
    // folders all come before its files.
    QStringList folders;
    for (const QString& match : matches) {
      for (QString folder = parentOf(match); !folder.isEmpty(); folder = parentOf(folder)) {
        if (!folders.contains(folder)) folders.append(folder);
      }
    }
    const std::function<void(const QString&)> under = [&](const QString& folder) {
      for (const QString& child : kFolders) {
        if (parentOf(child) == folder && folders.contains(child)) {
          rows.append(child + QStringLiteral(" directory"));
          under(child);
        }
      }
      QStringList files;
      for (const QString& match : matches) {
        if (parentOf(match) == folder && !files.contains(match)) files.append(match);
      }
      std::sort(files.begin(), files.end(), [](const QString& a, const QString& b) { return QString::compare(a, b, Qt::CaseInsensitive) < 0; });
      for (const QString& file : files) rows.append(file + QStringLiteral(" file"));
    };
    under(QString());
    return rows;
  }

  QString rootStatus() const {
    if (searchShown) return QStringLiteral("ready");
    switch (tree.value(QString()).state) {
      case State::Loaded:
        return QStringLiteral("ready");
      case State::Failed:
        return QStringLiteral("error");
      default:
        return QStringLiteral("loading");
    }
  }
};

void showValue(const Request& request, std::ostream& os) {
  os << request.kind.toStdString() << " '" << request.key.toStdString() << "' of " << request.root.toStdString();
}

struct Sut {
  struct Held {
    Request request;
    FakeMc::Rpc rpc;
  };

  FakeMc mc;
  McClient client;
  std::unique_ptr<WorkspaceFiles> files;
  std::unique_ptr<halc2::prop::ModelMirror> mirror;
  QObject barrier;
  QHash<QString, int> versions;
  QList<Held> held;

  Sut() {
    const auto hold = [this](const QString& kind, const QString& keyField) {
      return [this, kind, keyField](const FakeMc::Rpc& rpc) {
        const QString root = rpc.payload.value(QLatin1String("cwd")).toString();
        const QString key = rpc.payload.value(keyField).toString();
        const int version = versions.value(root);
        Request request{kind, key, root, 0, {}, {}};
        if (kind == QLatin1String("list")) {
          request.entries = listingOf(root, version, key);
        } else if (kind == QLatin1String("search")) {
          for (const QString& match : matchesOf(root, version, key)) request.entries.append({match, false, false});
        } else {
          request.contents = contentsOf(root, version, key);
        }
        held.append({request, rpc});
      };
    };
    mc.onRpc(QStringLiteral("projects.listEntries"), hold(QStringLiteral("list"), QStringLiteral("directoryPath")));
    mc.onRpc(QStringLiteral("projects.searchEntries"), hold(QStringLiteral("search"), QStringLiteral("query")));
    mc.onRpc(QStringLiteral("projects.readFile"), hold(QStringLiteral("read"), QStringLiteral("relativePath")));
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    halc2::prop::until([this] { return client.isReady(); });
    files = std::make_unique<WorkspaceFiles>(&client);
    files->setSearchDelay(0);
    files->setTarget(QStringLiteral("env-a"), QString());
    mirror = std::make_unique<halc2::prop::ModelMirror>(files->tree());
  }
  ~Sut() {
    mirror.reset();
    files.reset();
  }

  // Once this comes back, everything the client sent before it has reached
  // the MC and every answer sent before it has been read.
  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) {
      *answered = true;
    });
    return halc2::prop::until([&] { return *answered; });
  }

  void answer(const Request& request, int rank, bool ok) {
    for (qsizetype i = 0; i < held.size(); ++i) {
      if (!(held.at(i).request == request) || rank-- > 0) continue;
      const Held answered = held.takeAt(i);
      if (!ok) {
        mc.refuse(answered.rpc, QStringLiteral("no"));
      } else if (request.kind == QLatin1String("read")) {
        mc.reply(answered.rpc, QJsonObject{{QStringLiteral("contents"), answered.request.contents}});
      } else {
        mc.reply(answered.rpc, QJsonObject{{QStringLiteral("entries"), toJson(answered.request.entries)}});
      }
      return;
    }
    RC_FAIL("the MC holds no " + rc::toString(request.kind) + " '" + rc::toString(request.key) + "'");
  }

  QStringList rows() const {
    QStringList rows;
    FileTreeModel* tree = files->tree();
    for (int row = 0; row < tree->rowCount(); ++row) {
      const QModelIndex at = tree->index(row);
      rows.append(at.data(FileTreeModel::PathRole).toString() + QLatin1Char(' ') + at.data(FileTreeModel::KindRole).toString());
    }
    return rows;
  }
};

QStringList asked(const QList<Request>& requests) {
  QStringList asked;
  for (const Request& request : requests) asked.append(request.kind + QLatin1Char(' ') + request.key + QStringLiteral(" of ") + request.root);
  asked.sort();
  return asked;
}

void check(const Model& expected, Sut& sut) {
  const QStringList pending = asked(expected.pending);
  // A search goes out from a timer, after the command.
  halc2::prop::until([&] {
    QList<Request> held;
    for (const Sut::Held& request : sut.held) held.append(request.request);
    return asked(held) == pending;
  });
  RC_ASSERT(sut.sync());
  QList<Request> held;
  for (const Sut::Held& request : sut.held) held.append(request.request);
  RC_ASSERT(asked(held) == pending);

  WorkspaceFiles& files = *sut.files;
  RC_ASSERT(files.root() == expected.root);
  RC_ASSERT(sut.rows() == expected.rows());
  RC_ASSERT(files.tree()->rootStatus() == expected.rootStatus());
  RC_ASSERT(files.tree()->selectedPath() == expected.selected);
  RC_ASSERT(files.tree()->filtered() == expected.searchShown);
  RC_ASSERT(files.query() == expected.query);
  RC_ASSERT(files.searching() == expected.searching);
  RC_ASSERT(files.openPath() == expected.openPath);
  RC_ASSERT(files.fileStatus() == expected.fileStatus);
  if (expected.fileStatus != QLatin1String("loading")) RC_ASSERT(files.text() == expected.text);
  const QStringList problems = sut.mirror->problems();
  RC_ASSERT(problems == QStringList());
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(expected, sut);
  }
};

struct SetTarget : Step<SetTarget> {
  QString root = *oneOf(kRoots);
  explicit SetTarget(const Model&) {}
  void apply(Model& model) const override { model.setTarget(root); }
  void act(const Model&, Sut& sut) const { sut.files->setTarget(QStringLiteral("env-a"), root); }
  void show(std::ostream& os) const override { os << "workspace '" << root.toStdString() << "'"; }
};

struct SetActive : Step<SetActive> {
  bool active = *rc::gen::arbitrary<bool>();
  explicit SetActive(const Model&) {}
  void apply(Model& model) const override { model.setActive(active); }
  void act(const Model&, Sut& sut) const { sut.files->setActive(active); }
  void show(std::ostream& os) const override { os << (active ? "show the tab" : "hide the tab"); }
};

// The user clicks a folder the tree shows.
struct Toggle : Step<Toggle> {
  QString folder;
  explicit Toggle(const Model& model) {
    folder = *oneOf(kFolders);
    RC_PRE(!model.searchShown);
    RC_PRE(model.tree.value(parentOf(folder)).state == State::Loaded && model.tree.value(parentOf(folder)).expanded);
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(!model.searchShown);
    const Model::Folder parent = model.tree.value(parentOf(folder));
    RC_PRE(parent.state == State::Loaded && parent.expanded);
    RC_PRE(std::any_of(parent.children.begin(), parent.children.end(), [&](const Entry& entry) { return entry.path == folder; }));
  }
  void apply(Model& model) const override {
    if (model.tree.value(folder).expanded) {
      model.tree[folder].expanded = false;
    } else {
      model.expand(folder);
    }
  }
  void act(const Model&, Sut& sut) const { sut.files->tree()->toggle(folder); }
  void show(std::ostream& os) const override { os << "toggle " << folder.toStdString(); }
};

struct Answer : Step<Answer> {
  Request request;
  int rank = 0;
  bool ok = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  explicit Answer(const Model& model) {
    RC_PRE(!model.pending.isEmpty());
    const int index = *rc::gen::inRange<int>(0, int(model.pending.size()));
    request = model.pending.at(index);
    for (int i = 0; i < index; ++i) rank += model.pending.at(i) == request ? 1 : 0;
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(std::count(model.pending.begin(), model.pending.end(), request) > rank);
  }
  void apply(Model& model) const override { model.answer(request, rank, ok); }
  void act(const Model&, Sut& sut) const { sut.answer(request, rank, ok); }
  void show(std::ostream& os) const override {
    os << (ok ? "answer " : "refuse ") << request.kind.toStdString() << " '" << request.key.toStdString() << "' of '"
       << request.root.toStdString() << "' #" << rank;
  }
};

// The agent changed the workspace: the disk moves on and every listed folder
// is asked for again.
struct Change : Step<Change> {
  explicit Change(const Model& model) { RC_PRE(!model.root.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.root.isEmpty()); }
  void apply(Model& model) const override {
    ++model.versions[model.root];
    for (auto it = model.tree.cbegin(); it != model.tree.cend(); ++it) {
      if (it->state == State::Loaded) model.ask(QStringLiteral("list"), it.key());
    }
  }
  void act(const Model& before, Sut& sut) const {
    sut.versions[before.root] = before.version() + 1;
    sut.files->tree()->refresh();
  }
  void show(std::ostream& os) const override { os << "the agent changes the workspace"; }
};

struct Retry : Step<Retry> {
  QString folder;
  explicit Retry(const Model& model) {
    QStringList failed;
    for (auto it = model.tree.cbegin(); it != model.tree.cend(); ++it) {
      if (it->state == State::Failed) failed.append(it.key());
    }
    RC_PRE(!failed.isEmpty());
    folder = *oneOf(failed);
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(!model.searchShown && model.tree.value(folder).state == State::Failed);
  }
  void apply(Model& model) const override {
    model.tree[folder].state = State::Loading;
    model.ask(QStringLiteral("list"), folder);
  }
  // The top folder's "Try again", or a folder's error row.
  void act(const Model&, Sut& sut) const {
    if (folder.isEmpty()) {
      sut.files->reload();
    } else {
      sut.files->tree()->retry(folder);
    }
  }
  void show(std::ostream& os) const override { os << "retry '" << folder.toStdString() << "'"; }
};

struct Query : Step<Query> {
  QString query = *oneOf(kQueries);
  explicit Query(const Model&) {}
  void apply(Model& model) const override { model.setQuery(query); }
  void act(const Model&, Sut& sut) const { sut.files->setQuery(query); }
  void show(std::ostream& os) const override { os << "search '" << query.toStdString() << "'"; }
};

struct Open : Step<Open> {
  QString path;
  explicit Open(const Model& model) {
    RC_PRE(!model.root.isEmpty());
    path = *oneOf(filesOf(model.root, model.version()));
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.root.isEmpty()); }
  void apply(Model& model) const override { model.open(path); }
  void act(const Model&, Sut& sut) const { sut.files->openFile(path); }
  void show(std::ostream& os) const override { os << "open " << path.toStdString(); }
};

struct Close : Step<Close> {
  explicit Close(const Model&) {}
  void apply(Model& model) const override { model.close(); }
  void act(const Model&, Sut& sut) const { sut.files->closeFile(); }
  void show(std::ostream& os) const override { os << "close the file"; }
};

}  // namespace

class WorkspaceFilesProp : public QObject {
  Q_OBJECT

private slots:
  void files() {
    QVERIFY(rc::check("the Files tab shows the newest answers about the workspace on screen", [] {
      Sut sut;
      RC_ASSERT(sut.client.isReady());
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<SetTarget, SetActive, Toggle, Toggle, Answer, Answer, Answer, Answer, Change,
                                                         Retry, Query, Open, Open, Close>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceFilesProp)
#include "tst_WorkspaceFilesProp.moc"
