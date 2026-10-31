#include "SpaceController.h"

#include <QFile>
#include <QJsonArray>
#include <QUrl>

#include <algorithm>

#include "CommandRegistry.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<SpaceController> registrar(QStringLiteral("space"), {QStringLiteral("space")},
                                                           "Spaces");

const QString kRoute = QStringLiteral("space");

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

SpacePages::SpacePages(QObject* parent)
    : QObject(parent),
      m_spaces(new SpaceRows({"id", "name"}, this)),
      m_pages(new SpaceRows({"id", "title", "depth", "parentPageId", "hasChildren", "fromThread"}, this)),
      m_trash(new SpaceRows({"id", "title", "trashedAt"}, this)),
      m_blocks(new SpaceRows(
          {"id", "kind", "text", "checked", "linkedPageId", "linkedTitle", "byAgent", "openComments"}, this)),
      m_comments(new SpaceRows({"id", "blockId", "blockText", "body", "resolved", "byAgent", "createdAt"}, this)) {}

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
          {QStringLiteral("sourceThreadTitle"), thread.isEmpty() ? QString() : threadTitle(thread)}};
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
  // A page awaited in this Space is still awaited: it arrives with the Space's copy.
  if (id != m_awaitedSpace) m_awaitedPage.clear();
  m_space.clear();
  m_pending.clear();
  rebuild();
  emit spaceSelected(id);
}

void SpacePages::selectPage(const QString& id) {
  if (id == m_pageId || !m_space.of(QStringLiteral("page")).contains(id)) return;
  m_pageId = id;
  rebuild();
}

void SpacePages::awaitSpace(const QString& id) {
  m_awaitedSpace = id;
  selectSpace(id);
}

void SpacePages::awaitPage(const QString& id) {
  m_awaitedPage = id;
  selectPage(id);
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
      m_space.clear();
      m_pending.clear();
      emit spaceSelected({});
    }
  }
  const QHash<QString, QJsonObject>& pages = m_space.of(QStringLiteral("page"));
  if (pages.contains(m_awaitedPage)) m_pageId = std::exchange(m_awaitedPage, {});
  return false;
}

void SpacePages::rebuild() {
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
  QList<QVariantMap> blocks;
  for (const QJsonObject& block : sorted(pageBlocks, QLatin1String("order"))) {
    const QString id = text(block, QLatin1String("id"));
    const QString linked = text(block, QLatin1String("linkedPageId"));
    const auto shown = [&](const QString& field, const QVariant& value) {
      const auto it = m_pending.constFind(id + QLatin1Char('\n') + field);
      return it == m_pending.cend() ? value : it->value;
    };
    blocks.append({{QStringLiteral("id"), id},
                   {QStringLiteral("kind"), text(block, QLatin1String("kind"))},
                   {QStringLiteral("text"), shown(QStringLiteral("text"), text(block, QLatin1String("text")))},
                   {QStringLiteral("checked"),
                    shown(QStringLiteral("checked"), block.value(QLatin1String("checked")).toBool()).toBool()},
                   {QStringLiteral("linkedPageId"), linked},
                   {QStringLiteral("linkedTitle"), linked.isEmpty() ? QString() : titleOf(linked)},
                   {QStringLiteral("byAgent"), byAgent(block.value(QLatin1String("createdBy")))},
                   {QStringLiteral("openComments"), open.value(id)}});
  }
  m_blocks->setRows(blocks);

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
                     {QStringLiteral("body"), text(comment, QLatin1String("body"))},
                     {QStringLiteral("resolved"), !comment.value(QLatin1String("resolvedAt")).toString().isEmpty()},
                     {QStringLiteral("byAgent"), byAgent(comment.value(QLatin1String("author")))},
                     {QStringLiteral("createdAt"), text(comment, QLatin1String("createdAt"))}});
  }
  m_comments->setRows(comments);
  emit changed();
}

// --- SpaceController ------------------------------------------------------------------

SpaceController::SpaceController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : SpacePages(parent), m_bridge(bridge), m_client(client), m_store(store) {
  setThreadTitles([this](const QString& threadId) {
    const auto thread = m_store->thread(m_client->environment() + QLatin1Char(':') + threadId);
    return thread ? thread->title : QString();
  });
  connect(this, &SpacePages::spaceSelected, this, [this] {
    if (m_open) followSpace();
  });
}

void SpaceController::activate() {
  if (m_active) return;
  m_active = true;
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>(); keys && m_viewed) {
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
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation] { setOpen(navigation->route().kind == kRoute); });
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready && m_open) follow();
  });
  setOpen(navigation->route().kind == kRoute);
  publish();
}

void SpaceController::setOpen(bool open) {
  if (std::exchange(m_open, open) == open) return;
  if (open) {
    follow();
  } else {
    unfollow();
  }
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

void SpaceController::unfollow() {
  // The copies stay, so coming back resumes them.
  if (m_indexSubscription) m_client->unsubscribe(std::exchange(m_indexSubscription, 0));
  if (m_spaceSubscription) m_client->unsubscribe(std::exchange(m_spaceSubscription, 0));
  m_followedSpace.clear();
}

void SpaceController::call(const QString& method, QJsonObject payload, std::function<void(const QJsonObject&)> done,
                           std::function<QString(const QJsonObject&)> refused) {
  if (method != QLatin1String("list") && method != QLatin1String("create") && !payload.contains(QLatin1String("spaceId"))) {
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
  m_bridge->publish(QStringLiteral("space"), QVariantMap{{QStringLiteral("error"), m_error},
                                                          {QStringLiteral("busy"), m_writing > 0}});
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
          publish();
          if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
            navigation->open(NavigationController::Route::of(kRoute));
          }
          awaitSpace(space);
          awaitPage(result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString());
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

  if (action == kOpen) {
    if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
      navigation->open(NavigationController::Route::of(kRoute));
    }
    if (input.contains(QLatin1String("spaceId"))) awaitSpace(field(QLatin1String("spaceId")));
    if (input.contains(QLatin1String("pageId"))) awaitPage(pageId);
  } else if (action == QLatin1String("space.select")) {
    selectSpace(field(QLatin1String("spaceId")));
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
  } else if (action == QLatin1String("space.page.copyMarkdown")) {
    exportPage(pageId, [this](const QString& markdown) {
      m_bridge->setClipboardText(markdown);
      toast(QStringLiteral("success"), tr("Page copied as Markdown"));
    });
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
    QJsonObject insert = orNull(pick({"spaceId", "kind", "text", "checked", "linkedPageId"}),
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
  } else {
    return false;
  }
  return true;
}
