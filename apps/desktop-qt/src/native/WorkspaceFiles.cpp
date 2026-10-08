#include "WorkspaceFiles.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QHash>
#include <QLocale>
#include <QRegularExpression>

#include <functional>

#include <algorithm>
#include <utility>

#include "McClient.h"
#include "TimelineModel.h"

namespace {

QList<FileTreeModel::Entry> entriesOf(const QJsonValue& result) {
  QList<FileTreeModel::Entry> entries;
  for (const QJsonValue& value : result.toObject().value(QLatin1String("entries")).toArray()) {
    const QJsonObject entry = value.toObject();
    entries.append({entry.value(QLatin1String("path")).toString(),
                    entry.value(QLatin1String("kind")).toString() == QLatin1String("directory"),
                    entry.value(QLatin1String("ignored")).toBool()});
  }
  return entries;
}

}  // namespace

// --- TextLinesModel ------------------------------------------------------------------

void TextLinesModel::setText(const QString& text) {
  beginResetModel();
  m_text = text;
  m_lines.clear();
  m_maxColumns = 0;
  qsizetype at = 0;
  while (at < m_text.size()) {
    qsizetype end = m_text.indexOf(QLatin1Char('\n'), at);
    if (end < 0) end = m_text.size();
    qsizetype length = end - at;
    if (length > 0 && m_text.at(end - 1) == QLatin1Char('\r')) --length;
    m_lines.emplace_back(int(at), int(length));
    m_maxColumns = std::max(m_maxColumns, int(length));
    at = end + 1;
  }
  endResetModel();
  emit textChanged();
}

QString TextLinesModel::line(int row) const {
  if (row < 0 || row >= int(m_lines.size())) return {};
  return m_text.mid(m_lines[size_t(row)].first, m_lines[size_t(row)].second);
}

int TextLinesModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_lines.size());
}

QVariant TextLinesModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid()) return {};
  if (role == TextRole) return line(index.row());
  if (role == NumberRole) return index.row() + 1;
  return {};
}

QHash<int, QByteArray> TextLinesModel::roleNames() const {
  return {{TextRole, "text"}, {NumberRole, "number"}};
}

// --- WorkspaceFiles ------------------------------------------------------------------

WorkspaceFiles::WorkspaceFiles(McClient* client, QObject* parent) : QObject(parent), m_client(client) {
  m_tree.setFetch([this](const QString& folder) { list(folder); });
  m_searchDelay.setSingleShot(true);
  m_searchDelay.setInterval(searchDelayMs);
  connect(&m_searchDelay, &QTimer::timeout, this, &WorkspaceFiles::search);
  connect(&m_tree, &FileTreeModel::folderSettled, this, [this] { walkReveal(); });
  m_saveDelay.setSingleShot(true);
  m_saveDelay.setInterval(saveDelayMs);
  connect(&m_saveDelay, &QTimer::timeout, this, [this] { save(); });
  // What a file renders as, and so what its rendered view draws, follow the
  // file that is open and whether it has loaded.
  connect(this, &WorkspaceFiles::fileChanged, this, [this] {
    emit renderedChanged();
    emit textChanged();
  });
}

void WorkspaceFiles::setTarget(const QString& environmentId, const QString& root) {
  if (environmentId == m_environment && root == m_root) return;
  // An edit of the workspace being left is written there.
  save(true);
  m_environment = environmentId;
  m_root = root;
  // Answers about the workspace left are dropped.
  m_listRequests.clear();
  ++m_searchRequest;
  m_tree.clear();
  m_revealing.clear();
  if (!m_query.isEmpty()) {
    m_query.clear();
    emit queryChanged();
  }
  m_searchDelay.stop();
  m_searching = false;
  m_searchTruncated = false;
  m_searchProblem.clear();
  emit searchChanged();
  closeFile();
  emit targetChanged();
  setActive(m_active);
}

void WorkspaceFiles::setActive(bool active) {
  m_active = active;
  // The first look at a workspace lists its top folder.
  if (m_active && !m_root.isEmpty() && !m_tree.requested(QString())) {
    m_tree.reload();
  } else if (m_active && std::exchange(m_stale, false)) {
    m_tree.refresh();
  }
}

void WorkspaceFiles::setTimeline(TimelineModel* timeline) {
  if (timeline == m_timeline) return;
  if (m_timeline) disconnect(m_timeline, nullptr, this, nullptr);
  m_timeline = timeline;
  m_stale = false;
  m_mutation = mutation();
  if (m_timeline) connect(m_timeline, &TimelineModel::workspaceChanged, this, &WorkspaceFiles::followMutation);
}

QString WorkspaceFiles::mutation() const {
  if (!m_timeline) return {};
  QString item;
  int ordinal = -1;
  const QHash<QString, QJsonObject> items = m_timeline->entities(QStringLiteral("turn-item"));
  for (auto it = items.cbegin(); it != items.cend(); ++it) {
    const QString type = it->value(QLatin1String("type")).toString();
    if (type != QLatin1String("command_execution") && type != QLatin1String("file_change")) continue;
    const QString status = it->value(QLatin1String("status")).toString();
    if (status == QLatin1String("pending") || status == QLatin1String("running") || status == QLatin1String("waiting")) continue;
    if (const int at = it->value(QLatin1String("ordinal")).toInt(); at > ordinal) {
      ordinal = at;
      item = it.key();
    }
  }
  QStringList checkpoints;
  const QHash<QString, QJsonObject> kept = m_timeline->entities(QStringLiteral("checkpoint"));
  for (auto it = kept.cbegin(); it != kept.cend(); ++it) checkpoints.append(it.key() + QLatin1Char('=') + it->value(QLatin1String("status")).toString());
  checkpoints.sort();
  return item + QLatin1Char('\n') + checkpoints.join(QLatin1Char(','));
}

void WorkspaceFiles::followMutation() {
  const QString now = mutation();
  if (now == m_mutation) return;
  m_mutation = now;
  if (m_active) {
    m_tree.refresh();
  } else {
    m_stale = true;
  }
}

void WorkspaceFiles::reload() {
  if (m_root.isEmpty()) return;
  if (m_tree.rootStatus() == QLatin1String("error")) {
    m_tree.retry(QString());
  } else {
    m_tree.reload();
  }
}

void WorkspaceFiles::list(const QString& folder) {
  // The MC runs each listing on its own: one asked before this may answer after it.
  const int request = ++m_listRequest;
  m_listRequests.insert(folder, request);
  m_client->call(this, m_environment, QStringLiteral("projects.listEntries"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("directoryPath"), folder}},
                 [this, request, folder](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_listRequests.value(folder) != request) return;
                   if (error) {
                     m_tree.setFailed(folder, error->isEmpty() ? QStringLiteral("Unable to load folder.") : *error);
                     return;
                   }
                   m_tree.setListing(folder, entriesOf(result));
                 });
}

void WorkspaceFiles::setQuery(const QString& query) {
  if (query == m_query) return;
  m_query = query;
  emit queryChanged();
  // A search on its way is for another query.
  ++m_searchRequest;
  if (m_query.trimmed().isEmpty() || m_root.isEmpty()) {
    m_searchDelay.stop();
    m_searching = false;
    m_searchTruncated = false;
    m_searchProblem.clear();
    m_tree.setSearch(std::nullopt);
    emit searchChanged();
    return;
  }
  // The user looks for something else than the file being revealed.
  m_revealing.clear();
  m_searching = true;
  emit searchChanged();
  m_searchDelay.start();
}

void WorkspaceFiles::searchEntries(McClient* client, QObject* context, const QString& environmentId, const QString& cwd,
                                   const QString& query, int limit, SearchDone done) {
  client->call(context, environmentId, QStringLiteral("projects.searchEntries"),
               QJsonObject{{QStringLiteral("cwd"), cwd}, {QStringLiteral("query"), query}, {QStringLiteral("limit"), limit}},
               [done = std::move(done)](const QJsonValue& result, const std::optional<QString>& error) {
                 if (error) {
                   done({}, false, error);
                   return;
                 }
                 done(entriesOf(result), result.toObject().value(QLatin1String("truncated")).toBool(), std::nullopt);
               });
}

void WorkspaceFiles::search() {
  if (m_root.isEmpty()) return;
  const int request = ++m_searchRequest;
  searchEntries(m_client, this, m_environment, m_root, m_query.trimmed(), searchLimit,
                [this, request](const QList<FileTreeModel::Entry>& entries, bool truncated, const std::optional<QString>& error) {
                  if (request != m_searchRequest) return;
                  m_searching = false;
                  m_searchProblem = error ? (error->isEmpty() ? QStringLiteral("Unable to search files.") : *error) : QString();
                  m_searchTruncated = truncated;
                  m_tree.setSearch(entries);
                  emit searchChanged();
                });
}

void WorkspaceFiles::openFile(const QString& path, int line) {
  if (path.isEmpty() || m_root.isEmpty()) return;
  if (path != m_openPath) {
    save(true);
    if (std::exchange(m_editing, false)) emit renderedChanged();
  }
  m_openLine = line;
  if (path == m_openPath && m_fileStatus == QLatin1String("ready")) {
    // Already here: just go to the line.
    m_revealLine = line > 0 ? std::clamp(line, 1, std::max(1, m_lines.rowCount())) : 0;
    emit revealRequested();
  } else {
    m_openPath = path;
    reloadFile();
  }
  reveal(path);
}

void WorkspaceFiles::reloadFile() {
  if (m_openPath.isEmpty()) return;
  save(true);
  const int request = ++m_fileRequest;
  m_fileStatus = QStringLiteral("loading");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  m_truncated = false;
  emit fileChanged();
  m_client->call(this, m_environment, QStringLiteral("projects.readFile"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("relativePath"), m_openPath}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   if (error) {
                     m_fileStatus = QStringLiteral("error");
                     m_fileProblem = error->isEmpty() ? QStringLiteral("Unable to read this file.") : *error;
                     setText({});
                     emit fileChanged();
                     return;
                   }
                   const QJsonObject file = result.toObject();
                   setText(file.value(QLatin1String("contents")).toString());
                   m_fileStatus = QStringLiteral("ready");
                   m_truncated = file.value(QLatin1String("truncated")).toBool();
                   if (m_truncated) {
                     m_truncatedNotice = QStringLiteral("Preview limited to the first 1 MB of a %1 byte file.")
                                             .arg(QLocale(QLocale::English).toString(qint64(file.value(QLatin1String("byteLength")).toDouble())));
                   }
                   emit fileChanged();
                   m_revealLine = m_openLine > 0 ? std::clamp(m_openLine, 1, std::max(1, m_lines.rowCount())) : 0;
                   emit revealRequested();
                 });
}

void WorkspaceFiles::closeFile() {
  // What the user typed is written before the file goes.
  save(true);
  if (std::exchange(m_editing, false)) emit renderedChanged();
  ++m_fileRequest;
  const bool had = !m_openPath.isEmpty() || m_fileStatus != QLatin1String("none");
  m_openPath.clear();
  m_openLine = 0;
  m_revealLine = 0;
  m_fileStatus = QStringLiteral("none");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  m_truncated = false;
  setText({});
  if (!m_saveProblem.isEmpty()) {
    m_saveProblem.clear();
    emit saveChanged();
  }
  if (had) emit fileChanged();
}

// --- Rendering and editing -----------------------------------------------------------

namespace {

QString extensionOf(const QString& path) {
  const QString name = path.section(QLatin1Char('/'), -1);
  const qsizetype dot = name.lastIndexOf(QLatin1Char('.'));
  return dot < 0 ? QString() : name.mid(dot + 1).toLower();
}

// A list item that is a task: its marker's `[`, by line.
const QRegularExpression& taskLine() {
  static const QRegularExpression pattern(QStringLiteral("^(\\s*(?:[-*+]|\\d+[.)])[ \\t]+)\\[([ xX])\\](?=[ \\t]|$)"));
  return pattern;
}

// Calls `visit(offset of '[', checked)` for each task of `markdown`, outside
// fenced code.
void eachTask(const QString& markdown, const std::function<void(qsizetype, bool)>& visit) {
  bool fenced = false;
  qsizetype at = 0;
  while (at <= markdown.size()) {
    qsizetype end = markdown.indexOf(QLatin1Char('\n'), at);
    if (end < 0) end = markdown.size();
    const QString line = markdown.mid(at, end - at);
    if (line.trimmed().startsWith(QLatin1String("```")) || line.trimmed().startsWith(QLatin1String("~~~"))) {
      fenced = !fenced;
    } else if (!fenced) {
      if (const auto match = taskLine().match(line); match.hasMatch()) visit(at + match.capturedEnd(1), match.captured(2) != QLatin1String(" "));
    }
    at = end + 1;
  }
}

// One CSV record's cells: commas (or tabs) apart, quotes around a cell that
// holds one, a doubled quote for a quote.
QList<QStringList> csvRows(const QString& text, QChar separator, int limit) {
  QList<QStringList> rows;
  QStringList row;
  QString cell;
  bool quoted = false;
  const auto endRow = [&] {
    row.append(cell);
    cell.clear();
    if (row.size() > 1 || !row.first().isEmpty()) rows.append(row);
    row.clear();
  };
  for (qsizetype i = 0; i < text.size() && rows.size() < limit; ++i) {
    const QChar c = text.at(i);
    if (quoted) {
      if (c == u'"' && i + 1 < text.size() && text.at(i + 1) == u'"') {
        cell += u'"';
        ++i;
      } else if (c == u'"') {
        quoted = false;
      } else {
        cell += c;
      }
    } else if (c == u'"' && cell.isEmpty()) {
      quoted = true;
    } else if (c == separator) {
      row.append(cell);
      cell.clear();
    } else if (c == u'\n') {
      endRow();
    } else if (c != u'\r') {
      cell += c;
    }
  }
  if (rows.size() < limit && (!cell.isEmpty() || !row.isEmpty())) endRow();
  return rows;
}

QString markdownTable(const QString& text, QChar separator) {
  const QList<QStringList> rows = csvRows(text, separator, WorkspaceFiles::csvRowLimit + 1);
  if (rows.isEmpty()) return {};
  int columns = 0;
  for (const QStringList& row : rows) columns = std::max(columns, int(row.size()));
  const auto line = [columns](const QStringList& row) {
    QString out = QStringLiteral("|");
    for (int column = 0; column < columns; ++column) {
      QString cell = row.value(column);
      cell.replace(u'\\', QStringLiteral("\\\\")).replace(u'|', QStringLiteral("\\|")).replace(u'\n', u' ');
      out += u' ' + cell + QStringLiteral(" |");
    }
    return out + u'\n';
  };
  QString table = line(rows.first()) + QStringLiteral("|") + QStringLiteral(" --- |").repeated(columns) + u'\n';
  for (qsizetype row = 1; row < rows.size() && row <= WorkspaceFiles::csvRowLimit; ++row) table += line(rows.at(row));
  if (rows.size() > WorkspaceFiles::csvRowLimit) table += QStringLiteral("\nShowing the first %1 rows.\n").arg(WorkspaceFiles::csvRowLimit);
  return table;
}

}  // namespace

void WorkspaceFiles::setText(const QString& text) {
  m_saveDelay.stop();
  m_pending = false;
  ++m_revision;
  m_text = text;
  m_lines.setText(text);
  emit textChanged();
}

QString WorkspaceFiles::renderKind() const {
  static const QHash<QString, QString> kinds{
      {QStringLiteral("md"), QStringLiteral("markdown")},   {QStringLiteral("mdx"), QStringLiteral("markdown")},
      {QStringLiteral("markdown"), QStringLiteral("markdown")}, {QStringLiteral("mdown"), QStringLiteral("markdown")},
      {QStringLiteral("mkd"), QStringLiteral("markdown")},  {QStringLiteral("csv"), QStringLiteral("csv")},
      {QStringLiteral("tsv"), QStringLiteral("csv")},       {QStringLiteral("html"), QStringLiteral("html")},
      {QStringLiteral("htm"), QStringLiteral("html")},
  };
  return m_fileStatus == QLatin1String("ready") ? kinds.value(extensionOf(m_openPath)) : QString();
}

bool WorkspaceFiles::rendered() const {
  const QString kind = renderKind();
  return !kind.isEmpty() && !m_editing && !m_sourceKinds.contains(kind);
}

void WorkspaceFiles::setRendered(bool rendered) {
  const QString kind = renderKind();
  if (kind.isEmpty() || rendered == !m_sourceKinds.contains(kind)) return;
  if (rendered) {
    m_sourceKinds.removeAll(kind);
    if (std::exchange(m_editing, false)) save();
  } else {
    m_sourceKinds.append(kind);
  }
  emit sourceKindsChanged();
  emit renderedChanged();
}

void WorkspaceFiles::setSourceKinds(const QStringList& kinds) {
  if (kinds == m_sourceKinds) return;
  m_sourceKinds = kinds;
  emit renderedChanged();
}

QString WorkspaceFiles::renderedText() const {
  const QString kind = renderKind();
  if (kind == QLatin1String("csv")) return markdownTable(m_text, extensionOf(m_openPath) == QLatin1String("tsv") ? u'\t' : u',');
  if (kind != QLatin1String("markdown")) return m_text;
  // Each task's box becomes a link the rendered view answers with toggleTask.
  QString out = m_text;
  QList<std::pair<qsizetype, bool>> tasks;
  eachTask(m_text, [&tasks](qsizetype offset, bool checked) { tasks.append({offset, checked}); });
  for (qsizetype index = tasks.size() - 1; index >= 0; --index) {
    out.replace(tasks.at(index).first, 3, QStringLiteral("[%1](task:%2)").arg(tasks.at(index).second ? QStringLiteral("☑") : QStringLiteral("☐")).arg(index));
  }
  return out;
}

QString WorkspaceFiles::readOnlyReason() const {
  if (m_fileStatus != QLatin1String("ready")) return {};
  if (m_truncated) return tr("Files larger than 1 MB open read-only.");
  // Only a path inside the workspace can be written back.
  if (m_openPath.startsWith(QLatin1Char('/')) || m_openPath.contains(QLatin1String(":\\"))) return tr("Files outside the project open read-only.");
  return {};
}

void WorkspaceFiles::setEditing(bool editing) {
  editing = editing && editable();
  if (editing == m_editing) return;
  m_editing = editing;
  if (!m_editing) save();
  emit renderedChanged();
}

void WorkspaceFiles::edit(const QString& contents) {
  if (!editable() || contents == m_text) return;
  m_text = contents;
  ++m_revision;
  m_pending = true;
  m_saveProblem.clear();
  emit textChanged();
  emit saveChanged();
  m_saveDelay.start();
}

void WorkspaceFiles::toggleTask(int index) {
  if (!editable() || renderKind() != QLatin1String("markdown")) return;
  int seen = 0;
  qsizetype offset = -1;
  bool checked = false;
  eachTask(m_text, [&](qsizetype at, bool isChecked) {
    if (seen++ != index) return;
    offset = at;
    checked = isChecked;
  });
  if (offset < 0) return;
  QString next = m_text;
  next[offset + 1] = checked ? u' ' : u'x';
  m_text = next;
  m_lines.setText(m_text);
  ++m_revision;
  m_pending = true;
  emit textChanged();
  emit saveChanged();
  save();
}

void WorkspaceFiles::save(bool closing) {
  m_saveDelay.stop();
  if (!m_pending || m_openPath.isEmpty() || m_root.isEmpty()) return;
  // One write at a time: the next goes when this one is answered.
  if (m_saving && !closing) return;
  const QString path = m_openPath;
  const QString root = m_root;
  const int revision = m_revision;
  const int request = m_fileRequest;
  m_saving = !closing;
  if (closing) m_pending = false;
  m_client->call(this, m_environment, QStringLiteral("projects.writeFile"),
                 QJsonObject{{QStringLiteral("cwd"), root}, {QStringLiteral("relativePath"), path}, {QStringLiteral("contents"), m_text}},
                 [this, path, root, revision, request, closing](const QJsonValue&, const std::optional<QString>& error) {
                   const QString problem = error ? (error->isEmpty() ? QStringLiteral("Unable to save this file.") : *error) : QString();
                   if (error) emit saveFailed(path, problem);
                   // The file closed, or another opened, meanwhile.
                   if (closing || path != m_openPath || root != m_root || request != m_fileRequest) return;
                   m_saving = false;
                   if (error) {
                     // The edit stays, to be written with the next one.
                     m_saveProblem = problem;
                     emit saveChanged();
                     return;
                   }
                   m_saveProblem.clear();
                   if (revision == m_revision) {
                     m_pending = false;
                     if (!m_editing) m_lines.setText(m_text);
                   } else {
                     m_saveDelay.start();
                   }
                   emit saveChanged();
                 });
  emit saveChanged();
}

void WorkspaceFiles::setDefaultWrap(bool wrap) {
  if (wrap == m_defaultWrap) return;
  const bool before = this->wrap();
  m_defaultWrap = wrap;
  if (this->wrap() != before) emit wrapChanged();
}

void WorkspaceFiles::setWrap(bool wrap) {
  if (wrap == this->wrap()) return;
  m_wrap = wrap;
  emit wrapChanged();
}

void WorkspaceFiles::reveal(const QString& path) {
  // A file outside the workspace (opened by its full path) is not in the tree.
  if (path.isEmpty() || path.startsWith(QLatin1Char('/'))) return;
  // Revealing is about the user's tree, not a search's.
  if (!m_query.isEmpty()) setQuery({});
  m_revealing = path;
  if (!m_tree.requested(QString())) {
    m_tree.reload();
    return;
  }
  walkReveal();
}

void WorkspaceFiles::walkReveal() {
  if (m_revealing.isEmpty() || !m_tree.loaded(QString())) return;
  const QStringList parts = m_revealing.split(QLatin1Char('/'));
  QString folder;
  for (qsizetype i = 0; i + 1 < parts.size(); ++i) {
    folder = folder.isEmpty() ? parts.at(i) : folder + QLatin1Char('/') + parts.at(i);
    if (!m_tree.isExpanded(folder)) m_tree.expand(folder);
    // Walks on when the folder's listing lands (folderSettled).
    if (!m_tree.loaded(folder)) return;
  }
  m_tree.select(std::exchange(m_revealing, QString()));
}
