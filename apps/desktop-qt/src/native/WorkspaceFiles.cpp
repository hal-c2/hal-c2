#include "WorkspaceFiles.h"

#include <QDir>

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QHash>
#include <QLocale>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QTimeZone>

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

// A file outside the workspace, opened by its full path. The path is the
// thread's machine's, so a Windows one counts here too.
bool hostPath(const QString& path) {
  static const QRegularExpression full(QStringLiteral(R"(^(/|\\\\|[A-Za-z]:[/\\]))"));
  return full.match(path).hasMatch();
}

}  // namespace

// --- TextLinesModel ------------------------------------------------------------------

void TextLinesModel::setText(const QString& text, const QString& path) {
  // The same file again (written back as it was) keeps its colours.
  const bool same = path == m_path && text == m_text;
  beginResetModel();
  m_text = text;
  m_path = path;
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
  if (!same) read();
}

void TextLinesModel::read() {
  // A read under way is for what was before: it finishes and is let go.
  m_alive = std::make_shared<int>(0);
  setReading(false);
  setRuns(nullptr);
  // Past the cap a file stays plain, as do files with no name to know them by.
  if (m_path.isEmpty() || m_text.isEmpty() || m_text.size() > codereader::kMaxChars) return;
  const QString key = codereader::cacheKey(QString(), m_path, m_text);
  if (auto hit = codereader::cached(key)) {
    setRuns(std::move(hit));
    return;
  }
  auto job = std::make_shared<codereader::Job>();
  job->byPath = true;
  job->language = m_path.toUtf8();
  job->delta = m_text;
  job->key = key;
  setReading(true);
  codereader::start(job, m_alive, [this, key](const std::shared_ptr<codereader::Job>& job) {
    setReading(false);
    if (!job->known) return;
    codereader::keep(key, job->runs);
    setRuns(job->runs);
  });
}

void TextLinesModel::setRuns(std::shared_ptr<const codereader::Runs> runs) {
  if (!runs && !m_runs) return;
  const bool was = coloured();
  m_runs = std::move(runs);
  restyle();
  if (coloured() != was) emit colouredChanged();
}

void TextLinesModel::setReading(bool reading) {
  if (reading == m_reading) return;
  m_reading = reading;
  emit readingChanged();
}

void TextLinesModel::restyle() {
  if (!m_lines.empty()) emit dataChanged(index(0), index(int(m_lines.size()) - 1), {StyledRole});
}

void TextLinesModel::setBackground(const QColor& background) {
  if (background == m_background) return;
  const int before = codereader::themeFor(m_background);
  const bool was = coloured();
  m_background = background;
  emit backgroundChanged();
  // The other colouring of what was read: nothing is read again.
  if (m_runs && codereader::themeFor(m_background) != before) restyle();
  if (coloured() != was) emit colouredChanged();
}

void TextLinesModel::setColumnLimit(int limit) {
  if (limit == m_columnLimit) return;
  m_columnLimit = limit;
  emit columnLimitChanged();
  if (m_runs) restyle();
}

bool TextLinesModel::coloured() const {
  return m_runs && !m_runs->themes[codereader::themeFor(m_background)].isEmpty();
}

QString TextLinesModel::line(int row) const {
  if (row < 0 || row >= int(m_lines.size())) return {};
  return m_text.mid(m_lines[size_t(row)].first, m_lines[size_t(row)].second);
}

QString TextLinesModel::styled(int row) const {
  if (row < 0 || row >= int(m_lines.size()) || !coloured()) return {};
  const auto [offset, length] = m_lines[size_t(row)];
  // Cut as the viewer cuts a plain line, so no colour reaches past the cut.
  const bool cut = length > m_columnLimit;
  QString out = codereader::styled(m_text, offset, cut ? m_columnLimit : length, m_runs->themes[codereader::themeFor(m_background)]);
  if (cut) out += QStringLiteral("…");
  return out;
}

int TextLinesModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_lines.size());
}

QVariant TextLinesModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid()) return {};
  if (role == TextRole) return line(index.row());
  if (role == NumberRole) return index.row() + 1;
  if (role == StyledRole) return styled(index.row());
  return {};
}

QHash<int, QByteArray> TextLinesModel::roleNames() const {
  return {{TextRole, "text"}, {NumberRole, "number"}, {StyledRole, "styled"}};
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

void WorkspaceFiles::setTarget(const QString& environmentId, const QString& root, const QString& threadId) {
  m_thread = threadId;
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
    followOpenFile();
  }
  // The preview loads again when the tab shows, so needs a URL that works.
  if (m_active && m_fileStatus == QLatin1String("ready") && mediaExpired()) reloadFile();
}

void WorkspaceFiles::setTimeline(TimelineModel* timeline) {
  if (timeline == m_timeline) return;
  if (m_timeline) disconnect(m_timeline, nullptr, this, nullptr);
  m_timeline = timeline;
  m_stale = false;
  m_mutation = m_timeline ? m_timeline->workspaceMutation() : QString();
  if (m_timeline) connect(m_timeline, &TimelineModel::workspaceChanged, this, &WorkspaceFiles::followMutation);
}

void WorkspaceFiles::followMutation() {
  const QString now = m_timeline ? m_timeline->workspaceMutation() : QString();
  if (now == m_mutation) return;
  m_mutation = now;
  // Only a change that names a media file reads it again: its preview is not
  // fetched for what the agent does to other files.
  m_mediaRewritten = m_mediaRewritten || newestChangeNames(m_openPath);
  if (m_active) {
    m_tree.refresh();
    followOpenFile();
  } else {
    m_stale = true;
  }
}

bool WorkspaceFiles::newestChangeNames(const QString& path) const {
  if (!m_timeline || path.isEmpty()) return false;
  QJsonObject newest;
  int ordinal = -1;
  const QHash<QString, QJsonObject> items = m_timeline->entities(QStringLiteral("turn-item"));
  for (auto it = items.cbegin(); it != items.cend(); ++it) {
    if (it->value(QLatin1String("type")).toString() != QLatin1String("file_change")) continue;
    if (const int at = it->value(QLatin1String("ordinal")).toInt(); at > ordinal) {
      ordinal = at;
      newest = *it;
    }
  }
  if (newest.value(QLatin1String("fileName")).toString() == path) return true;
  for (const QJsonValue& change : newest.value(QLatin1String("changes")).toArray()) {
    if (change.toObject().value(QLatin1String("path")).toString() == path) return true;
  }
  return false;
}

void WorkspaceFiles::followOpenFile() {
  if (m_openPath.isEmpty()) return;
  if (!mediaKind().isEmpty()) {
    if (std::exchange(m_mediaRewritten, false)) reloadFile();
    return;
  }
  // A path that could not be read may be a file now (a folder the agent replaced).
  if (m_fileStatus != QLatin1String("ready")) {
    if (m_fileStatus == QLatin1String("error")) reloadFile();
    // The read under way may be from before this change.
    else if (m_fileStatus == QLatin1String("loading")) m_rereadLater = true;
    return;
  }
  // The user's own text stays: the file is read once it is written.
  if (m_pending || m_saving || m_editing) {
    m_rereadLater = true;
    return;
  }
  refreshFile();
}

void WorkspaceFiles::refreshFile() {
  // The read waiting on the writes will show what is there.
  if (m_readAfterWrites) return;
  const int request = ++m_fileRequest;
  const int revision = m_revision;
  m_rereadLater = false;
  m_client->call(this, m_environment, QStringLiteral("projects.readFile"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("relativePath"), m_openPath}},
                 [this, request, revision](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   // Read before the user's edit, so older than what they see.
                   if (revision != m_revision || m_pending || m_saving || m_editing) {
                     m_rereadLater = true;
                     rereadIfDue();
                     return;
                   }
                   // Every tick waited on this read; older ones lost theirs to it.
                   const QList<int> ticks = std::exchange(m_waitingTicks, {});
                   if (error) {
                     m_fileStatus = QStringLiteral("error");
                     m_fileProblem = readProblem(result, *error);
                     m_truncated = false;
                     m_truncatedNotice.clear();
                     setText({});
                     emit fileChanged();
                     return;
                   }
                   const QJsonObject file = result.toObject();
                   const QString contents = file.value(QLatin1String("contents")).toString();
                   const QString notice = m_truncatedNotice;
                   noteTruncation(file);
                   if (contents != m_text) {
                     // A task ticked against other text is not ticked: the user sees what is there now.
                     setText(contents);
                     emit fileChanged();
                   } else {
                     // A file past the limit can change size with the same first 1 MB.
                     if (notice != m_truncatedNotice) emit fileChanged();
                     // Saving what a cut-off read shows would drop the rest of the file.
                     if (!m_truncated) {
                       for (const int task : ticks) applyTask(task);
                     }
                   }
                 });
}

void WorkspaceFiles::noteTruncation(const QJsonObject& file) {
  m_truncated = file.value(QLatin1String("truncated")).toBool();
  m_truncatedNotice = m_truncated ? QStringLiteral("Preview limited to the first 1 MB of a %1 byte file.")
                                        .arg(QLocale(QLocale::English).toString(qint64(file.value(QLatin1String("byteLength")).toDouble())))
                                  : QString();
}

void WorkspaceFiles::rereadIfDue() {
  if (m_rereadLater && !m_pending && !m_saving && !m_editing && m_fileStatus == QLatin1String("ready") && mediaKind().isEmpty()) refreshFile();
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
  // A line is in the source, whatever the kind is usually read as.
  if (std::exchange(m_lineSource, line > 0) != (line > 0)) emit renderedChanged();
  if (path == m_openPath && m_fileStatus == QLatin1String("ready") && !mediaExpired()) {
    // Already here: just go to the line.
    m_revealLine = line > 0 ? std::clamp(line, 1, std::max(1, m_lines.rowCount())) : 0;
    emit revealRequested();
  } else {
    m_openPath = path;
    reloadFile();
  }
  reveal(path);
}

QString WorkspaceFiles::readProblem(const QJsonValue& detail, const QString& error) {
  const QString failure = detail.toObject().value(QLatin1String("failure")).toString();
  if (failure == QLatin1String("binary_file")) return tr("This file contains binary data and cannot be shown as text.");
  if (failure == QLatin1String("not_utf8")) return tr("This file is not UTF-8 text. Open it in another app to view its contents.");
  return error.isEmpty() ? tr("Unable to read this file.") : error;
}

void WorkspaceFiles::reloadFile() {
  if (m_openPath.isEmpty()) return;
  save(true);
  m_waitingTicks.clear();
  const int request = ++m_fileRequest;
  m_fileStatus = QStringLiteral("loading");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  m_truncated = false;
  m_mediaUrl.clear();
  m_mediaRewritten = false;
  m_rereadLater = false;
  emit fileChanged();
  m_readAfterWrites = false;
  if (!mediaKind().isEmpty()) return signMedia(request);
  // A read now would show the text from before the writes still to land.
  if (writingOpenFile()) {
    m_readAfterWrites = true;
    return;
  }
  readOpenFile();
}

bool WorkspaceFiles::writingOpenFile() const {
  const auto isOpenFile = [this](const Write& write) { return write.path == m_openPath && write.root == m_root && write.environment == m_environment; };
  return (m_underWay && isOpenFile(*m_underWay)) || std::any_of(m_writes.cbegin(), m_writes.cend(), isOpenFile);
}

void WorkspaceFiles::readOpenFile() {
  const int request = m_fileRequest;
  m_client->call(this, m_environment, QStringLiteral("projects.readFile"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("relativePath"), m_openPath}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   if (error) {
                     // The file changed since this read began: it may be readable now.
                     if (m_rereadLater) return reloadFile();
                     m_fileStatus = QStringLiteral("error");
                     m_fileProblem = readProblem(result, *error);
                     setText({});
                     emit fileChanged();
                     return;
                   }
                   const QJsonObject file = result.toObject();
                   setText(file.value(QLatin1String("contents")).toString());
                   m_fileStatus = QStringLiteral("ready");
                   noteTruncation(file);
                   emit fileChanged();
                   m_revealLine = m_openLine > 0 ? std::clamp(m_openLine, 1, std::max(1, m_lines.rowCount())) : 0;
                   emit revealRequested();
                   rereadIfDue();
                 });
}

QJsonObject WorkspaceFiles::fileResource() const {
  // A path in the workspace is the thread's file; a full path is served only
  // as a media file. With no thread, the workspace folder names itself.
  QJsonObject resource{{QStringLiteral("path"), m_openPath}};
  if (m_thread.isEmpty()) {
    resource.insert(QStringLiteral("_tag"), QStringLiteral("draft-workspace-file"));
    resource.insert(QStringLiteral("cwd"), m_root);
  } else {
    resource.insert(QStringLiteral("_tag"), hostPath(m_openPath) ? QStringLiteral("media-file") : QStringLiteral("workspace-file"));
    resource.insert(QStringLiteral("threadId"), m_thread);
  }
  return resource;
}

void WorkspaceFiles::commentOnLines(int first, int last, const QString& note) {
  const QString text = note.trimmed();
  if (text.isEmpty() || m_openPath.isEmpty() || first < 1) return;
  const QStringList lines = m_text.split(QLatin1Char('\n'));
  emit commentRequested({{QStringLiteral("sectionTitle"), tr("File")},
                         {QStringLiteral("sectionId"), QStringLiteral("file:") + m_openPath},
                         {QStringLiteral("filePath"), m_openPath},
                         {QStringLiteral("lineStart"), first},
                         {QStringLiteral("lineEnd"), last},
                         {QStringLiteral("diff"), QStringList(lines.mid(first - 1, last - first + 1)).join(QLatin1Char('\n'))},
                         {QStringLiteral("text"), text}});
}

void WorkspaceFiles::openInPreview() {
  if (m_openPath.isEmpty()) return;
  m_client->call(this, m_environment, QStringLiteral("assets.createUrl"), QJsonObject{{QStringLiteral("resource"), fileResource()}},
                 [this](const QJsonValue& result, const std::optional<QString>& error) {
                   const QString relative = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   if (error || relative.isEmpty()) {
                     emit previewRefused(error && !error->isEmpty() ? *error : tr("The environment did not serve the file."));
                     return;
                   }
                   emit previewReady(m_client->origin().resolved(QUrl(relative)));
                 });
}

void WorkspaceFiles::signMedia(int request) {
  m_client->call(this, m_environment, QStringLiteral("assets.createUrl"), QJsonObject{{QStringLiteral("resource"), fileResource()}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   const QString relative = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   setText({});
                   if (error || relative.isEmpty()) {
                     m_fileStatus = QStringLiteral("error");
                     m_fileProblem = error && !error->isEmpty() ? *error : QStringLiteral("Unable to load this file.");
                     emit fileChanged();
                     return;
                   }
                   // The cluster hands the address to the member that signed
                   // it. It stops working a minute before the MC says, so a
                   // preview asked for at the last moment still loads.
                   m_mediaUrl = m_client->origin().resolved(QUrl(relative));
                   m_mediaExpires = QDateTime::fromMSecsSinceEpoch(
                       qint64(result.toObject().value(QLatin1String("expiresAt")).toDouble()) - 60'000, QTimeZone::UTC);
                   const auto ready = [this, request] {
                     m_fileStatus = QStringLiteral("ready");
                     emit fileChanged();
                     if (std::exchange(m_openOnSign, 0) == request) emit mediaOpened(m_mediaUrl);
                   };
                   if (mediaKind() != QLatin1String("pdf")) return ready();
                   // Qt PDF opens local files alone.
                   m_client->download(this, relative, [this, request, ready](const QByteArray& bytes, const std::optional<QString>& error) {
                     if (request != m_fileRequest) return;
                     auto copy = std::make_unique<QTemporaryFile>(QDir::tempPath() + QStringLiteral("/hal-c2-XXXXXX.pdf"));
                     const bool kept = !error && copy->open() && copy->write(bytes) == bytes.size() && copy->flush();
                     if (kept) m_mediaDocument = std::move(copy);
                     ready();
                     if (!kept) mediaFailed(m_mediaUrl);
                   });
                 });
}

void WorkspaceFiles::openMedia() {
  if (mediaKind().isEmpty()) return;
  if (m_fileStatus == QLatin1String("ready") && !mediaExpired()) {
    emit mediaOpened(m_mediaUrl);
    return;
  }
  reloadFile();
  m_openOnSign = m_fileRequest;
}

bool WorkspaceFiles::mediaExpired() const {
  return !mediaKind().isEmpty() && (m_mediaUrl.isEmpty() || QDateTime::currentDateTimeUtc() >= m_mediaExpires);
}

void WorkspaceFiles::mediaFailed(const QUrl& url) {
  if (url.isEmpty() || url != m_mediaUrl || m_fileStatus != QLatin1String("ready")) return;
  static const QHash<QString, QString> nouns{{QStringLiteral("image"), QStringLiteral("image")},
                                             {QStringLiteral("video"), QStringLiteral("video")},
                                             {QStringLiteral("audio"), QStringLiteral("audio")},
                                             {QStringLiteral("pdf"), QStringLiteral("document")}};
  m_mediaUrl.clear();
  m_fileStatus = QStringLiteral("error");
  m_fileProblem = tr("The %1 could not be loaded.").arg(nouns.value(mediaKind(), QStringLiteral("file")));
  emit fileChanged();
}

void WorkspaceFiles::closeFile() {
  // What the user typed is written before the file goes.
  save(true);
  if (std::exchange(m_editing, false)) emit renderedChanged();
  ++m_fileRequest;
  m_waitingTicks.clear();
  m_readAfterWrites = false;
  const bool had = !m_openPath.isEmpty() || m_fileStatus != QLatin1String("none");
  m_openPath.clear();
  m_openLine = 0;
  m_lineSource = false;
  m_rereadLater = false;
  m_mediaRewritten = false;
  clearTrail();
  m_revealLine = 0;
  m_fileStatus = QStringLiteral("none");
  m_fileProblem.clear();
  m_truncatedNotice.clear();
  m_truncated = false;
  m_mediaUrl.clear();
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

}  // namespace

QChar WorkspaceFiles::previewDelimiter(const QString& name, const QString& mimeType) {
  const QString mime = mimeType.section(QLatin1Char(';'), 0, 0).trimmed().toLower();
  if (mime == QLatin1String("text/csv")) return u',';
  if (mime == QLatin1String("text/tab-separated-values")) return u'\t';
  if (!mime.isEmpty() && mime != QLatin1String("text/plain") && mime != QLatin1String("application/octet-stream")) return {};
  const QString extension = extensionOf(name);
  if (extension == QLatin1String("csv")) return u',';
  if (extension == QLatin1String("tsv")) return u'\t';
  return {};
}

// Quoted delimiters, doubled quotes and multi-line cells stay in their cell;
// the source view keeps all of the text.
WorkspaceFiles::DelimitedPreview WorkspaceFiles::parseDelimited(const QString& text, QChar delimiter) {
  DelimitedPreview preview;
  QStringList row;
  QString cell;
  bool quoted = false;
  const auto endCell = [&] {
    if (row.size() < tableColumnLimit) {
      row.append(cell);
    } else {
      preview.truncated = true;
    }
    cell.clear();
  };
  const auto add = [&](QChar character) {
    if (cell.size() < tableCellLimit) {
      cell += character;
    } else {
      preview.truncated = true;
    }
  };
  qsizetype rowStart = !text.isEmpty() && text.at(0) == QChar(0xfeff) ? 1 : 0;
  for (qsizetype index = rowStart; index < text.size(); ++index) {
    const QChar character = text.at(index);
    if (character == u'"') {
      if (quoted && index + 1 < text.size() && text.at(index + 1) == u'"') {
        add(u'"');
        ++index;
        continue;
      }
      if (quoted || cell.isEmpty()) {
        quoted = !quoted;
        continue;
      }
    }
    if (!quoted && (character == delimiter || character == u'\n' || character == u'\r')) {
      endCell();
      if (character == delimiter) continue;
      preview.rows.append(std::exchange(row, {}));
      if (character == u'\r' && index + 1 < text.size() && text.at(index + 1) == u'\n') ++index;
      rowStart = index + 1;
      if (preview.rows.size() == tableRowLimit) {
        preview.truncated = preview.truncated || index < text.size() - 1;
        return preview;
      }
    } else {
      add(character);
    }
  }
  // Anything after the last line ending is a row, a lone "" too.
  if (rowStart < text.size()) {
    endCell();
    preview.rows.append(row);
  }
  preview.truncated = preview.truncated || quoted;
  return preview;
}

QString WorkspaceFiles::tableMarkdown(const QString& text, QChar delimiter) {
  const DelimitedPreview preview = parseDelimited(text, delimiter);
  if (preview.rows.isEmpty()) return {};
  qsizetype columns = 0;
  for (const QStringList& row : preview.rows) columns = std::max(columns, row.size());
  const auto line = [columns](const QStringList& row) {
    QString out = QStringLiteral("|");
    for (qsizetype column = 0; column < columns; ++column) {
      QString cell = row.value(column);
      cell.replace(u'\\', QStringLiteral("\\\\")).replace(u'|', QStringLiteral("\\|")).replace(QStringLiteral("\r\n"), QStringLiteral(" ")).replace(u'\n', u' ').replace(u'\r', u' ');
      out += u' ' + cell + QStringLiteral(" |");
    }
    return out + u'\n';
  };
  QString table = line(preview.rows.first()) + QStringLiteral("|") + QStringLiteral(" --- |").repeated(columns) + u'\n';
  for (qsizetype row = 1; row < preview.rows.size(); ++row) table += line(preview.rows.at(row));
  if (preview.truncated) {
    table += u'\n' + tr("Table limited to the first %1 rows and %2 columns; the source shows the rest.").arg(tableRowLimit).arg(tableColumnLimit) + u'\n';
  }
  return table;
}

void WorkspaceFiles::setText(const QString& text) {
  m_saveDelay.stop();
  m_pending = false;
  ++m_revision;
  m_text = text;
  m_lines.setText(text, m_openPath);
  emit textChanged();
}

QString WorkspaceFiles::renderKind() const {
  static const QHash<QString, QString> kinds{
      {QStringLiteral("md"), QStringLiteral("markdown")},   {QStringLiteral("mdx"), QStringLiteral("markdown")},
      {QStringLiteral("markdown"), QStringLiteral("markdown")}, {QStringLiteral("mdown"), QStringLiteral("markdown")},
      {QStringLiteral("mkd"), QStringLiteral("markdown")},  {QStringLiteral("csv"), QStringLiteral("csv")},
      {QStringLiteral("tsv"), QStringLiteral("csv")},       {QStringLiteral("html"), QStringLiteral("html")},
      {QStringLiteral("htm"), QStringLiteral("html")},       {QStringLiteral("mmd"), QStringLiteral("mermaid")},
      {QStringLiteral("mermaid"), QStringLiteral("mermaid")},
  };
  return m_fileStatus == QLatin1String("ready") ? kinds.value(extensionOf(m_openPath)) : QString();
}

QString WorkspaceFiles::mediaKindOf(const QString& path) {
  // What the MC serves as media (its media extensions), less HTML, which renders as text.
  static const QHash<QString, QString> kinds = [] {
    QHash<QString, QString> kinds;
    const auto add = [&kinds](const char* kind, std::initializer_list<const char*> extensions) {
      for (const char* extension : extensions) kinds.insert(QLatin1String(extension), QLatin1String(kind));
    };
    add("image", {"png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "ico"});
    add("video", {"mp4", "webm", "mov", "m4v"});
    add("audio", {"mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac"});
    add("pdf", {"pdf"});
    return kinds;
  }();
  return kinds.value(extensionOf(path));
}

bool WorkspaceFiles::rendered() const {
  const QString kind = renderKind();
  return !kind.isEmpty() && !m_editing && !m_lineSource && !m_sourceKinds.contains(kind);
}

void WorkspaceFiles::setRendered(bool rendered) {
  const QString kind = renderKind();
  const bool leftLine = std::exchange(m_lineSource, false);
  if (kind.isEmpty() || rendered == !m_sourceKinds.contains(kind)) {
    if (leftLine) emit renderedChanged();
    return;
  }
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
  if (kind == QLatin1String("csv")) return tableMarkdown(m_text, previewDelimiter(m_openPath));
  if (kind == QLatin1String("mermaid")) {
    // The whole file is one diagram: a "mermaid" block, fenced past any run of
    // backticks in it.
    static const QRegularExpression ticks(QStringLiteral("`+"));
    qsizetype longest = 2;
    for (auto it = ticks.globalMatch(m_text); it.hasNext();) longest = std::max(longest, it.next().capturedLength());
    const QString fence(longest + 1, QLatin1Char('`'));
    return fence + QStringLiteral("mermaid\n") + m_text + (m_text.endsWith(QLatin1Char('\n')) ? QString() : QStringLiteral("\n")) + fence + QLatin1Char('\n');
  }
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

namespace {

QString hostWriteRefusal() {
  return WorkspaceFiles::tr("Saving a file outside the project needs terminal access, which this device was not paired with.");
}

}  // namespace

QString WorkspaceFiles::readOnlyReason() const {
  if (m_fileStatus != QLatin1String("ready")) return {};
  if (m_truncated) return tr("Files larger than 1 MB open read-only.");
  // A file outside the workspace is written back by its full path, by the MC
  // that read it; one that is not text it refuses (saveFailed). Such a write
  // reaches any file on that machine, so it needs the terminal access this
  // device may have been paired without; once refused, the others there open
  // read-only too.
  if (hostWritesRefused()) return hostWriteRefusal();
  return {};
}

bool WorkspaceFiles::outsideProject() const {
  return hostPath(m_openPath);
}

bool WorkspaceFiles::hostWritesRefused() const {
  return !m_hostWritesRefusedOn.isEmpty() && m_hostWritesRefusedOn == m_environment && hostPath(m_openPath);
}

void WorkspaceFiles::setEditing(bool editing) {
  editing = editing && editable();
  if (editing == m_editing) return;
  m_editing = editing;
  if (!m_editing) save();
  emit renderedChanged();
  rereadIfDue();
}

void WorkspaceFiles::edit(const QString& contents) {
  if (!editable() || contents == m_text) return;
  m_text = contents;
  ++m_revision;
  // A waiting tick counted the boxes of the text that was just replaced.
  m_waitingTicks.clear();
  m_pending = true;
  m_saveProblem.clear();
  emit textChanged();
  emit saveChanged();
  m_saveDelay.start();
}

void WorkspaceFiles::toggleTask(int index) {
  if (!editable() || renderKind() != QLatin1String("markdown")) return;
  // The file may have changed underneath what the user is looking at, unless
  // what they see is their own edit not written yet.
  if (m_pending || m_saving) {
    applyTask(index);
  } else {
    m_waitingTicks.append(index);
    refreshFile();
  }
}

void WorkspaceFiles::applyTask(int index) {
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
  m_lines.setText(m_text, m_openPath);
  ++m_revision;
  m_pending = true;
  emit textChanged();
  emit saveChanged();
  save();
}

void WorkspaceFiles::save(bool closing) {
  m_saveDelay.stop();
  if (!m_pending || m_openPath.isEmpty() || m_root.isEmpty()) return;
  if (hostWritesRefused()) {
    // Refused already: the edit stays on screen, unsaved, until the file goes,
    // and is never written to the file opened next.
    if (closing) m_pending = false;
    return;
  }
  // One write at a time: the next goes when this one is answered.
  if (m_saving && !closing) return;
  m_saving = !closing;
  if (closing) m_pending = false;
  m_writes.append({m_environment, m_root, m_openPath, m_text, m_revision, m_fileRequest, closing});
  writeNext();
  emit saveChanged();
}

void WorkspaceFiles::writeNext() {
  // The MC answers each call on its own, so two writes under way could land in
  // either order and put older text over newer.
  if (m_underWay) return;
  if (m_writes.isEmpty()) {
    if (std::exchange(m_readAfterWrites, false)) readOpenFile();
    emit writesFinished();
    return;
  }
  const Write write = m_writes.takeFirst();
  if (m_hostWritesRefusedOn == write.environment && hostPath(write.path)) {
    // Refused while this one waited. The edit stays on screen, if it still is.
    if (!write.closing && write.request == m_fileRequest) m_saving = false;
    emit saveChanged();
    writeNext();
    return;
  }
  m_underWay = write;
  if (m_readAfterWrites && !writingOpenFile()) {
    m_readAfterWrites = false;
    readOpenFile();
  }
  const auto [environment, root, path, contents, revision, request, closing] = write;
  m_client->call(this, environment, QStringLiteral("projects.writeFile"),
                 QJsonObject{{QStringLiteral("cwd"), root}, {QStringLiteral("relativePath"), path}, {QStringLiteral("contents"), contents}},
                 [this, path, root, environment, revision, request, closing](const QJsonValue& detail, const std::optional<QString>& error) {
                   const auto next = qScopeGuard([this] {
                     m_underWay.reset();
                     writeNext();
                   });
                   // A session without terminal access may not write outside the workspace (Rpc.required_scope/2).
                   const QJsonObject refusal = error ? detail.toObject() : QJsonObject();
                   const bool hostRefused = refusal.value(QLatin1String("_tag")) == QLatin1String("EnvironmentScopeRequiredError") &&
                                            refusal.value(QLatin1String("requiredScope")) == QLatin1String("terminal:operate");
                   if (hostRefused) m_hostWritesRefusedOn = environment;
                   const QString problem = hostRefused ? hostWriteRefusal()
                                           : error     ? (error->isEmpty() ? QStringLiteral("Unable to save this file.") : *error)
                                                       : QString();
                   if (error) emit saveFailed(path, problem);
                   // The file closed, or another opened, meanwhile.
                   if (closing || path != m_openPath || root != m_root || request != m_fileRequest) return;
                   m_saving = false;
                   if (hostRefused) {
                     // The file is read-only now; the view shows the edit that was not saved, to copy.
                     m_saveProblem = problem;
                     m_editing = false;
                     m_lines.setText(m_text, m_openPath);
                     emit renderedChanged();
                     emit fileChanged();
                     emit saveChanged();
                     return;
                   }
                   if (error) {
                     // The edit stays, to be written with the next one.
                     m_saveProblem = problem;
                     emit saveChanged();
                     return;
                   }
                   m_saveProblem.clear();
                   if (revision == m_revision) {
                     m_pending = false;
                     if (!m_editing) m_lines.setText(m_text, m_openPath);
                   } else {
                     m_saveDelay.start();
                   }
                   emit saveChanged();
                   rereadIfDue();
                 });
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
  if (path.isEmpty() || hostPath(path)) return;
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

// --- The path trail ------------------------------------------------------------------

void WorkspaceFiles::clearTrail() {
  ++m_trailRequest;
  if (m_trailFolder.isEmpty() && m_trailStatus.isEmpty()) return;
  m_trailFolder.clear();
  m_trailStatus.clear();
  m_trailProblem.clear();
  m_trailEntries.clear();
  emit trailChanged();
}

void WorkspaceFiles::listTrail(const QString& folder) {
  const int request = ++m_trailRequest;
  m_trailFolder = folder;
  m_trailStatus = QStringLiteral("loading");
  m_trailProblem.clear();
  m_trailEntries.clear();
  emit trailChanged();
  m_client->call(this, m_environment, QStringLiteral("projects.listEntries"),
                 QJsonObject{{QStringLiteral("cwd"), m_root}, {QStringLiteral("directoryPath"), folder}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_trailRequest) return;
                   if (error) {
                     const bool gone = result.toObject().value(QLatin1String("failure")) == QLatin1String("directory_not_found");
                     m_trailStatus = gone ? QStringLiteral("gone") : QStringLiteral("error");
                     m_trailProblem = gone ? tr("This folder is no longer available.") : error->isEmpty() ? tr("Unable to load folder.") : *error;
                     emit trailChanged();
                     return;
                   }
                   QList<FileTreeModel::Entry> entries = entriesOf(result);
                   std::stable_sort(entries.begin(), entries.end(), [](const FileTreeModel::Entry& a, const FileTreeModel::Entry& b) {
                     if (a.directory != b.directory) return a.directory;
                     return a.path.section(QLatin1Char('/'), -1).compare(b.path.section(QLatin1Char('/'), -1), Qt::CaseInsensitive) < 0;
                   });
                   for (const FileTreeModel::Entry& entry : std::as_const(entries)) {
                     m_trailEntries.append(QVariantMap{{QStringLiteral("path"), entry.path},
                                                       {QStringLiteral("name"), entry.path.section(QLatin1Char('/'), -1)},
                                                       {QStringLiteral("directory"), entry.directory}});
                   }
                   m_trailStatus = QStringLiteral("ready");
                   if (m_trailEntries.isEmpty()) {
                     m_trailProblem = result.toObject().value(QLatin1String("truncated")).toBool()
                                          ? tr("No entries from this folder are available in the partial workspace index.")
                                          : tr("This folder is empty.");
                   }
                   emit trailChanged();
                 });
}
