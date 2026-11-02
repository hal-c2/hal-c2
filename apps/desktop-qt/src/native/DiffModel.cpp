#include "DiffModel.h"

#include <QHash>
#include <QJsonObject>
#include <QVariantMap>

#include <algorithm>

namespace {

// "@@ -12,3 +14,5 @@ ..." -> 12 and 14.
void hunkStart(QStringView header, int& oldLine, int& newLine) {
  oldLine = 0;
  newLine = 0;
  const auto numberAfter = [&](QChar sign) {
    const qsizetype at = header.indexOf(sign, 2);
    if (at < 0) {
      return 0;
    }
    qsizetype end = at + 1;
    while (end < header.size() && header[end].isDigit()) {
      ++end;
    }
    return header.mid(at + 1, end - at - 1).toInt();
  };
  oldLine = numberAfter(QLatin1Char('-'));
  newLine = numberAfter(QLatin1Char('+'));
}

QString stripPrefix(QStringView path) {
  if (path.startsWith(u"a/") || path.startsWith(u"b/")) {
    return path.mid(2).toString();
  }
  return path.toString();
}

}  // namespace

DiffModel::DiffModel(QObject* parent) : QAbstractListModel(parent) {}

void DiffModel::setPatch(const QString& patch) {
  const bool listed = std::any_of(m_files.begin(), m_files.end(), [](const File& file) { return !file.state.isEmpty() || file.partial; });
  if (patch == m_patch && !listed) {
    return;
  }
  const bool allBefore = allExpanded();
  beginResetModel();
  m_patch = patch;
  parse();
  int total = 0;
  for (const File& file : m_files) {
    total += file.lineCount;
  }
  for (File& file : m_files) {
    file.expanded = !m_collapsedByDefault && total <= autoExpandLines;
    if (file.expanded) {
      ensureLines(file);
    }
  }
  rebuildRows();
  endResetModel();
  emit patchChanged();
  if (allExpanded() != allBefore) {
    emit expansionChanged();
  }
}

void DiffModel::parse() {
  m_maxColumns = 0;
  m_files = parseFrom(0);
  m_additions = 0;
  m_deletions = 0;
  for (const File& each : m_files) {
    m_additions += each.additions;
    m_deletions += each.deletions;
  }
}

std::vector<DiffModel::File> DiffModel::parseFrom(qsizetype from) {
  std::vector<File> files;
  const QStringView text(m_patch);
  File* file = nullptr;
  bool inHunk = false;
  qsizetype at = from;
  while (at < text.size()) {
    qsizetype end = text.indexOf(QLatin1Char('\n'), at);
    if (end < 0) {
      end = text.size();
    }
    const QStringView line = text.mid(at, end - at);
    if (line.startsWith(u"diff --git ")) {
      if (file) {
        file->end = int(at);
      }
      files.push_back({});
      file = &files.back();
      file->body = int(end + 1);
      inHunk = false;
      // "diff --git a/x b/x": good enough until ---/+++ or rename lines say.
      const qsizetype split = line.lastIndexOf(u" b/");
      if (split > 0) {
        file->path = line.mid(split + 3).toString();
      }
    } else if (!file) {
      // Anything before the first file header is not ours to show.
    } else if (line.startsWith(u"@@")) {
      if (!inHunk) {
        file->body = int(at);
      }
      inHunk = true;
      ++file->lineCount;
    } else if (inHunk) {
      ++file->lineCount;
      if (line.startsWith(u'+')) {
        ++file->additions;
      } else if (line.startsWith(u'-')) {
        ++file->deletions;
      }
      m_maxColumns = std::max(m_maxColumns, int(line.size()));
    } else if (line.startsWith(u"+++ ") && !line.endsWith(u"/dev/null")) {
      file->path = stripPrefix(line.mid(4));
    } else if (line.startsWith(u"--- ") && !line.endsWith(u"/dev/null")) {
      file->previousPath = stripPrefix(line.mid(4));
    } else if (line.startsWith(u"new file")) {
      file->change = QStringLiteral("added");
    } else if (line.startsWith(u"deleted file")) {
      file->change = QStringLiteral("deleted");
    } else if (line.startsWith(u"rename from ")) {
      file->change = QStringLiteral("renamed");
      file->previousPath = line.mid(12).toString();
    } else if (line.startsWith(u"rename to ")) {
      file->path = line.mid(10).toString();
    } else if (line.startsWith(u"Binary files") || line.startsWith(u"GIT binary patch")) {
      file->binary = true;
    }
    at = end + 1;
  }
  if (file) {
    file->end = int(text.size());
  }
  for (File& each : files) {
    // A file with no hunks has its body at its end.
    if (each.lineCount == 0) {
      each.body = each.end;
    }
    if (each.change != QLatin1String("renamed") && each.previousPath == each.path) {
      each.previousPath.clear();
    }
    if (each.change == QLatin1String("deleted") && each.path.isEmpty()) {
      each.path = each.previousPath;
    }
  }
  return files;
}

void DiffModel::setFiles(const QJsonArray& files) {
  const bool allBefore = allExpanded();
  beginResetModel();
  m_patch.clear();
  m_files.clear();
  m_additions = 0;
  m_deletions = 0;
  m_maxColumns = 0;
  for (const QJsonValue& value : files) {
    const QJsonObject stat = value.toObject();
    File file;
    file.path = stat.value(QLatin1String("path")).toString();
    file.previousPath = stat.value(QLatin1String("previousPath")).toString();
    if (!file.previousPath.isEmpty() && file.previousPath != file.path) {
      file.change = QStringLiteral("renamed");
    } else {
      file.previousPath.clear();
    }
    file.additions = stat.value(QLatin1String("additions")).toInt();
    file.deletions = stat.value(QLatin1String("deletions")).toInt();
    file.state = QStringLiteral("unloaded");
    file.parsed = true;
    m_additions += file.additions;
    m_deletions += file.deletions;
    m_files.push_back(std::move(file));
  }
  rebuildRows();
  endResetModel();
  emit patchChanged();
  if (allExpanded() != allBefore) emit expansionChanged();
}

bool DiffModel::setFilePatch(int file, const QString& patch, bool partial) {
  // A file whose changes are here keeps them.
  if (file < 0 || file >= fileCount() || !waiting(m_files[size_t(file)])) return false;
  const qsizetype from = m_patch.size();
  // Its own part of the patch, after every other file's.
  m_patch += patch;
  if (!m_patch.endsWith(QLatin1Char('\n'))) m_patch += QLatin1Char('\n');
  const int columns = m_maxColumns;
  std::vector<File> parsed = parseFrom(from);
  File& entry = m_files[size_t(file)];
  const auto found = std::find_if(parsed.begin(), parsed.end(), [&](const File& each) { return each.path == entry.path; });
  if (found == parsed.end()) {
    m_patch.truncate(from);
    m_maxColumns = columns;
    return false;
  }
  const bool allBefore = allExpanded();
  const int header = rowOfFile(file);
  // The counts listed are whole; the patch may not be.
  const int additions = entry.additions;
  const int deletions = entry.deletions;
  const bool expanded = entry.expanded;
  entry = std::move(*found);
  entry.additions = additions;
  entry.deletions = deletions;
  entry.partial = partial;
  entry.expanded = expanded;
  if (expanded) {
    ensureLines(entry);
    const int shown = linesShown(entry);
    if (shown > 0) {
      beginInsertRows({}, header + 1, header + shown);
      std::vector<Row> rows;
      for (int l = 0; l < shown; ++l) rows.push_back({file, l});
      m_rows.insert(m_rows.begin() + header + 1, rows.begin(), rows.end());
      endInsertRows();
    }
  }
  const QModelIndex at = index(header);
  emit dataChanged(at, at);
  emit patchChanged();
  if (allExpanded() != allBefore) emit expansionChanged();
  return true;
}

void DiffModel::setFileState(int file, const QString& state, const QString& note) {
  if (file < 0 || file >= fileCount()) return;
  File& entry = m_files[size_t(file)];
  // A file whose changes are here keeps them.
  if (!waiting(entry)) return;
  entry.state = state;
  entry.note = note;
  const QModelIndex at = index(rowOfFile(file));
  emit dataChanged(at, at, {StateRole, NoteRole});
}

QString DiffModel::withoutTruncatedMarker(const QString& patch) {
  static const QString marker = QStringLiteral("\n\n[truncated]");
  return patch.endsWith(marker) ? patch.left(patch.size() - marker.size()) + QLatin1Char('\n') : patch;
}

void DiffModel::ensureLines(File& file) {
  if (file.parsed) {
    return;
  }
  file.parsed = true;
  file.lines.reserve(size_t(file.lineCount));
  const QStringView text(m_patch);
  int oldLine = 0;
  int newLine = 0;
  qsizetype at = file.body;
  while (at < file.end) {
    qsizetype end = text.indexOf(QLatin1Char('\n'), at);
    if (end < 0 || end > file.end) {
      end = file.end;
    }
    const QStringView line = text.mid(at, end - at);
    Line row{int(at), int(line.size()), ' ', 0, 0};
    if (line.startsWith(u"@@")) {
      row.sign = '@';
      hunkStart(line, oldLine, newLine);
    } else if (line.startsWith(u'+')) {
      row.sign = '+';
      row.newLine = newLine++;
    } else if (line.startsWith(u'-')) {
      row.sign = '-';
      row.oldLine = oldLine++;
    } else if (line.startsWith(u'\\')) {
      row.sign = '\\';
    } else if (line.isEmpty() && end >= file.end) {
      break;  // the patch's trailing newline
    } else {
      row.oldLine = oldLine++;
      row.newLine = newLine++;
    }
    file.lines.push_back(row);
    at = end + 1;
  }
  pairLines(file);
}

void DiffModel::pairLines(File& file) const {
  file.pairs.clear();
  const int count = int(file.lines.size());
  int i = 0;
  while (i < count) {
    const char sign = file.lines[size_t(i)].sign;
    if (sign != '-' && sign != '+') {
      file.pairs.push_back({i, sign == '\\' ? -1 : i});
      ++i;
      continue;
    }
    // A run of removals and the additions after it, side by side.
    int removed = i;
    while (removed < count && file.lines[size_t(removed)].sign == '-') {
      ++removed;
    }
    int added = removed;
    while (added < count && file.lines[size_t(added)].sign == '+') {
      ++added;
    }
    const int left = removed - i;
    const int right = added - removed;
    for (int k = 0; k < std::max(left, right); ++k) {
      file.pairs.push_back({k < left ? i + k : -1, k < right ? removed + k : -1});
    }
    i = added;
  }
}

int DiffModel::linesShown(const File& file) const {
  if (!file.expanded) {
    return 0;
  }
  return int(m_split ? file.pairs.size() : file.lines.size());
}

void DiffModel::rebuildRows() {
  m_rows.clear();
  for (int f = 0; f < fileCount(); ++f) {
    m_rows.push_back({f, -1});
    const int shown = linesShown(m_files[size_t(f)]);
    for (int l = 0; l < shown; ++l) {
      m_rows.push_back({f, l});
    }
  }
}

void DiffModel::setSplit(bool split) {
  if (split == m_split) {
    return;
  }
  beginResetModel();
  m_split = split;
  rebuildRows();
  endResetModel();
  emit splitChanged();
}

bool DiffModel::allExpanded() const {
  // A file still waiting for its changes is only opened by hand.
  return std::all_of(m_files.begin(), m_files.end(), [this](const File& file) { return file.expanded || waiting(file); });
}

QStringList DiffModel::paths() const {
  QStringList out;
  for (const File& file : m_files) {
    out.append(file.path);
  }
  return out;
}

QVariantList DiffModel::tree() const {
  // In the diff's order: each folder and file where its first file is.
  struct Node {
    QString name;
    QString path;
    int file = -1;  // a file's index; -1 for a folder
    QString change;
    int additions = 0;
    int deletions = 0;
    std::vector<int> children;  // into nodes
  };
  std::vector<Node> nodes(1);
  QHash<QString, int> byPath;
  for (int f = 0; f < fileCount(); ++f) {
    const File& file = m_files[size_t(f)];
    const auto known = byPath.constFind(QLatin1Char('\x01') + file.path);
    if (known != byPath.cend()) {
      // The same path twice: a file replaced by a link.
      Node& node = nodes[size_t(*known)];
      node.change = QStringLiteral("modified");
      node.additions += file.additions;
      node.deletions += file.deletions;
      continue;
    }
    const QStringList parts = file.path.split(QLatin1Char('/'));
    int parent = 0;
    QString prefix;
    for (qsizetype i = 0; i + 1 < parts.size(); ++i) {
      prefix += parts.at(i);
      auto it = byPath.constFind(prefix);
      if (it == byPath.cend()) {
        nodes.push_back({parts.at(i), prefix});
        it = byPath.insert(prefix, int(nodes.size()) - 1);
        nodes[size_t(parent)].children.push_back(*it);
      }
      parent = *it;
      prefix += QLatin1Char('/');
    }
    nodes.push_back({parts.last(), file.path, f, file.change, file.additions, file.deletions});
    const int at = int(nodes.size()) - 1;
    byPath.insert(QLatin1Char('\x01') + file.path, at);
    nodes[size_t(parent)].children.push_back(at);
  }
  QVariantList rows;
  const auto walk = [&](auto&& self, const Node& node, int depth, bool shown) -> void {
    for (const int child : node.children) {
      const Node& each = nodes[size_t(child)];
      if (each.file < 0) {
        const bool open = folderOpen(each.path);
        rows.append(QVariantMap{{QStringLiteral("kind"), QStringLiteral("folder")}, {QStringLiteral("name"), each.name},
                                {QStringLiteral("path"), each.path}, {QStringLiteral("depth"), depth},
                                {QStringLiteral("open"), open}, {QStringLiteral("shown"), shown}});
        self(self, each, depth + 1, shown && open);
      } else {
        rows.append(QVariantMap{{QStringLiteral("kind"), QStringLiteral("file")}, {QStringLiteral("name"), each.name},
                                {QStringLiteral("path"), each.path}, {QStringLiteral("depth"), depth},
                                {QStringLiteral("file"), each.file}, {QStringLiteral("change"), each.change},
                                {QStringLiteral("additions"), each.additions}, {QStringLiteral("deletions"), each.deletions},
                                {QStringLiteral("shown"), shown}});
      }
    }
  };
  walk(walk, nodes.front(), 0, true);
  return rows;
}

void DiffModel::toggleFolder(const QString& path) {
  if (!m_closedFolders.remove(path)) m_closedFolders.insert(path);
  emit treeChanged();
}

QVariantMap DiffModel::excerpt(int file, const QString& side, int first, int last) {
  if (file < 0 || file >= fileCount() || first <= 0) return {};
  if (last < first) std::swap(first, last);
  File& entry = m_files[size_t(file)];
  ensureLines(entry);
  const bool old = side == QLatin1String("old");
  QStringList picked;
  int startIndex = -1, endIndex = -1, index = -1;
  QChar sameSide;
  bool mixed = false;
  for (const Line& line : entry.lines) {
    if (line.sign == '@' || line.sign == '\\') continue;
    ++index;
    const int number = old ? line.oldLine : line.newLine;
    if ((old ? line.sign != '-' : line.sign == '-') || number < first || number > last) continue;
    if (startIndex < 0) startIndex = index;
    endIndex = index;
    const QChar sign = QLatin1Char(line.sign);
    if (picked.isEmpty()) {
      sameSide = sign;
    } else if (sign != sameSide) {
      mixed = true;
    }
    picked.append(m_patch.mid(line.offset, line.length));
  }
  if (picked.isEmpty()) return {};
  const QString marker = mixed || sameSide == QLatin1Char(' ') ? QString() : QString(sameSide);
  return {{QStringLiteral("startIndex"), startIndex},
          {QStringLiteral("endIndex"), endIndex},
          {QStringLiteral("diff"), picked.join(QLatin1Char('\n'))},
          {QStringLiteral("rangeLabel"), first == last ? marker + QString::number(first)
                                                      : QStringLiteral("%1%2 to %1%3").arg(marker).arg(first).arg(last)}};
}

int DiffModel::rowOfFile(int file) const {
  if (file < 0 || file >= fileCount()) {
    return -1;
  }
  const auto it = std::lower_bound(m_rows.begin(), m_rows.end(), file,
                                   [](const Row& row, int f) { return row.file < f; });
  return int(it - m_rows.begin());
}

int DiffModel::fileOf(const QString& path) const {
  for (int f = 0; f < fileCount(); ++f) {
    if (m_files[size_t(f)].path == path) {
      return f;
    }
  }
  return -1;
}

void DiffModel::toggle(int file) {
  setExpanded(file, !expanded(file));
}

void DiffModel::setExpanded(int file, bool expand) {
  const bool allBefore = allExpanded();
  expandOne(file, expand);
  if (allExpanded() != allBefore) {
    emit expansionChanged();
  }
}

void DiffModel::expandOne(int file, bool expand) {
  if (file < 0 || file >= fileCount() || m_files[size_t(file)].expanded == expand) {
    return;
  }
  File& entry = m_files[size_t(file)];
  const int header = rowOfFile(file);
  if (expand) {
    ensureLines(entry);
    entry.expanded = true;
    if (entry.state == QLatin1String("unloaded") || entry.state == QLatin1String("error")) emit fileWanted(file);
    const int shown = linesShown(entry);
    if (shown > 0) {
      beginInsertRows({}, header + 1, header + shown);
      std::vector<Row> rows;
      rows.reserve(size_t(shown));
      for (int l = 0; l < shown; ++l) {
        rows.push_back({file, l});
      }
      m_rows.insert(m_rows.begin() + header + 1, rows.begin(), rows.end());
      endInsertRows();
    }
  } else {
    const int shown = linesShown(entry);
    entry.expanded = false;
    if (shown > 0) {
      beginRemoveRows({}, header + 1, header + shown);
      m_rows.erase(m_rows.begin() + header + 1, m_rows.begin() + header + 1 + shown);
      endRemoveRows();
    }
  }
  const QModelIndex at = index(header);
  emit dataChanged(at, at, {ExpandedRole});
}

void DiffModel::expandAll() {
  const bool allBefore = allExpanded();
  for (int f = 0; f < fileCount(); ++f) {
    if (waiting(m_files[size_t(f)])) continue;
    expandOne(f, true);
  }
  if (!allBefore) {
    emit expansionChanged();
  }
}

void DiffModel::collapseAll() {
  const bool allBefore = allExpanded();
  for (int f = 0; f < fileCount(); ++f) {
    expandOne(f, false);
  }
  if (allExpanded() != allBefore) {
    emit expansionChanged();
  }
}

int DiffModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QString DiffModel::textOf(const File& file, int line) const {
  if (line < 0) {
    return {};
  }
  const Line& entry = file.lines[size_t(line)];
  if (entry.sign == '@') {
    return m_patch.mid(entry.offset, entry.length);
  }
  if (entry.length == 0) {
    return {};
  }
  return m_patch.mid(entry.offset + 1, entry.length - 1);
}

QVariant DiffModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= rowCount()) {
    return {};
  }
  const Row& row = m_rows[size_t(index.row())];
  const File& file = m_files[size_t(row.file)];
  if (role == FileRole) {
    return row.file;
  }
  if (row.line < 0) {
    switch (role) {
      case KindRole:
        return QStringLiteral("file");
      case PathRole:
        return file.path;
      case PreviousPathRole:
        return file.previousPath;
      case ChangeRole:
        return file.change;
      case BinaryRole:
        return file.binary;
      case AdditionsRole:
        return file.additions;
      case DeletionsRole:
        return file.deletions;
      case ExpandedRole:
        return file.expanded;
      case StateRole:
        return file.state;
      case NoteRole:
        return file.note;
      case PartialRole:
        return file.partial;
      default:
        return {};
    }
  }
  int left = row.line;
  int right = -1;
  if (m_split) {
    const Pair& pair = file.pairs[size_t(row.line)];
    left = pair.left;
    right = pair.right;
  }
  const auto signOf = [&](int line) -> QString {
    if (line < 0) {
      return {};
    }
    return QString(QLatin1Char(file.lines[size_t(line)].sign));
  };
  const int any = left >= 0 ? left : right;
  const bool hunk = file.lines[size_t(any)].sign == '@';
  switch (role) {
    case KindRole:
      return hunk ? QStringLiteral("hunk") : QStringLiteral("line");
    case PathRole:
      return hunk ? textOf(file, any) : file.path;
    case TextRole:
      return textOf(file, left);
    case SignRole:
      return hunk ? QString() : signOf(left);
    case OldLineRole:
      return left >= 0 ? file.lines[size_t(left)].oldLine : 0;
    case NewLineRole: {
      const int line = m_split ? right : left;
      return line >= 0 ? file.lines[size_t(line)].newLine : 0;
    }
    case RightTextRole:
      return m_split && !hunk ? textOf(file, right) : QString();
    case RightSignRole:
      return m_split && !hunk ? signOf(right) : QString();
    case ExpandedRole:
      return file.expanded;
    default:
      return {};
  }
}

QHash<int, QByteArray> DiffModel::roleNames() const {
  return {
      {KindRole, "kind"},
      {FileRole, "file"},
      {PathRole, "path"},
      {PreviousPathRole, "previousPath"},
      {ChangeRole, "change"},
      {BinaryRole, "binary"},
      {AdditionsRole, "additions"},
      {DeletionsRole, "deletions"},
      {ExpandedRole, "expanded"},
      {TextRole, "text"},
      {SignRole, "sign"},
      {OldLineRole, "oldLine"},
      {NewLineRole, "newLine"},
      {RightTextRole, "rightText"},
      {RightSignRole, "rightSign"},
      {StateRole, "state"},
      {NoteRole, "note"},
      {PartialRole, "partial"},
  };
}
