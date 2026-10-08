// FileTreeModel: the Files tab's tree as the user sees it while folders are
// expanded, collapsed and listed in any order, listings land late (for a
// folder already collapsed, or under one that is), fail and are retried, the
// workspace changes on disk and is listed again, a search swaps its own tree
// in and out, and every folder is expanded or collapsed at once.
//
// The model is the disk, the user's tree and the search's (each folder:
// whether it is listed, its children as last listed, whether it is open), and
// the folders asked for and not answered yet. The visible rows follow from it.

#include "Prop.h"
#include "WorkspaceModels.h"

#include "FileTreeModel.h"

namespace {

using Entry = FileTreeModel::Entry;

const QStringList kDirectories{QStringLiteral("a"), QStringLiteral("a/b"), QStringLiteral("c"), QStringLiteral("n")};
const QStringList kFiles{QStringLiteral("R"), QStringLiteral("a/x"), QStringLiteral("a/b/y"), QStringLiteral("c/z"), QStringLiteral("n/q")};
// Files the agent creates and deletes.
const QStringList kOptional{QStringLiteral("a/new"), QStringLiteral("Z"), QStringLiteral("c/Big")};

// rc::gen::elementOf finds no begin() for a QList.
rc::Gen<QString> oneOf(const QStringList& paths) { return rc::gen::elementOf(std::vector<QString>(paths.begin(), paths.end())); }

QString parentOf(const QString& path) {
  const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
  return slash < 0 ? QString() : path.left(slash);
}

QString nameOf(const QString& path) { return path.mid(path.lastIndexOf(QLatin1Char('/')) + 1); }

bool isDirectory(const QString& path) { return kDirectories.contains(path); }
// Git ignores `n`, so expanding everything leaves it closed.
bool isIgnored(const QString& path) { return path == QLatin1String("n") || path.startsWith(QLatin1String("n/")); }

Entry entryOf(const QString& path) { return {path, isDirectory(path), isIgnored(path)}; }

QList<Entry> sorted(QList<Entry> entries) {
  std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
    if (a.directory != b.directory) return a.directory;
    const int order = QString::compare(nameOf(a.path), nameOf(b.path), Qt::CaseInsensitive);
    return order != 0 ? order < 0 : a.path < b.path;
  });
  return entries;
}

enum class State { Unloaded, Loading, Loaded, Failed };

struct Folder {
  State state = State::Unloaded;
  QList<Entry> children;
  bool expanded = false;
};

struct Model {
  // The files on disk.
  QSet<QString> present{kFiles.begin(), kFiles.end()};
  QMap<QString, Folder> user;
  QMap<QString, Folder> search;
  bool searching = false;
  bool expandAll = false;
  // Folders asked for and not answered, as a multiset.
  QStringList pending;
  QString selected;

  QMap<QString, Folder>& shown() { return searching ? search : user; }
  const QMap<QString, Folder>& shown() const { return searching ? search : user; }

  QList<Entry> listing(const QString& folder) const {
    QList<Entry> entries;
    for (const QString& path : kDirectories) {
      if (parentOf(path) == folder) entries.append(entryOf(path));
    }
    for (const QString& path : present) {
      if (parentOf(path) == folder) entries.append(entryOf(path));
    }
    return sorted(entries);
  }

  void fetch(const QString& folder) { pending.append(folder); }

  void expand(const QString& path) {
    Folder& folder = shown()[path];
    if (folder.expanded) return;
    folder.expanded = true;
    if (folder.state != State::Unloaded) return;
    if (!searching) {
      folder.state = State::Loading;
      fetch(path);
      return;
    }
    // A folder the search did not list shows what the user's tree has of it,
    // listed once for both.
    Folder& listed = user[path];
    if (listed.state == State::Unloaded) {
      listed.state = State::Loading;
      fetch(path);
    }
    folder.state = listed.state;
    folder.children = listed.children;
  }

  void expandUnder(const QString& path) {
    const QList<Entry> children = user.value(path).children;
    for (const Entry& child : children) {
      if (!child.directory || child.ignored) continue;
      if (searching) {
        Folder& folder = user[child.path];
        folder.expanded = true;
        if (folder.state == State::Unloaded) {
          folder.state = State::Loading;
          fetch(child.path);
        }
      } else {
        expand(child.path);
      }
      expandUnder(child.path);
    }
  }

  void answer(const QString& path, bool ok) {
    pending.removeOne(path);
    Folder& folder = user[path];
    folder.state = ok ? State::Loaded : State::Failed;
    folder.children = ok ? listing(path) : QList<Entry>();
    if (searching && search.value(path).state == State::Loading) {
      search[path].state = folder.state;
      search[path].children = folder.children;
    }
    if (ok && expandAll) expandUnder(path);
  }

  struct Row {
    QString path;
    int depth;
    QString kind;
    bool expanded;
    bool ignored;
    bool selected;
    bool operator==(const Row&) const = default;
  };

  void rowsUnder(const QString& path, int depth, QList<Row>& rows) const {
    const Folder folder = shown().value(path);
    switch (folder.state) {
      case State::Loading:
        rows.append({path, depth, QStringLiteral("loading"), false, false, false});
        break;
      case State::Failed:
        rows.append({path, depth, QStringLiteral("error"), false, false, false});
        break;
      case State::Loaded:
        for (const Entry& child : folder.children) {
          const bool open = child.directory && shown().value(child.path).expanded;
          rows.append({child.path, depth, child.directory ? QStringLiteral("directory") : QStringLiteral("file"), open, child.ignored,
                       !selected.isEmpty() && child.path == selected});
          if (open) rowsUnder(child.path, depth + 1, rows);
        }
        break;
      case State::Unloaded:
        break;
    }
  }

  QList<Row> rows() const {
    QList<Row> rows;
    if (shown().value(QString()).expanded) rowsUnder(QString(), 0, rows);
    return rows;
  }

  QString rootStatus() const {
    if (!shown().contains(QString())) return QStringLiteral("loading");
    switch (shown().value(QString()).state) {
      case State::Loaded:
        return QStringLiteral("ready");
      case State::Failed:
        return QStringLiteral("error");
      default:
        return QStringLiteral("loading");
    }
  }
};

void showValue(const Model::Row& row, std::ostream& os) {
  os << std::string(size_t(row.depth) * 2, ' ') << row.path.toStdString() << " " << row.kind.toStdString()
     << (row.expanded ? " open" : "") << (row.ignored ? " ignored" : "") << (row.selected ? " selected" : "");
}

struct Sut {
  FileTreeModel tree;
  QStringList fetched;
  halc2::prop::ModelMirror mirror{&tree};

  Sut() { tree.setFetch([this](const QString& folder) { fetched.append(folder); }); }

  QList<Model::Row> rows() const {
    QList<Model::Row> rows;
    for (int row = 0; row < tree.rowCount(); ++row) {
      const QModelIndex at = tree.index(row);
      rows.append({at.data(FileTreeModel::PathRole).toString(), at.data(FileTreeModel::DepthRole).toInt(),
                   at.data(FileTreeModel::KindRole).toString(), at.data(FileTreeModel::ExpandedRole).toBool(),
                   at.data(FileTreeModel::IgnoredRole).toBool(), at.data(FileTreeModel::SelectedRole).toBool()});
    }
    return rows;
  }
};

using Command = rc::state::Command<Model, Sut>;

// What every command ends on: the rows, the folders asked for, the tree's signals.
void check(const Model& expected, Sut& sut) {
  RC_ASSERT(sut.rows() == expected.rows());
  QStringList asked = sut.fetched;
  QStringList pending = expected.pending;
  asked.sort();
  pending.sort();
  RC_ASSERT(asked == pending);
  RC_ASSERT(sut.tree.rootStatus() == expected.rootStatus());
  RC_ASSERT(sut.tree.selectedPath() == expected.selected);
  RC_ASSERT(sut.tree.filtered() == expected.searching);
  RC_ASSERT(sut.tree.allExpanded() == expected.expandAll);
  const QStringList problems = sut.mirror.problems();
  RC_ASSERT(problems == QStringList());
}

struct Reload : Command {
  void apply(Model& model) const override {
    // A search on screen stays; the user's tree starts over behind it.
    model.user = {};
    model.expandAll = false;
    if (!model.searching) model.selected.clear();
    // The owner drops answers to what it asked before (WorkspaceFiles' generation).
    model.pending.clear();
    model.user[QString()].expanded = true;
    model.user[QString()].state = State::Loading;
    model.fetch(QString());
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.fetched.clear();
    sut.tree.reload();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "reload"; }
};

struct Expand : Command {
  QString path = *oneOf(kDirectories);
  void apply(Model& model) const override { model.expand(path); }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.expand(path);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "expand " << path.toStdString(); }
};

struct Collapse : Command {
  QString path = *oneOf(kDirectories);
  void apply(Model& model) const override { model.shown()[path].expanded = false; }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.collapse(path);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "collapse " << path.toStdString(); }
};

// The MC answers one of the folders asked for, as the disk is now, or fails.
struct Answer : Command {
  QString path;
  bool ok = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  explicit Answer(const Model& model) {
    RC_PRE(!model.pending.isEmpty());
    path = *oneOf(model.pending);
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.pending.contains(path)); }
  void apply(Model& model) const override { model.answer(path, ok); }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.fetched.removeOne(path);
    if (ok) {
      sut.tree.setListing(path, before.listing(path));
    } else {
      sut.tree.setFailed(path, QStringLiteral("no such folder"));
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << (ok ? "list " : "fail ") << "'" << path.toStdString() << "'"; }
};

struct Retry : Command {
  QString path = *oneOf(QStringList{QString()} + kDirectories);
  void apply(Model& model) const override {
    if (model.user.value(path).state != State::Failed) return;
    model.user[path].state = State::Loading;
    model.fetch(path);
    if (model.searching && model.search.value(path).state == State::Failed) model.search[path].state = State::Loading;
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.retry(path);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "retry '" << path.toStdString() << "'"; }
};

// The agent changed the workspace: every listed folder is asked for again.
struct Refresh : Command {
  void apply(Model& model) const override {
    for (auto it = model.user.cbegin(); it != model.user.cend(); ++it) {
      if (it->state == State::Loaded) model.fetch(it.key());
    }
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.refresh();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "refresh"; }
};

struct Touch : Command {
  QString path = *oneOf(kOptional + QStringList{QStringLiteral("R")});
  void apply(Model& model) const override {
    if (!model.present.remove(path)) model.present.insert(path);
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "disk toggles " << path.toStdString(); }
};

struct ExpandAll : Command {
  void apply(Model& model) const override {
    model.expandAll = true;
    model.expandUnder(QString());
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.expandAll();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "expand all"; }
};

struct CollapseAll : Command {
  void apply(Model& model) const override {
    model.expandAll = false;
    for (auto it = model.user.begin(); it != model.user.end(); ++it) it->expanded = it.key().isEmpty();
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.collapseAll();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "collapse all"; }
};

struct Search : Command {
  QStringList matches = *rc::gen::container<QStringList>(*rc::gen::inRange(0, 4), oneOf(kDirectories + kFiles + kOptional));
  void apply(Model& model) const override {
    model.searching = true;
    model.search = {};
    model.search[QString()] = {State::Loaded, {}, true};
    QSet<QString> listed;
    const auto add = [&](const Entry& entry) {
      if (listed.contains(entry.path)) return;
      listed.insert(entry.path);
      model.search[parentOf(entry.path)].children.append(entry);
    };
    for (const QString& match : matches) {
      // A match's folders are listed as plain folders.
      for (QString folder = parentOf(match); !folder.isEmpty(); folder = parentOf(folder)) add({folder, true, false});
      add(entryOf(match));
    }
    for (auto it = model.search.begin(); it != model.search.end(); ++it) {
      it->state = State::Loaded;
      it->expanded = true;
      it->children = sorted(it->children);
    }
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    QList<Entry> entries;
    for (const QString& match : matches) entries.append(entryOf(match));
    sut.tree.setSearch(entries);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "search finds "; rc::show(matches, os); }
};

struct EndSearch : Command {
  void apply(Model& model) const override {
    model.searching = false;
    model.search = {};
  }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.setSearch(std::nullopt);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "end search"; }
};

struct Select : Command {
  QString path = *oneOf(kDirectories + kFiles + QStringList{QString()});
  void apply(Model& model) const override { model.selected = path; }
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    sut.tree.select(path);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "select '" << path.toStdString() << "'"; }
};

}  // namespace

class WorkspaceTreeProp : public QObject {
  Q_OBJECT

private slots:
  void tree() {
    QVERIFY(rc::check("the file tree shows what was listed of the folders the user opened", [] {
      Sut sut;
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<Reload, Expand, Expand, Collapse, Answer, Answer, Answer, Retry, Refresh,
                                                         Touch, ExpandAll, CollapseAll, Search, EndSearch, Select>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceTreeProp)
#include "tst_WorkspaceTreeProp.moc"
