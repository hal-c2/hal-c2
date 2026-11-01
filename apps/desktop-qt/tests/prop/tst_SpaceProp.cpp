// The pages of one Space as the MC streams them (SpacePages over SpaceStream),
// against a model of what a user should see.
//
// The model keeps the MC's Space (pages, blocks, comments, decks and slides) and its log, and
// what the client holds of it: the copy, the offset and log it holds it as of,
// and whether it follows the stream. The fake MC in it answers a `sub` as
// HalC2.Streams.Server does: a snapshot in parts when the copy is new or of
// another log, else the events since the offset (as the log has them, or one
// whole entity each when they take several frames, only the last of which moves
// the offset), then `live`. Answers can be cut off part-way, frames can come
// twice, the stream can be dropped or resynced, and the MC can restart on a new
// log. The user's edits of blocks wait on the MC's answers, which come before or
// after the events that carry them, or are refusals.
//
// After each step the client's copy is the model's, the rows equal the model's
// projection of it (the user's edits shown until the stream catches up with
// them), QAbstractItemModelTester finds nothing wrong with the row signals, every
// row whose roles changed was redrawn, and no row that stayed the same was. The
// presenter stays on its slide whatever moves around it, takes the place of one
// that went, and closes when there is nothing left to present.
//
// The second property is of images: what happens to one shows on every block of
// it and in the lists, and an address is asked for exactly when an image is on
// screen and has none on its way: never twice at once, never for a deleted one,
// again after a failure once the rows change, and a late answer from a Space
// the user left is dropped.

#include "Prop.h"

#include <QAbstractItemModelTester>

#include <algorithm>
#include <memory>
#include <optional>
#include <vector>

#include "SpaceController.h"

namespace {

const QString kSpace = QStringLiteral("space-1");
const QString kPage = QStringLiteral("page");
const QString kAgent = QStringLiteral("pageAgent");
const QString kBlock = QStringLiteral("block");
const QString kComment = QStringLiteral("comment");
const QString kDeck = QStringLiteral("deck");
const QString kSlide = QStringLiteral("slide");
const QString kSite = QStringLiteral("site");
constexpr int kMaxPages = 5;
constexpr int kMaxDecks = 3;
constexpr int kMaxSlides = 6;
constexpr int kMaxBlocks = 6;
constexpr int kMaxComments = 4;
constexpr int kMaxSites = 3;

// Entities by "kind\nid".
using Entities = QMap<QString, QJsonObject>;

QString keyOf(const QString& kind, const QString& id) { return kind + QLatin1Char('\n') + id; }

// One of `values` (RapidCheck's elementOf finds no begin() for a QList).
QString pick(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

// The MC's clock: later writes read later.
QString stamp(int at) { return QStringLiteral("2026-09-23T10:%1Z").arg(at, 6, 10, QLatin1Char('0')); }

QString str(const QJsonObject& entity, const char* field) { return entity.value(QLatin1String(field)).toString(); }

QJsonValue nullable(const QString& value) { return value.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value); }

QMap<QString, QJsonObject> ofKind(const Entities& entities, const QString& kind) {
  QMap<QString, QJsonObject> all;
  const QString prefix = kind + QLatin1Char('\n');
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    if (it.key().startsWith(prefix)) all.insert(it.key().mid(prefix.size()), *it);
  }
  return all;
}

// --- The model --------------------------------------------------------------------

struct Event {
  int seq = 0;
  QString kind;
  QString id;
  QJsonObject patch;
};

// An edit the client asked the MC for, not yet answered.
struct Request {
  int token = 0;
  QString block;
  QString field;
  QVariant value;
};

// An edit shown over the stream's value, and when the MC's answer wrote it.
struct Pend {
  int token = 0;
  QVariant value;
  QString answeredAt;
};

struct Model {
  // The MC's: the Space, this log's events, and the seq each entity last changed at.
  Entities mc;
  QList<Event> log;
  QMap<QString, int> changedAt;
  int seq = 0;
  int handle = 1;
  int clock = 0;
  // The client's: its copy, as of which offset of which log.
  Entities held;
  qint64 offset = -1;
  int heldHandle = 0;
  // Its subscription stands and is caught up: changes reach it.
  bool following = false;
  // What its stream says: caught up once, since it last subscribed.
  bool streamLive = false;
  bool unreachable = false;
  QJsonObject lastEvents;
  QString selected;
  QString deck;
  // The presenter: on which slide, and where it last was in the deck.
  bool presenting = false;
  QString slideId;
  int slideIndex = 0;
  // By "block\nfield".
  QMap<QString, Pend> pending;
  QList<Request> requests;
  int tokens = 0;
  // The MC writes only decks and slides, so a run stays with presenting.
  bool decksOnly = false;
};

bool trashed(const QJsonObject& page) { return !str(page, "trashedAt").isEmpty(); }

QString titleOf(const Entities& held, const QString& id) {
  const QString title = str(held.value(keyOf(kPage, id)), "title").trimmed();
  return title.isEmpty() ? QStringLiteral("Untitled") : title;
}

// Pages sorted as they were made.
bool madeBefore(const QJsonObject& a, const QJsonObject& b) {
  const int order = QString::compare(str(a, "createdAt"), str(b, "createdAt"));
  return order != 0 ? order < 0 : str(a, "id") < str(b, "id");
}

// The page tree: untrashed pages under their parent when the copy holds it, else
// at the top; depth first, each page's subpages as they were made. A page under
// a trashed one is not shown.
QList<QVariantMap> treeOf(const Entities& held) {
  const QMap<QString, QJsonObject> pages = ofKind(held, kPage);
  const auto placedUnder = [&](const QJsonObject& page) {
    const QString parent = str(page, "parentPageId");
    return pages.contains(parent) ? parent : QString();
  };
  const auto children = [&](const QString& parent) {
    QList<QJsonObject> under;
    for (const QJsonObject& page : pages) {
      if (!trashed(page) && placedUnder(page) == parent) under.append(page);
    }
    std::sort(under.begin(), under.end(), madeBefore);
    return under;
  };
  QList<QVariantMap> tree;
  const std::function<void(const QString&, int)> place = [&](const QString& parent, int depth) {
    for (const QJsonObject& page : children(parent)) {
      const QString id = str(page, "id");
      tree.append({{QStringLiteral("id"), id},
                   {QStringLiteral("title"), titleOf(held, id)},
                   {QStringLiteral("depth"), depth},
                   {QStringLiteral("parentPageId"), parent},
                   {QStringLiteral("hasChildren"), !children(id).isEmpty()},
                   {QStringLiteral("fromThread"), !str(page, "sourceThreadId").isEmpty()}});
      place(id, depth + 1);
    }
  };
  place(QString(), 0);
  return tree;
}

// Trashed pages, the latest first.
QList<QVariantMap> trashOf(const Entities& held) {
  QList<QJsonObject> pages;
  for (const QJsonObject& page : ofKind(held, kPage)) {
    if (trashed(page)) pages.append(page);
  }
  std::sort(pages.begin(), pages.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "trashedAt"), str(b, "trashedAt"));
    return order != 0 ? order > 0 : str(a, "id") > str(b, "id");
  });
  QList<QVariantMap> rows;
  for (const QJsonObject& page : pages) {
    const QString id = str(page, "id");
    rows.append({{QStringLiteral("id"), id}, {QStringLiteral("title"), titleOf(held, id)}, {QStringLiteral("trashedAt"), str(page, "trashedAt")}});
  }
  return rows;
}

bool byAgent(const QJsonObject& entity, const char* field) {
  return entity.value(QLatin1String(field)).toObject().value(QLatin1String("type")).toString() == QLatin1String("agent");
}

QList<QJsonObject> commentsOf(const Model& model) {
  QList<QJsonObject> comments;
  for (const QJsonObject& comment : ofKind(model.held, kComment)) {
    if (str(comment, "pageId") == model.selected) comments.append(comment);
  }
  return comments;
}

// The selected page's blocks by their order, each showing the user's edit of it.
QList<QVariantMap> blocksOf(const Model& model) {
  QList<QJsonObject> blocks;
  for (const QJsonObject& block : ofKind(model.held, kBlock)) {
    if (str(block, "pageId") == model.selected) blocks.append(block);
  }
  std::sort(blocks.begin(), blocks.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "order"), str(b, "order"));
    return order != 0 ? order < 0 : str(a, "id") < str(b, "id");
  });
  const QList<QJsonObject> comments = commentsOf(model);
  QList<QVariantMap> rows;
  for (const QJsonObject& block : blocks) {
    const QString id = str(block, "id");
    const auto shown = [&](const QString& field, const QVariant& value) {
      const auto it = model.pending.constFind(keyOf(id, field));
      return it == model.pending.cend() ? value : it->value;
    };
    int open = 0;
    for (const QJsonObject& comment : comments) {
      if (str(comment, "blockId") == id && str(comment, "resolvedAt").isEmpty()) ++open;
    }
    const QString linked = str(block, "linkedPageId");
    rows.append({{QStringLiteral("id"), id},
                 {QStringLiteral("kind"), str(block, "kind")},
                 {QStringLiteral("text"), shown(QStringLiteral("text"), str(block, "text"))},
                 {QStringLiteral("checked"), shown(QStringLiteral("checked"), block.value(QLatin1String("checked")).toBool()).toBool()},
                 {QStringLiteral("linkedPageId"), linked},
                 {QStringLiteral("linkedTitle"), linked.isEmpty() ? QString() : titleOf(model.held, linked)},
                 {QStringLiteral("byAgent"), byAgent(block, "createdBy")},
                 {QStringLiteral("openComments"), open},
                 {QStringLiteral("imageId"), QString()},
                 {QStringLiteral("imageState"), QString()},
                 {QStringLiteral("imageUrl"), QString()},
                 {QStringLiteral("imageWidth"), 0},
                 {QStringLiteral("imageHeight"), 0}});
  }
  return rows;
}

// The selected page's comments, open ones first, each as it was made.
QList<QVariantMap> commentRowsOf(const Model& model) {
  QList<QJsonObject> comments = commentsOf(model);
  std::sort(comments.begin(), comments.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const bool aResolved = !str(a, "resolvedAt").isEmpty();
    const bool bResolved = !str(b, "resolvedAt").isEmpty();
    if (aResolved != bResolved) return !aResolved;
    return madeBefore(a, b);
  });
  QSet<QString> onPage;
  for (const QVariantMap& row : blocksOf(model)) onPage.insert(row.value(QStringLiteral("id")).toString());
  QList<QVariantMap> rows;
  for (const QJsonObject& comment : comments) {
    const QString block = str(comment, "blockId");
    rows.append({{QStringLiteral("id"), str(comment, "id")},
                 {QStringLiteral("blockId"), block},
                 {QStringLiteral("blockText"), str(model.held.value(keyOf(kBlock, block)), "text")},
                 {QStringLiteral("blockGone"), !block.isEmpty() && !onPage.contains(block)},
                 {QStringLiteral("body"), str(comment, "body")},
                 {QStringLiteral("resolved"), !str(comment, "resolvedAt").isEmpty()},
                 {QStringLiteral("byAgent"), byAgent(comment, "author")},
                 {QStringLiteral("createdAt"), str(comment, "createdAt")}});
  }
  return rows;
}

// Whether a page and the pages above it are out of the trash.
bool untrashed(const Entities& held, const QJsonObject& page) {
  QSet<QString> seen;
  for (QJsonObject at = page; !at.isEmpty();) {
    if (trashed(at)) return false;
    const QString parent = str(at, "parentPageId");
    if (parent.isEmpty() || seen.contains(parent)) break;
    seen.insert(parent);
    at = held.value(keyOf(kPage, parent));
  }
  return true;
}

// What the page has published: one site at most, as the MC keeps it.
QVariantMap siteShownOf(const Model& model) {
  for (const QJsonObject& site : ofKind(model.held, kSite)) {
    if (str(site, "pageId") != model.selected) continue;
    return {{QStringLiteral("url"), str(site, "url")},
            {QStringLiteral("localOnly"), site.value(QLatin1String("localOnly")).toBool()},
            {QStringLiteral("behind"), site.value(QLatin1String("behind")).toBool()},
            {QStringLiteral("publishedAt"), str(site, "publishedAt")}};
  }
  return {};
}

QVariantMap pageOf(const Model& model) {
  const QJsonObject page = model.held.value(keyOf(kPage, model.selected));
  if (page.isEmpty()) return {};
  const QString thread = str(page, "sourceThreadId");
  return {{QStringLiteral("id"), model.selected},
          {QStringLiteral("title"), titleOf(model.held, model.selected)},
          {QStringLiteral("parentPageId"), str(page, "parentPageId")},
          {QStringLiteral("trashed"), !untrashed(model.held, page)},
          {QStringLiteral("sourceThreadId"), thread},
          {QStringLiteral("sourceThreadTitle"), thread.isEmpty() ? QString() : QStringLiteral("a thread")},
          {QStringLiteral("site"), siteShownOf(model)}};
}

QVariantMap agentOf(const Model& model) {
  const QJsonObject agent = model.held.value(keyOf(kAgent, model.selected));
  if (agent.isEmpty()) return {};
  return {{QStringLiteral("status"), str(agent, "status")},
          {QStringLiteral("request"), str(agent, "request")},
          {QStringLiteral("threadId"), str(agent, "threadId")},
          {QStringLiteral("threadTitle"), QStringLiteral("a thread")},
          {QStringLiteral("edited"), agent.value(QLatin1String("edited")).toBool()},
          {QStringLiteral("error"), str(agent, "error")}};
}

// The decks out of the trash as they were made.
QList<QVariantMap> decksOf(const Entities& held) {
  QList<QJsonObject> decks;
  for (const QJsonObject& deck : ofKind(held, kDeck)) {
    if (!trashed(deck)) decks.append(deck);
  }
  std::sort(decks.begin(), decks.end(), madeBefore);
  QList<QVariantMap> rows;
  for (const QJsonObject& deck : decks) rows.append({{QStringLiteral("id"), str(deck, "id")}, {QStringLiteral("title"), str(deck, "title")}});
  return rows;
}

// Trashed decks, the latest first.
QList<QVariantMap> deckTrashOf(const Entities& held) {
  QList<QJsonObject> decks;
  for (const QJsonObject& deck : ofKind(held, kDeck)) {
    if (trashed(deck)) decks.append(deck);
  }
  std::sort(decks.begin(), decks.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "trashedAt"), str(b, "trashedAt"));
    return order != 0 ? order > 0 : str(a, "id") > str(b, "id");
  });
  QList<QVariantMap> rows;
  for (const QJsonObject& deck : decks) {
    rows.append({{QStringLiteral("id"), str(deck, "id")}, {QStringLiteral("title"), str(deck, "title")}, {QStringLiteral("trashedAt"), str(deck, "trashedAt")}});
  }
  return rows;
}

// The open deck's slides by their order.
QList<QVariantMap> slidesOf(const Model& model) {
  QList<QJsonObject> slides;
  for (const QJsonObject& slide : ofKind(model.held, kSlide)) {
    if (str(slide, "deckId") == model.deck) slides.append(slide);
  }
  std::sort(slides.begin(), slides.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "order"), str(b, "order"));
    return order != 0 ? order < 0 : str(a, "id") < str(b, "id");
  });
  QList<QVariantMap> rows;
  for (const QJsonObject& slide : slides) {
    rows.append({{QStringLiteral("id"), str(slide, "id")}, {QStringLiteral("title"), str(slide, "title")}, {QStringLiteral("body"), str(slide, "body")}});
  }
  return rows;
}

QVariantMap deckOf(const Model& model) {
  const QJsonObject deck = model.held.value(keyOf(kDeck, model.deck));
  if (deck.isEmpty()) return {};
  return {{QStringLiteral("id"), model.deck}, {QStringLiteral("title"), str(deck, "title")}, {QStringLiteral("trashed"), trashed(deck)}};
}

// What follows a change to the copy or to the user's edits: a selected page the
// copy no longer holds gives way to the first of the tree, an open deck it no
// longer holds closes and so does the presenter when its deck went, is trashed
// or has no slides left, and an edit is dropped once its block went or the copy
// holds what the MC's answer wrote, or later.
void reconcile(Model& model) {
  for (auto it = model.pending.begin(); it != model.pending.end();) {
    const QJsonObject block = model.held.value(keyOf(kBlock, it.key().section(QLatin1Char('\n'), 0, 0)));
    const bool caughtUp = !it->answeredAt.isEmpty() && str(block, "updatedAt") >= it->answeredAt;
    it = block.isEmpty() || caughtUp ? model.pending.erase(it) : std::next(it);
  }
  if (model.offset >= 0 && !model.held.contains(keyOf(kPage, model.selected))) {
    const QList<QVariantMap> tree = treeOf(model.held);
    model.selected = tree.isEmpty() ? QString() : tree.first().value(QStringLiteral("id")).toString();
  }
  if (model.offset >= 0 && !model.held.contains(keyOf(kDeck, model.deck))) model.deck.clear();
  if (!model.presenting) return;
  const QJsonObject deck = model.held.value(keyOf(kDeck, model.deck));
  const QList<QVariantMap> slides = slidesOf(model);
  if (deck.isEmpty() || trashed(deck) || slides.isEmpty()) {
    model.presenting = false;
    return;
  }
  const auto at = std::find_if(slides.cbegin(), slides.cend(), [&](const QVariantMap& row) { return row.value(QStringLiteral("id")).toString() == model.slideId; });
  model.slideIndex = at != slides.cend() ? int(at - slides.cbegin()) : std::min(model.slideIndex, int(slides.size()) - 1);
  model.slideId = slides.at(model.slideIndex).value(QStringLiteral("id")).toString();
}

QString handleOf(int handle) { return QStringLiteral("log-%1").arg(handle); }

QJsonArray json(const Event& event) {
  return {event.seq, event.kind, event.id, event.patch, stamp(event.seq)};
}

QJsonObject eventsFrame(const QList<Event>& events, qint64 offset) {
  QJsonArray all;
  for (const Event& event : events) all.append(json(event));
  return {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), offset}, {QStringLiteral("events"), all}};
}

// The MC writes `after` (nullopt deletes) as `patch`; a client following the
// stream is sent it.
void write(Model& model, const QString& kind, const QString& id, const std::optional<QJsonObject>& after, const QJsonObject& patch) {
  const QString key = keyOf(kind, id);
  const int seq = ++model.seq;
  if (after) {
    model.mc.insert(key, *after);
  } else {
    model.mc.remove(key);
  }
  model.log.append({seq, kind, id, patch});
  model.changedAt.insert(key, seq);
  if (model.following) {
    model.held = model.mc;
    model.offset = seq;
    model.lastEvents = eventsFrame({model.log.last()}, seq);
  } else {
    model.lastEvents = {};
  }
}

// --- The client -------------------------------------------------------------------

int modelTestFailures = 0;
QtMessageHandler previousHandler = nullptr;

void countModelTestFailures(QtMsgType type, const QMessageLogContext& context, const QString& message) {
  if (context.category && qstrcmp(context.category, "qt.modeltest") == 0 && type >= QtWarningMsg) ++modelTestFailures;
  previousHandler(type, context, message);
}

struct Sut {
  SpacePages pages;
  std::vector<std::unique_ptr<QAbstractItemModelTester>> testers;
  // Every row dataChanged named since the step began, as "list\nid".
  QSet<QString> redrawn;
  // Each row when the step began, by "list\nid".
  QHash<QString, QVariantMap> before;

  Sut() {
    for (const auto& [name, rows] : lists()) {
      testers.push_back(std::make_unique<QAbstractItemModelTester>(rows, QAbstractItemModelTester::FailureReportingMode::Warning));
      QObject::connect(rows, &QAbstractItemModel::dataChanged, rows, [this, name, rows](const QModelIndex& top, const QModelIndex& bottom) {
        for (int row = top.row(); row <= bottom.row(); ++row) {
          redrawn.insert(name + QLatin1Char('\n') + rows->get(row).value(QStringLiteral("id")).toString());
        }
      });
    }
    // The index holds the one Space, which is selected as the first there is.
    const QJsonObject space{{QStringLiteral("id"), kSpace}, {QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), stamp(0)}};
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                        {QStringLiteral("rows"), QJsonArray{QJsonArray{QStringLiteral("space"), kSpace, space}}},
                        {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
  }

  ~Sut() { testers.clear(); }

  QList<std::pair<QString, SpaceRows*>> lists() const {
    return {{QStringLiteral("spaces"), pages.spaces()}, {QStringLiteral("pages"), pages.pages()}, {QStringLiteral("trash"), pages.trash()},
            {QStringLiteral("blocks"), pages.blocks()}, {QStringLiteral("comments"), pages.comments()},
            {QStringLiteral("decks"), pages.decks()}, {QStringLiteral("deckTrash"), pages.deckTrash()}, {QStringLiteral("slides"), pages.slides()}};
  }

  QHash<QString, QVariantMap> rows() const {
    QHash<QString, QVariantMap> all;
    for (const auto& [name, rows] : lists()) {
      for (const QVariantMap& row : rows->rows()) all.insert(name + QLatin1Char('\n') + row.value(QStringLiteral("id")).toString(), row);
    }
    return all;
  }

  void begin() {
    redrawn.clear();
    before = rows();
    modelTestFailures = 0;
  }

  void send(const QJsonObject& frame) { pages.receiveSpace(frame); }

  void check(const Model& model) {
    RC_ASSERT(pages.spaceId() == kSpace);
    for (const QString& kind : {kPage, kBlock, kComment, kAgent, kDeck, kSlide, kSite}) {
      QMap<QString, QJsonObject> got;
      for (auto it = pages.space().of(kind).cbegin(); it != pages.space().of(kind).cend(); ++it) got.insert(it.key(), *it);
      RC_ASSERT(got == ofKind(model.held, kind));
    }
    RC_ASSERT(pages.space().offset() == model.offset);
    RC_ASSERT(pages.pageId() == model.selected);
    RC_ASSERT(pages.pages()->rows() == treeOf(model.held));
    RC_ASSERT(pages.trash()->rows() == trashOf(model.held));
    RC_ASSERT(pages.blocks()->rows() == blocksOf(model));
    RC_ASSERT(pages.comments()->rows() == commentRowsOf(model));
    RC_ASSERT(pages.page() == pageOf(model));
    RC_ASSERT(pages.agent() == agentOf(model));
    RC_ASSERT(pages.deckId() == model.deck);
    RC_ASSERT(pages.decks()->rows() == decksOf(model.held));
    RC_ASSERT(pages.deckTrash()->rows() == deckTrashOf(model.held));
    const QList<QVariantMap> slides = slidesOf(model);
    RC_ASSERT(pages.slides()->rows() == slides);
    RC_ASSERT(pages.deck() == deckOf(model));
    RC_ASSERT(pages.presenting() == model.presenting);
    RC_ASSERT(pages.slideNumber() == (model.presenting ? model.slideIndex + 1 : 0));
    RC_ASSERT(pages.slideCount() == (model.presenting ? int(slides.size()) : 0));
    RC_ASSERT(pages.slide() == (model.presenting ? slides.value(model.slideIndex) : QVariantMap()));
    const QString status = model.unreachable ? QStringLiteral("unreachable") : model.streamLive ? QStringLiteral("live") : QStringLiteral("loading");
    RC_ASSERT(pages.status() == status);
    for (auto it = model.pending.cbegin(); it != model.pending.cend(); ++it) {
      RC_ASSERT(pages.pending(it.key().section(QLatin1Char('\n'), 0, 0), it.key().section(QLatin1Char('\n'), 1)));
    }
    RC_ASSERT(modelTestFailures == 0);
    const QHash<QString, QVariantMap> now = rows();
    for (const QString& row : std::as_const(redrawn)) {
      RC_ASSERT(before.contains(row));
      RC_ASSERT(before.value(row) != now.value(row));
    }
    for (auto it = now.cbegin(); it != now.cend(); ++it) {
      if (before.contains(it.key()) && before.value(it.key()) != *it) RC_ASSERT(redrawn.contains(it.key()));
    }
  }
};

using Command = rc::state::Command<Model, Sut>;

// --- The MC's writes --------------------------------------------------------------

QStringList idsOf(const Model& model, const QString& kind) { return ofKind(model.mc, kind).keys(); }

QString unused(const Model& model, const QString& kind, int most) {
  for (int n = 1; n <= most; ++n) {
    const QString id = QStringLiteral("%1-%2").arg(kind).arg(n);
    if (!model.mc.contains(keyOf(kind, id))) return id;
  }
  return {};
}

// The pages at and under `id` in the MC.
QSet<QString> subtree(const Model& model, const QString& id) {
  QSet<QString> under{id};
  for (bool grew = true; grew;) {
    grew = false;
    for (const QJsonObject& page : ofKind(model.mc, kPage)) {
      if (under.contains(str(page, "parentPageId")) && !under.contains(str(page, "id"))) {
        under.insert(str(page, "id"));
        grew = true;
      }
    }
  }
  return under;
}

// A change another client (or an agent) makes through the MC, which goes to
// this client's copy if it follows the stream (twice, when the frame comes again).
struct Write : Command {
  QString op;
  QString id;
  // What the change writes: a title, text, order, parent, kind, author.
  QString value;
  QString other;
  bool flag = false;
  bool twice = false;

  explicit Write(const Model& model) {
    const QStringList pages = idsOf(model, kPage);
    const QStringList blocks = idsOf(model, kBlock);
    const QStringList comments = idsOf(model, kComment);
    const QStringList decks = idsOf(model, kDeck);
    const QStringList slides = idsOf(model, kSlide);
    const QStringList sites = idsOf(model, kSite);
    std::vector<QString> ops;
    const auto offer = [&ops](int weight, const char* name) { ops.insert(ops.end(), weight, QString::fromLatin1(name)); };
    if (pages.size() < kMaxPages && !model.decksOnly) offer(3, "page.create");
    if (!pages.isEmpty()) {
      offer(2, "page.rename");
      offer(2, "page.move");
      offer(3, "page.trash");
      offer(1, "page.delete");
      if (blocks.size() < kMaxBlocks) offer(4, "block.create");
      offer(1, "pageAgent.create");
      offer(2, "pageAgent.status");
      offer(1, "pageAgent.delete");
    }
    if (!blocks.isEmpty()) {
      offer(2, "block.text");
      offer(3, "block.append");
      offer(1, "block.order");
      offer(2, "block.check");
      offer(1, "block.replace");
      offer(1, "block.delete");
      if (comments.size() < kMaxComments) offer(2, "comment.create");
    }
    if (!comments.isEmpty()) {
      offer(2, "comment.resolve");
      offer(1, "comment.delete");
    }
    if (decks.size() < kMaxDecks) offer(2, "deck.create");
    if (!decks.isEmpty()) {
      offer(1, "deck.rename");
      offer(2, "deck.trash");
      offer(1, "deck.delete");
      if (slides.size() < kMaxSlides) offer(4, "slide.create");
    }
    if (!slides.isEmpty()) {
      offer(2, "slide.update");
      offer(2, "slide.order");
      offer(2, "slide.delete");
    }
    if (!pages.isEmpty() && sites.size() < kMaxSites) offer(2, "site.create");
    if (!sites.isEmpty()) {
      offer(2, "site.behind");
      offer(1, "site.republish");
      offer(1, "site.delete");
    }
    op = *rc::gen::elementOf(ops);
    const QString kind = op.section(QLatin1Char('.'), 0, 0);
    const bool creates = op.endsWith(QLatin1String(".create"));
    id = kind == kAgent ? pick(pages) : creates ? unused(model, kind, kind == kPage ? kMaxPages : kind == kBlock ? kMaxBlocks : kind == kComment ? kMaxComments : kind == kDeck ? kMaxDecks : kind == kSite ? kMaxSites : kMaxSlides)
                 : pick(kind == kPage ? pages : kind == kBlock ? blocks : kind == kComment ? comments : kind == kDeck ? decks : kind == kSite ? sites : slides);
    if (op == QLatin1String("page.create")) {
      value = pick({QStringLiteral("Roadmap"), QStringLiteral("Q3"), QStringLiteral("  "), QString()});
      other = pick(pages + QStringList{QString()});
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("page.rename")) {
      value = pick({QStringLiteral("Plans"), QStringLiteral("Roadmap"), QString()});
    } else if (op == QLatin1String("page.move")) {
      other = pick(pages + QStringList{QString()});
    } else if (op == QLatin1String("block.create")) {
      value = pick({QStringLiteral("paragraph"), QStringLiteral("checklist"), QStringLiteral("heading"), QStringLiteral("link")});
      other = pick(pages);
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("block.text") || op == QLatin1String("block.replace")) {
      value = pick({QStringLiteral("One"), QStringLiteral("Two"), QString()});
    } else if (op == QLatin1String("block.append")) {
      value = pick({QStringLiteral(" more"), QStringLiteral("!")});
    } else if (op == QLatin1String("block.order")) {
      value = pick({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")});
    } else if (op == QLatin1String("pageAgent.status")) {
      value = pick({QStringLiteral("stopping"), QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("stopped")});
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("deck.create") || op == QLatin1String("deck.rename")) {
      value = pick({QStringLiteral("Pitch"), QStringLiteral("Review")});
    } else if (op == QLatin1String("slide.create")) {
      value = pick({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")});
      other = pick(decks);
    } else if (op == QLatin1String("slide.update")) {
      value = pick({QStringLiteral("One"), QStringLiteral("Two"), QString()});
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("slide.order")) {
      value = pick({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")});
    } else if (op == QLatin1String("page.trash") || op == QLatin1String("deck.trash")) {
      // How a restore unsets trashedAt: as null, or by leaving it out.
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("comment.create")) {
      other = pick(blocks);
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("site.create")) {
      other = pick(pages);
      flag = *rc::gen::arbitrary<bool>();
    }
    twice = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});
  }

  struct Made {
    QString kind;
    std::optional<QJsonObject> after;
    QJsonObject patch;
  };

  // The change as the MC makes it of what it holds now, or nullopt when it
  // cannot (what it names is gone, or a page would go under itself).
  std::optional<Made> made(const Model& model) const {
    const QString kind = op.section(QLatin1Char('.'), 0, 0);
    if (id.isEmpty()) return std::nullopt;
    const QJsonObject current = model.mc.value(keyOf(kind, id));
    const bool creates = op.endsWith(QLatin1String(".create"));
    if (creates != current.isEmpty()) return std::nullopt;
    const QString at = stamp(model.clock + 1);
    const auto set = [&](const QJsonObject& fields) -> std::optional<Made> {
      QJsonObject after = current;
      for (auto it = fields.begin(); it != fields.end(); ++it) after.insert(it.key(), it.value());
      return Made{kind, after, {{QStringLiteral("s"), fields}}};
    };
    const auto author = [](bool agent) { return QJsonObject{{QStringLiteral("type"), agent ? QStringLiteral("agent") : QStringLiteral("user")}}; };
    if (op == QLatin1String("page.create")) {
      if (!other.isEmpty() && !model.mc.contains(keyOf(kPage, other))) return std::nullopt;
      return set({{QStringLiteral("id"), id}, {QStringLiteral("title"), value}, {QStringLiteral("parentPageId"), nullable(other)},
                  {QStringLiteral("sourceThreadId"), nullable(flag ? QStringLiteral("thread-1") : QString())},
                  {QStringLiteral("createdAt"), at}, {QStringLiteral("trashedAt"), QJsonValue::Null}});
    }
    if (op == QLatin1String("page.rename")) return set({{QStringLiteral("title"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("page.move")) {
      if (!other.isEmpty() && (!model.mc.contains(keyOf(kPage, other)) || subtree(model, id).contains(other))) return std::nullopt;
      return set({{QStringLiteral("parentPageId"), nullable(other)}, {QStringLiteral("updatedAt"), at}});
    }
    if (op == QLatin1String("deck.create")) {
      return set({{QStringLiteral("id"), id}, {QStringLiteral("title"), value}, {QStringLiteral("createdAt"), at}, {QStringLiteral("trashedAt"), QJsonValue::Null}});
    }
    if (op == QLatin1String("deck.rename")) return set({{QStringLiteral("title"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("slide.create")) {
      if (!model.mc.contains(keyOf(kDeck, other))) return std::nullopt;
      return set({{QStringLiteral("id"), id}, {QStringLiteral("deckId"), other}, {QStringLiteral("title"), QStringLiteral("New")},
                  {QStringLiteral("body"), QString()}, {QStringLiteral("order"), value}, {QStringLiteral("updatedAt"), at}});
    }
    if (op == QLatin1String("slide.update")) return set({{flag ? QStringLiteral("body") : QStringLiteral("title"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("slide.order")) return set({{QStringLiteral("order"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("page.trash") || op == QLatin1String("deck.trash")) {
      if (!trashed(current)) return set({{QStringLiteral("trashedAt"), at}});
      if (!flag) return set({{QStringLiteral("trashedAt"), QJsonValue::Null}});
      QJsonObject after = current;
      after.remove(QStringLiteral("trashedAt"));
      return Made{kind, after, {{QStringLiteral("u"), QJsonArray{QStringLiteral("trashedAt")}}}};
    }
    if (op == QLatin1String("pageAgent.create")) {
      return set({{QStringLiteral("id"), id}, {QStringLiteral("pageId"), id}, {QStringLiteral("threadId"), QStringLiteral("thread-1")},
                  {QStringLiteral("request"), QStringLiteral("tidy")}, {QStringLiteral("status"), QStringLiteral("running")},
                  {QStringLiteral("edited"), false}, {QStringLiteral("error"), QJsonValue::Null}});
    }
    if (op == QLatin1String("pageAgent.status")) {
      return set({{QStringLiteral("status"), value}, {QStringLiteral("edited"), flag},
                  {QStringLiteral("error"), nullable(value == QLatin1String("failed") ? QStringLiteral("out of credits") : QString())}});
    }
    if (op.endsWith(QLatin1String(".delete"))) return Made{kind, std::nullopt, {{QStringLiteral("d"), true}}};
    if (op == QLatin1String("block.create")) {
      if (!model.mc.contains(keyOf(kPage, other))) return std::nullopt;
      QJsonObject block{{QStringLiteral("id"), id}, {QStringLiteral("pageId"), other}, {QStringLiteral("kind"), value},
                        {QStringLiteral("text"), QStringLiteral("New")}, {QStringLiteral("checked"), false},
                        {QStringLiteral("order"), QStringLiteral("b")}, {QStringLiteral("createdBy"), author(flag)},
                        {QStringLiteral("updatedAt"), at}};
      if (value == QLatin1String("link")) block.insert(QStringLiteral("linkedPageId"), other);
      return set(block);
    }
    if (op == QLatin1String("block.text")) return set({{QStringLiteral("text"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("block.append")) {
      QJsonObject after = current;
      after.insert(QStringLiteral("text"), str(current, "text") + value);
      after.insert(QStringLiteral("updatedAt"), at);
      return Made{kind, after, {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), value}}}, {QStringLiteral("s"), QJsonObject{{QStringLiteral("updatedAt"), at}}}}};
    }
    if (op == QLatin1String("block.order")) return set({{QStringLiteral("order"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("block.check")) {
      return set({{QStringLiteral("checked"), !current.value(QLatin1String("checked")).toBool()}, {QStringLiteral("updatedAt"), at}});
    }
    if (op == QLatin1String("block.replace")) {
      // The whole block written anew, as a replay sends one: what it leaves out goes.
      QJsonObject after{{QStringLiteral("id"), id}, {QStringLiteral("pageId"), current.value(QLatin1String("pageId"))},
                        {QStringLiteral("kind"), current.value(QLatin1String("kind"))}, {QStringLiteral("text"), value},
                        {QStringLiteral("order"), current.value(QLatin1String("order"))}, {QStringLiteral("updatedAt"), at}};
      return Made{kind, after, {{QStringLiteral("d"), true}, {QStringLiteral("s"), after}}};
    }
    if (op == QLatin1String("comment.create")) {
      const QJsonObject block = model.mc.value(keyOf(kBlock, other));
      if (block.isEmpty()) return std::nullopt;
      return set({{QStringLiteral("id"), id}, {QStringLiteral("pageId"), block.value(QLatin1String("pageId"))},
                  {QStringLiteral("blockId"), other}, {QStringLiteral("body"), QStringLiteral("Which week?")},
                  {QStringLiteral("resolvedAt"), QJsonValue::Null}, {QStringLiteral("author"), author(flag)},
                  {QStringLiteral("createdAt"), at}});
    }
    if (op == QLatin1String("site.create")) {
      if (!model.mc.contains(keyOf(kPage, other))) return std::nullopt;
      for (const QJsonObject& site : ofKind(model.mc, kSite)) {
        if (str(site, "pageId") == other) return std::nullopt;
      }
      return set({{QStringLiteral("id"), id}, {QStringLiteral("pageId"), other}, {QStringLiteral("url"), QStringLiteral("http://mc/sites/") + id},
                  {QStringLiteral("localOnly"), flag}, {QStringLiteral("behind"), false}, {QStringLiteral("publishedAt"), at}});
    }
    if (op == QLatin1String("site.behind")) return set({{QStringLiteral("behind"), !current.value(QLatin1String("behind")).toBool()}});
    if (op == QLatin1String("site.republish")) return set({{QStringLiteral("behind"), false}, {QStringLiteral("publishedAt"), at}});
    // comment.resolve: resolves an open one, reopens a resolved one.
    return set({{QStringLiteral("resolvedAt"), str(current, "resolvedAt").isEmpty() ? QJsonValue(at) : QJsonValue(QJsonValue::Null)}});
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(made(model).has_value()); }

  void apply(Model& model) const override {
    const Made change = *made(model);
    ++model.clock;
    write(model, change.kind, id, change.after, change.patch);
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    if (model.following) {
      sut.send(next.lastEvents);
      if (twice) sut.send(next.lastEvents);
    }
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Write(" << op.toStdString() << " " << id.toStdString() << " " << value.toStdString() << " " << other.toStdString()
       << (flag ? " flag" : "") << (twice ? " twice" : "") << ")";
  }
};

// --- Following the stream ---------------------------------------------------------

// The client subscribes and the MC answers: a snapshot in `parts` when the copy
// is new or of another log; else what changed since its offset, one whole entity
// each in `parts` frames when `whole` (only the last moving the offset), or the
// log's events in one (after one the copy holds, when `again`); then `live`.
// Cut, the answer stops before `live` and the connection drops.
struct Subscribe : Command {
  int parts = 1;
  bool whole = false;
  bool again = false;
  // Frames delivered before the cut, or -1.
  int cut = -1;

  explicit Subscribe(const Model&) {
    parts = *rc::gen::inRange(1, 4);
    whole = *rc::gen::arbitrary<bool>();
    again = *rc::gen::arbitrary<bool>();
    cut = *rc::gen::weightedElement<int>({{6, -1}, {1, 0}, {1, 1}, {1, 2}});
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.following); }

  QList<QJsonObject> frames(const Model& model) const {
    QList<QJsonObject> frames;
    const QString handle = handleOf(model.handle);
    if (model.offset < 0 || model.heldHandle != model.handle) {
      QJsonArray rows;
      for (auto it = model.mc.cbegin(); it != model.mc.cend(); ++it) {
        rows.append(QJsonArray{it.key().section(QLatin1Char('\n'), 0, 0), it.key().section(QLatin1Char('\n'), 1), *it});
      }
      const int count = int(std::max<qsizetype>(1, std::min<qsizetype>(parts, rows.size())));
      const int size = int((rows.size() + count - 1) / count);
      for (int part = 0; part < count; ++part) {
        QJsonArray chunk;
        for (int i = part * size; i < std::min<int>(int(rows.size()), (part + 1) * size); ++i) chunk.append(rows.at(i));
        frames.append({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), model.seq}, {QStringLiteral("part"), part},
                       {QStringLiteral("rows"), chunk}, {QStringLiteral("done"), part == count - 1}, {QStringLiteral("handle"), handle}});
      }
    } else if (whole || parts > 1) {
      QList<Event> changed;
      for (auto it = model.changedAt.cbegin(); it != model.changedAt.cend(); ++it) {
        if (*it <= model.offset) continue;
        const QString kind = it.key().section(QLatin1Char('\n'), 0, 0);
        const QString id = it.key().section(QLatin1Char('\n'), 1);
        const auto entity = model.mc.constFind(it.key());
        changed.append({*it, kind, id,
                        entity == model.mc.cend() ? QJsonObject{{QStringLiteral("d"), true}}
                                                  : QJsonObject{{QStringLiteral("d"), true}, {QStringLiteral("s"), *entity}}});
      }
      std::sort(changed.begin(), changed.end(), [](const Event& a, const Event& b) { return a.seq < b.seq; });
      const int count = int(std::min<qsizetype>(parts, changed.size()));
      for (int part = 0; part < count; ++part) {
        const qsizetype from = changed.size() * part / count;
        const qsizetype to = changed.size() * (part + 1) / count;
        const QList<Event> chunk = changed.mid(from, to - from);
        frames.append(eventsFrame(chunk, part == count - 1 ? chunk.last().seq : model.offset));
      }
    } else {
      QList<Event> missed;
      const Event* held = nullptr;
      for (const Event& event : model.log) {
        if (event.seq > model.offset) {
          missed.append(event);
        } else {
          held = &event;
        }
      }
      if (!missed.isEmpty()) {
        if (again && held) missed.prepend(*held);
        frames.append(eventsFrame(missed, missed.last().seq));
      }
    }
    frames.append({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), model.seq}, {QStringLiteral("handle"), handle}});
    return frames;
  }

  int delivered(const QList<QJsonObject>& frames) const {
    return cut < 0 ? int(frames.size()) : std::min<int>(cut, int(frames.size()) - 1);
  }

  void apply(Model& model) const override {
    const QList<QJsonObject> sent = frames(model);
    const int count = delivered(sent);
    model.streamLive = false;
    model.lastEvents = {};
    // Caught up once the snapshot's last part, or the last events frame, landed.
    if (count >= sent.size() - 1) {
      model.held = model.mc;
      model.offset = model.seq;
      model.heldHandle = model.handle;
    }
    if (cut < 0) {
      model.following = true;
      model.streamLive = true;
      model.unreachable = false;
    } else {
      model.unreachable = true;
    }
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    const QJsonObject sub = sut.pages.space().subscribing();
    if (model.offset < 0) {
      RC_ASSERT(sub.value(QLatin1String("offset")).isNull());
      RC_ASSERT(!sub.contains(QLatin1String("handle")));
    } else {
      RC_ASSERT(qint64(sub.value(QLatin1String("offset")).toDouble()) == model.offset);
      RC_ASSERT(sub.value(QLatin1String("handle")).toString() == handleOf(model.heldHandle));
    }
    const QList<QJsonObject> sent = frames(model);
    for (int i = 0; i < delivered(sent); ++i) sut.send(sent.at(i));
    if (cut >= 0) sut.pages.setUnreachable(true);
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Subscribe(parts=" << parts << (whole ? " whole" : "") << (again ? " again" : "") << " cut=" << cut << ")";
  }
};

// The connection drops: the MC cannot be reached until the client subscribes again.
struct Drop : Command {
  explicit Drop(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following || !model.unreachable); }
  void apply(Model& model) const override {
    model.following = false;
    model.unreachable = true;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.setUnreachable(true);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

// The stream's server stopped: `resync` ends the subscription, and the client
// subscribes again from what it holds.
struct Resync : Command {
  explicit Resync(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following); }
  void apply(Model& model) const override {
    model.following = false;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.send({{QStringLiteral("t"), QStringLiteral("resync")}});
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Resync"; }
};

// The last events frame comes again (a reconnect sent it twice).
struct Duplicate : Command {
  explicit Duplicate(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following && !model.lastEvents.isEmpty()); }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    sut.begin();
    sut.send(model.lastEvents);
    sut.check(model);
  }
  void show(std::ostream& os) const override { os << "Duplicate"; }
};

// The MC restarts on another log, its seq starting again (perhaps below the
// client's offset); the Space is what it was.
struct NewLog : Command {
  int seq = 0;
  explicit NewLog(const Model&) { seq = *rc::gen::inRange(0, 3); }
  void apply(Model& model) const override {
    ++model.handle;
    model.seq = seq;
    model.log.clear();
    model.changedAt.clear();
    model.following = false;
    model.unreachable = true;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.setUnreachable(true);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "NewLog(seq=" << seq << ")"; }
};

// --- The user ---------------------------------------------------------------------

// The user opens a page; one the copy does not hold is not selected.
struct SelectPage : Command {
  QString id;
  explicit SelectPage(const Model&) {
    id = QStringLiteral("page-%1").arg(*rc::gen::inRange(1, kMaxPages + 1));
  }
  void apply(Model& model) const override {
    if (model.held.contains(keyOf(kPage, id))) {
      model.selected = id;
      model.deck.clear();
      model.presenting = false;
    }
    reconcile(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.selectPage(id);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "SelectPage(" << id.toStdString() << ")"; }
};

// The user opens a deck; one the copy does not hold is not opened. The deck
// already open stays as it is.
struct SelectDeck : Command {
  QString id;
  explicit SelectDeck(const Model&) { id = QStringLiteral("deck-%1").arg(*rc::gen::inRange(1, kMaxDecks + 1)); }
  void apply(Model& model) const override {
    if (model.held.contains(keyOf(kDeck, id)) && model.deck != id) {
      model.deck = id;
      model.presenting = false;
    }
    reconcile(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.selectDeck(id);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "SelectDeck(" << id.toStdString() << ")"; }
};

// The user presents a deck, from its first slide. One that is gone or trashed is
// refused and stays closed; one with no slides opens but does not present.
struct Present : Command {
  QString id;
  explicit Present(const Model&) { id = QStringLiteral("deck-%1").arg(*rc::gen::inRange(1, kMaxDecks + 1)); }
  void apply(Model& model) const override {
    const QJsonObject deck = model.held.value(keyOf(kDeck, id));
    if (deck.isEmpty() || trashed(deck)) return;
    if (model.deck != id) {
      model.deck = id;
      model.presenting = false;
    }
    const QList<QVariantMap> slides = slidesOf(model);
    if (slides.isEmpty()) return;
    model.presenting = true;
    model.slideIndex = 0;
    model.slideId = slides.first().value(QStringLiteral("id")).toString();
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const QJsonObject deck = model.held.value(keyOf(kDeck, id));
    const bool opens = !deck.isEmpty() && !trashed(deck) && !slidesOf(next).isEmpty();
    sut.begin();
    RC_ASSERT(sut.pages.present(id) == opens);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Present(" << id.toStdString() << ")"; }
};

// The user steps through the slides, which stops at either end.
struct Step : Command {
  int by = 1;
  explicit Step(const Model&) { by = *rc::gen::element(1, -1, 1, 2, -2); }
  void apply(Model& model) const override {
    if (!model.presenting) return;
    const QList<QVariantMap> slides = slidesOf(model);
    model.slideIndex = std::clamp(model.slideIndex + by, 0, int(slides.size()) - 1);
    model.slideId = slides.at(model.slideIndex).value(QStringLiteral("id")).toString();
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.step(by);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Step(" << by << ")"; }
};

struct Leave : Command {
  void apply(Model& model) const override { model.presenting = false; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.leave();
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

// The user writes a block's text or ticks it, and the client asks the MC for it.
struct Edit : Command {
  QString block;
  QString field;
  QVariant value;

  explicit Edit(const Model& model) {
    const QStringList blocks = ofKind(model.held, kBlock).keys();
    block = blocks.isEmpty() ? QStringLiteral("block-1") : pick(blocks);
    field = *rc::gen::arbitrary<bool>() ? QStringLiteral("text") : QStringLiteral("checked");
    value = field == QLatin1String("text") ? QVariant(pick({QStringLiteral("Mine"), QStringLiteral("One"), QString()}))
                                           : QVariant(*rc::gen::arbitrary<bool>());
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(model.held.contains(keyOf(kBlock, block))); }

  void apply(Model& model) const override {
    const int token = ++model.tokens;
    model.pending.insert(keyOf(block, field), {token, value, {}});
    model.requests.append({token, block, field, value});
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    RC_ASSERT(sut.pages.pend(block, field, value) == next.tokens);
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Edit(" << block.toStdString() << " " << field.toStdString() << "=" << QJsonValue::fromVariant(value).toVariant().toString().toStdString() << ")";
  }
};

// The MC answers an edit: it writes it (its event reaching a following client
// before or after the answer), or refuses it, as it does one whose block went.
// An edit the user made again since is answered too, and changes nothing shown.
struct Answer : Command {
  int token = 0;
  bool accept = true;
  bool eventFirst = true;

  explicit Answer(const Model& model) {
    std::vector<int> tokens;
    for (const Request& request : model.requests) tokens.push_back(request.token);
    token = tokens.empty() ? 0 : *rc::gen::elementOf(tokens);
    accept = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
    eventFirst = *rc::gen::arbitrary<bool>();
  }

  std::optional<Request> request(const Model& model) const {
    for (const Request& request : model.requests) {
      if (request.token == token) return request;
    }
    return std::nullopt;
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(request(model).has_value()); }

  bool written(const Model& model) const { return accept && model.mc.contains(keyOf(kBlock, request(model)->block)); }

  // The MC writes the edit.
  void writeIt(Model& model, const Request& request) const {
    const QString at = stamp(++model.clock);
    QJsonObject after = model.mc.value(keyOf(kBlock, request.block));
    const QJsonObject fields{{request.field, QJsonValue::fromVariant(request.value)}, {QStringLiteral("updatedAt"), at}};
    for (auto it = fields.begin(); it != fields.end(); ++it) after.insert(it.key(), it.value());
    write(model, kBlock, request.block, after, {{QStringLiteral("s"), fields}});
    reconcile(model);
  }

  // The answer reaches the client: the block the MC wrote, or nullopt.
  void settle(Model& model, const Request& request, const std::optional<QJsonObject>& block) const {
    model.requests.removeIf([this](const Request& at) { return at.token == token; });
    const auto it = model.pending.find(keyOf(request.block, request.field));
    if (it != model.pending.end() && it->token == token) {
      if (block) {
        it->answeredAt = str(*block, "updatedAt");
      } else {
        model.pending.erase(it);
      }
    }
    reconcile(model);
  }

  void apply(Model& model) const override {
    const Request asked = *request(model);
    if (!written(model)) {
      settle(model, asked, std::nullopt);
      return;
    }
    writeIt(model, asked);
    settle(model, asked, model.mc.value(keyOf(kBlock, asked.block)));
  }

  void run(const Model& model, Sut& sut) const override {
    const Request asked = *request(model);
    if (!written(model)) {
      Model next = model;
      apply(next);
      sut.begin();
      sut.pages.settle(token, std::nullopt);
      sut.check(next);
      return;
    }
    Model wrote = model;
    writeIt(wrote, asked);
    const QJsonObject block = wrote.mc.value(keyOf(kBlock, asked.block));
    const auto deliver = [&](Model& at) {
      sut.begin();
      if (model.following) sut.send(wrote.lastEvents);
      sut.check(at);
    };
    const auto answer = [&](Model& at) {
      settle(at, asked, block);
      sut.begin();
      sut.pages.settle(token, block);
      sut.check(at);
    };
    if (eventFirst) {
      deliver(wrote);
      answer(wrote);
    } else {
      // Answered first: the edit shows until the stream holds what it wrote.
      Model answered = model;
      settle(answered, asked, block);
      sut.begin();
      sut.pages.settle(token, block);
      sut.check(answered);
      Model next = model;
      apply(next);
      sut.begin();
      if (model.following) sut.send(wrote.lastEvents);
      sut.check(next);
    }
  }

  void show(std::ostream& os) const override {
    os << "Answer(" << token << (accept ? " accept" : " refuse") << (eventFirst ? " event-first" : " answer-first") << ")";
  }
};

// The client following a deck of four slides, which it presents.
void presentFourSlides(Model& model, Sut& sut) {
  const QString at = stamp(1);
  QJsonArray rows;
  const auto hold = [&](const QString& kind, const QString& id, const QJsonObject& entity) {
    model.mc.insert(keyOf(kind, id), entity);
    model.changedAt.insert(keyOf(kind, id), 1);
    rows.append(QJsonArray{kind, id, entity});
  };
  hold(kDeck, QStringLiteral("deck-1"), {{QStringLiteral("id"), QStringLiteral("deck-1")}, {QStringLiteral("title"), QStringLiteral("Pitch")}, {QStringLiteral("createdAt"), at}, {QStringLiteral("trashedAt"), QJsonValue::Null}});
  const QStringList orders{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"), QStringLiteral("d")};
  for (qsizetype n = 0; n < orders.size(); ++n) {
    const QString id = QStringLiteral("slide-%1").arg(n + 1);
    hold(kSlide, id, {{QStringLiteral("id"), id}, {QStringLiteral("deckId"), QStringLiteral("deck-1")}, {QStringLiteral("title"), id}, {QStringLiteral("body"), QString()}, {QStringLiteral("order"), orders.at(n)}, {QStringLiteral("updatedAt"), at}});
  }
  model.decksOnly = true;
  model.held = model.mc;
  model.seq = model.clock = 1;
  model.offset = 1;
  model.heldHandle = model.handle;
  model.following = model.streamLive = true;
  model.deck = QStringLiteral("deck-1");
  model.presenting = true;
  model.slideId = QStringLiteral("slide-1");
  sut.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
            {QStringLiteral("done"), true}, {QStringLiteral("handle"), handleOf(model.handle)}});
  sut.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), handleOf(model.handle)}});
  RC_ASSERT(sut.pages.present(QStringLiteral("deck-1")));
  sut.begin();
  sut.check(model);
}

// --- Images -----------------------------------------------------------------------

struct ImagesModel {
  // Image ids, oldest first, and whether each is in the trash.
  QStringList order;
  QSet<QString> binned;
  int made = 0;
  // Each block's page and image, in the order placed; a block outlives its image.
  QList<std::pair<QString, QString>> blocks;
  QString open = QStringLiteral("page-1");
  bool browser = false;
  QSet<QString> inFlight;
  QMap<QString, QString> addresses;
  // The addresses whose end has come; shown until a new one arrives.
  QSet<QString> lapsed;
  // What the last step asked to have signed, sorted.
  QStringList asked;
  int seq = 1;
};

QString addressFor(const QString& id) { return QStringLiteral("http://mc/assets/space/%1?signature=x").arg(id); }

QSet<QString> onScreen(const ImagesModel& model) {
  QSet<QString> wanted;
  for (const auto& [page, image] : model.blocks) {
    if (page == model.open && model.order.contains(image) && !model.binned.contains(image)) wanted.insert(image);
  }
  if (model.browser) wanted.unite(QSet<QString>(model.order.cbegin(), model.order.cend()));
  return wanted;
}

// Whether an image on screen has an address whose end the client must watch for.
bool refreshDue(const ImagesModel& model) {
  const QSet<QString> wanted = onScreen(model);
  return std::any_of(wanted.cbegin(), wanted.cend(), [&model](const QString& id) {
    return model.addresses.contains(id) && !model.lapsed.contains(id) && !model.inFlight.contains(id);
  });
}

// Whatever rebuilds the rows asks for each image on screen with no good address.
void askForImages(ImagesModel& model) {
  const QSet<QString> wanted = onScreen(model);
  for (const QString& id : wanted) {
    if (model.inFlight.contains(id) || (model.addresses.contains(id) && !model.lapsed.contains(id))) continue;
    model.inFlight.insert(id);
    model.asked.append(id);
  }
  model.asked.sort();
}

struct ImagesSut {
  SpacePages pages;
  QStringList asked;
  int changes = 0;
  qint64 now = 1'800'000'000'000;

  ImagesSut() {
    pages.setClock([this] { return now; });
    QObject::connect(&pages, &SpacePages::changed, &pages, [this] { ++changes; });
    QObject::connect(&pages, &SpacePages::imagesNeeded, &pages, [this](const QStringList& ids) { asked.append(ids); });
    QJsonArray spaces;
    for (const QString& id : {kSpace, QStringLiteral("space-2")}) {
      spaces.append(QJsonArray{QStringLiteral("space"), id, QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("name"), id}, {QStringLiteral("createdAt"), stamp(0)}}});
    }
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                        {QStringLiteral("rows"), spaces}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    pages.selectSpace(kSpace);
    follow({});
  }

  // The Space as the MC holds it, from a snapshot; `rows` beside the two pages.
  void follow(QJsonArray rows) {
    for (const QString& id : {QStringLiteral("page-1"), QStringLiteral("page-2")}) {
      rows.append(QJsonArray{kPage, id, QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                                                     {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), stamp(0)}}});
    }
    pages.receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
                        {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    pages.receiveSpace({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    pages.selectPage(QStringLiteral("page-1"));
  }

  void event(int seq, const QString& kind, const QString& id, const QJsonObject& patch) {
    pages.receiveSpace({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq},
                        {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, stamp(seq)})}}});
  }

  void check(const ImagesModel& model) {
    QStringList asking = asked;
    asking.sort();
    RC_ASSERT(asking == model.asked);
    QList<QVariantMap> blocks;
    for (qsizetype i = 0; i < model.blocks.size(); ++i) {
      const auto& [page, image] = model.blocks.at(i);
      if (page != model.open) continue;
      const bool there = model.order.contains(image);
      const bool binned = model.binned.contains(image);
      blocks.append({{QStringLiteral("id"), QStringLiteral("block-%1").arg(i)},
                     {QStringLiteral("imageId"), image},
                     {QStringLiteral("imageState"), !there ? QStringLiteral("deleted") : binned ? QStringLiteral("trashed") : QStringLiteral("shown")},
                     {QStringLiteral("imageUrl"), there && !binned ? model.addresses.value(image) : QString()},
                     {QStringLiteral("imageWidth"), there ? 4 : 0},
                     {QStringLiteral("imageHeight"), there ? 3 : 0}});
    }
    QList<QVariantMap> shown;
    for (const QVariantMap& row : pages.blocks()->rows()) {
      QVariantMap some;
      for (const QString& role : {QStringLiteral("id"), QStringLiteral("imageId"), QStringLiteral("imageState"), QStringLiteral("imageUrl"), QStringLiteral("imageWidth"), QStringLiteral("imageHeight")}) {
        some.insert(role, row.value(role));
      }
      shown.append(some);
    }
    RC_ASSERT(shown == blocks);
    const auto listed = [](const SpaceRows* rows) {
      QStringList out;
      for (const QVariantMap& row : rows->rows()) out.append(row.value(QStringLiteral("id")).toString() + QLatin1Char(' ') + row.value(QStringLiteral("url")).toString());
      return out;
    };
    QStringList kept;
    QStringList binned;
    for (auto it = model.order.crbegin(); it != model.order.crend(); ++it) {
      (model.binned.contains(*it) ? binned : kept).append(*it + QLatin1Char(' ') + model.addresses.value(*it));
    }
    RC_ASSERT(listed(pages.images()) == kept);
    RC_ASSERT(listed(pages.imageTrash()) == binned);
    RC_ASSERT(refreshTimer()->isActive() == refreshDue(model));
  }

  QTimer* refreshTimer() { return pages.findChild<QTimer*>(QStringLiteral("spaceAddressRefresh")); }

  void answer(const QString& image) { pages.setImageAddress(image, addressFor(image), now + 3'600'000); }
};

using ImageCommand = rc::state::Command<ImagesModel, ImagesSut>;

// Runs one step: `apply` says what it should do, `act` does it to the client.
template <typename Self>
void imageStep(const Self& self, const ImagesModel& model, ImagesSut& sut) {
  ImagesModel next = model;
  self.apply(next);
  sut.asked.clear();
  self.act(next, sut);
  sut.check(next);
}

QJsonObject imageEntity(const QString& id, int seq) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("name"), id}, {QStringLiteral("mimeType"), QStringLiteral("image/png")}, {QStringLiteral("width"), 4}, {QStringLiteral("height"), 3},
          {QStringLiteral("prompt"), QJsonValue::Null}, {QStringLiteral("generatedBy"), QJsonValue::Null}, {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), stamp(seq)}};
}

QJsonObject blockEntity(qsizetype index, const QString& page, const QString& image, int seq) {
  return {{QStringLiteral("id"), QStringLiteral("block-%1").arg(index)}, {QStringLiteral("pageId"), page}, {QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("text"), image},
          {QStringLiteral("imageId"), image}, {QStringLiteral("order"), stamp(seq)}, {QStringLiteral("createdAt"), stamp(seq)}};
}

struct AddImage : ImageCommand {
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    ++model.seq;
    model.order.append(QStringLiteral("image-%1").arg(++model.made));
    askForImages(model);
  }
  void act(const ImagesModel& next, ImagesSut& sut) const {
    sut.event(next.seq, QStringLiteral("image"), next.order.last(), {{QStringLiteral("s"), imageEntity(next.order.last(), next.seq)}});
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "AddImage"; }
};

// Into the trash and out of it.
struct BinImage : ImageCommand {
  QString image;
  explicit BinImage(const ImagesModel& model) {
    RC_PRE(!model.order.isEmpty());
    image = pick(model.order);
  }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.order.contains(image)); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    ++model.seq;
    if (!model.binned.remove(image)) model.binned.insert(image);
    askForImages(model);
  }
  void act(const ImagesModel& next, ImagesSut& sut) const {
    sut.event(next.seq, QStringLiteral("image"), image, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("trashedAt"), next.binned.contains(image) ? QJsonValue(stamp(next.seq)) : QJsonValue(QJsonValue::Null)}}}});
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "BinImage(" << image.toStdString() << ")"; }
};

struct DeleteImage : ImageCommand {
  QString image;
  explicit DeleteImage(const ImagesModel& model) {
    RC_PRE(!model.binned.isEmpty());
    image = pick(model.binned.values());
  }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.binned.contains(image)); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    ++model.seq;
    model.order.removeAll(image);
    model.binned.remove(image);
    model.addresses.remove(image);
    model.lapsed.remove(image);
    askForImages(model);
  }
  void act(const ImagesModel& next, ImagesSut& sut) const { sut.event(next.seq, QStringLiteral("image"), image, {{QStringLiteral("d"), true}}); }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "DeleteImage(" << image.toStdString() << ")"; }
};

struct PlaceImage : ImageCommand {
  QString image;
  QString page;
  explicit PlaceImage(const ImagesModel& model) {
    QStringList live;
    for (const QString& id : model.order) {
      if (!model.binned.contains(id)) live.append(id);
    }
    RC_PRE(!live.isEmpty());
    image = pick(live);
    page = pick({QStringLiteral("page-1"), QStringLiteral("page-2")});
  }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.order.contains(image) && !model.binned.contains(image)); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    ++model.seq;
    model.blocks.append({page, image});
    askForImages(model);
  }
  void act(const ImagesModel& next, ImagesSut& sut) const {
    const qsizetype index = next.blocks.size() - 1;
    sut.event(next.seq, kBlock, QStringLiteral("block-%1").arg(index), {{QStringLiteral("s"), blockEntity(index, page, image, next.seq)}});
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "PlaceImage(" << image.toStdString() << " on " << page.toStdString() << ")"; }
};

struct OpenPage : ImageCommand {
  QString page;
  explicit OpenPage(const ImagesModel& model) { page = model.open == QLatin1String("page-1") ? QStringLiteral("page-2") : QStringLiteral("page-1"); }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.open != page); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    model.open = page;
    askForImages(model);
  }
  void act(const ImagesModel&, ImagesSut& sut) const { sut.pages.selectPage(page); }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "OpenPage(" << page.toStdString() << ")"; }
};

struct ToggleBrowser : ImageCommand {
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    model.browser = !model.browser;
    askForImages(model);
  }
  void act(const ImagesModel& next, ImagesSut& sut) const { sut.pages.setImagesShown(next.browser); }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "ToggleBrowser"; }
};

// The MC answers one request; a refusal leaves the image to be asked for when
// the rows next change.
struct AnswerAddress : ImageCommand {
  QString image;
  bool ok = *rc::gen::arbitrary<bool>();
  explicit AnswerAddress(const ImagesModel& model) {
    RC_PRE(!model.inFlight.isEmpty());
    image = pick(model.inFlight.values());
  }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.inFlight.contains(image)); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    model.inFlight.remove(image);
    if (!ok) return;
    model.lapsed.remove(image);
    if (model.order.contains(image)) model.addresses.insert(image, addressFor(image));
    askForImages(model);
  }
  void act(const ImagesModel&, ImagesSut& sut) const {
    if (ok) {
      sut.answer(image);
      QCoreApplication::processEvents();
    } else {
      sut.pages.imageAddressFailed(image);
    }
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "AnswerAddress(" << image.toStdString() << (ok ? " ok" : " refused") << ")"; }
};

// The MC answers everything on its way in one turn of the event loop: the rows
// are rebuilt once, however many there are.
struct AnswerAllAtOnce : ImageCommand {
  explicit AnswerAllAtOnce(const ImagesModel& model) { RC_PRE(model.inFlight.size() >= 2); }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(model.inFlight.size() >= 2); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    for (const QString& image : std::as_const(model.inFlight)) {
      model.lapsed.remove(image);
      if (model.order.contains(image)) model.addresses.insert(image, addressFor(image));
    }
    model.inFlight.clear();
    askForImages(model);
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override {
    ImagesModel next = model;
    apply(next);
    sut.asked.clear();
    sut.changes = 0;
    for (const QString& image : model.inFlight) sut.answer(image);
    QCoreApplication::processEvents();
    RC_ASSERT(sut.changes == 1);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "AnswerAllAtOnce"; }
};

// An hour or two pass with nothing changing in the Space. What is on screen is
// signed anew by the client's own timer; what is not waits until it is shown.
struct AddressesLapse : ImageCommand {
  explicit AddressesLapse(const ImagesModel& model) { RC_PRE(!model.addresses.isEmpty()); }
  void checkPreconditions(const ImagesModel& model) const override { RC_PRE(!model.addresses.isEmpty()); }
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    const bool fires = refreshDue(model);
    for (auto it = model.addresses.cbegin(); it != model.addresses.cend(); ++it) model.lapsed.insert(it.key());
    if (fires) askForImages(model);
  }
  void act(const ImagesModel&, ImagesSut& sut) const {
    sut.now += 2 * 3'600'000;
    if (sut.refreshTimer()->isActive()) {
      sut.refreshTimer()->start(0);
      QCoreApplication::processEvents();
    }
  }
  void run(const ImagesModel& model, ImagesSut& sut) const override { imageStep(*this, model, sut); }
  void show(std::ostream& os) const override { os << "AddressesLapse"; }
};

// The user goes to another Space and comes back: what was on its way answers
// while they are gone and is dropped, and everything on screen is asked for anew.
struct LeaveAndReturn : ImageCommand {
  void apply(ImagesModel& model) const override {
    model.asked.clear();
    model.inFlight.clear();
    model.addresses.clear();
    model.lapsed.clear();
    model.open = QStringLiteral("page-1");
    askForImages(model);
  }
  void act(const ImagesModel&, ImagesSut& sut) const {}
  void run(const ImagesModel& model, ImagesSut& sut) const override {
    ImagesModel next = model;
    apply(next);
    sut.pages.selectSpace(QStringLiteral("space-2"));
    for (const QString& id : model.inFlight) sut.pages.setImageAddress(id, addressFor(id), 4102444800000);
    RC_ASSERT(sut.pages.images()->rows().isEmpty());
    RC_ASSERT(sut.pages.blocks()->rows().isEmpty());
    sut.pages.selectSpace(kSpace);
    QJsonArray rows;
    for (const QString& id : next.order) {
      QJsonObject image = imageEntity(id, 1 + next.order.indexOf(id));
      if (next.binned.contains(id)) image.insert(QStringLiteral("trashedAt"), stamp(1));
      rows.append(QJsonArray{QStringLiteral("image"), id, image});
    }
    for (qsizetype i = 0; i < next.blocks.size(); ++i) {
      rows.append(QJsonArray{kBlock, QStringLiteral("block-%1").arg(i), blockEntity(i, next.blocks.at(i).first, next.blocks.at(i).second, 1 + static_cast<int>(i))});
    }
    sut.asked.clear();
    sut.follow(rows);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "LeaveAndReturn"; }
};

}  // namespace

class SpaceProp : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { previousHandler = qInstallMessageHandler(countModelTestFailures); }
  void cleanupTestCase() { qInstallMessageHandler(previousHandler); }

  void stream() {
    QVERIFY(rc::check("the Space's rows are the MC's Space as the client holds it, with the user's edits until it holds them", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<Write, Write, Write, Write, Write, Subscribe, Subscribe, Drop, Resync,
                                                         Duplicate, NewLog, SelectPage, SelectPage, Edit, Edit, Answer, Answer,
                                                         SelectDeck, SelectDeck, Present, Present, Step, Step, Step, Leave>());
    }));
  }

  void presenter() {
    QVERIFY(rc::check("the presenter stays on its slide as the deck changes, and closes when nothing is left to present", [] {
      Model model;
      Sut sut;
      presentFourSlides(model, sut);
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<Write, Write, Write, Write, Write, Write, Subscribe, Drop, Resync, NewLog,
                                                         SelectPage, SelectDeck, Present, Step, Step, Step, Leave>());
    }));
  }

  void images() {
    QVERIFY(rc::check("every image shows as the MC holds it, and an address is asked for once while it is on screen", [] {
      ImagesModel model;
      ImagesSut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<AddImage, AddImage, BinImage, DeleteImage, PlaceImage, PlaceImage, OpenPage, ToggleBrowser, AnswerAddress, AnswerAddress, AnswerAllAtOnce, AddressesLapse, LeaveAndReturn>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceProp)
#include "tst_SpaceProp.moc"
