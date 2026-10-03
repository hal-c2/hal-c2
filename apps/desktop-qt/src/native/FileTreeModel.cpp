#include "FileTreeModel.h"

#include <QSet>

#include <algorithm>
#include <utility>

namespace {

QString parentOf(const QString& path) {
  const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
  return slash < 0 ? QString() : path.left(slash);
}

QString nameOf(const QString& path) {
  return path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
}

// Folders first, then by name as people read it.
void sortEntries(QList<FileTreeModel::Entry>& entries) {
  std::sort(entries.begin(), entries.end(), [](const FileTreeModel::Entry& a, const FileTreeModel::Entry& b) {
    if (a.directory != b.directory) return a.directory;
    const int order = QString::compare(nameOf(a.path), nameOf(b.path), Qt::CaseInsensitive);
    return order != 0 ? order < 0 : a.path < b.path;
  });
}

}  // namespace

FileTreeModel::FileTreeModel(QObject* parent) : QAbstractListModel(parent) {}

void FileTreeModel::clear() {
  beginResetModel();
  m_folders.clear();
  m_search.clear();
  m_searching = false;
  m_rows.clear();
  m_selected.clear();
  endResetModel();
  if (std::exchange(m_expandAll, false)) emit allExpandedChanged();
  emit rootChanged();
  emit selectedChanged();
}

void FileTreeModel::expandUnder(const QString& folder) {
  // By value: expanding loads, and a listing may land while walking.
  const QList<Entry> children = m_folders.value(folder).children;
  for (const Entry& child : children) {
    if (!child.directory || child.ignored) continue;
    if (m_searching) {
      // The search's rows are on screen: the user's tree opens behind them.
      Folder& entry = m_folders[child.path];
      entry.expanded = true;
      if (entry.state == State::Unloaded) {
        entry.state = State::Loading;
        if (m_fetch) m_fetch(child.path);
      }
    } else {
      expand(child.path);
    }
    expandUnder(child.path);
  }
}

void FileTreeModel::expandAll() {
  if (!m_expandAll) {
    m_expandAll = true;
    emit allExpandedChanged();
  }
  expandUnder(QString());
}

void FileTreeModel::collapseAll() {
  if (m_expandAll) {
    m_expandAll = false;
    emit allExpandedChanged();
  }
  beginResetModel();
  for (auto it = m_folders.begin(); it != m_folders.end(); ++it) it->expanded = it.key().isEmpty();
  m_rows = rowsUnder(QString(), 0);
  endResetModel();
}

void FileTreeModel::refresh() {
  if (!m_fetch) return;
  QStringList loadedFolders;
  for (auto it = m_folders.cbegin(); it != m_folders.cend(); ++it) {
    if (it->state == State::Loaded) loadedFolders.append(it.key());
  }
  for (const QString& folder : std::as_const(loadedFolders)) m_fetch(folder);
}

void FileTreeModel::reload() {
  clear();
  Folder& root = m_folders[QString()];
  root.expanded = true;
  load(QString());
}

void FileTreeModel::load(const QString& folder) {
  Folder& entry = folders()[folder];
  entry.state = State::Loading;
  entry.problem.clear();
  if (folder.isEmpty()) emit rootChanged();
  if (m_fetch) m_fetch(folder);
}

void FileTreeModel::setListing(const QString& folder, const QList<Entry>& entries) {
  Folder& entry = m_folders[folder];
  entry.state = State::Loaded;
  entry.problem.clear();
  entry.children = entries;
  sortEntries(entry.children);
  if (!m_searching) refill(folder);
  if (m_expandAll) expandUnder(folder);
  if (folder.isEmpty()) emit rootChanged();
  emit folderSettled(folder);
}

void FileTreeModel::setFailed(const QString& folder, const QString& problem) {
  Folder& entry = m_folders[folder];
  entry.state = State::Failed;
  entry.problem = problem;
  entry.children.clear();
  if (!m_searching) refill(folder);
  if (folder.isEmpty()) emit rootChanged();
  emit folderSettled(folder);
}

void FileTreeModel::setSearch(const std::optional<QList<Entry>>& matches) {
  beginResetModel();
  m_searching = matches.has_value();
  m_search.clear();
  if (matches) {
    Folder& root = m_search[QString()];
    root.state = State::Loaded;
    root.expanded = true;
    QSet<QString> listed;
    const auto add = [&](const Entry& entry) {
      if (listed.contains(entry.path)) return;
      listed.insert(entry.path);
      m_search[parentOf(entry.path)].children.append(entry);
    };
    for (const Entry& match : *matches) {
      // Its folders, so the match shows where it lives.
      QString folder = parentOf(match.path);
      while (!folder.isEmpty()) {
        add({folder, true, false});
        folder = parentOf(folder);
      }
      add(match);
    }
    for (auto it = m_search.begin(); it != m_search.end(); ++it) {
      it->state = State::Loaded;
      it->expanded = true;
      sortEntries(it->children);
    }
  }
  m_rows = rowsUnder(QString(), 0);
  endResetModel();
  emit rootChanged();
}

QString FileTreeModel::rootStatus() const {
  const auto root = folders().constFind(QString());
  if (root == folders().cend()) return QStringLiteral("loading");
  switch (root->state) {
    case State::Loaded:
      return QStringLiteral("ready");
    case State::Failed:
      return QStringLiteral("error");
    default:
      return QStringLiteral("loading");
  }
}

QString FileTreeModel::rootProblem() const {
  return folders().value(QString()).problem;
}

bool FileTreeModel::loaded(const QString& folder) const {
  return m_folders.value(folder).state == State::Loaded;
}

bool FileTreeModel::isExpanded(const QString& folder) const {
  return folders().value(folder).expanded;
}

QList<FileTreeModel::Row> FileTreeModel::rowsUnder(const QString& folder, int depth) const {
  QList<Row> rows;
  const Folder entry = folders().value(folder);
  switch (entry.state) {
    case State::Loading:
      rows.append({folder, depth, QStringLiteral("loading"), false});
      break;
    case State::Failed:
      rows.append({folder, depth, QStringLiteral("error"), false});
      break;
    case State::Loaded:
      for (const Entry& child : entry.children) {
        rows.append({child.path, depth, child.directory ? QStringLiteral("directory") : QStringLiteral("file"), child.ignored});
        if (child.directory && folders().value(child.path).expanded) rows.append(rowsUnder(child.path, depth + 1));
      }
      break;
    case State::Unloaded:
      break;
  }
  return rows;
}

std::pair<int, int> FileTreeModel::childRange(const QString& folder) const {
  if (folder.isEmpty()) return {0, int(m_rows.size())};
  const int row = rowOf(folder);
  if (row < 0) return {-1, -1};
  const int depth = m_rows.at(row).depth;
  int end = row + 1;
  while (end < m_rows.size() && m_rows.at(end).depth > depth) ++end;
  return {row + 1, end};
}

void FileTreeModel::refill(const QString& folder) {
  // A folder shows its children only when it and every folder above it is open.
  if (!folders().value(folder).expanded) return;
  const auto [first, end] = childRange(folder);
  if (first < 0) return;
  const int depth = folder.isEmpty() ? 0 : m_rows.at(first - 1).depth + 1;
  const QList<Row> rows = rowsUnder(folder, depth);
  if (end > first) {
    beginRemoveRows({}, first, end - 1);
    m_rows.remove(first, end - first);
    endRemoveRows();
  }
  if (!rows.isEmpty()) {
    beginInsertRows({}, first, first + int(rows.size()) - 1);
    for (qsizetype i = 0; i < rows.size(); ++i) m_rows.insert(first + i, rows.at(i));
    endInsertRows();
  }
}

void FileTreeModel::toggle(const QString& path) {
  if (isExpanded(path)) {
    collapse(path);
  } else {
    expand(path);
  }
}

void FileTreeModel::expand(const QString& path) {
  Folder& entry = folders()[path];
  if (entry.expanded) return;
  entry.expanded = true;
  if (entry.state == State::Unloaded) {
    entry.state = State::Loading;
    if (m_fetch) m_fetch(path);
  }
  refill(path);
  const int row = rowOf(path);
  if (row >= 0) emit dataChanged(index(row), index(row), {ExpandedRole});
}

void FileTreeModel::collapse(const QString& path) {
  if (path.isEmpty()) return;
  Folder& entry = folders()[path];
  if (!entry.expanded) return;
  const auto [first, end] = childRange(path);
  entry.expanded = false;
  if (first >= 0 && end > first) {
    beginRemoveRows({}, first, end - 1);
    m_rows.remove(first, end - first);
    endRemoveRows();
  }
  const int row = rowOf(path);
  if (row >= 0) emit dataChanged(index(row), index(row), {ExpandedRole});
}

void FileTreeModel::retry(const QString& folder) {
  if (m_folders.value(folder).state != State::Failed) return;
  load(folder);
  if (!m_searching) refill(folder);
}

void FileTreeModel::select(const QString& path) {
  if (path == m_selected) return;
  const int before = rowOf(m_selected);
  m_selected = path;
  const int after = rowOf(m_selected);
  if (before >= 0) emit dataChanged(index(before), index(before), {SelectedRole});
  if (after >= 0) emit dataChanged(index(after), index(after), {SelectedRole});
  emit selectedChanged();
}

int FileTreeModel::rowOf(const QString& path) const {
  if (path.isEmpty()) return -1;
  for (int row = 0; row < m_rows.size(); ++row) {
    const Row& entry = m_rows.at(row);
    if (entry.path == path && (entry.kind == QLatin1String("file") || entry.kind == QLatin1String("directory"))) return row;
  }
  return -1;
}

QStringList FileTreeModel::visiblePaths() const {
  QStringList paths;
  for (const Row& row : m_rows) {
    if (row.kind == QLatin1String("file") || row.kind == QLatin1String("directory")) paths.append(row.path);
  }
  return paths;
}

int FileTreeModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant FileTreeModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  switch (role) {
    case PathRole:
      return row.path;
    case NameRole:
      return nameOf(row.path);
    case DepthRole:
      return row.depth;
    case KindRole:
      return row.kind;
    case ExpandedRole:
      return row.kind == QLatin1String("directory") && folders().value(row.path).expanded;
    case IgnoredRole:
      return row.ignored;
    case ProblemRole:
      return row.kind == QLatin1String("error") ? folders().value(row.path).problem : QString();
    case SelectedRole:
      return !m_selected.isEmpty() && row.path == m_selected && row.kind != QLatin1String("loading") &&
             row.kind != QLatin1String("error");
    default:
      return {};
  }
}

QHash<int, QByteArray> FileTreeModel::roleNames() const {
  return {
      {PathRole, "path"},       {NameRole, "name"},       {DepthRole, "depth"},       {KindRole, "kind"},
      {ExpandedRole, "expanded"}, {IgnoredRole, "ignored"}, {ProblemRole, "problem"}, {SelectedRole, "selected"},
  };
}
