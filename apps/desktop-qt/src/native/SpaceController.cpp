#include "SpaceController.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QMimeDatabase>
#include <QSignalBlocker>
#include <QUrl>

#include <algorithm>
#include <limits>
#include <utility>

#include "CommandRegistry.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThisMachine.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<SpaceController> registrar(QStringLiteral("space"), {QStringLiteral("space")},
                                                           "Spaces");

const QString kRoute = QStringLiteral("space");
constexpr int kHistoryRefreshMs = 1000;

// The MC's limit on an image (HalC2.Attachments.max_image_bytes), and the types
// it takes: said before the upload, which the MC would refuse.
const qint64 kMaxImageBytes = 10 * 1024 * 1024;
const QStringList kImageTypes{QStringLiteral("image/png"), QStringLiteral("image/jpeg"), QStringLiteral("image/gif"),
                              QStringLiteral("image/webp")};
// An address this close to its end is signed anew. However wrong this machine's
// clock is against the MC's, one is taken as good for a while, or every change
// to the rows would sign it again.
const qint64 kAddressMarginMs = 60'000;
const qint64 kAddressAtLeastMs = 5 * 60'000;
// How soon a refused address is asked for again, with nothing else changing.
const int kAddressRetryMs = 30'000;
// Long enough to take in the signed addresses of one batch, which arrive over
// several turns of the event loop.
const int kRebuildSoonMs = 50;
// How long a page the MC could not say who is on waits to ask it again.
const int kViewersRetryMs = 1000;

// HalC2.Patch: `s` sets, `u` unsets, `a` appends to strings, `d` deletes
// (alone) or replaces (with `s`/`a`). nullopt when the entity is gone.
std::optional<QJsonObject> patched(const QJsonObject& entity, const QJsonObject& patch) {
  const bool replace = patch.value(QLatin1String("d")).toBool();
  if (replace && !patch.contains(QLatin1String("s")) && !patch.contains(QLatin1String("a"))) return std::nullopt;
  QJsonObject next = replace ? QJsonObject() : entity;
  const QJsonObject set = patch.value(QLatin1String("s")).toObject();
  for (auto it = set.begin(); it != set.end(); ++it) next.insert(it.key(), it.value());
  for (const QJsonValue& field : patch.value(QLatin1String("u")).toArray()) next.remove(field.toString());
  const QJsonObject append = patch.value(QLatin1String("a")).toObject();
  for (auto it = append.begin(); it != append.end(); ++it) {
    next.insert(it.key(), next.value(it.key()).toString() + it.value().toString());
  }
  return next;
}

QString text(const QJsonObject& entity, QLatin1String field) { return entity.value(field).toString(); }

bool byAgent(const QJsonValue& author) {
  return author.toObject().value(QLatin1String("type")).toString() == QLatin1String("agent");
}

// Written by the page's own update rather than by a person or a thread.
bool byUpdate(const QJsonValue& author) {
  return author.toObject().value(QLatin1String("type")).toString() == QLatin1String("schedule");
}

// Written by the project file the page is, read again after it changed.
bool byFile(const QJsonValue& author) {
  return author.toObject().value(QLatin1String("type")).toString() == QLatin1String("file");
}

// In the order the MC keeps them: by `field`, then id.
QList<QJsonObject> sorted(QList<QJsonObject> entities, QLatin1String field) {
  std::sort(entities.begin(), entities.end(), [field](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(text(a, field), text(b, field));
    return order != 0 ? order < 0 : text(a, QLatin1String("id")) < text(b, QLatin1String("id"));
  });
  return entities;
}

QJsonObject spaceShape(const QString& environment, const QString& stream) {
  return {{QStringLiteral("type"), QStringLiteral("stream")},
          {QStringLiteral("environment"), environment},
          {QStringLiteral("stream"), stream}};
}

bool trashed(const QJsonObject& page) { return !page.value(QLatin1String("trashedAt")).toString().isEmpty(); }

QJsonValue nullable(const QString& value) { return value.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value); }

}  // namespace

// --- SpaceStream ----------------------------------------------------------------------

const QHash<QString, QJsonObject>& SpaceStream::of(const QString& kind) const {
  static const QHash<QString, QJsonObject> none;
  const auto it = m_entities.constFind(kind);
  return it == m_entities.cend() ? none : *it;
}

QJsonObject SpaceStream::subscribing() {
  m_catchingUp = true;
  m_live = false;
  m_catchUp.clear();
  m_incoming.clear();
  if (m_offset < 0) return {{QStringLiteral("offset"), QJsonValue::Null}};
  QJsonObject resume{{QStringLiteral("offset"), m_offset}};
  if (!m_handle.isEmpty()) resume.insert(QStringLiteral("handle"), m_handle);
  return resume;
}

bool SpaceStream::receive(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  const QJsonValue offset = frame.value(QLatin1String("offset"));
  const qint64 reached = offset.isDouble() ? qint64(offset.toDouble()) : -1;
  if (type == QLatin1String("snapshot")) {
    if (frame.value(QLatin1String("part")).toInt() == 0) m_incoming.clear();
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      m_incoming[row.at(0).toString()].insert(row.at(1).toString(), row.at(2).toObject());
    }
    if (!frame.value(QLatin1String("done")).toBool()) return false;
    m_entities = std::exchange(m_incoming, {});
    m_catchUp.clear();
    m_offset = std::max<qint64>(reached, 0);
    m_handle = frame.value(QLatin1String("handle")).toString();
    return true;
  }
  if (type == QLatin1String("events")) {
    // A catch-up that takes several frames is applied as one: its parts carry
    // the offset the copy is at, the last one the offset they bring it to.
    m_catchUp.append(frame.value(QLatin1String("events")).toArray());
    if (m_catchingUp && reached >= 0 && reached <= m_offset) return false;
    QJsonArray all;
    for (const QJsonArray& part : std::exchange(m_catchUp, {})) {
      for (const QJsonValue& event : part) all.append(event);
    }
    const bool changed = events(all);
    if (m_offset >= 0 && reached > m_offset) m_offset = reached;
    return changed;
  }
  if (type == QLatin1String("live")) {
    m_catchingUp = false;
    bool changed = !m_live;
    if (!m_catchUp.isEmpty()) {
      QJsonArray all;
      for (const QJsonArray& part : std::exchange(m_catchUp, {})) {
        for (const QJsonValue& event : part) all.append(event);
      }
      changed = events(all) || changed;
    }
    if (m_offset >= 0 && reached > m_offset) m_offset = reached;
    const QString handle = frame.value(QLatin1String("handle")).toString();
    if (!handle.isEmpty()) m_handle = handle;
    m_live = true;
    return changed;
  }
  if (type == QLatin1String("resync")) {
    // The resubscription that follows goes on from the offset it names, never an earlier one.
    if (m_offset >= 0 && reached > m_offset) m_offset = reached;
  }
  return false;
}

bool SpaceStream::events(const QJsonArray& events) {
  bool changed = false;
  for (const QJsonValue& value : events) {
    const QJsonArray event = value.toArray();
    // One the copy holds already (a frame sent again on a reconnect).
    if (m_offset >= 0 && event.at(0).isDouble() && qint64(event.at(0).toDouble()) <= m_offset) continue;
    const QString kind = event.at(1).toString();
    const QString id = event.at(2).toString();
    QHash<QString, QJsonObject>& entities = m_entities[kind];
    const auto next = patched(entities.value(id), event.at(3).toObject());
    if (next) {
      entities.insert(id, *next);
    } else {
      entities.remove(id);
    }
    changed = true;
  }
  return changed;
}

// --- SpaceRows ------------------------------------------------------------------------

SpaceRows::SpaceRows(const QList<QByteArray>& roles, QObject* parent) : QAbstractListModel(parent), m_roles(roles) {}

int SpaceRows::rowCount(const QModelIndex& parent) const { return parent.isValid() ? 0 : int(m_rows.size()); }

QVariant SpaceRows::data(const QModelIndex& index, int role) const {
  const int field = role - Qt::UserRole;
  if (!index.isValid() || index.row() >= m_rows.size() || field < 0 || field >= m_roles.size()) return {};
  return m_rows.at(index.row()).value(QString::fromLatin1(m_roles.at(field)));
}

QHash<int, QByteArray> SpaceRows::roleNames() const {
  QHash<int, QByteArray> names;
  for (int i = 0; i < m_roles.size(); ++i) names.insert(Qt::UserRole + i, m_roles.at(i));
  return names;
}

int SpaceRows::indexOf(const QString& id) const {
  for (int i = 0; i < m_rows.size(); ++i) {
    if (m_rows.at(i).value(QStringLiteral("id")).toString() == id) return i;
  }
  return -1;
}

void SpaceRows::setRows(const QList<QVariantMap>& rows) {
  const int before = int(m_rows.size());
  const auto id = [](const QVariantMap& row) { return row.value(QStringLiteral("id")).toString(); };
  QSet<QString> kept;
  for (const QVariantMap& row : rows) kept.insert(id(row));
  for (int i = int(m_rows.size()) - 1; i >= 0; --i) {
    if (kept.contains(id(m_rows.at(i)))) continue;
    beginRemoveRows({}, i, i);
    m_rows.removeAt(i);
    endRemoveRows();
  }
  for (int i = 0; i < rows.size(); ++i) {
    const QString want = id(rows.at(i));
    int at = -1;
    for (int j = i; j < m_rows.size(); ++j) {
      if (id(m_rows.at(j)) == want) {
        at = j;
        break;
      }
    }
    if (at < 0) {
      beginInsertRows({}, i, i);
      m_rows.insert(i, rows.at(i));
      endInsertRows();
      continue;
    }
    if (at != i) {
      beginMoveRows({}, at, at, {}, i);
      m_rows.move(at, i);
      endMoveRows();
    }
    if (m_rows.at(i) != rows.at(i)) {
      m_rows[i] = rows.at(i);
      emit dataChanged(index(i), index(i));
    }
  }
  if (m_rows.size() != before) emit countChanged();
}

// --- SpacePages -----------------------------------------------------------------------

SpaceHistory::SpaceHistory(std::function<QString(const QString&)> titleOf,
                           std::function<QVariantMap(const QString&)> imageFields, QObject* parent)
    : QObject(parent),
      m_titleOf(std::move(titleOf)),
      m_imageFields(std::move(imageFields)),
      m_versions(new SpaceRows({"id", "version", "at", "byAgent", "byUpdate", "byFile", "threadTitle", "restoredFromAt"}, this)),
      m_blocks(new SpaceRows({"id", "kind", "text", "level", "checked", "linkedPageId", "linkedTitle", "byAgent", "openComments",
                              "chart", "imageId", "imageState", "imageUrl", "imageWidth", "imageHeight"},
                             this)) {}

SpaceHistory::Next SpaceHistory::open(const QString& pageId) {
  {
    // Going from one page's history to another's never shows none.
    const QSignalBlocker blocker(this);
    close();
    m_pageId = pageId;
    if (!pageId.isEmpty()) m_listToken = ++m_tokens;
  }
  emit changed();
  if (pageId.isEmpty()) return std::nullopt;
  return Request{m_listToken, {{QStringLiteral("pageId"), pageId}}};
}

void SpaceHistory::close() {
  m_pageId.clear();
  m_listToken = 0;
  m_appending = m_refreshing = m_stale = m_failed = false;
  m_nextBefore = -1;
  m_versions->setRows({});
  stopReading();
  emit changed();
}

SpaceHistory::Next SpaceHistory::more() {
  if (!shown() || loading() || !hasMore()) return std::nullopt;
  m_listToken = ++m_tokens;
  m_appending = true;
  m_failed = false;
  emit changed();
  return Request{m_listToken, {{QStringLiteral("pageId"), m_pageId}, {QStringLiteral("before"), m_nextBefore}}};
}

SpaceHistory::Next SpaceHistory::refresh() {
  if (!shown()) return std::nullopt;
  if (loading()) {
    m_stale = true;
    return std::nullopt;
  }
  m_listToken = ++m_tokens;
  m_refreshing = true;
  m_failed = false;
  emit changed();
  // As far back as the user has looked, up to what the MC sends at once; receive()
  // keeps the rows older than that, so the list does not shrink under them.
  const int limit = std::clamp(static_cast<int>(m_versions->rowCount()), 30, 100);
  return Request{m_listToken, {{QStringLiteral("pageId"), m_pageId}, {QStringLiteral("limit"), limit}}};
}

SpaceHistory::Next SpaceHistory::settled() {
  m_listToken = 0;
  m_appending = m_refreshing = false;
  emit changed();
  if (!std::exchange(m_stale, false)) return std::nullopt;
  return refresh();
}

SpaceHistory::Next SpaceHistory::receive(int token, const QJsonObject& result) {
  if (token == 0 || token != m_listToken) return std::nullopt;
  const QList<QVariantMap> had = m_versions->rows();
  QList<QVariantMap> rows = m_appending ? had : QList<QVariantMap>();
  QSet<QString> held;
  for (const QVariantMap& row : rows) held.insert(row.value(QStringLiteral("id")).toString());
  for (const QJsonValue& value : result.value(QLatin1String("versions")).toArray()) {
    const QJsonObject version = value.toObject();
    const qint64 number = version.value(QLatin1String("version")).toInteger();
    const QString id = QString::number(number);
    if (held.contains(id)) continue;
    held.insert(id);
    rows.append({{QStringLiteral("id"), id},
                 {QStringLiteral("version"), number},
                 {QStringLiteral("at"), text(version, QLatin1String("at"))},
                 {QStringLiteral("byAgent"), byAgent(version.value(QLatin1String("author")))},
                 {QStringLiteral("byUpdate"), byUpdate(version.value(QLatin1String("author")))},
                 {QStringLiteral("byFile"), byFile(version.value(QLatin1String("author")))},
                 {QStringLiteral("threadTitle"), text(version, QLatin1String("threadTitle"))},
                 {QStringLiteral("restoredFromAt"), text(version, QLatin1String("restoredFromAt"))}});
  }
  qint64 nextBefore = result.value(QLatin1String("nextBefore")).toInteger(-1);
  // A refresh that stopped at a row already held joins up with the older rows; one
  // that stopped short of them leaves a gap, so they go.
  const auto oldest = std::find_if(had.begin(), had.end(), [&](const QVariantMap& row) {
    return row.value(QStringLiteral("version")).toLongLong() == nextBefore;
  });
  if (m_refreshing && nextBefore >= 0 && oldest != had.end() && oldest + 1 != had.end()) {
    rows.append(QList<QVariantMap>(oldest + 1, had.end()));
    nextBefore = m_nextBefore;
  }
  m_versions->setRows(rows);
  m_nextBefore = nextBefore;
  m_failed = false;
  return settled();
}

SpaceHistory::Next SpaceHistory::failed(int token) {
  if (token == 0 || token != m_listToken) return std::nullopt;
  m_failed = true;
  return settled();
}

SpaceHistory::Request SpaceHistory::read(qint64 version) {
  stopReading();
  m_reading = true;
  m_readToken = ++m_tokens;
  emit changed();
  return {m_readToken, {{QStringLiteral("pageId"), m_pageId}, {QStringLiteral("version"), version}}};
}

void SpaceHistory::stopReading() {
  m_reading = false;
  m_readToken = 0;
  m_version.clear();
  m_read = {};
  m_blocks->setRows({});
  emit changed();
}

void SpaceHistory::receiveVersion(int token, const QJsonObject& result) {
  if (token == 0 || token != m_readToken) return;
  m_readToken = 0;
  m_read = result.value(QLatin1String("blocks")).toArray();
  repaint();
  m_version = {{QStringLiteral("version"), result.value(QLatin1String("version")).toInteger()},
               {QStringLiteral("at"), text(result, QLatin1String("at"))},
               {QStringLiteral("title"), text(result, QLatin1String("title"))}};
  emit changed();
  if (!imagesRead().isEmpty()) emit imagesArrived();
}

void SpaceHistory::failedVersion(int token) {
  if (token == 0 || token != m_readToken) return;
  stopReading();
}

QStringList SpaceHistory::imagesRead() const {
  QStringList images;
  for (const QJsonValue& value : m_read) {
    const QJsonObject block = value.toObject();
    if (text(block, QLatin1String("kind")) == QLatin1String("image")) images.append(text(block, QLatin1String("imageId")));
  }
  return images;
}

void SpaceHistory::repaint() {
  QList<QVariantMap> rows;
  for (const QJsonValue& value : m_read) {
    const QJsonObject block = value.toObject();
    const QString linked = text(block, QLatin1String("linkedPageId"));
    const bool image = text(block, QLatin1String("kind")) == QLatin1String("image");
    QVariantMap row{{QStringLiteral("id"), text(block, QLatin1String("id"))},
                    {QStringLiteral("kind"), text(block, QLatin1String("kind"))},
                    {QStringLiteral("text"), text(block, QLatin1String("text"))},
                    {QStringLiteral("level"), block.value(QLatin1String("level")).toInt(2)},
                    {QStringLiteral("checked"), block.value(QLatin1String("checked")).toBool()},
                    {QStringLiteral("linkedPageId"), linked},
                    {QStringLiteral("linkedTitle"), linked.isEmpty() ? QString() : m_titleOf(linked)},
                    {QStringLiteral("byAgent"), byAgent(block.value(QLatin1String("updatedBy")))},
                    {QStringLiteral("openComments"), 0},
                    {QStringLiteral("chart"), block.value(QLatin1String("chart")).toObject().toVariantMap()}};
    row.insert(m_imageFields(image ? text(block, QLatin1String("imageId")) : QString()));
    rows.append(row);
  }
  m_blocks->setRows(rows);
}

SpacePages::SpacePages(QObject* parent)
    : QObject(parent),
      m_spaces(new SpaceRows({"id", "name"}, this)),
      m_pages(new SpaceRows({"id", "title", "depth", "parentPageId", "hasChildren", "fromThread"}, this)),
      m_trash(new SpaceRows({"id", "title", "trashedAt"}, this)),
      m_blocks(new SpaceRows({"id", "kind", "text", "level", "checked", "linkedPageId", "linkedTitle", "byAgent", "openComments",
                              "chart", "imageId", "imageState", "imageUrl", "imageWidth", "imageHeight"},
                             this)),
      m_comments(new SpaceRows({"id", "blockId", "blockText", "blockGone", "body", "resolved", "byAgent", "createdAt"}, this)),
      m_decks(new SpaceRows({"id", "title"}, this)),
      m_deckTrash(new SpaceRows({"id", "title", "trashedAt"}, this)),
      m_slides(new SpaceRows({"id", "title", "body"}, this)),
      m_images(new SpaceRows({"id", "name", "prompt", "mimeType", "width", "height", "generatedBy", "url"}, this)),
      m_imageTrash(new SpaceRows({"id", "name", "prompt", "mimeType", "width", "height", "generatedBy", "url"}, this)),
      m_history(new SpaceHistory([this](const QString& id) { return titleOf(id); },
                                 [this](const QString& id) { return imageFields(id); }, this)) {
  m_addressRefresh = new QTimer(this);
  m_addressRefresh->setObjectName(QStringLiteral("spaceAddressRefresh"));
  m_addressRefresh->setSingleShot(true);
  connect(m_addressRefresh, &QTimer::timeout, this, &SpacePages::rebuild);
  m_rebuildSoon = new QTimer(this);
  m_rebuildSoon->setObjectName(QStringLiteral("spaceRebuildSoon"));
  m_rebuildSoon->setSingleShot(true);
  m_rebuildSoon->setInterval(kRebuildSoonMs);
  connect(m_rebuildSoon, &QTimer::timeout, this, &SpacePages::rebuild);
  connect(m_history, &SpaceHistory::imagesArrived, m_rebuildSoon, qOverload<>(&QTimer::start));
}

QString SpacePages::spaceName() const {
  return text(m_index.entity(QStringLiteral("space"), m_spaceId), QLatin1String("name"));
}

QVariantMap SpacePages::page() const {
  const QJsonObject page = m_space.entity(QStringLiteral("page"), m_pageId);
  if (page.isEmpty()) return {};
  const QString thread = text(page, QLatin1String("sourceThreadId"));
  return {{QStringLiteral("id"), m_pageId},
          {QStringLiteral("title"), titleOf(m_pageId)},
          {QStringLiteral("parentPageId"), text(page, QLatin1String("parentPageId"))},
          {QStringLiteral("trashed"), !live(page)},
          {QStringLiteral("sourceThreadId"), thread},
          {QStringLiteral("sourceThreadTitle"), thread.isEmpty() ? QString() : threadTitle(thread)},
          {QStringLiteral("schedule"), updateOf(page)},
          {QStringLiteral("writtenAt"), text(page, QLatin1String("writtenAt"))},
          {QStringLiteral("site"), siteOf(m_pageId)},
          {QStringLiteral("file"), fileOf(m_pageId)}};
}

QVariantMap SpacePages::fileOf(const QString& pageId) const {
  const QJsonObject file = m_space.entity(QStringLiteral("page"), pageId).value(QLatin1String("file")).toObject();
  if (file.isEmpty()) return {};
  const QString project = text(file, QLatin1String("projectId"));
  const QString title = m_projectTitle ? m_projectTitle(project) : QString();
  return {{QStringLiteral("projectId"), project},
          {QStringLiteral("projectTitle"), title.isEmpty() ? QStringLiteral("a project") : title},
          {QStringLiteral("path"), text(file, QLatin1String("path"))},
          {QStringLiteral("missing"), file.value(QLatin1String("missing")).toBool()},
          // Edited while the file was gone; an MC that does not say has none.
          {QStringLiteral("unwritten"), file.value(QLatin1String("unwritten")).toBool()},
          {QStringLiteral("conflictAt"), text(file, QLatin1String("conflictAt"))}};
}

QString SpacePages::cadenceLabel(const QJsonObject& cadence) {
  if (cadence.value(QLatin1String("type")).toString() == QLatin1String("interval")) {
    const qint64 minutes = qint64(cadence.value(QLatin1String("everyMs")).toDouble()) / 60000;
    if (minutes == 60) return QStringLiteral("Every hour");
    if (minutes > 0 && minutes % 60 == 0) return QStringLiteral("Every %1 hours").arg(minutes / 60);
    return minutes == 1 ? QStringLiteral("Every minute") : QStringLiteral("Every %1 minutes").arg(minutes);
  }
  static const QStringList names{QStringLiteral("Sun"), QStringLiteral("Mon"), QStringLiteral("Tue"), QStringLiteral("Wed"),
                                 QStringLiteral("Thu"), QStringLiteral("Fri"), QStringLiteral("Sat")};
  QStringList days;
  const QJsonArray weekdays = cadence.value(QLatin1String("weekdays")).toArray();
  for (const QJsonValue& day : weekdays) days.append(names.value(day.toInt()));
  return QStringLiteral("%1 at %2")
      .arg(days.isEmpty() || days.size() == names.size() ? QStringLiteral("Every day") : days.join(QStringLiteral(", ")),
           cadence.value(QLatin1String("timeOfDay")).toString());
}

QVariantMap SpacePages::updateOf(const QJsonObject& page) {
  const QJsonObject schedule = page.value(QLatin1String("schedule")).toObject();
  if (schedule.isEmpty()) return {};
  QVariantMap update = schedule.toVariantMap();
  update.insert(QStringLiteral("cadenceLabel"), cadenceLabel(schedule.value(QLatin1String("cadence")).toObject()));
  return update;
}

QVariantMap SpacePages::siteOf(const QString& pageId) const {
  for (const QJsonObject& site : m_space.of(QStringLiteral("site"))) {
    if (text(site, QLatin1String("pageId")) != pageId) continue;
    return {{QStringLiteral("url"), text(site, QLatin1String("url"))},
            {QStringLiteral("localOnly"), site.value(QLatin1String("localOnly")).toBool()},
            {QStringLiteral("behind"), site.value(QLatin1String("behind")).toBool()},
            {QStringLiteral("publishedAt"), text(site, QLatin1String("publishedAt"))}};
  }
  return {};
}

QVariantMap SpacePages::agent() const {
  const QJsonObject agent = m_space.entity(QStringLiteral("pageAgent"), m_pageId);
  if (agent.isEmpty()) return {};
  const QString thread = text(agent, QLatin1String("threadId"));
  return {{QStringLiteral("status"), text(agent, QLatin1String("status"))},
          {QStringLiteral("request"), text(agent, QLatin1String("request"))},
          {QStringLiteral("threadId"), thread},
          {QStringLiteral("threadTitle"), threadTitle(thread)},
          {QStringLiteral("edited"), agent.value(QLatin1String("edited")).toBool()},
          {QStringLiteral("error"), text(agent, QLatin1String("error"))}};
}

QVariantMap SpacePages::deck() const {
  const QJsonObject deck = m_space.entity(QStringLiteral("deck"), m_deckId);
  if (deck.isEmpty()) return {};
  return {{QStringLiteral("id"), m_deckId},
          {QStringLiteral("title"), text(deck, QLatin1String("title"))},
          {QStringLiteral("trashed"), trashed(deck)}};
}

QString SpacePages::status() const {
  if (m_unreachable) return QStringLiteral("unreachable");
  const SpaceStream& stream = m_spaceId.isEmpty() ? m_index : m_space;
  return stream.live() ? QStringLiteral("live") : QStringLiteral("loading");
}

QString SpacePages::titleOf(const QString& pageId) const {
  const QString title = text(m_space.entity(QStringLiteral("page"), pageId), QLatin1String("title")).trimmed();
  return title.isEmpty() ? QStringLiteral("Untitled") : title;
}

QString SpacePages::threadTitle(const QString& threadId) const {
  const QString title = m_threadTitle ? m_threadTitle(threadId) : QString();
  return title.isEmpty() ? QStringLiteral("a thread") : title;
}

void SpacePages::receiveIndex(const QJsonObject& frame) {
  const bool wasUnreachable = std::exchange(m_unreachable, false);
  if (m_index.receive(frame) || wasUnreachable) rebuild();
}

void SpacePages::receiveSpace(const QJsonObject& frame) {
  const bool wasUnreachable = std::exchange(m_unreachable, false);
  if (m_space.receive(frame) || wasUnreachable) rebuild();
}

void SpacePages::setUnreachable(bool unreachable) {
  if (std::exchange(m_unreachable, unreachable) != unreachable) rebuild();
}

void SpacePages::selectSpace(const QString& id) {
  if (id == m_spaceId || !m_index.of(QStringLiteral("space")).contains(id)) return;
  m_spaceId = id;
  m_pageId.clear();
  m_deckId.clear();
  m_presenting = false;
  // What is awaited in this Space is still awaited: it arrives with the Space's copy.
  if (id != m_awaitedSpace) {
    m_awaitedPage.clear();
    m_awaitedDeck.clear();
  }
  m_space.clear();
  m_pending.clear();
  m_addresses.clear();
  m_signing.clear();
  rebuild();
  emit spaceSelected(id);
}

void SpacePages::selectPage(const QString& id) {
  if ((id == m_pageId && m_deckId.isEmpty()) || !m_space.of(QStringLiteral("page")).contains(id)) return;
  m_pageId = id;
  m_deckId.clear();
  m_presenting = false;
  rebuild();
}

void SpacePages::selectDeck(const QString& id) {
  if (id == m_deckId || !m_space.of(QStringLiteral("deck")).contains(id)) return;
  m_deckId = id;
  m_presenting = false;
  rebuild();
}

void SpacePages::setImagesShown(bool shown) {
  if (std::exchange(m_imagesShown, shown) != shown) rebuild();
}

void SpacePages::setImageAddress(const QString& imageId, const QString& url, qint64 expiresAt) {
  if (!m_signing.remove(imageId)) return;
  m_addresses.insert(imageId, {url, qMax(expiresAt, m_now() + kAddressAtLeastMs)});
  if (!m_rebuildSoon->isActive()) m_rebuildSoon->start();
}

void SpacePages::imageAddressFailed(const QString& imageId) {
  m_signing.remove(imageId);
  if (!m_addressRefresh->isActive() || m_addressRefresh->remainingTime() > kAddressRetryMs) m_addressRefresh->start(kAddressRetryMs);
}

QVariantMap SpacePages::imageFields(const QString& imageId) const {
  const QHash<QString, QJsonObject>& images = m_space.of(QStringLiteral("image"));
  const auto image = images.constFind(imageId);
  const bool found = image != images.cend();
  const QString state = imageId.isEmpty() ? QString()
                        : !found          ? QStringLiteral("deleted")
                        : trashed(*image) ? QStringLiteral("trashed")
                                          : QStringLiteral("shown");
  return {{QStringLiteral("imageId"), imageId},
          {QStringLiteral("imageState"), state},
          {QStringLiteral("imageUrl"), state == QLatin1String("shown") ? m_addresses.value(imageId).url : QString()},
          {QStringLiteral("imageWidth"), found ? image->value(QLatin1String("width")).toInt() : 0},
          {QStringLiteral("imageHeight"), found ? image->value(QLatin1String("height")).toInt() : 0}};
}

QStringList SpacePages::imagesToSign(const QSet<QString>& wanted) {
  QStringList needed;
  for (const QString& id : wanted) {
    const auto address = m_addresses.constFind(id);
    if (m_signing.contains(id)) continue;
    if (address != m_addresses.cend() && address->expiresAt - kAddressMarginMs > m_now()) continue;
    m_signing.insert(id);
    needed.append(id);
  }
  needed.sort();
  return needed;
}

void SpacePages::awaitSpace(const QString& id) {
  m_awaitedSpace = id;
  selectSpace(id);
}

void SpacePages::awaitPage(const QString& id) {
  m_awaitedDeck.clear();
  m_awaitedPage = id;
  selectPage(id);
}

void SpacePages::awaitDeck(const QString& id) {
  m_awaitedPage.clear();
  m_awaitedDeck = id;
  selectDeck(id);
}

bool SpacePages::present(const QString& id) {
  const QJsonObject deck = m_space.entity(QStringLiteral("deck"), id);
  if (deck.isEmpty() || trashed(deck)) return false;
  selectDeck(id);
  if (m_slides->rowCount() == 0) return false;
  m_presenting = true;
  m_slideIndex = 0;
  m_slideId = m_slides->get(0).value(QStringLiteral("id")).toString();
  emit changed();
  return true;
}

void SpacePages::step(int by) {
  if (!m_presenting) return;
  const int at = std::clamp(m_slideIndex + by, 0, m_slides->rowCount() - 1);
  if (at == m_slideIndex) return;
  m_slideIndex = at;
  m_slideId = m_slides->get(at).value(QStringLiteral("id")).toString();
  emit changed();
}

void SpacePages::leave() {
  if (std::exchange(m_presenting, false)) emit changed();
}

void SpacePages::followPresenter() {
  if (!m_presenting) return;
  const QJsonObject deck = m_space.entity(QStringLiteral("deck"), m_deckId);
  const int count = m_slides->rowCount();
  if (deck.isEmpty() || trashed(deck) || count == 0) {
    m_presenting = false;
    return;
  }
  const int at = m_slides->indexOf(m_slideId);
  // A slide that went is followed by what took its place.
  m_slideIndex = at >= 0 ? at : std::min(m_slideIndex, count - 1);
  m_slideId = m_slides->get(m_slideIndex).value(QStringLiteral("id")).toString();
}

bool SpacePages::live(const QJsonObject& page) const {
  const QHash<QString, QJsonObject>& pages = m_space.of(QStringLiteral("page"));
  QSet<QString> seen;
  for (QJsonObject at = page; !at.isEmpty();) {
    if (trashed(at)) return false;
    const QString parent = text(at, QLatin1String("parentPageId"));
    if (parent.isEmpty() || seen.contains(parent)) break;
    seen.insert(parent);
    at = pages.value(parent);
  }
  return true;
}

int SpacePages::pend(const QString& blockId, const QString& field, const QVariant& value) {
  const int token = ++m_tokens;
  m_pending.insert(blockId + QLatin1Char('\n') + field, {blockId, field, value, token, {}});
  rebuild();
  return token;
}

void SpacePages::settle(int token, const std::optional<QJsonObject>& block) {
  for (auto it = m_pending.begin(); it != m_pending.end(); ++it) {
    if (it->token != token) continue;
    if (!block) {
      m_pending.erase(it);
    } else {
      // An answer without a time is caught up with by any value the stream holds.
      const QString at = text(*block, QLatin1String("updatedAt"));
      it->answeredAt = at.isEmpty() ? QStringLiteral(" ") : at;
    }
    rebuild();
    return;
  }
}

void SpacePages::reconcile() {
  for (auto it = m_pending.begin(); it != m_pending.end();) {
    const QJsonObject block = m_space.entity(QStringLiteral("block"), it->blockId);
    const bool caughtUp =
        !it->answeredAt.isEmpty() && QString::compare(text(block, QLatin1String("updatedAt")), it->answeredAt) >= 0;
    it = block.isEmpty() || caughtUp ? m_pending.erase(it) : std::next(it);
  }
}

bool SpacePages::reselect() {
  const QHash<QString, QJsonObject>& spaces = m_index.of(QStringLiteral("space"));
  if (spaces.contains(m_awaitedSpace)) {
    // Selected while still awaited, so the page awaited in it stays awaited.
    if (m_awaitedSpace != m_spaceId) {
      selectSpace(m_awaitedSpace);
      m_awaitedSpace.clear();
      return true;
    }
    m_awaitedSpace.clear();
  }
  if (m_index.hasCopy() && !spaces.contains(m_spaceId)) {
    const QList<QJsonObject> made = sorted(spaces.values(), QLatin1String("createdAt"));
    if (!made.isEmpty()) {
      selectSpace(text(made.first(), QLatin1String("id")));
      return true;
    }
    if (!m_spaceId.isEmpty()) {
      m_spaceId.clear();
      m_pageId.clear();
      m_deckId.clear();
      m_presenting = false;
      m_space.clear();
      m_pending.clear();
      emit spaceSelected({});
    }
  }
  const QHash<QString, QJsonObject>& pages = m_space.of(QStringLiteral("page"));
  if (pages.contains(m_awaitedPage)) {
    m_pageId = std::exchange(m_awaitedPage, {});
    m_deckId.clear();
    m_presenting = false;
  }
  if (m_space.of(QStringLiteral("deck")).contains(m_awaitedDeck)) {
    m_deckId = std::exchange(m_awaitedDeck, {});
    m_presenting = false;
  }
  return false;
}

void SpacePages::rebuild() {
  m_rebuildSoon->stop();
  // selectSpace rebuilt it already.
  if (reselect()) return;
  reconcile();

  QList<QVariantMap> spaces;
  for (const QJsonObject& space : sorted(m_index.of(QStringLiteral("space")).values(), QLatin1String("createdAt"))) {
    spaces.append({{QStringLiteral("id"), text(space, QLatin1String("id"))},
                   {QStringLiteral("name"), text(space, QLatin1String("name"))}});
  }
  m_spaces->setRows(spaces);

  // The tree, depth first, each page's subpages in the order they were made.
  const QHash<QString, QJsonObject>& pages = m_space.of(QStringLiteral("page"));
  QHash<QString, QList<QJsonObject>> children;
  QList<QJsonObject> inTrash;
  for (const QJsonObject& page : pages) {
    if (trashed(page)) {
      inTrash.append(page);
      continue;
    }
    const QString parent = text(page, QLatin1String("parentPageId"));
    children[pages.contains(parent) ? parent : QString()].append(page);
  }
  for (auto it = children.begin(); it != children.end(); ++it) *it = sorted(*it, QLatin1String("createdAt"));
  QList<QVariantMap> tree;
  QSet<QString> placed;
  const std::function<void(const QString&, int)> place = [&](const QString& parent, int depth) {
    for (const QJsonObject& page : children.value(parent)) {
      const QString id = text(page, QLatin1String("id"));
      if (placed.contains(id)) continue;
      placed.insert(id);
      tree.append({{QStringLiteral("id"), id},
                   {QStringLiteral("title"), titleOf(id)},
                   {QStringLiteral("depth"), depth},
                   {QStringLiteral("parentPageId"), parent},
                   {QStringLiteral("hasChildren"), !children.value(id).isEmpty()},
                   {QStringLiteral("fromThread"), !text(page, QLatin1String("sourceThreadId")).isEmpty()}});
      place(id, depth + 1);
    }
  };
  place(QString(), 0);
  m_pages->setRows(tree);
  // A page that went is followed by the first one.
  if (m_space.hasCopy() && !pages.contains(m_pageId)) {
    m_pageId = tree.isEmpty() ? QString() : tree.first().value(QStringLiteral("id")).toString();
  }

  QList<QVariantMap> trash;
  QList<QJsonObject> latest = sorted(inTrash, QLatin1String("trashedAt"));
  std::reverse(latest.begin(), latest.end());
  for (const QJsonObject& page : latest) {
    const QString id = text(page, QLatin1String("id"));
    trash.append({{QStringLiteral("id"), id},
                  {QStringLiteral("title"), titleOf(id)},
                  {QStringLiteral("trashedAt"), text(page, QLatin1String("trashedAt"))}});
  }
  m_trash->setRows(trash);

  QList<QJsonObject> pageComments;
  QHash<QString, int> open;
  for (const QJsonObject& comment : m_space.of(QStringLiteral("comment"))) {
    if (text(comment, QLatin1String("pageId")) != m_pageId) continue;
    pageComments.append(comment);
    if (comment.value(QLatin1String("resolvedAt")).toString().isEmpty()) ++open[text(comment, QLatin1String("blockId"))];
  }

  QList<QJsonObject> pageBlocks;
  for (const QJsonObject& block : m_space.of(QStringLiteral("block"))) {
    if (text(block, QLatin1String("pageId")) == m_pageId) pageBlocks.append(block);
  }
  const QHash<QString, QJsonObject>& images = m_space.of(QStringLiteral("image"));
  for (auto it = m_addresses.begin(); it != m_addresses.end();) {
    it = images.contains(it.key()) ? std::next(it) : m_addresses.erase(it);
  }
  QSet<QString> wanted;
  QList<QVariantMap> blocks;
  QSet<QString> onPage;
  for (const QJsonObject& block : sorted(pageBlocks, QLatin1String("order"))) {
    const QString id = text(block, QLatin1String("id"));
    onPage.insert(id);
    const QString imageId = text(block, QLatin1String("kind")) == QLatin1String("image") ? text(block, QLatin1String("imageId")) : QString();
    const QVariantMap fields = imageFields(imageId);
    if (fields.value(QStringLiteral("imageState")) == QLatin1String("shown")) wanted.insert(imageId);
    const QString linked = text(block, QLatin1String("linkedPageId"));
    const auto shown = [&](const QString& field, const QVariant& value) {
      const auto it = m_pending.constFind(id + QLatin1Char('\n') + field);
      return it == m_pending.cend() ? value : it->value;
    };
    QVariantMap row{{QStringLiteral("id"), id},
                    {QStringLiteral("kind"), text(block, QLatin1String("kind"))},
                    {QStringLiteral("text"), shown(QStringLiteral("text"), text(block, QLatin1String("text")))},
                    {QStringLiteral("level"), block.value(QLatin1String("level")).toInt(2)},
                    {QStringLiteral("checked"),
                     shown(QStringLiteral("checked"), block.value(QLatin1String("checked")).toBool()).toBool()},
                    {QStringLiteral("linkedPageId"), linked},
                    {QStringLiteral("linkedTitle"), linked.isEmpty() ? QString() : titleOf(linked)},
                    {QStringLiteral("byAgent"), byAgent(block.value(QLatin1String("createdBy")))},
                    {QStringLiteral("openComments"), open.value(id)},
                    {QStringLiteral("chart"), block.value(QLatin1String("chart")).toObject().toVariantMap()}};
    row.insert(fields);
    blocks.append(row);
  }
  m_blocks->setRows(blocks);
  for (const QString& imageId : m_history->imagesRead()) {
    if (imageFields(imageId).value(QStringLiteral("imageState")) == QLatin1String("shown")) wanted.insert(imageId);
  }
  m_history->repaint();

  QList<QVariantMap> kept;
  QList<QVariantMap> binned;
  QList<QJsonObject> newest = sorted(images.values(), QLatin1String("createdAt"));
  std::reverse(newest.begin(), newest.end());
  for (const QJsonObject& image : newest) {
    const QString id = text(image, QLatin1String("id"));
    if (m_imagesShown) wanted.insert(id);
    (trashed(image) ? binned : kept)
        .append({{QStringLiteral("id"), id},
                 {QStringLiteral("name"), text(image, QLatin1String("name"))},
                 {QStringLiteral("prompt"), text(image, QLatin1String("prompt"))},
                 {QStringLiteral("mimeType"), text(image, QLatin1String("mimeType"))},
                 {QStringLiteral("width"), image.value(QLatin1String("width")).toInt()},
                 {QStringLiteral("height"), image.value(QLatin1String("height")).toInt()},
                 {QStringLiteral("generatedBy"),
                  image.value(QLatin1String("generatedBy")).toObject().value(QLatin1String("instanceId")).toString()},
                 {QStringLiteral("url"), m_addresses.value(id).url}});
  }
  m_images->setRows(kept);
  m_imageTrash->setRows(binned);

  // Open ones first, each in the order it was made.
  std::stable_sort(pageComments.begin(), pageComments.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const bool aResolved = !a.value(QLatin1String("resolvedAt")).toString().isEmpty();
    const bool bResolved = !b.value(QLatin1String("resolvedAt")).toString().isEmpty();
    if (aResolved != bResolved) return !aResolved;
    const int order = QString::compare(text(a, QLatin1String("createdAt")), text(b, QLatin1String("createdAt")));
    return order != 0 ? order < 0 : text(a, QLatin1String("id")) < text(b, QLatin1String("id"));
  });
  QList<QVariantMap> comments;
  for (const QJsonObject& comment : pageComments) {
    const QString blockId = text(comment, QLatin1String("blockId"));
    comments.append({{QStringLiteral("id"), text(comment, QLatin1String("id"))},
                     {QStringLiteral("blockId"), blockId},
                     {QStringLiteral("blockText"),
                      text(m_space.entity(QStringLiteral("block"), blockId), QLatin1String("text"))},
                     {QStringLiteral("blockGone"), !blockId.isEmpty() && !onPage.contains(blockId)},
                     {QStringLiteral("body"), text(comment, QLatin1String("body"))},
                     {QStringLiteral("resolved"), !comment.value(QLatin1String("resolvedAt")).toString().isEmpty()},
                     {QStringLiteral("byAgent"), byAgent(comment.value(QLatin1String("author")))},
                     {QStringLiteral("createdAt"), text(comment, QLatin1String("createdAt"))}});
  }
  m_comments->setRows(comments);
  if (m_viewersPage != m_pageId) clearViewers();

  const QHash<QString, QJsonObject>& decks = m_space.of(QStringLiteral("deck"));
  if (m_space.hasCopy() && !decks.contains(m_deckId)) m_deckId.clear();
  QList<QJsonObject> liveDecks;
  QList<QJsonObject> trashedDecks;
  for (const QJsonObject& deck : decks) (trashed(deck) ? trashedDecks : liveDecks).append(deck);
  QList<QVariantMap> deckRows;
  for (const QJsonObject& deck : sorted(liveDecks, QLatin1String("createdAt"))) {
    deckRows.append({{QStringLiteral("id"), text(deck, QLatin1String("id"))},
                     {QStringLiteral("title"), text(deck, QLatin1String("title"))}});
  }
  m_decks->setRows(deckRows);
  QList<QVariantMap> deckTrash;
  trashedDecks = sorted(trashedDecks, QLatin1String("trashedAt"));
  std::reverse(trashedDecks.begin(), trashedDecks.end());
  for (const QJsonObject& deck : trashedDecks) {
    deckTrash.append({{QStringLiteral("id"), text(deck, QLatin1String("id"))},
                      {QStringLiteral("title"), text(deck, QLatin1String("title"))},
                      {QStringLiteral("trashedAt"), text(deck, QLatin1String("trashedAt"))}});
  }
  m_deckTrash->setRows(deckTrash);

  QList<QJsonObject> deckSlides;
  for (const QJsonObject& slide : m_space.of(QStringLiteral("slide"))) {
    if (text(slide, QLatin1String("deckId")) == m_deckId) deckSlides.append(slide);
  }
  QList<QVariantMap> slides;
  for (const QJsonObject& slide : sorted(deckSlides, QLatin1String("order"))) {
    slides.append({{QStringLiteral("id"), text(slide, QLatin1String("id"))},
                   {QStringLiteral("title"), text(slide, QLatin1String("title"))},
                   {QStringLiteral("body"), text(slide, QLatin1String("body"))}});
  }
  m_slides->setRows(slides);
  followPresenter();
  emit changed();
  const QStringList needed = imagesToSign(wanted);
  armAddressRefresh(wanted);
  if (!needed.isEmpty()) emit imagesNeeded(needed);
}

void SpacePages::armAddressRefresh(const QSet<QString>& wanted) {
  std::optional<qint64> due;
  for (const QString& id : wanted) {
    const auto address = m_addresses.constFind(id);
    if (address == m_addresses.cend() || m_signing.contains(id)) continue;
    due = qMin(due.value_or(address->expiresAt), address->expiresAt);
  }
  if (!due) return m_addressRefresh->stop();
  const qint64 delay = *due - kAddressMarginMs - m_now();
  m_addressRefresh->start(int(std::clamp<qint64>(delay, 0, std::numeric_limits<int>::max())));
}

void SpacePages::receiveViewers(const QString& pageId, const QJsonObject& frame) {
  if (pageId != m_pageId || frame.value(QLatin1String("t")).toString() != QLatin1String("spacePresence")) return;
  QStringList devices;
  QStringList agents;
  for (const QJsonValue& viewer : frame.value(QLatin1String("viewers")).toArray()) {
    const QJsonObject row = viewer.toObject();
    if (row.value(QLatin1String("type")).toString() == QLatin1String("agent")) {
      agents.append(row.value(QLatin1String("title")).toString());
    } else {
      for (const QJsonValue& device : row.value(QLatin1String("devices")).toArray()) devices.append(device.toString());
    }
  }
  m_viewersPage = pageId;
  const QVariantMap viewers{{QStringLiteral("devices"), devices}, {QStringLiteral("agents"), agents}};
  if (viewers == m_viewers) return;
  m_viewers = viewers;
  emit viewersChanged();
}

void SpacePages::clearViewers() {
  m_viewersPage.clear();
  if (m_viewers.isEmpty()) return;
  m_viewers.clear();
  emit viewersChanged();
}

// --- SpaceController ------------------------------------------------------------------

SpaceController::SpaceController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : SpacePages(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_viewersRetry = new QTimer(this);
  m_viewersRetry->setObjectName(QStringLiteral("spaceViewersRetry"));
  m_viewersRetry->setSingleShot(true);
  m_viewersRetry->setInterval(kViewersRetryMs);
  connect(m_viewersRetry, &QTimer::timeout, this, [this] {
    if (!m_viewersSubscription && !m_followedViewers.isEmpty()) subscribeViewers();
  });
  setThreadTitles([this](const QString& threadId) {
    const auto thread = m_store->thread(m_client->environment() + QLatin1Char(':') + threadId);
    return thread ? thread->title : QString();
  });
  setProjectTitles([this](const QString& projectId) {
    const QJsonObject project = m_store->projectRow(m_client->environment(), projectId);
    return project.value(QLatin1String("title")).toString();
  });
  connect(this, &SpacePages::spaceSelected, this, [this] {
    if (m_open) followSpace();
  });
  m_historyRefresh = new QTimer(this);
  m_historyRefresh->setSingleShot(true);
  m_historyRefresh->setInterval(kHistoryRefreshMs);
  connect(m_historyRefresh, &QTimer::timeout, this, [this] { askHistory(history()->refresh()); });
  connect(this, &SpacePages::changed, this, &SpaceController::followHistory);
  connect(this, &SpacePages::changed, this, &SpaceController::followViewers);
  connect(this, &SpacePages::imagesNeeded, this, &SpaceController::signImages);
}

void SpaceController::activate() {
  if (m_active) return;
  m_active = true;
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(kOpen, tr("Open Space"),
                          [navigation] { navigation->open(NavigationController::Route::of(kRoute)); });
    keys->commands()->setTerms(kOpen, {QStringLiteral("space"), QStringLiteral("pages"), QStringLiteral("notes"),
                                       QStringLiteral("docs"), QStringLiteral("wiki")});
    keys->commands()->add(kPageFromThread, tr("Create page from thread"), [this, navigation] {
      if (navigation->threadKey().isEmpty()) {
        refuse(tr("Open a thread to make a page from it."));
      } else {
        pageFromThread(navigation->threadKey());
      }
    });
    keys->commands()->setTerms(kPageFromThread, {QStringLiteral("space"), QStringLiteral("page"),
                                                 QStringLiteral("summary"), QStringLiteral("summarise")});
    keys->commands()->add(kHistory, tr("Show page history"), [this, navigation] {
      navigation->open(NavigationController::Route::of(kRoute));
      if (pageId().isEmpty() || !deckId().isEmpty()) {
        refuse(tr("Open a page to see its history."));
      } else {
        openHistory(pageId());
      }
    });
    keys->commands()->setTerms(kHistory, {QStringLiteral("space"), QStringLiteral("page"), QStringLiteral("versions"),
                                          QStringLiteral("restore"), QStringLiteral("undo")});
    keys->commands()->add(kAskAgent, tr("Ask an agent about this page"), [this, navigation] {
      navigation->open(NavigationController::Route::of(kRoute));
      if (pageId().isEmpty()) {
        refuse(tr("Open a page to ask an agent about it."));
      } else if (page().value(QStringLiteral("trashed")).toBool()) {
        refuse(tr("Restore the page to ask an agent about it."));
      } else {
        emit agentAskRequested();
      }
    });
    keys->commands()->setTerms(kAskAgent, {QStringLiteral("space"), QStringLiteral("page"), QStringLiteral("agent"),
                                           QStringLiteral("tidy"), QStringLiteral("@agent")});
    keys->commands()->add(kDeckFromPage, tr("Make a deck from page"), [this] {
      if (!m_open || pageId().isEmpty() || !deckId().isEmpty()) {
        refuse(tr("Open a page in a Space to make a deck from it."));
      } else {
        handle(QStringLiteral("space.deck.createFromPage"), QVariantMap());
      }
    });
    keys->commands()->setTerms(kDeckFromPage, {QStringLiteral("space"), QStringLiteral("slides"),
                                               QStringLiteral("presentation")});
    keys->commands()->add(kPresentDeck, tr("Present deck"), [this] {
      if (!m_open || deckId().isEmpty()) {
        refuse(tr("Open a deck in a Space to present it."));
      } else {
        presentDeck(deckId());
      }
    });
    keys->commands()->setTerms(kPresentDeck, {QStringLiteral("space"), QStringLiteral("slides"),
                                              QStringLiteral("presentation"), QStringLiteral("slideshow")});
    keys->commands()->add(kPickFile, tr("Open a project file in a Space"),
                          [this] { handle(kPickFile, QVariantMap()); });
    keys->commands()->setTerms(kPickFile, {QStringLiteral("space"), QStringLiteral("page"), QStringLiteral("file"),
                                           QStringLiteral("markdown"), QStringLiteral("docs")});
    keys->commands()->add(kScanFiles, tr("Scan project for Space files"), [this] {
      const QString project = projectHere();
      if (project.isEmpty()) {
        refuse(tr("Add a project on this machine to scan it for Space files."));
      } else {
        scanFiles(project, false);
      }
    });
    keys->commands()->setTerms(kScanFiles, {QStringLiteral("space"), QStringLiteral("files"), QStringLiteral("markdown"),
                                            QStringLiteral("hal-c2.json"), QStringLiteral("config")});
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation] { setOpen(navigation->route().kind == kRoute); });
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready && m_open) follow();
    if (ready) {
      for (const QString& project : QSet<QString>(m_filesWanted)) listFiles(m_client->environment(), project);
    }
    followViewers();
  });
  setOpen(navigation->route().kind == kRoute);
  publish();
}

void SpaceController::setOpen(bool open) {
  if (std::exchange(m_open, open) == open) return;
  if (open) {
    follow();
  } else {
    leave();
    unfollow();
    history()->close();
    m_historyRefresh->stop();
    m_pageShown = false;
    if (!std::exchange(m_picking, QString()).isEmpty()) publish();
  }
  followViewers();
}

void SpaceController::setPageShownBySteps(bool bySteps) {
  m_pageShownBySteps = bySteps;
  followViewers();
}

void SpaceController::follow() {
  if (!m_client->isReady() || m_client->environment().isEmpty()) return;
  // Asking lists Personal into an MC that has no Space yet.
  if (!m_listed) call(QStringLiteral("list"), {}, [this](const QJsonObject&) { m_listed = true; });
  if (!m_indexSubscription) {
    m_indexSubscription = m_client->subscribe(
        this, spaceShape(m_client->environment(), QStringLiteral("spaces")),
        [this](const QJsonObject& frame) {
          const QString type = frame.value(QLatin1String("t")).toString();
          if (type == QLatin1String("error") || type == QLatin1String("end")) {
            setUnreachable(true);
          } else {
            receiveIndex(frame);
          }
        },
        [this] { return index().subscribing(); });
  }
  followSpace();
}

void SpaceController::followSpace() {
  if (m_followedSpace == spaceId() && (m_spaceSubscription || spaceId().isEmpty())) return;
  if (m_spaceSubscription) m_client->unsubscribe(std::exchange(m_spaceSubscription, 0));
  m_followedSpace = spaceId();
  if (m_followedSpace.isEmpty() || !m_client->isReady()) return;
  const QString followed = m_followedSpace;
  m_spaceSubscription = m_client->subscribe(
      this, spaceShape(m_client->environment(), QStringLiteral("space:") + followed),
      [this, followed](const QJsonObject& frame) {
        if (followed != spaceId()) return;
        const QString type = frame.value(QLatin1String("t")).toString();
        if (type == QLatin1String("error") || type == QLatin1String("end")) {
          setUnreachable(true);
        } else {
          receiveSpace(frame);
        }
      },
      [this, followed] { return followed == spaceId() ? space().subscribing() : QJsonObject(); });
}

bool SpaceController::pageOnShow() const {
  // A deck or the image browser takes the selected page's place.
  return m_open && m_client->isReady() && deckId().isEmpty() && !imagesShown() && (!m_pageShownBySteps || m_pageShown);
}

void SpaceController::followViewers() {
  syncShownFile();
  const QString page = pageOnShow() ? pageId() : QString();
  if (page == m_followedViewers) return;
  if (m_viewersSubscription) m_client->unsubscribe(std::exchange(m_viewersSubscription, 0));
  m_followedViewers = page;
  clearViewers();
  if (page.isEmpty()) return;
  subscribeViewers();
}

void SpaceController::setViewersRetryMs(int ms) {
  m_viewersRetry->setInterval(ms);
}

void SpaceController::subscribeViewers() {
  const QString page = m_followedViewers;
  m_viewersSubscription = m_client->subscribe(
      this,
      {{QStringLiteral("type"), QStringLiteral("spacePresence")},
       {QStringLiteral("environment"), m_client->environment()},
       {QStringLiteral("spaceId"), spaceId()},
       {QStringLiteral("pageId"), page}},
      [this, page](const QJsonObject& frame) {
        if (frame.value(QLatin1String("t")).toString() == QLatin1String("error")) {
          // The MC could not say (its presence service is down, or the page's MC out of
          // reach) and keeps nothing of this subscription: nobody is shown until it can.
          m_client->unsubscribe(std::exchange(m_viewersSubscription, 0));
          clearViewers();
          m_viewersRetry->start();
          return;
        }
        receiveViewers(page, frame);
      });
}

void SpaceController::unfollow() {
  // The copies stay, so coming back resumes them.
  if (m_indexSubscription) m_client->unsubscribe(std::exchange(m_indexSubscription, 0));
  if (m_spaceSubscription) m_client->unsubscribe(std::exchange(m_spaceSubscription, 0));
  m_followedSpace.clear();
}

void SpaceController::call(const QString& method, QJsonObject payload, std::function<void(const QJsonObject&)> done,
                           std::function<QString(const QJsonObject&)> refused) {
  // The Spaces and a project's files are no Space's.
  if (method != QLatin1String("list") && method != QLatin1String("create") && !method.startsWith(QLatin1String("files.")) &&
      !payload.contains(QLatin1String("spaceId"))) {
    payload.insert(QStringLiteral("spaceId"), spaceId());
  }
  if (!m_error.isEmpty()) {
    m_error.clear();
    publish();
  }
  m_client->call(this, m_client->environment(), QStringLiteral("space.") + method, payload,
                 [this, done, refused](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) {
                     const QString said = refused ? refused(result.toObject()) : QString();
                     refuse(said.isEmpty() ? *error : said);
                   } else if (done) {
                     done(result.toObject());
                   }
                 });
}

void SpaceController::refuse(const QString& message) {
  m_error = message;
  publish();
  toast(QStringLiteral("error"), message);
}

void SpaceController::toast(const QString& type, const QString& title, const QString& description) {
  if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->show(type, title, description);
}

void SpaceController::publish() {
  QVariantList projects;
  if (!m_picking.isEmpty()) {
    for (const QJsonObject& project : m_store->projectRows(m_client->environment())) {
      projects.append(QVariantMap{{QStringLiteral("id"), project.value(QLatin1String("id")).toString()},
                                  {QStringLiteral("title"), project.value(QLatin1String("title")).toString()}});
    }
  }
  m_bridge->publish(QStringLiteral("space"), QVariantMap{{QStringLiteral("error"), m_error},
                                                          {QStringLiteral("busy"), m_writing > 0},
                                                          {QStringLiteral("drawing"), m_drawing > 0},
                                                          {QStringLiteral("written"), m_written},
                                                          {QStringLiteral("addingImage"), m_addingImages > 0},
                                                          {QStringLiteral("generatingImage"), m_generatingImages > 0},
                                                          {QStringLiteral("imageProviders"), m_imageProviders},
                                                          {QStringLiteral("files"), m_files},
                                                          {QStringLiteral("picking"), m_picking},
                                                          {QStringLiteral("projects"), projects}});
}

void SpaceController::exportPage(const QString& pageId, std::function<void(const QString&)> done) {
  call(QStringLiteral("page.exportMarkdown"), {{QStringLiteral("pageId"), pageId}},
       [done](const QJsonObject& result) { done(result.value(QLatin1String("markdown")).toString()); });
}

void SpaceController::importMarkdown(const QString& markdown) {
  call(QStringLiteral("page.importMarkdown"), {{QStringLiteral("markdown"), markdown}},
       [this](const QJsonObject& result) {
         awaitPage(result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString());
         toast(QStringLiteral("success"), tr("Page imported"));
       });
}

void SpaceController::pageFromThread(const QString& threadKey) {
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  if (threadKey.left(colon) != m_client->environment()) {
    return refuse(tr("A page can be made only from a thread on this machine. Move the thread here first."));
  }
  const QString threadId = threadKey.mid(colon + 1);
  const auto write = [this, threadId](const QString& space) {
    ++m_writing;
    publish();
    toast(QStringLiteral("loading"), tr("Writing a page from the thread…"));
    call(
        QStringLiteral("page.createFromThread"),
        {{QStringLiteral("spaceId"), space}, {QStringLiteral("threadId"), threadId}},
        [this, space](const QJsonObject& result) {
          --m_writing;
          // Said before the route opens: the phone's Space screen opens this page when it arrives.
          m_written = result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString();
          publish();
          if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
            navigation->open(NavigationController::Route::of(kRoute));
          }
          awaitSpace(space);
          awaitPage(m_written);
          toast(QStringLiteral("success"), tr("Page written from the thread"));
        },
        [this](const QJsonObject& detail) {
          --m_writing;
          publish();
          if (detail.value(QLatin1String("_tag")).toString() != QLatin1String("SpaceTextGenerationError")) return QString();
          const QString why = detail.value(QLatin1String("message")).toString();
          if (detail.value(QLatin1String("reason")).toString() == QLatin1String("unavailable")) {
            return tr("Text generation is unavailable, so no page was written. Set up a provider that can "
                      "generate text in Settings, then try again.");
          }
          return why.isEmpty() ? tr("Text generation failed, so no page was written.")
                               : tr("Text generation failed, so no page was written: %1").arg(why);
        });
  };
  if (!spaceId().isEmpty()) return write(spaceId());
  // Not opened yet: the first Space, Personal on a new MC.
  call(QStringLiteral("list"), {}, [this, write](const QJsonObject& result) {
    m_listed = true;
    const QJsonArray spaces = result.value(QLatin1String("spaces")).toArray();
    if (spaces.isEmpty()) return;
    write(spaces.first().toObject().value(QLatin1String("id")).toString());
  });
}

void SpaceController::listFiles(const QString& environmentId, const QString& projectId) {
  if (projectId.isEmpty() || environmentId != m_client->environment()) return;
  // Asked again on every connection: what the files are may have changed meanwhile.
  m_filesWanted.insert(projectId);
  if (!m_client->isReady()) return;
  // Only the latest answer for a project is kept, whatever order they come in.
  const int token = ++m_fileTokens;
  m_listing.insert(projectId, token);
  m_client->call(this, environmentId, QStringLiteral("space.files.list"), QJsonObject{{QStringLiteral("projectId"), projectId}},
                 [this, projectId, token](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_listing.value(projectId) != token) return;
                   // Asked again on connecting; what the files were stands meanwhile.
                   if (error && *error == QLatin1String("disconnected")) return;
                   m_listing.remove(projectId);
                   // A project the MC cannot list offers none of its files, and says why.
                   if (error) {
                     m_files.insert(projectId, QVariantMap{{QStringLiteral("config"), QString()},
                                                           {QStringLiteral("paths"), QVariantMap()},
                                                           {QStringLiteral("error"), *error}});
                     publish();
                     return;
                   }
                   receiveFiles(projectId, result.toObject());
                 });
}

void SpaceController::receiveFiles(const QString& projectId, const QJsonObject& result) {
  QVariantMap paths;
  for (const QJsonValue& value : result.value(QLatin1String("files")).toArray()) {
    const QJsonObject file = value.toObject();
    const QJsonObject page = file.value(QLatin1String("page")).toObject();
    paths.insert(text(file, QLatin1String("relativePath")),
                 QVariantMap{{QStringLiteral("kind"), text(file, QLatin1String("kind"))},
                             {QStringLiteral("spaceId"), text(page, QLatin1String("spaceId"))},
                             {QStringLiteral("pageId"), text(page, QLatin1String("pageId"))},
                             {QStringLiteral("title"), text(page, QLatin1String("title"))}});
  }
  m_files.insert(projectId, QVariantMap{{QStringLiteral("config"), text(result, QLatin1String("config"))},
                                        {QStringLiteral("paths"), paths}});
  publish();
}

bool SpaceController::isSpaceFile(const QString& environmentId, const QString& projectId, const QString& relativePath) const {
  if (environmentId != m_client->environment()) return false;
  QString path = relativePath;
  if (path.startsWith(QLatin1String("./"))) path = path.mid(2);
  return m_files.value(projectId).toMap().value(QStringLiteral("paths")).toMap().contains(path);
}

void SpaceController::openFile(const QString& environmentId, const QString& projectId, const QString& relativePath) {
  // The Space view shows this MC's Spaces only, and a file opens in one of its own MC's.
  if (environmentId != m_client->environment()) {
    return refuse(tr("A file opens in a Space only from a project on this machine."));
  }
  const auto open = [this, projectId, relativePath](const QString& space) {
    // Opening the same file again says its page again.
    if (!m_written.isEmpty()) {
      m_written.clear();
      publish();
    }
    call(
        QStringLiteral("page.openFile"),
        {{QStringLiteral("spaceId"), space}, {QStringLiteral("projectId"), projectId}, {QStringLiteral("relativePath"), relativePath}},
        [this, space, projectId](const QJsonObject& result) {
          m_picking.clear();
          // Said before the route opens: the phone's Space screen opens this page when it arrives.
          m_written = result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString();
          publish();
          if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
            navigation->open(NavigationController::Route::of(kRoute));
          }
          // The file's page may be in another Space, which is where it is shown.
          awaitSpace(result.value(QLatin1String("spaceId")).toString(space));
          awaitPage(m_written);
          listFiles(m_client->environment(), projectId);
        },
        [relativePath](const QJsonObject& detail) {
          const QString reason = detail.value(QLatin1String("reason")).toString();
          if (reason == QLatin1String("notSpaceFile")) {
            return tr("%1 is not a file this project shows in a Space. Add it to the spaces section of its "
                      "hal-c2.json, or scan the project for Space files.")
                .arg(relativePath);
          }
          if (reason == QLatin1String("notFound")) return tr("There is no file %1 in this project.").arg(relativePath);
          if (reason == QLatin1String("invalid")) return tr("%1 is outside the project.").arg(relativePath);
          return QString();
        });
  };
  // Not in a Space: the one shown last, else the first, Personal on a new MC.
  if (!spaceId().isEmpty()) return open(spaceId());
  call(QStringLiteral("list"), {}, [this, open](const QJsonObject& result) {
    m_listed = true;
    const QJsonArray spaces = result.value(QLatin1String("spaces")).toArray();
    if (spaces.isEmpty()) return refuse(tr("There is no Space to open the file in. Make a Space first, then open the file."));
    open(spaces.first().toObject().value(QLatin1String("id")).toString());
  });
}

QString SpaceController::projectHere() const {
  const QString environment = m_client->environment();
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  const QString threadKey = navigation ? navigation->threadKey() : QString();
  if (threadKey.left(threadKey.indexOf(QLatin1Char(':'))) == environment) {
    const QString project = m_store->threadRow(threadKey).value(QLatin1String("projectId")).toString();
    if (!project.isEmpty()) return project;
  }
  if (!m_lastPicked.isEmpty() && !m_store->projectRow(environment, m_lastPicked).isEmpty()) return m_lastPicked;
  const QList<QJsonObject> projects = m_store->projectRows(environment);
  return projects.isEmpty() ? QString() : projects.first().value(QLatin1String("id")).toString();
}

void SpaceController::scanFiles(const QString& projectId, bool replace) {
  QJsonObject scan{{QStringLiteral("projectId"), projectId}};
  if (replace) scan.insert(QStringLiteral("replace"), true);
  call(QStringLiteral("files.scan"), scan, [this, projectId](const QJsonObject& result) {
    QString title = m_store->projectRow(m_client->environment(), projectId).value(QLatin1String("title")).toString();
    if (title.isEmpty()) title = tr("the project");
    QStringList entries;
    for (const QJsonValue& entry : result.value(QLatin1String("entries")).toArray()) {
      entries.append(entry.toObject().value(QLatin1String("path")).toString());
    }
    const QString found = entries.join(QStringLiteral(", "));
    const QString status = result.value(QLatin1String("status")).toString();
    if (status == QLatin1String("written")) {
      toast(QStringLiteral("success"), tr("Wrote the spaces section of %1").arg(title), found);
    } else if (status == QLatin1String("current")) {
      toast(QStringLiteral("info"), tr("The spaces section of %1 is up to date").arg(title), found);
    } else if (status == QLatin1String("kept")) {
      // Someone wrote the section by hand: it is replaced only when the user says so.
      if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
        toasts->show(QStringLiteral("info"), tr("%1 keeps the spaces section someone wrote").arg(title),
                     tr("The scan would write: %1").arg(found),
                     ToastController::Action{tr("Replace it"), [this, projectId] { scanFiles(projectId, true); }}, 0);
      }
    } else {
      toast(QStringLiteral("info"), tr("%1 has no Markdown files for a Space").arg(title));
    }
    listFiles(m_client->environment(), projectId);
  });
}

void SpaceController::showFile(const QString& pageId) {
  const QVariantMap file = fileOf(pageId);
  if (file.isEmpty()) return refuse(tr("This page is not a project file."));
  // The Files tab is a thread's: the project's latest one on the project folder
  // shows the file the page follows; a worktree's copy only when there is no other.
  const QString environment = m_client->environment();
  const QString project = file.value(QStringLiteral("projectId")).toString();
  const QString root = QDir::cleanPath(m_store->projectRow(environment, project).value(QLatin1String("workspaceRoot")).toString());
  const auto onRoot = [&](const sidebar::Thread& thread) {
    const QString worktree = m_store->threadRow(thread.key()).value(QLatin1String("worktreePath")).toString();
    return worktree.isEmpty() || QDir::cleanPath(worktree) == root;
  };
  std::optional<sidebar::Thread> latest;
  bool latestOnRoot = false;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.environmentId != environment || thread.projectId != project || thread.archivedAt || thread.subagent) continue;
    const bool here = onRoot(thread);
    if (!latest || (here && !latestOnRoot) || (here == latestOnRoot && thread.updatedAt > latest->updatedAt)) {
      latest = thread;
      latestOnRoot = here;
    }
  }
  if (!latest) {
    return refuse(tr("Start a thread in %1 to see its files.").arg(file.value(QStringLiteral("projectTitle")).toString()));
  }
  if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
    navigation->open(NavigationController::Route::thread(environment + QLatin1Char(':') + latest->id));
  }
  m_bridge->dispatch(QStringLiteral("panel.open"),
                     QVariantMap{{QStringLiteral("tab"), QStringLiteral("files")}, {QStringLiteral("path"), file.value(QStringLiteral("path"))}});
}

void SpaceController::syncShownFile() {
  const QString page = pageOnShow() && !fileOf(pageId()).isEmpty() ? pageId() : QString();
  if (page == m_synced) return;
  m_synced = page;
  if (page.isEmpty()) return;
  // What the stream then shows is the answer; one that fails leaves the page as it was.
  m_client->call(this, m_client->environment(), QStringLiteral("space.page.syncFile"),
                 QJsonObject{{QStringLiteral("spaceId"), spaceId()}, {QStringLiteral("pageId"), page}},
                 [](const QJsonValue&, const std::optional<QString>&) {});
}

void SpaceController::openHistory(const QString& page) {
  m_historyRefresh->stop();
  m_historyOffset = space().offset();
  askHistory(history()->open(page));
}

void SpaceController::followHistory() {
  if (!history()->shown()) return;
  if (!deckId().isEmpty()) {
    m_historyRefresh->stop();
    history()->close();
  } else if (history()->pageId() != pageId()) {
    openHistory(pageId());
  } else if (space().offset() != m_historyOffset) {
    m_historyOffset = space().offset();
    if (!m_historyRefresh->isActive()) m_historyRefresh->start();
  }
}

void SpaceController::askHistory(const SpaceHistory::Next& request) {
  if (!request) return;
  const int token = request->token;
  call(
      QStringLiteral("page.history"), request->payload,
      [this, token](const QJsonObject& result) { askHistory(history()->receive(token, result)); },
      [this, token](const QJsonObject&) {
        askHistory(history()->failed(token));
        return QString();
      });
}

void SpaceController::presentDeck(const QString& id) {
  if (present(id)) return;
  const QJsonObject deck = space().entity(QStringLiteral("deck"), id);
  refuse(!deck.isEmpty() && deck.value(QLatin1String("trashedAt")).toString().isEmpty()
             ? tr("This deck has no slides to present.")
             : tr("Restore this deck from the trash to present it."));
}

// The signed address needs no token, and the MC's origin is whichever way this
// client reaches it, so an Image loads it over LAN and Tailscale alike.
void SpaceController::signImages(const QStringList& imageIds) {
  const QString space = spaceId();
  for (const QString& id : imageIds) {
    m_client->call(this, m_client->environment(), QStringLiteral("assets.createUrl"),
                   QJsonObject{{QStringLiteral("resource"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("space-image")},
                                                                        {QStringLiteral("spaceId"), space},
                                                                        {QStringLiteral("imageId"), id},
                                                                        {QStringLiteral("disposition"), QStringLiteral("inline")}}}},
                   [this, id](const QJsonValue& result, const std::optional<QString>& error) {
                     if (error) return imageAddressFailed(id);
                     const QJsonObject signed_ = result.toObject();
                     setImageAddress(id, m_client->origin().resolved(QUrl(signed_.value(QLatin1String("relativeUrl")).toString())).toString(),
                                     qint64(signed_.value(QLatin1String("expiresAt")).toDouble()));
                   });
  }
}

// Reads the file, says what the MC would refuse without sending it, uploads it
// and has the MC take the upload as an image of the Space selected when asked.
void SpaceController::addImageFile(const QString& url) {
  const QUrl parsed(url);
  // A phone's picker hands out a content URI, which QFile opens as it is.
  const QString path = parsed.isLocalFile() ? parsed.toLocalFile() : url;
  QFile file(path);
  if (path.isEmpty() || !file.open(QIODevice::ReadOnly)) return refuse(tr("Could not read %1.").arg(path));
  const QString name = QFileInfo(path).fileName();
  if (file.size() > kMaxImageBytes) return refuse(tr("%1 is larger than the 10 MB an image may be.").arg(name));
  const QByteArray bytes = file.readAll();
  const QString mimeType = QMimeDatabase().mimeTypeForData(bytes).name();
  if (!kImageTypes.contains(mimeType)) return refuse(tr("%1 is not a PNG, JPEG, GIF or WebP image.").arg(name));

  m_error.clear();
  ++m_addingImages;
  publish();
  const QString space = spaceId();
  const auto failed = [this](const QString& why) {
    --m_addingImages;
    refuse(why);
  };
  m_client->call(
      this, m_client->environment(), QStringLiteral("attachments.createUploadUrl"),
      QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("mimeType"), mimeType}, {QStringLiteral("sizeBytes"), bytes.size()}},
      [this, bytes, mimeType, name, space, failed](const QJsonValue& result, const std::optional<QString>& error) {
        if (error) return failed(*error);
        const QJsonObject upload = result.toObject();
        const QString attachmentId = upload.value(QLatin1String("attachmentId")).toString();
        m_client->upload(this, upload.value(QLatin1String("relativeUrl")).toString(), bytes, mimeType,
                         [this, attachmentId, name, space, failed](const QJsonValue&, const std::optional<QString>& error) {
                           if (error) return failed(*error);
                           // The answer ends the work whichever way it goes.
                           --m_addingImages;
                           publish();
                           call(QStringLiteral("image.add"),
                                {{QStringLiteral("spaceId"), space}, {QStringLiteral("attachmentId"), attachmentId}, {QStringLiteral("name"), name}});
                         });
      });
}

void SpaceController::generateImage(const QString& prompt, const QJsonObject& selection) {
  QJsonObject generate{{QStringLiteral("prompt"), prompt}};
  if (!selection.isEmpty()) generate.insert(QStringLiteral("modelSelection"), selection);
  ++m_generatingImages;
  publish();
  toast(QStringLiteral("loading"), tr("Generating an image…"));
  call(
      QStringLiteral("image.generate"), generate,
      [this](const QJsonObject&) {
        --m_generatingImages;
        publish();
        toast(QStringLiteral("success"), tr("Image generated"));
      },
      [this](const QJsonObject& detail) {
        --m_generatingImages;
        publish();
        if (detail.value(QLatin1String("_tag")).toString() != QLatin1String("SpaceImageGenerationError")) return QString();
        const QString reason = detail.value(QLatin1String("reason")).toString();
        const QString why = detail.value(QLatin1String("message")).toString();
        if (reason == QLatin1String("failed")) {
          return why.isEmpty() ? tr("Image generation failed, so no image was made.")
                               : tr("Image generation failed, so no image was made: %1").arg(why);
        }
        if (reason == QLatin1String("unavailable")) {
          return tr("Image generation is unavailable, so no image was made. Set up Codex or Grok in Settings, "
                    "then try again.");
        }
        return why;
      });
}

bool SpaceController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("space."))) return false;
  const QJsonObject input = QJsonObject::fromVariantMap(payload.toMap());
  const auto field = [&input](QLatin1String name) { return input.value(name).toString(); };
  const auto pick = [&input](std::initializer_list<const char*> names) {
    QJsonObject out;
    for (const char* name : names) {
      const QString key = QString::fromLatin1(name);
      if (input.contains(key)) out.insert(key, input.value(key));
    }
    return out;
  };
  // An empty parent or block to follow is none: the top of the Space, the start of the page.
  const auto orNull = [&input](QJsonObject out, QLatin1String name) {
    if (input.contains(name)) out.insert(name, nullable(input.value(name).toString()));
    return out;
  };
  const QString pageId = input.contains(QLatin1String("pageId")) ? field(QLatin1String("pageId")) : this->pageId();
  const QString deckId = input.contains(QLatin1String("deckId")) ? field(QLatin1String("deckId")) : this->deckId();
  const auto opensDeck = [this](const QJsonObject& result) {
    awaitDeck(result.value(QLatin1String("deck")).toObject().value(QLatin1String("id")).toString());
  };

  if (action == kOpen) {
    if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
      navigation->open(NavigationController::Route::of(kRoute));
    }
    if (input.contains(QLatin1String("spaceId"))) awaitSpace(field(QLatin1String("spaceId")));
    if (input.contains(QLatin1String("pageId"))) awaitPage(pageId);
  } else if (action == QLatin1String("space.select")) {
    selectSpace(field(QLatin1String("spaceId")));
  } else if (action == QLatin1String("space.pageShown")) {
    m_pageShown = input.value(QLatin1String("shown")).toBool();
    followViewers();
  } else if (action == QLatin1String("space.openFile")) {
    openFile(input.contains(QLatin1String("environmentId")) ? field(QLatin1String("environmentId")) : m_client->environment(),
             field(QLatin1String("projectId")), field(QLatin1String("relativePath")));
  } else if (action == QLatin1String("space.files.list")) {
    listFiles(m_client->environment(), field(QLatin1String("projectId")));
  } else if (action == kPickFile) {
    const QString project = input.contains(QLatin1String("projectId")) ? field(QLatin1String("projectId")) : projectHere();
    if (project.isEmpty()) {
      refuse(tr("Add a project on this machine to open its files in a Space."));
    } else {
      if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
        navigation->open(NavigationController::Route::of(kRoute));
      }
      m_picking = m_lastPicked = project;
      publish();
      listFiles(m_client->environment(), project);
    }
  } else if (action == QLatin1String("space.files.pickClose")) {
    if (!std::exchange(m_picking, QString()).isEmpty()) publish();
  } else if (action == QLatin1String("space.files.scan")) {
    const QString project = input.contains(QLatin1String("projectId")) ? field(QLatin1String("projectId")) : projectHere();
    if (project.isEmpty()) {
      refuse(tr("Add a project on this machine to scan it for Space files."));
    } else {
      scanFiles(project, input.value(QLatin1String("replace")).toBool());
    }
  } else if (action == QLatin1String("space.page.unlinkFile")) {
    const QString project = fileOf(pageId).value(QStringLiteral("projectId")).toString();
    call(QStringLiteral("page.unlinkFile"), {{QStringLiteral("pageId"), pageId}}, [this, project](const QJsonObject&) {
      toast(QStringLiteral("success"), tr("The page no longer follows its file"));
      listFiles(m_client->environment(), project);
    });
  } else if (action == QLatin1String("space.page.showFile")) {
    showFile(pageId);
  } else if (action == QLatin1String("space.selectPage")) {
    selectPage(pageId);
  } else if (action == QLatin1String("space.create")) {
    call(QStringLiteral("create"), pick({"name"}), [this](const QJsonObject& result) {
      awaitSpace(result.value(QLatin1String("space")).toObject().value(QLatin1String("id")).toString());
    });
  } else if (action == QLatin1String("space.rename")) {
    call(QStringLiteral("rename"), pick({"spaceId", "name"}));
  } else if (action == QLatin1String("space.delete")) {
    call(QStringLiteral("delete"), pick({"spaceId"}));
  } else if (action == QLatin1String("space.page.create")) {
    QJsonObject create = orNull(pick({"spaceId"}), QLatin1String("parentPageId"));
    const QString title = field(QLatin1String("title")).trimmed();
    create.insert(QStringLiteral("title"), title.isEmpty() ? QStringLiteral("Untitled") : title);
    // `link`: also add a block to the parent page that links to the new one.
    const QString linkFrom = input.value(QLatin1String("link")).toBool() ? field(QLatin1String("parentPageId")) : QString();
    call(QStringLiteral("page.create"), create, [this, linkFrom, title](const QJsonObject& result) {
      const QString id = result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString();
      if (!linkFrom.isEmpty() && !id.isEmpty()) {
        call(QStringLiteral("block.insert"), {{QStringLiteral("pageId"), linkFrom},
                                              {QStringLiteral("kind"), QStringLiteral("subpage_link")},
                                              {QStringLiteral("text"), title.isEmpty() ? QStringLiteral("Untitled") : title},
                                              {QStringLiteral("linkedPageId"), id}});
      }
      awaitPage(id);
    });
  } else if (action == QLatin1String("space.page.rename")) {
    call(QStringLiteral("page.rename"),
         {{QStringLiteral("pageId"), pageId}, {QStringLiteral("title"), field(QLatin1String("title"))}});
  } else if (action == QLatin1String("space.page.move")) {
    QJsonObject move = orNull(pick({"spaceId"}), QLatin1String("parentPageId"));
    move.insert(QStringLiteral("pageId"), pageId);
    if (!move.contains(QLatin1String("parentPageId"))) move.insert(QStringLiteral("parentPageId"), QJsonValue::Null);
    call(QStringLiteral("page.move"), move);
  } else if (action == QLatin1String("space.page.trash")) {
    call(QStringLiteral("page.trash"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.restore")) {
    call(QStringLiteral("page.restore"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.delete")) {
    call(QStringLiteral("page.delete"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.schedule.set")) {
    QJsonObject set = pick({"spaceId", "instruction", "cadence"});
    set.insert(QStringLiteral("pageId"), pageId);
    call(QStringLiteral("page.schedule.set"), set);
  } else if (action == QLatin1String("space.page.schedule.setEnabled")) {
    QJsonObject set = pick({"spaceId", "enabled"});
    set.insert(QStringLiteral("pageId"), pageId);
    call(QStringLiteral("page.schedule.setEnabled"), set);
  } else if (action == QLatin1String("space.page.schedule.runNow")) {
    call(QStringLiteral("page.schedule.runNow"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.schedule.remove")) {
    call(QStringLiteral("page.schedule.remove"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.copyMarkdown")) {
    exportPage(pageId, [this](const QString& markdown) {
      m_bridge->setClipboardText(markdown);
      toast(QStringLiteral("success"), tr("Page copied as Markdown"));
    });
  } else if (action == QLatin1String("space.page.publish")) {
    QJsonObject publish{{QStringLiteral("pageId"), pageId}};
    // A machine this client reached over the network is reached there by anyone
    // else, and the MC may only know the loopback it listens on: as for a pairing
    // link, the client names the address.
    const QUrl reached = m_client->origin().adjusted(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
    if (input.value(QLatin1String("tailscale")).toBool()) {
      publish.insert(QStringLiteral("tailscale"), true);
    } else if (!thisMachine::loopbackHost(reached.host())) {
      publish.insert(QStringLiteral("baseUrl"), reached.toString());
    }
    call(QStringLiteral("page.publish"), publish);
  } else if (action == QLatin1String("space.page.unpublish")) {
    call(QStringLiteral("page.unpublish"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.page.copySiteLink")) {
    const QString url = siteOf(pageId).value(QStringLiteral("url")).toString();
    if (url.isEmpty()) {
      refuse(tr("This page is not published."));
    } else {
      m_bridge->setClipboardText(url);
      toast(QStringLiteral("success"), tr("Site link copied"));
    }
  } else if (action == QLatin1String("space.page.saveMarkdown")) {
    const QString path = QUrl(field(QLatin1String("url"))).toLocalFile();
    exportPage(pageId, [this, path](const QString& markdown) {
      QFile file(path);
      if (path.isEmpty() || !file.open(QIODevice::WriteOnly | QIODevice::Truncate) ||
          file.write(markdown.toUtf8()) < 0) {
        refuse(tr("Could not save the page to %1.").arg(path));
      } else {
        toast(QStringLiteral("success"), tr("Page saved as Markdown"), path);
      }
    });
  } else if (action == QLatin1String("space.page.importMarkdown")) {
    importMarkdown(field(QLatin1String("markdown")));
  } else if (action == QLatin1String("space.page.importFile")) {
    const QString path = QUrl(field(QLatin1String("url"))).toLocalFile();
    QFile file(path);
    if (path.isEmpty() || !file.open(QIODevice::ReadOnly)) {
      refuse(tr("Could not read %1.").arg(path));
    } else {
      importMarkdown(QString::fromUtf8(file.readAll()));
    }
  } else if (action == kPageFromThread) {
    pageFromThread(field(QLatin1String("threadKey")));
  } else if (action == QLatin1String("space.block.insert")) {
    QJsonObject insert = orNull(pick({"spaceId", "kind", "text", "checked", "linkedPageId", "imageId"}),
                                QLatin1String("afterBlockId"));
    insert.insert(QStringLiteral("pageId"), pageId);
    call(QStringLiteral("block.insert"), insert);
  } else if (action == QLatin1String("space.block.update") || action == QLatin1String("space.block.setChecked")) {
    const bool tick = action == QLatin1String("space.block.setChecked");
    const QString blockId = field(QLatin1String("blockId"));
    const QString name = tick ? QStringLiteral("checked") : QStringLiteral("text");
    const QJsonValue value = input.value(name);
    const int token = pend(blockId, name, value.toVariant());
    call(tick ? QStringLiteral("block.setChecked") : QStringLiteral("block.update"),
         {{QStringLiteral("blockId"), blockId}, {name, value}},
         [this, token](const QJsonObject& result) { settle(token, result.value(QLatin1String("block")).toObject()); },
         [this, token](const QJsonObject&) {
           settle(token, std::nullopt);
           return QString();
         });
  } else if (action == QLatin1String("space.block.move")) {
    QJsonObject move = orNull(pick({"spaceId", "blockId"}), QLatin1String("afterBlockId"));
    call(QStringLiteral("block.move"), move);
  } else if (action == QLatin1String("space.block.visualize")) {
    QJsonObject ask = orNull(pick({"spaceId", "request", "blockId"}), QLatin1String("afterBlockId"));
    ask.insert(QStringLiteral("pageId"), pageId);
    ++m_drawing;
    publish();
    call(
        QStringLiteral("block.visualize"), ask,
        [this](const QJsonObject&) {
          --m_drawing;
          publish();
        },
        // The MC's refusal says why no chart was drawn.
        [this](const QJsonObject&) {
          --m_drawing;
          publish();
          return QString();
        });
  } else if (action == QLatin1String("space.block.delete")) {
    call(QStringLiteral("block.delete"), pick({"spaceId", "blockId"}));
  } else if (action == QLatin1String("space.comment.add")) {
    QJsonObject add = pick({"spaceId", "blockId", "body"});
    add.insert(QStringLiteral("pageId"), pageId);
    call(QStringLiteral("comment.add"), add);
  } else if (action == QLatin1String("space.comment.resolve")) {
    call(QStringLiteral("comment.resolve"), pick({"spaceId", "commentId"}));
  } else if (action == QLatin1String("space.comment.reopen")) {
    call(QStringLiteral("comment.reopen"), pick({"spaceId", "commentId"}));
  } else if (action == kHistory) {
    openHistory(pageId);
  } else if (action == QLatin1String("space.history.close")) {
    m_historyRefresh->stop();
    history()->close();
  } else if (action == QLatin1String("space.agent.ask")) {
    const QString request = field(QLatin1String("request"));
    call(
        QStringLiteral("page.askAgent"), {{QStringLiteral("pageId"), pageId}, {QStringLiteral("request"), request}},
        [this, pageId, request](const QJsonObject&) { emit agentAskAnswered(pageId, request, true); },
        [this, pageId, request](const QJsonObject&) {
          emit agentAskAnswered(pageId, request, false);
          return QString();
        });
  } else if (action == QLatin1String("space.agent.stop")) {
    call(QStringLiteral("page.stopAgent"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.agent.dismiss")) {
    call(QStringLiteral("page.dismissAgent"), {{QStringLiteral("pageId"), pageId}});
  } else if (action == QLatin1String("space.agent.openThread")) {
    const QString thread = agent().value(QStringLiteral("threadId")).toString();
    const QString key = m_client->environment() + QLatin1Char(':') + thread;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    if (!m_store->thread(key)) {
      toast(QStringLiteral("info"), tr("The agent's thread is not available."));
    } else if (navigation) {
      navigation->open(NavigationController::Route::thread(key));
    }
  } else if (action == QLatin1String("space.history.more")) {
    askHistory(history()->more());
  } else if (action == QLatin1String("space.history.read")) {
    const SpaceHistory::Request read = history()->read(input.value(QLatin1String("version")).toInteger());
    call(
        QStringLiteral("page.version"), read.payload,
        [this, token = read.token](const QJsonObject& result) { history()->receiveVersion(token, result); },
        [this, token = read.token](const QJsonObject&) {
          history()->failedVersion(token);
          return QString();
        });
  } else if (action == QLatin1String("space.history.back")) {
    history()->stopReading();
  } else if (action == QLatin1String("space.history.restore")) {
    QJsonObject restore{{QStringLiteral("pageId"), history()->pageId()},
                        {QStringLiteral("version"), input.value(QLatin1String("version")).toInteger()}};
    call(QStringLiteral("page.restoreVersion"), restore, [this](const QJsonObject&) {
      history()->stopReading();
      m_historyRefresh->stop();
      askHistory(history()->refresh());
      toast(QStringLiteral("success"), tr("Version restored"));
    });
  } else if (action == QLatin1String("space.selectDeck")) {
    selectDeck(deckId);
  } else if (action == QLatin1String("space.deck.create")) {
    call(QStringLiteral("deck.create"), pick({"spaceId", "title"}), opensDeck);
  } else if (action == QLatin1String("space.deck.createFromPage")) {
    call(QStringLiteral("deck.createFromPage"), {{QStringLiteral("pageId"), pageId}}, opensDeck);
  } else if (action == QLatin1String("space.deck.rename")) {
    QJsonObject rename = pick({"spaceId", "title"});
    rename.insert(QStringLiteral("deckId"), deckId);
    call(QStringLiteral("deck.rename"), rename);
  } else if (action == QLatin1String("space.deck.trash")) {
    call(QStringLiteral("deck.trash"), {{QStringLiteral("deckId"), deckId}});
  } else if (action == QLatin1String("space.deck.restore")) {
    call(QStringLiteral("deck.restore"), {{QStringLiteral("deckId"), deckId}});
  } else if (action == QLatin1String("space.deck.delete")) {
    call(QStringLiteral("deck.delete"), {{QStringLiteral("deckId"), deckId}});
  } else if (action == QLatin1String("space.slide.insert")) {
    QJsonObject insert = orNull(pick({"spaceId", "title", "body"}), QLatin1String("afterSlideId"));
    insert.insert(QStringLiteral("deckId"), deckId);
    call(QStringLiteral("slide.insert"), insert);
  } else if (action == QLatin1String("space.slide.update")) {
    call(QStringLiteral("slide.update"), pick({"spaceId", "slideId", "title", "body"}));
  } else if (action == QLatin1String("space.slide.move")) {
    call(QStringLiteral("slide.move"), orNull(pick({"spaceId", "slideId"}), QLatin1String("afterSlideId")));
  } else if (action == QLatin1String("space.slide.delete")) {
    call(QStringLiteral("slide.delete"), pick({"spaceId", "slideId"}));
  } else if (action == QLatin1String("space.deck.present")) {
    presentDeck(deckId);
  } else if (action == QLatin1String("space.deck.step")) {
    step(input.value(QLatin1String("by")).toInt());
  } else if (action == QLatin1String("space.deck.leave")) {
    leave();
  } else if (action == QLatin1String("space.images.show")) {
    setImagesShown(input.value(QLatin1String("shown")).toBool());
  } else if (action == QLatin1String("space.image.providers")) {
    call(QStringLiteral("image.providers"), {}, [this](const QJsonObject& result) {
      m_imageProviders = result.toVariantMap();
      publish();
    });
  } else if (action == QLatin1String("space.image.addFile")) {
    addImageFile(field(QLatin1String("url")));
  } else if (action == QLatin1String("space.image.generate")) {
    generateImage(field(QLatin1String("prompt")), input.value(QLatin1String("modelSelection")).toObject());
  } else if (action == QLatin1String("space.image.trash") || action == QLatin1String("space.image.restore") ||
             action == QLatin1String("space.image.delete")) {
    call(action.mid(6), pick({"spaceId", "imageId"}));
  } else {
    return false;
  }
  return true;
}
