#include "WorkspaceFiles.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>

#include <algorithm>

#include "McClient.h"

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
}

void WorkspaceFiles::setTarget(const QString& environmentId, const QString& root) {
  if (environmentId == m_environment && root == m_root) return;
  m_environment = environmentId;
  m_root = root;
  ++m_generation;
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
  if (m_active && !m_root.isEmpty() && m_tree.rootStatus() == QLatin1String("loading") && !m_tree.loaded(QString()) &&
      m_tree.rowCount() == 0) {
    m_tree.reload();
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
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("projects.listEntries"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("directoryPath"), folder}},
                 [this, generation, folder](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
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
  if (m_query.trimmed().isEmpty()) {
    m_searchDelay.stop();
    ++m_searchRequest;
    m_searching = false;
    m_searchTruncated = false;
    m_searchProblem.clear();
    m_tree.setSearch(std::nullopt);
    emit searchChanged();
    return;
  }
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
  const int request = ++m_fileRequest;
  m_fileStatus = QStringLiteral("loading");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  emit fileChanged();
  m_client->call(this, m_environment, QStringLiteral("projects.readFile"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("relativePath"), m_openPath}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   if (error) {
                     m_fileStatus = QStringLiteral("error");
                     m_fileProblem = error->isEmpty() ? QStringLiteral("Unable to read this file.") : *error;
                     m_lines.setText({});
                     emit fileChanged();
                     return;
                   }
                   const QJsonObject file = result.toObject();
                   m_lines.setText(file.value(QLatin1String("contents")).toString());
                   m_fileStatus = QStringLiteral("ready");
                   if (file.value(QLatin1String("truncated")).toBool()) {
                     m_truncatedNotice = QStringLiteral("Preview limited to the first 1 MB of a %1 byte file.")
                                             .arg(QLocale(QLocale::English).toString(qint64(file.value(QLatin1String("byteLength")).toDouble())));
                   }
                   emit fileChanged();
                   m_revealLine = m_openLine > 0 ? std::clamp(m_openLine, 1, std::max(1, m_lines.rowCount())) : 0;
                   emit revealRequested();
                 });
}

void WorkspaceFiles::closeFile() {
  ++m_fileRequest;
  const bool had = !m_openPath.isEmpty() || m_fileStatus != QLatin1String("none");
  m_openPath.clear();
  m_openLine = 0;
  m_revealLine = 0;
  m_fileStatus = QStringLiteral("none");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  m_lines.setText({});
  if (had) emit fileChanged();
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
  if (path.isEmpty()) return;
  // Revealing is about the user's tree, not a search's.
  if (!m_query.isEmpty()) setQuery({});
  m_revealing = path;
  if (m_tree.rowCount() == 0 && m_tree.rootStatus() == QLatin1String("loading") && !m_tree.loaded(QString())) {
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
