// Pages in a Space (features/space/pages.feature, self-updating-pages.feature, visualize.feature): the MC's `space.*` calls,
// faked here as the MC answers them (lib/hal_c2/space.ex and space/*.ex),
// its `spaces` and `space:<id>` streams (served as every `stream` is, by
// TimelineSteps.cpp), and what SpaceController shows of them.

#include <QAbstractItemModel>
#include <QBuffer>
#include <QFile>
#include <QFont>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QRegularExpression>
#include <QSet>
#include <QTest>

#include <algorithm>
#include <memory>
#include <optional>
#include <utility>

#include "Brick.h"
#include "CommandRegistry.h"
#include "FakeFiles.h"
#include "FilesWorkspace.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Mermaid.h"
#include "NavigationController.h"
#include "Space.h"
#include "SpaceController.h"
#include "Stream.h"
#include "ThemeStore.h"
#include "World.h"

namespace {

using namespace stream;

const QString kIndex = QStringLiteral("spaces");

QString streamOf(const QString& spaceId) {
  return QStringLiteral("space:") + spaceId;
}

// A `space.*` answer: its result, or the refusal's message and detail.
struct Answer {
  QJsonObject result;
  QString error;
  QJsonObject detail;
};

// A page's version as the MC reads it from its log: one author's run of edits.
struct FakeVersion {
  int version = 0;
  QString at;
  QJsonObject author;
  QString restoredFromAt;
  QJsonObject content;
};

// The MC's Spaces, beside the streams that hold them.
struct FakeSpaces {
  // Each page's versions, oldest first, and whether the next edit comes after
  // long enough to start a new one.
  QHash<QString, QList<FakeVersion>> versions;
  bool paused = false;
  int ids = 0;
  int clock = 0;
  // Threads with something to summarise.
  QSet<QString> talked;
  // How text generation answers: available, unavailable or failed.
  QString generation = QStringLiteral("available");
  // What a run of a page's update writes.
  QString writes;
  // How image generation answers: available, unavailable or failed.
  QString imageGeneration = QStringLiteral("available");
  // The images a client asked an address for.
  QStringList signedImages;
  // The folder the last summary was written in, and the thread it was of.
  QString cwd;
  QString summarised;
  // Whether the next ask is refused, whether a stop ends an agent, and how many came.
  bool refuseAsk = false;
  QString keptWords;
  bool ignoresStop = false;
  int stops = 0;
  // The chart text generation draws next; none when the request cannot be answered.
  QJsonObject chart;
  // The page the last chart was asked for on.
  QString asked;
  // How the client's last `space.*` was answered.
  QString lastMethod;
  Answer last;
  // The ids page titles, block texts and comment bodies named, kept after they go.
  QHash<QString, QString> named;
  // The Space the scenario writes in.
  QString current;
  // Where the MC makes a site's link: on the address it knows, marked when only
  // this machine can open that, and what Tailscale names the machine (none: not running).
  QString address = QStringLiteral("http://192.168.1.20:3773");
  bool localOnly = false;
  QString tailnet;
  // The link each page was last published on, kept after it stops working.
  QHash<QString, QString> links;
  // Where the log of the current Space stood when a block moved, and what
  // the client's blocks did since.
  qsizetype mark = 0;
  QStringList seen;
  // Another client following the Spaces (and, once it chose one, a Space).
  std::unique_ptr<SpacePages> second;
  // Who is on each page: the other devices, and the agents by thread title.
  QHash<QString, QStringList> devices;
  QHash<QString, QStringList> agents;
  // Whether a client asking who is on a page is turned down.
  bool viewersRefused = false;
  // How the next scan of a project's files answers, and the files read again
  // because a client showed their page.
  QString scan = QStringLiteral("written");
  int syncs = 0;
  // How many times a client asked for a project's files.
  int listings = 0;
  // The link the agent's message has.
  QString link;
  // Whether the thread whose files the user browses works in a worktree of the project.
  bool onWorktree = false;
};

FakeSpaces& fake(FakeMc& mc) {
  return mc.part<FakeSpaces>();
}

QString stamp(FakeMc& mc) {
  return iso(now().addSecs(++fake(mc).clock));
}

QString newId(FakeMc& mc, const QString& kind) {
  return QStringLiteral("%1-%2").arg(kind).arg(++fake(mc).ids);
}

QString text(const QJsonObject& entity, QLatin1String field) {
  return entity.value(field).toString();
}

QList<QJsonObject> all(FakeMc& mc, const QString& stream, const QString& kind) {
  QList<QJsonObject> out;
  const QMap<QString, QJsonObject> entities = mc.part<FakeStreams>().threads.value(stream);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    if (it.key().startsWith(kind + QLatin1Char('\n'))) out.append(*it);
  }
  return out;
}

QJsonObject one(FakeMc& mc, const QString& stream, const QString& kind, const QString& id) {
  return mc.part<FakeStreams>().threads.value(stream).value(kind + QLatin1Char('\n') + id);
}

QList<QJsonObject> sortedBy(QList<QJsonObject> rows, QLatin1String field) {
  std::stable_sort(rows.begin(), rows.end(), [field](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(text(a, field), text(b, field));
    return order != 0 ? order < 0 : text(a, QLatin1String("id")) < text(b, QLatin1String("id"));
  });
  return rows;
}

// The snapshot of `stream` a follower starting now is sent, and its `live`.
QList<QJsonObject> snapshot(FakeMc& mc, const QString& stream) {
  FakeStreams& streams = mc.part<FakeStreams>();
  QJsonArray rows;
  const QMap<QString, QJsonObject> entities = streams.threads.value(stream);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const QStringList key = it.key().split(QLatin1Char('\n'));
    rows.append(QJsonArray{key.at(0), key.at(1), *it});
  }
  return {{{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), streams.seq}, {QStringLiteral("part"), 0},
           {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), streams.handle}},
          {{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), streams.seq}, {QStringLiteral("handle"), streams.handle}}};
}

// One change to an entity of `stream`, appended to its log and sent to
// whoever follows it ({"s": set, "d": delete}).
void put(FakeMc& mc, const QString& stream, const QString& kind, const QString& id, const QJsonObject& patch) {
  FakeStreams& streams = mc.part<FakeStreams>();
  QMap<QString, QJsonObject>& entities = streams.threads[stream];
  const QString key = kind + QLatin1Char('\n') + id;
  if (patch.value(QLatin1String("d")).toBool()) {
    entities.remove(key);
  } else {
    QJsonObject& entity = entities[key];
    const QJsonObject set = patch.value(QLatin1String("s")).toObject();
    for (auto it = set.begin(); it != set.end(); ++it) entity.insert(it.key(), it.value());
  }
  const int seq = ++streams.seq;
  streams.log[stream].append({seq, kind, id, patch});
  QJsonObject events{{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq},
                     {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, iso(now())})}}};
  for (const int follower : mc.subscribers(QStringLiteral("stream"))) {
    if (mc.shapeOf(follower).value(QLatin1String("stream")).toString() != stream) continue;
    events.insert(QStringLiteral("id"), follower);
    deliver(mc, events);
  }
  if (SpacePages* second = fake(mc).second.get()) {
    if (stream == kIndex) second->receiveIndex(events);
    if (!second->spaceId().isEmpty() && stream == streamOf(second->spaceId())) second->receiveSpace(events);
  }
}

void set(FakeMc& mc, const QString& stream, const QString& kind, const QString& id, const QJsonObject& fields) {
  put(mc, stream, kind, id, {{QStringLiteral("s"), fields}});
}

void remove(FakeMc& mc, const QString& stream, const QString& kind, const QString& id) {
  put(mc, stream, kind, id, {{QStringLiteral("d"), true}});
}

// --- The MC's answers -------------------------------------------------------

Answer refused(const QString& reason, const QString& message, const QString& tag = QStringLiteral("SpaceError")) {
  return {{}, message, {{QStringLiteral("_tag"), tag}, {QStringLiteral("reason"), reason}, {QStringLiteral("message"), message}}};
}

const QJsonObject kUser{{QStringLiteral("type"), QStringLiteral("user")}};
// A page's update writes as itself, whoever ran it.
const QJsonObject kSchedule{{QStringLiteral("type"), QStringLiteral("schedule")}};

QJsonObject agent(const QString& threadId) {
  return {{QStringLiteral("type"), QStringLiteral("agent")}, {QStringLiteral("threadId"), threadId}};
}

// HalC2.Space.Order.between: a key after `low` and before `high` (none: the end).
QList<int> mid(const QList<int>& low, const std::optional<QList<int>>& high);

QList<int> midFirst(const QList<int>& low, const std::optional<QList<int>>& high) {
  const int lo = low.isEmpty() ? 0 : low.first();
  const int hi = high ? high->first() : 36;
  if (hi - lo > 1) return {(lo + hi) / 2};
  if (high && high->size() > 1) return {hi};
  return QList<int>{lo} + mid(low.mid(1), std::nullopt);
}

QList<int> mid(const QList<int>& low, const std::optional<QList<int>>& high) {
  if (!high) return midFirst(low, high);
  qsizetype common = 0;
  while (common < high->size() && (common < low.size() ? low.at(common) : 0) == high->at(common)) ++common;
  if (common == 0) return midFirst(low, high);
  return high->mid(0, common) + mid(low.mid(common), high->mid(common));
}

QString between(const QString& low, const std::optional<QString>& high) {
  static const QString digits = QStringLiteral("0123456789abcdefghijklmnopqrstuvwxyz");
  const auto toDigits = [](const QString& key) {
    QList<int> out;
    for (const QChar c : key) out.append(int(digits.indexOf(c)));
    return out;
  };
  QString key;
  for (const int digit : mid(toDigits(low), high ? std::optional(toDigits(*high)) : std::nullopt)) key.append(digits.at(digit));
  return key;
}

bool trashed(const QJsonObject& page) {
  return !text(page, QLatin1String("trashedAt")).isEmpty();
}

// Neither the page nor any page it sits in is in the trash.
bool live(FakeMc& mc, const QString& space, QJsonObject page) {
  QSet<QString> seen;
  while (!page.isEmpty()) {
    if (trashed(page)) return false;
    const QString parent = text(page, QLatin1String("parentPageId"));
    if (parent.isEmpty() || seen.contains(parent)) break;
    seen.insert(parent);
    page = one(mc, streamOf(space), QStringLiteral("page"), parent);
  }
  return true;
}

// The page and every page inside it.
QStringList within(FakeMc& mc, const QString& space, const QString& pageId) {
  QStringList found{pageId};
  for (qsizetype i = 0; i < found.size(); ++i) {
    for (const QJsonObject& page : all(mc, streamOf(space), QStringLiteral("page"))) {
      const QString id = text(page, QLatin1String("id"));
      if (text(page, QLatin1String("parentPageId")) == found.at(i) && !found.contains(id)) found.append(id);
    }
  }
  return found;
}

QList<QJsonObject> blocksOf(FakeMc& mc, const QString& space, const QString& pageId) {
  QList<QJsonObject> blocks;
  for (const QJsonObject& block : all(mc, streamOf(space), QStringLiteral("block"))) {
    if (text(block, QLatin1String("pageId")) == pageId) blocks.append(block);
  }
  return sortedBy(blocks, QLatin1String("order"));
}

// Where a page that can be written to is, or why it cannot be.
std::optional<Answer> writable(FakeMc& mc, const QString& space, const QString& pageId) {
  const QJsonObject page = one(mc, streamOf(space), QStringLiteral("page"), pageId);
  if (page.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no page %1.").arg(pageId));
  if (!live(mc, space, page)) return refused(QStringLiteral("trashed"), QStringLiteral("The page is in the trash."));
  return std::nullopt;
}

// The order key of a block placed after `after` (absent: last, null: first)
// on the page, without the block `moving`.
std::optional<QString> place(FakeMc& mc, const QString& space, const QString& pageId, const QJsonValue& after, const QString& moving = {}) {
  QList<QJsonObject> blocks = blocksOf(mc, space, pageId);
  blocks.removeIf([&](const QJsonObject& block) { return text(block, QLatin1String("id")) == moving; });
  const auto order = [&](qsizetype i) { return text(blocks.at(i), QLatin1String("order")); };
  if (after.isUndefined()) return between(blocks.isEmpty() ? QString() : order(blocks.size() - 1), std::nullopt);
  if (after.isNull()) return between(QString(), blocks.isEmpty() ? std::nullopt : std::optional(order(0)));
  for (qsizetype i = 0; i < blocks.size(); ++i) {
    if (text(blocks.at(i), QLatin1String("id")) != after.toString()) continue;
    return between(order(i), i + 1 < blocks.size() ? std::optional(order(i + 1)) : std::nullopt);
  }
  return std::nullopt;
}

QString titleOf(FakeMc& mc, const QString& space, const QString& pageId) {
  return text(one(mc, streamOf(space), QStringLiteral("page"), pageId), QLatin1String("title"));
}

// HalC2.Space.Markdown.export.
QString exportMarkdown(FakeMc& mc, const QString& space, const QJsonObject& page) {
  QStringList parts{QStringLiteral("# ") + text(page, QLatin1String("title"))};
  bool inList = false;
  for (const QJsonObject& block : blocksOf(mc, space, text(page, QLatin1String("id")))) {
    const QString kind = text(block, QLatin1String("kind"));
    const QString said = text(block, QLatin1String("text"));
    QString line;
    if (kind == QLatin1String("heading")) {
      line = QStringLiteral("## ") + said;
    } else if (kind == QLatin1String("checklist")) {
      line = (block.value(QLatin1String("checked")).toBool() ? QStringLiteral("- [x] ") : QStringLiteral("- [ ] ")) + said;
    } else if (kind == QLatin1String("callout")) {
      QStringList quoted;
      for (const QString& part : said.split(QLatin1Char('\n'))) quoted.append((QStringLiteral("> ") + part).trimmed());
      line = quoted.join(QLatin1Char('\n'));
    } else if (kind == QLatin1String("code")) {
      const QString fence = text(block, QLatin1String("fence")).isEmpty() ? QStringLiteral("```") : text(block, QLatin1String("fence"));
      line = fence + text(block, QLatin1String("language")) + text(block, QLatin1String("info")) + QLatin1Char('\n') + said + QLatin1Char('\n') + fence;
    } else if (kind == QLatin1String("subpage_link")) {
      const QString linked = text(block, QLatin1String("linkedPageId"));
      const QString title = titleOf(mc, space, linked);
      line = QStringLiteral("[%1](#%2)").arg(title.isEmpty() ? said : title, linked);
    } else {
      line = said;
    }
    const bool item = kind == QLatin1String("checklist");
    if (item && inList) {
      parts.last() += QLatin1Char('\n') + line;
    } else {
      parts.append(line);
    }
    inList = item;
  }
  return parts.join(QStringLiteral("\n\n")) + QLatin1Char('\n');
}

// HalC2.Space.Markdown.parse: the title, and each block's kind, text,
// checked and linkedPageId.
std::pair<QString, QList<QJsonObject>> parseMarkdown(const QString& markdown) {
  static const QRegularExpression title(QStringLiteral("^#\\s+(.*)$"));
  static const QRegularExpression heading(QStringLiteral("^#{2,6}\\s+(.*)$"));
  static const QRegularExpression item(QStringLiteral("^\\s*[-*]\\s+\\[([ xX])\\]\\s?(.*)$"));
  static const QRegularExpression link(QStringLiteral("^\\[(.+)\\]\\(#([\\w-]+)\\)$"));
  static const QRegularExpression notParagraph(QStringLiteral("^(#{1,6}\\s|>| {0,3}(```|~~~)|\\s*[-*]\\s+\\[[ xX]\\])"));
  static const QRegularExpression fenced(QStringLiteral("^ {0,3}(`{3,}|~{3,})"));
  // A fence from the start of the line is a code block; indented, or with a space
  // before its language, it is kept as written (block(:code)).
  static const QRegularExpression code(QStringLiteral("^(`{3,}|~{3,})(?:(\\S+)(.*))?$"));
  const auto block = [](const QString& kind, const QString& said) {
    return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), said}, {QStringLiteral("checked"), false},
                       {QStringLiteral("linkedPageId"), QJsonValue::Null}};
  };
  QStringList lines = QString(markdown).replace(QStringLiteral("\r\n"), QStringLiteral("\n")).split(QLatin1Char('\n'));
  QList<QJsonObject> blocks;
  QString pageTitle;
  for (qsizetype i = 0; i < lines.size();) {
    const QString line = lines.at(i);
    QRegularExpressionMatch match;
    if (line.trimmed().isEmpty()) {
      ++i;
    } else if ((match = fenced.match(line)).hasMatch()) {
      const QString fence = match.captured(1);
      QStringList inside;
      while (++i < lines.size() && !lines.at(i).trimmed().startsWith(fence)) inside.append(lines.at(i));
      const QString close = i < lines.size() ? lines.at(i++) : QString();
      if ((match = code.match(line)).hasMatch()) {
        QJsonObject fencedCode = block(QStringLiteral("code"), inside.join(QLatin1Char('\n')));
        if (fence != QLatin1String("```")) fencedCode.insert(QStringLiteral("fence"), fence);
        if (!match.captured(2).isEmpty()) fencedCode.insert(QStringLiteral("language"), match.captured(2));
        if (!match.captured(3).isEmpty()) fencedCode.insert(QStringLiteral("info"), match.captured(3));
        blocks.append(fencedCode);
      } else {
        blocks.append(block(QStringLiteral("raw"), (QStringList{line} + inside + QStringList{close}).join(QLatin1Char('\n'))));
      }
    } else if ((match = title.match(line)).hasMatch()) {
      // A `# ` heading anywhere but the top is an ordinary heading.
      if (blocks.isEmpty() && pageTitle.isNull()) {
        pageTitle = match.captured(1).trimmed();
      } else {
        blocks.append(block(QStringLiteral("heading"), match.captured(1).trimmed()));
      }
      ++i;
    } else if ((match = heading.match(line)).hasMatch()) {
      blocks.append(block(QStringLiteral("heading"), match.captured(1).trimmed()));
      ++i;
    } else if ((match = item.match(line)).hasMatch()) {
      QJsonObject checklist = block(QStringLiteral("checklist"), match.captured(2));
      checklist.insert(QStringLiteral("checked"), match.captured(1) != QLatin1String(" "));
      blocks.append(checklist);
      ++i;
    } else if ((match = link.match(line.trimmed())).hasMatch()) {
      QJsonObject linked = block(QStringLiteral("subpage_link"), match.captured(1));
      linked.insert(QStringLiteral("linkedPageId"), match.captured(2));
      blocks.append(linked);
      ++i;
    } else if (line.startsWith(QLatin1Char('>'))) {
      QStringList quote;
      for (; i < lines.size() && lines.at(i).startsWith(QLatin1Char('>')); ++i) {
        QString part = lines.at(i).mid(1);
        if (part.startsWith(QLatin1Char(' '))) part.remove(0, 1);
        quote.append(part);
      }
      blocks.append(block(QStringLiteral("callout"), quote.join(QLatin1Char('\n'))));
    } else {
      QStringList paragraph;
      for (; i < lines.size() && !lines.at(i).trimmed().isEmpty() && !notParagraph.match(lines.at(i)).hasMatch(); ++i) {
        paragraph.append(lines.at(i));
      }
      blocks.append(block(QStringLiteral("paragraph"), paragraph.join(QLatin1Char('\n'))));
    }
  }
  return {pageTitle, blocks};
}

Answer createPage(FakeMc& mc, const QString& space, const QString& title, const QJsonValue& parent, const QJsonObject& extra = {}) {
  if (title.trimmed().isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("A page needs a title."));
  if (parent.isString()) {
    if (const auto why = writable(mc, space, parent.toString())) return *why;
  }
  const QString id = newId(mc, QStringLiteral("page"));
  const QString at = stamp(mc);
  QJsonObject page{{QStringLiteral("id"), id},
                   {QStringLiteral("spaceId"), space},
                   {QStringLiteral("title"), title.trimmed()},
                   {QStringLiteral("parentPageId"), parent.isString() ? parent : QJsonValue(QJsonValue::Null)},
                   {QStringLiteral("sourceThreadId"), QJsonValue::Null},
                   {QStringLiteral("trashedAt"), QJsonValue::Null},
                   {QStringLiteral("createdAt"), at},
                   {QStringLiteral("updatedAt"), at}};
  for (auto it = extra.begin(); it != extra.end(); ++it) page.insert(it.key(), it.value());
  set(mc, streamOf(space), QStringLiteral("page"), id, page);
  return {{{QStringLiteral("page"), page}}};
}

Answer insertBlock(FakeMc& mc, const QString& space, const QString& pageId, const QJsonObject& spec, const QJsonValue& after,
                   const QJsonObject& author) {
  if (const auto why = writable(mc, space, pageId)) return *why;
  static const QStringList kinds{QStringLiteral("paragraph"), QStringLiteral("heading"), QStringLiteral("checklist"),
                                 QStringLiteral("callout"), QStringLiteral("subpage_link"), QStringLiteral("image"),
                                 QStringLiteral("raw"), QStringLiteral("table"), QStringLiteral("code")};
  const QString kind = text(spec, QLatin1String("kind"));
  if (!kinds.contains(kind)) return refused(QStringLiteral("invalid"), QStringLiteral("There is no block kind %1.").arg(kind));
  const QJsonValue level = spec.value(QLatin1String("level"));
  if (kind == QLatin1String("heading") && !level.isUndefined() && (level.toInt() < 1 || level.toInt() > 6)) {
    return refused(QStringLiteral("invalid"), QStringLiteral("A heading's level is 1 to 6."));
  }
  const QString linked = text(spec, QLatin1String("linkedPageId"));
  if (kind == QLatin1String("subpage_link") && one(mc, streamOf(space), QStringLiteral("page"), linked).isEmpty()) {
    return refused(QStringLiteral("notFound"), QStringLiteral("A subpage link needs a page to link to."));
  }
  const QString imageId = text(spec, QLatin1String("imageId"));
  const QJsonObject image = one(mc, streamOf(space), QStringLiteral("image"), imageId);
  if (kind == QLatin1String("image")) {
    if (image.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no image %1 in this Space.").arg(imageId));
    if (trashed(image)) return refused(QStringLiteral("trashed"), QStringLiteral("The image \"%1\" is in the trash.").arg(text(image, QLatin1String("name"))));
  }
  const std::optional<QString> order = place(mc, space, pageId, after);
  if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(after.toString()));
  const QString id = newId(mc, QStringLiteral("block"));
  const QString at = stamp(mc);
  QJsonObject block{{QStringLiteral("id"), id},
                    {QStringLiteral("pageId"), pageId},
                    {QStringLiteral("kind"), kind},
                    {QStringLiteral("text"), text(spec, QLatin1String("text"))},
                    {QStringLiteral("order"), *order},
                    {QStringLiteral("createdBy"), author},
                    {QStringLiteral("updatedBy"), author},
                    {QStringLiteral("createdAt"), at},
                    {QStringLiteral("updatedAt"), at}};
  if (kind == QLatin1String("checklist")) block.insert(QStringLiteral("checked"), spec.value(QLatin1String("checked")).toBool());
  if (kind == QLatin1String("subpage_link")) block.insert(QStringLiteral("linkedPageId"), linked);
  if (kind == QLatin1String("heading") && !level.isUndefined()) block.insert(QStringLiteral("level"), level.toInt());
  for (const QLatin1String extra : {QLatin1String("language"), QLatin1String("fence"), QLatin1String("info")}) {
    if (kind == QLatin1String("code") && !text(spec, extra).isEmpty()) block.insert(extra, spec.value(extra));
  }
  if (kind == QLatin1String("image")) {
    block.insert(QStringLiteral("imageId"), imageId);
    if (text(block, QLatin1String("text")).isEmpty()) block.insert(QStringLiteral("text"), image.value(QLatin1String("name")));
  }
  set(mc, streamOf(space), QStringLiteral("block"), id, block);
  return {{{QStringLiteral("block"), block}}};
}

Answer importMarkdown(FakeMc& mc, const QString& space, const QString& markdown, const QString& title, const QJsonValue& parent,
                      const QJsonObject& extra, const QJsonObject& author) {
  const auto [parsed, blocks] = parseMarkdown(markdown);
  const QString named = !title.trimmed().isEmpty() ? title : !parsed.trimmed().isEmpty() ? parsed : QStringLiteral("Untitled");
  const Answer made = createPage(mc, space, named, parent, extra);
  if (!made.error.isEmpty()) return made;
  const QString pageId = made.result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString();
  for (const QJsonObject& block : blocks) insertBlock(mc, space, pageId, block, QJsonValue::Undefined, author);
  return made;
}

// --- Project files as pages (lib/hal_c2/space/files.ex) -----------------------

// What a page takes from its file is the file's.
const QJsonObject kFile{{QStringLiteral("type"), QStringLiteral("file")}};

// The project's Markdown, as the spaces section the MC defaults to covers it.
bool spaceFile(const QString& path) {
  return path.endsWith(QLatin1String(".md"));
}

QString hashOf(const QString& contents) {
  return QString::number(qHash(contents), 16);
}

// The page of any Space that is `path` of `project`, with its Space; none when no page is.
std::pair<QString, QJsonObject> pageOfFile(FakeMc& mc, const QString& project, const QString& path) {
  for (const QJsonObject& space : all(mc, kIndex, QStringLiteral("space"))) {
    const QString id = text(space, QLatin1String("id"));
    for (const QJsonObject& page : all(mc, streamOf(id), QStringLiteral("page"))) {
      const QJsonObject file = page.value(QLatin1String("file")).toObject();
      if (text(file, QLatin1String("projectId")) == project && text(file, QLatin1String("path")) == path) return {id, page};
    }
  }
  return {};
}

// The page's blocks, made again from what its file says now, and the file as read.
void takeFile(FakeMc& mc, const QString& space, const QString& pageId, const QJsonObject& changes = {}) {
  QJsonObject file = one(mc, streamOf(space), QStringLiteral("page"), pageId).value(QLatin1String("file")).toObject();
  const QString contents = fakeFiles(mc).files.value(text(file, QLatin1String("path")));
  for (const QJsonObject& block : blocksOf(mc, space, pageId)) remove(mc, streamOf(space), QStringLiteral("block"), text(block, QLatin1String("id")));
  for (const QJsonObject& block : parseMarkdown(contents).second) insertBlock(mc, space, pageId, block, QJsonValue::Undefined, kFile);
  file.insert(QStringLiteral("hash"), hashOf(contents));
  file.insert(QStringLiteral("size"), contents.toUtf8().size());
  file.insert(QStringLiteral("missing"), false);
  for (auto it = changes.begin(); it != changes.end(); ++it) file.insert(it.key(), it.value());
  set(mc, streamOf(space), QStringLiteral("page"), pageId, {{QStringLiteral("file"), file}, {QStringLiteral("updatedAt"), stamp(mc)}});
}

// The file gone from under its page, which keeps what it said.
void loseFile(FakeMc& mc, const QString& space, const QJsonObject& page) {
  QJsonObject file = page.value(QLatin1String("file")).toObject();
  if (file.value(QLatin1String("missing")).toBool()) return;
  file.insert(QStringLiteral("missing"), true);
  set(mc, streamOf(space), QStringLiteral("page"), text(page, QLatin1String("id")), {{QStringLiteral("file"), file}});
}

// `space.files.list` and `space.files.scan`: no Space's.
Answer filesCall(FakeMc& mc, const QString& method, const QJsonObject& in) {
  const QString project = text(in, QLatin1String("projectId"));
  if (!mc.projects.contains(project)) return refused(QStringLiteral("notFound"), QStringLiteral("There is no project %1 on this MC.").arg(project));
  if (method == QLatin1String("files.list")) {
    ++fake(mc).listings;
    QJsonArray files;
    const QMap<QString, QString>& contents = fakeFiles(mc).files;
    for (auto it = contents.cbegin(); it != contents.cend(); ++it) {
      if (!spaceFile(it.key())) continue;
      const auto [space, page] = pageOfFile(mc, project, it.key());
      const QJsonValue open = page.isEmpty() ? QJsonValue(QJsonValue::Null)
                                             : QJsonValue(QJsonObject{{QStringLiteral("spaceId"), space}, {QStringLiteral("pageId"), page.value(QLatin1String("id"))},
                                                                      {QStringLiteral("title"), page.value(QLatin1String("title"))}});
      files.append(QJsonObject{{QStringLiteral("relativePath"), it.key()}, {QStringLiteral("kind"), QStringLiteral("page")}, {QStringLiteral("page"), open}});
    }
    return {{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), files}}};
  }
  if (method == QLatin1String("files.scan")) {
    return {{{QStringLiteral("status"), fake(mc).scan},
             {QStringLiteral("entries"), QJsonArray{QJsonObject{{QStringLiteral("path"), QStringLiteral("**/*.md")}, {QStringLiteral("kind"), QStringLiteral("page")}}}}}};
  }
  return refused(QStringLiteral("invalid"), QStringLiteral("space.%1 is missing a required field.").arg(method));
}

// `space.page.openFile`: the file's page, made in `space` unless a Space already has it.
Answer openFile(FakeMc& mc, const QString& space, const QJsonObject& in) {
  const QString project = text(in, QLatin1String("projectId"));
  const QString path = text(in, QLatin1String("relativePath"));
  if (path.startsWith(QLatin1Char('/')) || path.split(QLatin1Char('/')).contains(QStringLiteral(".."))) {
    return refused(QStringLiteral("invalid"), QStringLiteral("%1 is outside the project.").arg(path));
  }
  if (!mc.projects.contains(project) || !fakeFiles(mc).files.contains(path)) {
    return refused(QStringLiteral("notFound"), QStringLiteral("There is no file %1 in the project %2.").arg(path, project));
  }
  if (!spaceFile(path)) return refused(QStringLiteral("notSpaceFile"), QStringLiteral("%1 is not in the spaces section of the project.").arg(path));
  if (const auto [where, page] = pageOfFile(mc, project, path); !page.isEmpty()) {
    return {{{QStringLiteral("spaceId"), where}, {QStringLiteral("page"), page}, {QStringLiteral("created"), false}}};
  }
  const QString contents = fakeFiles(mc).files.value(path);
  const QJsonObject file{{QStringLiteral("projectId"), project},  {QStringLiteral("path"), path},       {QStringLiteral("hash"), hashOf(contents)},
                         {QStringLiteral("size"), contents.toUtf8().size()}, {QStringLiteral("missing"), false}, {QStringLiteral("conflictAt"), QJsonValue::Null}};
  Answer made = importMarkdown(mc, space, contents, {}, QJsonValue::Null, {{QStringLiteral("file"), file}}, kFile);
  if (!made.error.isEmpty()) return made;
  made.result.insert(QStringLiteral("spaceId"), space);
  made.result.insert(QStringLiteral("created"), true);
  return made;
}

// `space.page.syncFile`: the file read again; what changed in it is the page's.
Answer syncFile(FakeMc& mc, const QString& space, const QJsonObject& page) {
  ++fake(mc).syncs;
  const QJsonObject file = page.value(QLatin1String("file")).toObject();
  if (file.isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("The page is not a project file."));
  const QString id = text(page, QLatin1String("id"));
  const QMap<QString, QString>& files = fakeFiles(mc).files;
  const QString path = text(file, QLatin1String("path"));
  if (!files.contains(path)) {
    loseFile(mc, space, page);
  } else if (hashOf(files.value(path)) != text(file, QLatin1String("hash")) || file.value(QLatin1String("missing")).toBool()) {
    takeFile(mc, space, id);
  }
  return {{{QStringLiteral("page"), one(mc, streamOf(space), QStringLiteral("page"), id)}}};
}

// The summary text generation writes of a thread.
const QString kSummaryTitle = QStringLiteral("Release plan");
const QString kSummary = QStringLiteral("Ship pages on Friday, once the Space streams are in.");

QJsonObject spaceOf(FakeMc& mc, const QString& id) {
  return one(mc, kIndex, QStringLiteral("space"), id);
}

QJsonObject makeSpace(FakeMc& mc, const QString& name) {
  const QString id = newId(mc, QStringLiteral("space"));
  const QString at = stamp(mc);
  const QJsonObject space{{QStringLiteral("id"), id}, {QStringLiteral("name"), name}, {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}};
  set(mc, kIndex, QStringLiteral("space"), id, space);
  return space;
}

// Keeps an image of the Space, as what the MC knows about it.
Answer keepImage(FakeMc& mc, const QString& space, const QString& name, const QJsonValue& prompt, const QJsonValue& generatedBy) {
  const QString id = newId(mc, QStringLiteral("image"));
  const QString at = stamp(mc);
  const QJsonObject image{{QStringLiteral("id"), id},
                          {QStringLiteral("spaceId"), space},
                          {QStringLiteral("name"), name},
                          {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                          {QStringLiteral("sizeBytes"), 64},
                          {QStringLiteral("width"), 4},
                          {QStringLiteral("height"), 3},
                          {QStringLiteral("prompt"), prompt},
                          {QStringLiteral("generatedBy"), generatedBy},
                          {QStringLiteral("trashedAt"), QJsonValue::Null},
                          {QStringLiteral("createdBy"), kUser},
                          {QStringLiteral("createdAt"), at},
                          {QStringLiteral("updatedAt"), at}};
  set(mc, streamOf(space), QStringLiteral("image"), id, image);
  return {{{QStringLiteral("image"), image}}};
}

// `space.image.*` as the MC's (apps/server-ex lib/hal_c2/space/images.ex). The
// file behind an upload is the MC's to check; this fake takes every upload.
Answer imageCall(FakeMc& mc, const QString& space, const QString& method, const QJsonObject& in) {
  const QString stream = streamOf(space);
  const QString tag = QStringLiteral("SpaceImageGenerationError");
  if (method == QLatin1String("image.add")) {
    if (text(in, QLatin1String("attachmentId")).isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("There is no such upload."));
    return keepImage(mc, space, text(in, QLatin1String("name")), QJsonValue::Null, QJsonValue::Null);
  }
  if (method == QLatin1String("image.generate")) {
    if (fake(mc).imageGeneration == QLatin1String("unavailable")) return refused(QStringLiteral("unavailable"), QStringLiteral("No provider that can make an image is set up."), tag);
    if (fake(mc).imageGeneration == QLatin1String("failed")) return refused(QStringLiteral("failed"), QStringLiteral("The provider left no image."), tag);
    const QString prompt = text(in, QLatin1String("prompt"));
    return keepImage(mc, space, prompt + QStringLiteral(".png"), prompt, QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}});
  }
  const QString id = text(in, QLatin1String("imageId"));
  const QJsonObject image = one(mc, stream, QStringLiteral("image"), id);
  if (image.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no image %1 in this Space.").arg(id));
  const QString name = text(image, QLatin1String("name"));
  const auto answer = [&] { return Answer{{{QStringLiteral("image"), one(mc, stream, QStringLiteral("image"), id)}}}; };
  if (method == QLatin1String("image.trash")) {
    if (trashed(image)) return refused(QStringLiteral("trashed"), QStringLiteral("The image \"%1\" is in the trash.").arg(name));
    const QString at = stamp(mc);
    set(mc, stream, QStringLiteral("image"), id, {{QStringLiteral("trashedAt"), at}, {QStringLiteral("updatedAt"), at}});
    return answer();
  }
  if (method == QLatin1String("image.restore")) {
    if (!trashed(image)) return refused(QStringLiteral("invalid"), QStringLiteral("The image \"%1\" is not in the trash.").arg(name));
    set(mc, stream, QStringLiteral("image"), id, {{QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("updatedAt"), stamp(mc)}});
    return answer();
  }
  if (method == QLatin1String("image.delete")) {
    if (!trashed(image)) return refused(QStringLiteral("invalid"), QStringLiteral("Only an image in the trash can be deleted; move \"%1\" there first.").arg(name));
    remove(mc, stream, QStringLiteral("image"), id);
    return {{{QStringLiteral("imageId"), id}}};
  }
  return refused(QStringLiteral("invalid"), QStringLiteral("space.%1 is missing a required field.").arg(method));
}

// Personal, for an MC that has no Space yet.
void seed(FakeMc& mc) {
  if (all(mc, kIndex, QStringLiteral("space")).isEmpty()) makeSpace(mc, QStringLiteral("Personal"));
}

// What a version holds of a block: all but who last wrote it and when.
QJsonObject versioned(QJsonObject block) {
  block.remove(QLatin1String("updatedBy"));
  block.remove(QLatin1String("updatedAt"));
  return block;
}

QJsonObject contentOf(FakeMc& mc, const QString& space, const QJsonObject& page) {
  QJsonArray blocks;
  for (const QJsonObject& block : blocksOf(mc, space, text(page, QLatin1String("id")))) blocks.append(versioned(block));
  return {{QStringLiteral("title"), page.value(QLatin1String("title"))}, {QStringLiteral("blocks"), blocks}};
}

// Whatever the last write did to a page is its author's version: the last one
// grown, or a new one after a pause, another author or a restore.
void noteEdits(FakeMc& mc, const QString& space, const QJsonObject& author) {
  FakeSpaces& spaces = fake(mc);
  for (const QJsonObject& page : all(mc, streamOf(space), QStringLiteral("page"))) {
    QList<FakeVersion>& versions = spaces.versions[text(page, QLatin1String("id"))];
    const QJsonObject content = contentOf(mc, space, page);
    if (!versions.isEmpty() && versions.last().content == content) continue;
    const bool grows = !versions.isEmpty() && !spaces.paused && versions.last().restoredFromAt.isEmpty() && versions.last().author == author;
    if (!grows) versions.append(FakeVersion{});
    versions.last() = {++spaces.ids, stamp(mc), author, QString(), content};
    spaces.paused = false;
  }
}

Answer historyCall(FakeMc& mc, const QString& method, const QJsonObject& in) {
  const QString space = text(in, QLatin1String("spaceId"));
  const QString pageId = text(in, QLatin1String("pageId"));
  const QJsonObject page = one(mc, streamOf(space), QStringLiteral("page"), pageId);
  if (page.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no page %1 in this Space.").arg(pageId));
  QList<FakeVersion>& versions = fake(mc).versions[pageId];

  if (method == QLatin1String("page.history")) {
    const int before = in.value(QLatin1String("before")).toInt(-1);
    const int limit = in.value(QLatin1String("limit")).toInt(30);
    QJsonArray shown;
    QJsonValue next(QJsonValue::Null);
    for (auto it = versions.crbegin(); it != versions.crend(); ++it) {
      if (before >= 0 && it->version >= before) continue;
      if (shown.size() == limit) {
        next = shown.last().toObject().value(QLatin1String("version"));
        break;
      }
      const QString thread = text(it->author, QLatin1String("threadId"));
      shown.append(QJsonObject{{QStringLiteral("version"), it->version},
                               {QStringLiteral("at"), it->at},
                               {QStringLiteral("author"), it->author},
                               {QStringLiteral("threadTitle"), thread.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(mc.threads.value(thread).value(QLatin1String("title")).toString())},
                               {QStringLiteral("restoredFromAt"), it->restoredFromAt.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(it->restoredFromAt)}});
    }
    return {{{QStringLiteral("versions"), shown}, {QStringLiteral("nextBefore"), next}}};
  }

  const int wanted = in.value(QLatin1String("version")).toInt(-1);
  const auto found = std::find_if(versions.cbegin(), versions.cend(), [wanted](const FakeVersion& version) { return version.version == wanted; });
  if (found == versions.cend()) return refused(QStringLiteral("notFound"), QStringLiteral("This page has no version %1.").arg(wanted));
  const FakeVersion version = *found;

  if (method == QLatin1String("page.version")) {
    return {{{QStringLiteral("version"), version.version},
             {QStringLiteral("at"), version.at},
             {QStringLiteral("title"), version.content.value(QLatin1String("title"))},
             {QStringLiteral("blocks"), version.content.value(QLatin1String("blocks"))}}};
  }

  if (const auto why = writable(mc, space, pageId)) return *why;
  const QJsonObject before = contentOf(mc, space, page);
  const QString stream = streamOf(space);
  // HalC2.Space.History.restore/5 never writes a generated part: the page's stays as it
  // is, a page that updates itself takes none of a version's, and any other gets it back
  // as the block it reads as.
  const bool updates = page.value(QLatin1String("schedule")).isObject();
  QSet<QString> kept;
  for (const QJsonValue& value : version.content.value(QLatin1String("blocks")).toArray()) {
    QJsonObject block = value.toObject();
    if (text(block, QLatin1String("kind")) == QLatin1String("generated")) {
      if (updates) continue;
      const QJsonObject first = parseMarkdown(text(block, QLatin1String("text"))).second.value(0);
      block.insert(QStringLiteral("kind"), text(first, QLatin1String("kind")));
      block.insert(QStringLiteral("text"), text(first, QLatin1String("text")));
    }
    const QString id = text(block, QLatin1String("id"));
    kept.insert(id);
    if (versioned(one(mc, stream, QStringLiteral("block"), id)) == block) continue;
    block.insert(QStringLiteral("updatedBy"), kUser);
    block.insert(QStringLiteral("updatedAt"), stamp(mc));
    set(mc, stream, QStringLiteral("block"), id, block);
  }
  for (const QJsonObject& block : blocksOf(mc, space, pageId)) {
    const QString id = text(block, QLatin1String("id"));
    if (text(block, QLatin1String("kind")) != QLatin1String("generated") && !kept.contains(id)) remove(mc, stream, QStringLiteral("block"), id);
  }
  if (page.value(QLatin1String("title")) != version.content.value(QLatin1String("title")))
    set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("title"), version.content.value(QLatin1String("title"))}});
  const QJsonObject after = contentOf(mc, space, one(mc, stream, QStringLiteral("page"), pageId));
  if (after != before) versions.append(FakeVersion{++fake(mc).ids, stamp(mc), kUser, version.at, after});
  return {{{QStringLiteral("page"), one(mc, streamOf(space), QStringLiteral("page"), pageId)}}};
}

const QString kGenerated = QStringLiteral("generated");

QJsonObject generatedOf(FakeMc& mc, const QString& space, const QString& pageId) {
  for (const QJsonObject& block : all(mc, streamOf(space), QStringLiteral("block"))) {
    if (text(block, QLatin1String("pageId")) == pageId && text(block, QLatin1String("kind")) == kGenerated) return block;
  }
  return {};
}

QList<QJsonObject> slidesOf(FakeMc& mc, const QString& stream, const QString& deckId) {
  QList<QJsonObject> slides;
  for (const QJsonObject& slide : all(mc, stream, QStringLiteral("slide"))) {
    if (text(slide, QLatin1String("deckId")) == deckId) slides.append(slide);
  }
  return sortedBy(slides, QLatin1String("order"));
}

// Why the deck takes no edit, if it does not.
std::optional<Answer> deckRefusal(FakeMc& mc, const QString& stream, const QString& deckId) {
  const QJsonObject deck = one(mc, stream, QStringLiteral("deck"), deckId);
  if (deck.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no deck %1 in this Space.").arg(deckId));
  if (trashed(deck)) return refused(QStringLiteral("trashed"), QStringLiteral("The deck \"%1\" is in the trash.").arg(text(deck, QLatin1String("title"))));
  return std::nullopt;
}

// The order key of a slide placed after `after` (absent: last, null: first) in
// the deck, without the slide `moving`.
std::optional<QString> placeSlide(FakeMc& mc, const QString& stream, const QString& deckId, const QJsonValue& after, const QString& moving = {}) {
  QList<QJsonObject> slides = slidesOf(mc, stream, deckId);
  slides.removeIf([&](const QJsonObject& slide) { return text(slide, QLatin1String("id")) == moving; });
  const auto order = [&](qsizetype i) { return text(slides.at(i), QLatin1String("order")); };
  if (after.isUndefined()) return between(slides.isEmpty() ? QString() : order(slides.size() - 1), std::nullopt);
  if (after.isNull()) return between(QString(), slides.isEmpty() ? std::nullopt : std::optional(order(0)));
  for (qsizetype i = 0; i < slides.size(); ++i) {
    if (text(slides.at(i), QLatin1String("id")) != after.toString()) continue;
    return between(order(i), i + 1 < slides.size() ? std::optional(order(i + 1)) : std::nullopt);
  }
  return std::nullopt;
}

QJsonObject makeSlide(FakeMc& mc, const QString& stream, const QString& deckId, const QString& title, const QString& body, const QString& order) {
  const QString id = newId(mc, QStringLiteral("slide"));
  const QString at = stamp(mc);
  const QJsonObject slide{{QStringLiteral("id"), id},           {QStringLiteral("deckId"), deckId},
                          {QStringLiteral("title"), title},     {QStringLiteral("body"), body},
                          {QStringLiteral("order"), order},     {QStringLiteral("createdAt"), at},
                          {QStringLiteral("updatedAt"), at}};
  set(mc, stream, QStringLiteral("slide"), id, slide);
  return slide;
}

// A deck with a slide for each {title, body}.
Answer makeDeck(FakeMc& mc, const QString& space, const QString& title, const QList<std::pair<QString, QString>>& specs) {
  const QString id = newId(mc, QStringLiteral("deck"));
  const QString at = stamp(mc);
  const QJsonObject deck{{QStringLiteral("id"), id},
                         {QStringLiteral("spaceId"), space},
                         {QStringLiteral("title"), title},
                         {QStringLiteral("trashedAt"), QJsonValue::Null},
                         {QStringLiteral("createdAt"), at},
                         {QStringLiteral("updatedAt"), at}};
  set(mc, streamOf(space), QStringLiteral("deck"), id, deck);
  for (const auto& [slideTitle, body] : specs) {
    makeSlide(mc, streamOf(space), id, slideTitle, body, *placeSlide(mc, streamOf(space), id, QJsonValue(QJsonValue::Undefined)));
  }
  return {{{QStringLiteral("deck"), deck}}};
}

// One line of a slide's body, for a block of the page it is made from.
QString slideLine(FakeMc& mc, const QString& space, const QJsonObject& block) {
  const QString kind = text(block, QLatin1String("kind"));
  const QString said = text(block, QLatin1String("text"));
  if (kind == QLatin1String("checklist")) return (block.value(QLatin1String("checked")).toBool() ? QStringLiteral("- [x] ") : QStringLiteral("- [ ] ")) + said;
  if (kind == QLatin1String("callout")) return QStringLiteral("> ") + said;
  if (kind == QLatin1String("subpage_link")) {
    const QJsonObject linked = one(mc, streamOf(space), QStringLiteral("page"), text(block, QLatin1String("linkedPageId")));
    if (!linked.isEmpty()) return text(linked, QLatin1String("title"));
  }
  return said;
}

Answer deckFromPage(FakeMc& mc, const QString& space, const QString& pageId) {
  if (const auto why = writable(mc, space, pageId)) return *why;
  const QString title = text(one(mc, streamOf(space), QStringLiteral("page"), pageId), QLatin1String("title"));
  QList<std::pair<QString, QStringList>> sections;
  for (const QJsonObject& block : blocksOf(mc, space, pageId)) {
    if (text(block, QLatin1String("kind")) == QLatin1String("heading")) {
      sections.append({text(block, QLatin1String("text")), {}});
      continue;
    }
    if (sections.isEmpty()) sections.append({title, {}});
    sections.last().second.append(slideLine(mc, space, block));
  }
  if (sections.isEmpty()) sections.append({title, {}});
  QList<std::pair<QString, QString>> specs;
  for (const auto& [slideTitle, lines] : sections) specs.append({slideTitle, lines.join(QLatin1Char('\n'))});
  return makeDeck(mc, space, title, specs);
}

// What a site shows of the page: its title and its blocks' text.
QJsonArray siteSnapshot(FakeMc& mc, const QString& space, const QJsonObject& page) {
  QJsonArray shown{text(page, QLatin1String("title"))};
  for (const QJsonObject& block : sortedBy(all(mc, streamOf(space), QStringLiteral("block")), QLatin1String("order"))) {
    if (text(block, QLatin1String("pageId")) == text(page, QLatin1String("id"))) shown.append(text(block, QLatin1String("text")));
  }
  return shown;
}

// The MC's side of a page's agent: its thread is a row like any other, and how its run ends
// is the scenario's.
Answer agentCall(FakeMc& mc, const QString& method, const QJsonObject& in) {
  const QString stream = streamOf(text(in, QLatin1String("spaceId")));
  const QString pageId = text(in, QLatin1String("pageId"));
  const QJsonObject asked = one(mc, stream, QStringLiteral("pageAgent"), pageId);
  const bool active = text(asked, QLatin1String("status")) == QLatin1String("running") || text(asked, QLatin1String("status")) == QLatin1String("stopping");
  if (method == QLatin1String("page.askAgent")) {
    if (std::exchange(fake(mc).refuseAsk, false)) return refused(QStringLiteral("invalid"), QStringLiteral("An agent is already working on this page."));
    QString request = text(in, QLatin1String("request")).trimmed();
    if (request.startsWith(QLatin1String("@agent"))) request = request.mid(6).trimmed();
    if (request.isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("Say what the agent should do."));
    if (active) return refused(QStringLiteral("invalid"), QStringLiteral("An agent is already working on this page."));
    const QString thread = newId(mc, QStringLiteral("agent-thread"));
    QJsonObject row = mc.threads.first();
    row.insert(QStringLiteral("id"), thread);
    row.insert(QStringLiteral("title"), QStringLiteral("Page agent"));
    mc.threads.insert(thread, row);
    mc.sendRow(thread, row);
    const QJsonObject agent{{QStringLiteral("id"), pageId},
                            {QStringLiteral("pageId"), pageId},
                            {QStringLiteral("threadId"), thread},
                            {QStringLiteral("request"), request},
                            {QStringLiteral("status"), QStringLiteral("running")},
                            {QStringLiteral("edited"), false},
                            {QStringLiteral("error"), QJsonValue::Null},
                            {QStringLiteral("startedAt"), stamp(mc)},
                            {QStringLiteral("endedAt"), QJsonValue::Null}};
    set(mc, stream, QStringLiteral("pageAgent"), pageId, agent);
    return {{{QStringLiteral("agent"), agent}}};
  }
  if (asked.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("No agent was asked on this page."));
  if (method == QLatin1String("page.stopAgent")) {
    ++fake(mc).stops;
    if (active && fake(mc).ignoresStop) set(mc, stream, QStringLiteral("pageAgent"), pageId, {{QStringLiteral("status"), QStringLiteral("stopping")}});
    else if (active) set(mc, stream, QStringLiteral("pageAgent"), pageId, {{QStringLiteral("status"), QStringLiteral("stopped")}, {QStringLiteral("endedAt"), stamp(mc)}});
    return {{{QStringLiteral("agent"), one(mc, stream, QStringLiteral("pageAgent"), pageId)}}};
  }
  if (active) return refused(QStringLiteral("invalid"), QStringLiteral("The agent is still working on this page."));
  remove(mc, stream, QStringLiteral("pageAgent"), pageId);
  return {{{QStringLiteral("pageId"), pageId}}};
}

QJsonObject siteOfPage(FakeMc& mc, const QString& space, const QString& pageId) {
  for (const QJsonObject& site : all(mc, streamOf(space), QStringLiteral("site"))) {
    if (text(site, QLatin1String("pageId")) == pageId) return site;
  }
  return {};
}

// A page's update (lib/hal_c2/space/schedule.ex). The fake has no clock to wait
// on, so a run ends within its `runNow`.
Answer schedule(FakeMc& mc, const QString& method, const QString& space, const QJsonObject& page, const QJsonObject& in) {
  const QString stream = streamOf(space);
  const QString pageId = text(page, QLatin1String("id"));
  const auto answer = [&] { return Answer{{{QStringLiteral("page"), one(mc, stream, QStringLiteral("page"), pageId)}}}; };
  const auto nextRun = [&] { return iso(now().addSecs(3600 + ++fake(mc).clock)); };
  QJsonObject shown = page.value(QLatin1String("schedule")).toObject();
  const auto show = [&](const QJsonObject& fields) {
    for (auto it = fields.begin(); it != fields.end(); ++it) shown.insert(it.key(), it.value());
    set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("schedule"), shown}});
  };
  if (method == QLatin1String("page.schedule.set")) {
    if (text(in, QLatin1String("instruction")).trimmed().isEmpty()) {
      return refused(QStringLiteral("invalid"), QStringLiteral("A page's update needs an instruction."));
    }
    show({{QStringLiteral("instruction"), text(in, QLatin1String("instruction")).trimmed()},
          {QStringLiteral("cadence"), in.value(QLatin1String("cadence"))},
          {QStringLiteral("enabled"), shown.isEmpty() || shown.value(QLatin1String("enabled")).toBool()},
          {QStringLiteral("nextRunAt"), nextRun()},
          {QStringLiteral("lastRunStatus"), shown.value(QLatin1String("lastRunStatus")).toString(QStringLiteral("never"))}});
    return answer();
  }
  if (shown.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("This page has no update."));
  if (method == QLatin1String("page.schedule.setEnabled")) {
    const bool enabled = in.value(QLatin1String("enabled")).toBool();
    show({{QStringLiteral("enabled"), enabled}, {QStringLiteral("nextRunAt"), enabled ? QJsonValue(nextRun()) : QJsonValue(QJsonValue::Null)}});
    return answer();
  }
  const QJsonObject block = generatedOf(mc, space, pageId);
  if (method == QLatin1String("page.schedule.remove")) {
    if (!block.isEmpty()) {
      const QList<QJsonObject> parsed = parseMarkdown(text(block, QLatin1String("text"))).second;
      const QJsonObject first = parsed.value(0);
      set(mc, stream, QStringLiteral("block"), text(block, QLatin1String("id")),
          {{QStringLiteral("kind"), text(first, QLatin1String("kind"))}, {QStringLiteral("text"), text(first, QLatin1String("text"))}});
    }
    set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("schedule"), QJsonValue::Null}, {QStringLiteral("writtenAt"), QJsonValue::Null}});
    return answer();
  }
  const QString at = stamp(mc);
  const QString generation = fake(mc).generation;
  if (generation != QLatin1String("available")) {
    const QString error = generation == QLatin1String("failed") ? QStringLiteral("the model is overloaded") : QStringLiteral("No text generation provider is set up.");
    show({{QStringLiteral("lastRunAt"), at}, {QStringLiteral("lastRunStatus"), QStringLiteral("failed")}, {QStringLiteral("lastRunError"), error}});
    return answer();
  }
  if (block.isEmpty()) {
    const Answer inserted = insertBlock(mc, space, pageId, {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), fake(mc).writes}},
                                        QJsonValue::Undefined, kSchedule);
    set(mc, stream, QStringLiteral("block"), text(inserted.result.value(QLatin1String("block")).toObject(), QLatin1String("id")), {{QStringLiteral("kind"), kGenerated}});
  } else {
    set(mc, stream, QStringLiteral("block"), text(block, QLatin1String("id")), {{QStringLiteral("text"), fake(mc).writes}, {QStringLiteral("updatedBy"), kSchedule}, {QStringLiteral("updatedAt"), at}});
  }
  set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("writtenAt"), at}});
  show({{QStringLiteral("lastRunAt"), at}, {QStringLiteral("lastRunStatus"), QStringLiteral("succeeded")}, {QStringLiteral("lastRunError"), QJsonValue::Null}});
  return answer();
}

Answer publishPage(FakeMc& mc, const QString& space, const QJsonObject& page, const QJsonObject& in) {
  FakeSpaces& spaces = fake(mc);
  const bool overTailscale = in.value(QLatin1String("tailscale")).toBool();
  if (overTailscale && spaces.tailnet.isEmpty()) return refused(QStringLiteral("unavailable"), QStringLiteral("Tailscale is not running on this machine."));
  const QString base = text(in, QLatin1String("baseUrl"));
  const QString address = overTailscale ? QStringLiteral("https://") + spaces.tailnet : !base.isEmpty() ? base : spaces.address;
  const bool localOnly = !overTailscale && base.isEmpty() && spaces.localOnly;
  const QJsonObject before = siteOfPage(mc, space, text(page, QLatin1String("id")));
  // Published again it keeps its token, and an address only this machine can open never replaces one others reach.
  const QString id = before.isEmpty() ? newId(mc, QStringLiteral("token")) : text(before, QLatin1String("id"));
  const bool keepsAddress = !before.isEmpty() && localOnly && !before.value(QLatin1String("localOnly")).toBool();
  const QString url = keepsAddress ? text(before, QLatin1String("url")) : QStringLiteral("%1/sites/%2/%3").arg(address, space, id);
  set(mc, streamOf(space), QStringLiteral("site"), id,
      {{QStringLiteral("id"), id}, {QStringLiteral("spaceId"), space}, {QStringLiteral("pageId"), page.value(QLatin1String("id"))},
       {QStringLiteral("url"), url}, {QStringLiteral("localOnly"), keepsAddress ? false : localOnly}, {QStringLiteral("publishedAt"), stamp(mc)},
       {QStringLiteral("behind"), false}, {QStringLiteral("snapshot"), siteSnapshot(mc, space, page)}});
  spaces.links.insert(text(page, QLatin1String("id")), url);
  return {{{QStringLiteral("site"), one(mc, streamOf(space), QStringLiteral("site"), id)}}};
}

Answer decide(FakeMc& mc, const QString& method, const QJsonObject& in);

// A change, with what it means for the Space's sites: the site of a page gone or
// in the trash comes down, and the others are behind when publishing would change them.
Answer call(FakeMc& mc, const QString& method, const QJsonObject& in) {
  if (method.endsWith(QLatin1String("Agent"))) return agentCall(mc, method, in);
  const bool history = method == QLatin1String("page.history") || method == QLatin1String("page.version") || method == QLatin1String("page.restoreVersion");
  const Answer answer = history ? historyCall(mc, method, in) : decide(mc, method, in);
  const QString space = text(in, QLatin1String("spaceId"));
  if (space.isEmpty()) return answer;
  const bool fromFile = method == QLatin1String("page.openFile") || method == QLatin1String("page.syncFile");
  if (!history && answer.error.isEmpty()) {
    noteEdits(mc, space, method == QLatin1String("page.schedule.runNow") ? kSchedule : fromFile ? kFile : kUser);
  }
  const QString stream = streamOf(space);
  for (const QJsonObject& site : all(mc, stream, QStringLiteral("site"))) {
    const QJsonObject page = one(mc, stream, QStringLiteral("page"), text(site, QLatin1String("pageId")));
    const QString id = text(site, QLatin1String("id"));
    if (page.isEmpty() || !live(mc, space, page)) {
      remove(mc, stream, QStringLiteral("site"), id);
      continue;
    }
    const bool behind = siteSnapshot(mc, space, page) != site.value(QLatin1String("snapshot")).toArray();
    if (behind != site.value(QLatin1String("behind")).toBool()) set(mc, stream, QStringLiteral("site"), id, {{QStringLiteral("behind"), behind}});
  }
  return answer;
}

Answer decide(FakeMc& mc, const QString& method, const QJsonObject& in) {
  const QString space = text(in, QLatin1String("spaceId"));
  const QString stream = streamOf(space);
  const QString pageId = text(in, QLatin1String("pageId"));
  const QString blockId = text(in, QLatin1String("blockId"));
  const auto blank = [](const QJsonValue& value) { return value.toString().trimmed().isEmpty(); };

  if (method == QLatin1String("list")) {
    seed(mc);
    QJsonArray spaces;
    for (const QJsonObject& row : sortedBy(all(mc, kIndex, QStringLiteral("space")), QLatin1String("createdAt"))) spaces.append(row);
    return {{{QStringLiteral("spaces"), spaces}}};
  }
  if (method == QLatin1String("create")) {
    if (blank(in.value(QLatin1String("name")))) return refused(QStringLiteral("invalid"), QStringLiteral("A Space needs a name."));
    seed(mc);
    return {{{QStringLiteral("space"), makeSpace(mc, text(in, QLatin1String("name")).trimmed())}}};
  }
  if (method == QLatin1String("image.providers")) {
    const auto provider = [](const char* id, const char* status, const QString& message) {
      return QJsonObject{{QStringLiteral("instanceId"), QLatin1String(id)}, {QStringLiteral("driver"), QLatin1String(id)}, {QStringLiteral("status"), QLatin1String(status)}, {QStringLiteral("message"), message}};
    };
    const bool able = fake(mc).imageGeneration == QLatin1String("available");
    return {{{QStringLiteral("providers"), QJsonArray{provider("codex", able ? "ready" : "unavailable", {}), provider("claudeAgent", "unsupported", QStringLiteral("Claude does not generate images here."))}},
             {QStringLiteral("selection"), able ? QJsonValue(QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}) : QJsonValue(QJsonValue::Null)}}};
  }
  if (method.startsWith(QLatin1String("files."))) return filesCall(mc, method, in);
  if (spaceOf(mc, space).isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no Space %1.").arg(space));
  if (method.startsWith(QLatin1String("image."))) return imageCall(mc, space, method, in);
  if (method == QLatin1String("page.openFile")) return openFile(mc, space, in);
  if (method == QLatin1String("rename")) {
    if (blank(in.value(QLatin1String("name")))) return refused(QStringLiteral("invalid"), QStringLiteral("A Space needs a name."));
    set(mc, kIndex, QStringLiteral("space"), space, {{QStringLiteral("name"), text(in, QLatin1String("name")).trimmed()}, {QStringLiteral("updatedAt"), stamp(mc)}});
    return {{{QStringLiteral("space"), spaceOf(mc, space)}}};
  }
  if (method == QLatin1String("delete")) {
    if (!all(mc, stream, QStringLiteral("page")).isEmpty() || !all(mc, stream, QStringLiteral("deck")).isEmpty() ||
        !all(mc, stream, QStringLiteral("image")).isEmpty()) {
      return refused(QStringLiteral("notEmpty"), QStringLiteral("A Space with pages, decks or images cannot be deleted; delete them first."));
    }
    remove(mc, kIndex, QStringLiteral("space"), space);
    return {{{QStringLiteral("spaceId"), space}}};
  }
  if (method == QLatin1String("page.create")) return createPage(mc, space, text(in, QLatin1String("title")), in.value(QLatin1String("parentPageId")));
  if (method == QLatin1String("page.importMarkdown")) {
    return importMarkdown(mc, space, text(in, QLatin1String("markdown")), text(in, QLatin1String("title")), in.value(QLatin1String("parentPageId")), {}, kUser);
  }
  if (method == QLatin1String("page.createFromThread")) {
    const QString threadId = text(in, QLatin1String("threadId"));
    const QJsonObject thread = mc.threads.value(threadId);
    QString root = text(thread, QLatin1String("worktreePath"));
    if (root.isEmpty()) root = text(mc.projects.value(text(thread, QLatin1String("projectId"))), QLatin1String("workspaceRoot"));
    if (thread.isEmpty() || root.isEmpty()) {
      return refused(QStringLiteral("notFound"), QStringLiteral("There is no thread %1 with a project folder on this MC.").arg(threadId));
    }
    if (!fake(mc).talked.contains(threadId)) return refused(QStringLiteral("invalid"), QStringLiteral("The thread has nothing to summarise yet."));
    fake(mc).cwd = root;
    fake(mc).summarised = threadId;
    const QString tag = QStringLiteral("SpaceTextGenerationError");
    if (fake(mc).generation == QLatin1String("unavailable")) return refused(QStringLiteral("unavailable"), QStringLiteral("No text generation provider is set up."), tag);
    if (fake(mc).generation == QLatin1String("failed")) return refused(QStringLiteral("failed"), QStringLiteral("The provider stopped answering."), tag);
    return importMarkdown(mc, space, QStringLiteral("# %1\n\n%2\n").arg(kSummaryTitle, kSummary), kSummaryTitle, in.value(QLatin1String("parentPageId")),
                          {{QStringLiteral("sourceThreadId"), threadId}}, agent(threadId));
  }

  if (method.startsWith(QLatin1String("page."))) {
    const QJsonObject page = one(mc, stream, QStringLiteral("page"), pageId);
    if (page.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no page %1.").arg(pageId));
    const auto answer = [&] { return Answer{{{QStringLiteral("page"), one(mc, stream, QStringLiteral("page"), pageId)}}}; };
    if (method == QLatin1String("page.exportMarkdown")) return {{{QStringLiteral("markdown"), exportMarkdown(mc, space, page)}}};
    if (method == QLatin1String("page.syncFile")) return syncFile(mc, space, page);
    if (method == QLatin1String("page.unlinkFile")) {
      set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("file"), QJsonValue::Null}, {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.restore")) {
      if (!trashed(page)) return refused(QStringLiteral("invalid"), QStringLiteral("The page is not in the trash."));
      // Back where it was, unless that page is gone or in the trash itself.
      const QJsonObject parent = one(mc, stream, QStringLiteral("page"), text(page, QLatin1String("parentPageId")));
      const bool keep = !parent.isEmpty() && live(mc, space, parent);
      set(mc, stream, QStringLiteral("page"), pageId,
          {{QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("parentPageId"), keep ? page.value(QLatin1String("parentPageId")) : QJsonValue::Null},
           {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.delete")) {
      if (!trashed(page)) return refused(QStringLiteral("invalid"), QStringLiteral("Only a page in the trash can be deleted for good."));
      const QStringList gone = within(mc, space, pageId);
      for (const QJsonObject& comment : all(mc, stream, QStringLiteral("comment"))) {
        if (gone.contains(text(comment, QLatin1String("pageId")))) remove(mc, stream, QStringLiteral("comment"), text(comment, QLatin1String("id")));
      }
      for (const QJsonObject& block : all(mc, stream, QStringLiteral("block"))) {
        if (gone.contains(text(block, QLatin1String("pageId"))) || gone.contains(text(block, QLatin1String("linkedPageId")))) {
          remove(mc, stream, QStringLiteral("block"), text(block, QLatin1String("id")));
        }
      }
      for (const QString& id : gone) remove(mc, stream, QStringLiteral("page"), id);
      return {{{QStringLiteral("deletedPageIds"), QJsonArray::fromStringList(gone)}}};
    }
    if (method == QLatin1String("page.unpublish")) {
      const QJsonObject site = siteOfPage(mc, space, pageId);
      if (!site.isEmpty()) remove(mc, stream, QStringLiteral("site"), text(site, QLatin1String("id")));
      return {{{QStringLiteral("pageId"), pageId}}};
    }
    if (!live(mc, space, page)) return refused(QStringLiteral("trashed"), QStringLiteral("The page is in the trash."));
    if (method == QLatin1String("page.publish")) return publishPage(mc, space, page, in);
    if (method == QLatin1String("page.rename")) {
      if (blank(in.value(QLatin1String("title")))) return refused(QStringLiteral("invalid"), QStringLiteral("A page needs a title."));
      set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("title"), text(in, QLatin1String("title")).trimmed()}, {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.move")) {
      const QJsonValue parent = in.value(QLatin1String("parentPageId"));
      if (parent.isString()) {
        if (within(mc, space, pageId).contains(parent.toString())) return refused(QStringLiteral("cycle"), QStringLiteral("A page cannot move inside itself."));
        if (const auto why = writable(mc, space, parent.toString())) return *why;
      }
      set(mc, stream, QStringLiteral("page"), pageId,
          {{QStringLiteral("parentPageId"), parent.isString() ? parent : QJsonValue(QJsonValue::Null)}, {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method.startsWith(QLatin1String("page.schedule."))) return schedule(mc, method, space, page, in);
    if (method == QLatin1String("page.trash")) {
      const QString at = stamp(mc);
      set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("trashedAt"), at}, {QStringLiteral("updatedAt"), at}});
      return answer();
    }
  }

  if (method == QLatin1String("block.insert")) {
    return insertBlock(mc, space, pageId, in, in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined, kUser);
  }
  if (method == QLatin1String("block.visualize")) {
    if (const auto why = writable(mc, space, pageId)) return *why;
    const QString tag = QStringLiteral("SpaceChartError");
    const QJsonObject chart = fake(mc).chart;
    if (fake(mc).generation == QLatin1String("unavailable")) return refused(QStringLiteral("unavailable"), QStringLiteral("No chart was drawn: no text generation provider is set up."), tag);
    if (fake(mc).generation == QLatin1String("failed")) return refused(QStringLiteral("failed"), QStringLiteral("No chart was drawn: the provider stopped answering."), tag);
    if (chart.isEmpty()) return refused(QStringLiteral("unanswerable"), QStringLiteral("No chart was drawn: the page and this MC's threads cannot answer that."), tag);
    const QString summary = QStringLiteral("%1 (a chart; %2)").arg(text(chart, QLatin1String("title")), text(chart, QLatin1String("source")));
    const QJsonObject fields{{QStringLiteral("kind"), QStringLiteral("chart")}, {QStringLiteral("text"), summary}, {QStringLiteral("chart"), chart}};
    QString id = blockId;
    if (id.isEmpty()) {
      const QJsonValue after = in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined;
      const Answer made = insertBlock(mc, space, pageId, {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), summary}}, after, kUser);
      if (!made.error.isEmpty()) return made;
      id = text(made.result.value(QLatin1String("block")).toObject(), QLatin1String("id"));
    } else if (text(one(mc, stream, QStringLiteral("block"), id), QLatin1String("kind")) != QLatin1String("chart")) {
      return refused(QStringLiteral("invalid"), QStringLiteral("Only a chart can be asked for again."));
    }
    set(mc, stream, QStringLiteral("block"), id, fields);
    return {{{QStringLiteral("block"), one(mc, stream, QStringLiteral("block"), id)}}};
  }
  if (method.startsWith(QLatin1String("block."))) {
    const QJsonObject block = one(mc, stream, QStringLiteral("block"), blockId);
    if (block.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1.").arg(blockId));
    if (const auto why = writable(mc, space, text(block, QLatin1String("pageId")))) return *why;
    const auto write = [&](QJsonObject fields) {
      fields.insert(QStringLiteral("updatedBy"), kUser);
      fields.insert(QStringLiteral("updatedAt"), stamp(mc));
      set(mc, stream, QStringLiteral("block"), blockId, fields);
      return Answer{{{QStringLiteral("block"), one(mc, stream, QStringLiteral("block"), blockId)}}};
    };
    if (method == QLatin1String("block.update")) {
      if (text(block, QLatin1String("kind")) == kGenerated) {
        return refused(QStringLiteral("invalid"), QStringLiteral("What a page's update wrote cannot be edited by hand."));
      }
      return write({{QStringLiteral("text"), in.value(QLatin1String("text"))}});
    }
    if (method == QLatin1String("block.setChecked")) {
      if (text(block, QLatin1String("kind")) != QLatin1String("checklist")) {
        return refused(QStringLiteral("invalid"), QStringLiteral("Only a checklist item can be ticked."));
      }
      return write({{QStringLiteral("checked"), in.value(QLatin1String("checked")).toBool()}});
    }
    if (method == QLatin1String("block.move")) {
      const QJsonValue after = in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined;
      const std::optional<QString> order = place(mc, space, text(block, QLatin1String("pageId")), after, blockId);
      if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(after.toString()));
      return write({{QStringLiteral("order"), *order}});
    }
    if (method == QLatin1String("block.delete")) {
      for (const QJsonObject& comment : all(mc, stream, QStringLiteral("comment"))) {
        if (text(comment, QLatin1String("blockId")) == blockId) remove(mc, stream, QStringLiteral("comment"), text(comment, QLatin1String("id")));
      }
      remove(mc, stream, QStringLiteral("block"), blockId);
      return {{{QStringLiteral("blockId"), blockId}}};
    }
  }

  if (method == QLatin1String("comment.add")) {
    if (const auto why = writable(mc, space, pageId)) return *why;
    if (blank(in.value(QLatin1String("body")))) return refused(QStringLiteral("invalid"), QStringLiteral("A comment needs a body."));
    if (!blockId.isEmpty() && text(one(mc, stream, QStringLiteral("block"), blockId), QLatin1String("pageId")) != pageId) {
      return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(blockId));
    }
    const QString id = newId(mc, QStringLiteral("comment"));
    const QString at = stamp(mc);
    const QJsonObject comment{{QStringLiteral("id"), id},
                              {QStringLiteral("pageId"), pageId},
                              {QStringLiteral("blockId"), blockId.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(blockId)},
                              {QStringLiteral("author"), kUser},
                              {QStringLiteral("body"), text(in, QLatin1String("body")).trimmed()},
                              {QStringLiteral("resolvedAt"), QJsonValue::Null},
                              {QStringLiteral("createdAt"), at},
                              {QStringLiteral("updatedAt"), at}};
    set(mc, stream, QStringLiteral("comment"), id, comment);
    return {{{QStringLiteral("comment"), comment}}};
  }
  if (method == QLatin1String("comment.resolve") || method == QLatin1String("comment.reopen")) {
    const QString id = text(in, QLatin1String("commentId"));
    const QJsonObject comment = one(mc, stream, QStringLiteral("comment"), id);
    if (comment.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no comment %1.").arg(id));
    const bool resolve = method == QLatin1String("comment.resolve");
    // Already so: nothing changes.
    if (resolve == !comment.value(QLatin1String("resolvedAt")).isNull()) return {{{QStringLiteral("comment"), comment}}};
    const QString at = stamp(mc);
    set(mc, stream, QStringLiteral("comment"), id, {{QStringLiteral("resolvedAt"), resolve ? QJsonValue(at) : QJsonValue(QJsonValue::Null)}, {QStringLiteral("updatedAt"), at}});
    return {{{QStringLiteral("comment"), one(mc, stream, QStringLiteral("comment"), id)}}};
  }
  if (method.startsWith(QLatin1String("deck."))) {
    const QString deckId = text(in, QLatin1String("deckId"));
    const QJsonObject deck = one(mc, stream, QStringLiteral("deck"), deckId);
    const QString title = text(deck, QLatin1String("title"));
    const QString at = stamp(mc);
    const auto updated = [&](const QJsonObject& fields) {
      QJsonObject change = fields;
      change.insert(QStringLiteral("updatedAt"), at);
      set(mc, stream, QStringLiteral("deck"), deckId, change);
      return Answer{{{QStringLiteral("deck"), one(mc, stream, QStringLiteral("deck"), deckId)}}};
    };
    if (method == QLatin1String("deck.create")) {
      if (blank(in.value(QLatin1String("title")))) return refused(QStringLiteral("invalid"), QStringLiteral("A deck needs a title."));
      return makeDeck(mc, space, text(in, QLatin1String("title")).trimmed(), {{QString(), QString()}});
    }
    if (method == QLatin1String("deck.createFromPage")) return deckFromPage(mc, space, pageId);
    if (method == QLatin1String("deck.rename")) {
      if (const auto why = deckRefusal(mc, stream, deckId)) return *why;
      if (blank(in.value(QLatin1String("title")))) return refused(QStringLiteral("invalid"), QStringLiteral("A deck needs a title."));
      return updated({{QStringLiteral("title"), text(in, QLatin1String("title")).trimmed()}});
    }
    if (method == QLatin1String("deck.trash")) {
      if (const auto why = deckRefusal(mc, stream, deckId)) return *why;
      return updated({{QStringLiteral("trashedAt"), at}});
    }
    if (deck.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no deck %1 in this Space.").arg(deckId));
    if (method == QLatin1String("deck.restore")) {
      if (!trashed(deck)) return refused(QStringLiteral("invalid"), QStringLiteral("The deck \"%1\" is not in the trash.").arg(title));
      return updated({{QStringLiteral("trashedAt"), QJsonValue::Null}});
    }
    if (method == QLatin1String("deck.delete")) {
      if (!trashed(deck)) return refused(QStringLiteral("invalid"), QStringLiteral("Only a deck in the trash can be deleted; move \"%1\" there first.").arg(title));
      for (const QJsonObject& slide : slidesOf(mc, stream, deckId)) remove(mc, stream, QStringLiteral("slide"), text(slide, QLatin1String("id")));
      remove(mc, stream, QStringLiteral("deck"), deckId);
      return {{{QStringLiteral("deckId"), deckId}}};
    }
  }
  if (method == QLatin1String("slide.insert")) {
    const QString deckId = text(in, QLatin1String("deckId"));
    if (const auto why = deckRefusal(mc, stream, deckId)) return *why;
    const auto order = placeSlide(mc, stream, deckId, in.contains(QLatin1String("afterSlideId")) ? in.value(QLatin1String("afterSlideId")) : QJsonValue(QJsonValue::Undefined));
    if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no slide %1 in this deck.").arg(text(in, QLatin1String("afterSlideId"))));
    return {{{QStringLiteral("slide"), makeSlide(mc, stream, deckId, text(in, QLatin1String("title")), text(in, QLatin1String("body")), *order)}}};
  }
  if (method.startsWith(QLatin1String("slide."))) {
    const QString slideId = text(in, QLatin1String("slideId"));
    const QJsonObject slide = one(mc, stream, QStringLiteral("slide"), slideId);
    if (slide.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no slide %1 in this Space.").arg(slideId));
    const QString deckId = text(slide, QLatin1String("deckId"));
    if (const auto why = deckRefusal(mc, stream, deckId)) return *why;
    if (method == QLatin1String("slide.delete")) {
      remove(mc, stream, QStringLiteral("slide"), slideId);
      return {{{QStringLiteral("slideId"), slideId}}};
    }
    QJsonObject change{{QStringLiteral("updatedAt"), stamp(mc)}};
    if (method == QLatin1String("slide.update")) {
      for (const QLatin1String field : {QLatin1String("title"), QLatin1String("body")}) {
        if (in.contains(field)) change.insert(field, in.value(field));
      }
    } else if (method == QLatin1String("slide.move")) {
      const auto order = placeSlide(mc, stream, deckId, in.contains(QLatin1String("afterSlideId")) ? in.value(QLatin1String("afterSlideId")) : QJsonValue(QJsonValue::Undefined), slideId);
      if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no slide %1 in this deck.").arg(text(in, QLatin1String("afterSlideId"))));
      change.insert(QStringLiteral("order"), *order);
    }
    set(mc, stream, QStringLiteral("slide"), slideId, change);
    return {{{QStringLiteral("slide"), one(mc, stream, QStringLiteral("slide"), slideId)}}};
  }
  return refused(QStringLiteral("invalid"), QStringLiteral("space.%1 is missing a required field.").arg(method));
}

// The `spacePresence` frame of `page` for the subscription `id`.
QJsonObject viewersFrame(FakeMc& mc, int id, const QString& page) {
  QJsonArray viewers;
  QStringList devices = fake(mc).devices.value(page);
  devices.sort();
  if (!devices.isEmpty()) viewers.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("user")}, {QStringLiteral("devices"), QJsonArray::fromStringList(devices)}});
  for (const QString& title : fake(mc).agents.value(page)) {
    viewers.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("agent")}, {QStringLiteral("threadId"), QStringLiteral("thread-") + title}, {QStringLiteral("title"), title}});
  }
  return {{QStringLiteral("t"), QStringLiteral("spacePresence")}, {QStringLiteral("id"), id}, {QStringLiteral("viewers"), viewers}};
}

// The MC cannot say who is on a page: it answers an error and keeps nothing.
void refuseViewers(FakeMc& mc, int id) {
  deliver(mc, QJsonObject{{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("MC unavailable: noconnection")}});
  mc.forget(id);
}

// Whoever has `page` open hears who is on it now.
void tellViewers(FakeMc& mc, const QString& page) {
  for (const int id : mc.subscribers(QStringLiteral("spacePresence"))) {
    if (mc.shapeOf(id).value(QLatin1String("pageId")).toString() == page) deliver(mc, viewersFrame(mc, id, page));
  }
}

const FakeMc::Extension spaceCalls([](FakeMc& mc) {
  mc.onShape(QStringLiteral("spacePresence"), [&mc](int id, const QJsonObject& shape) {
    if (fake(mc).viewersRefused) return refuseViewers(mc, id);
    deliver(mc, viewersFrame(mc, id, shape.value(QLatin1String("pageId")).toString()));
  });
  mc.onRpc(QStringLiteral("space."), [&mc](const FakeMc::Rpc& rpc) {
    const Answer answer = call(mc, rpc.method.mid(6), rpc.payload);
    fake(mc).lastMethod = rpc.method;
    fake(mc).last = answer;
    if (answer.error.isEmpty()) {
      mc.reply(rpc, answer.result);
    } else {
      mc.refuse(rpc, answer.error, answer.detail);
    }
  });
});

// --- The scenario's Spaces, pages and blocks, by name ------------------------

// Something the scenario made, kept by what the user calls it.
void name(World& world, const QString& kind, const QString& said, const QString& id) {
  fake(world.mc).named.insert(kind + QLatin1Char('\n') + said, id);
}

QString idOfSpace(World& world, const QString& name) {
  for (const QJsonObject& space : all(world.mc, kIndex, QStringLiteral("space"))) {
    if (text(space, QLatin1String("name")) == name) return text(space, QLatin1String("id"));
  }
  fail(QStringLiteral("the MC has no Space %1").arg(name));
}

QString current(World& world) {
  const QString space = fake(world.mc).current;
  expect(!space.isEmpty(), QStringLiteral("no Space was made for the scenario"));
  return space;
}

// The page `title` of the scenario's Space, or "" when there is none.
QString findPage(World& world, const QString& title) {
  for (const QJsonObject& page : all(world.mc, streamOf(current(world)), QStringLiteral("page"))) {
    if (text(page, QLatin1String("title")) == title) return text(page, QLatin1String("id"));
  }
  return {};
}

QString idOfPage(World& world, const QString& title) {
  const QString id = findPage(world, title);
  expect(!id.isEmpty(), QStringLiteral("the Space has no page %1").arg(title));
  return id;
}

QJsonObject findBlock(World& world, const QString& said) {
  for (const QJsonObject& block : all(world.mc, streamOf(current(world)), QStringLiteral("block"))) {
    if (text(block, QLatin1String("text")) == said) return block;
  }
  return {};
}

QJsonObject blockSaying(World& world, const QString& said) {
  const QJsonObject block = findBlock(world, said);
  expect(!block.isEmpty(), QStringLiteral("the Space has no block %1").arg(said));
  return block;
}

QString idOfComment(World& world, const QString& body) {
  for (const QJsonObject& comment : all(world.mc, streamOf(current(world)), QStringLiteral("comment"))) {
    if (text(comment, QLatin1String("body")) == body) return text(comment, QLatin1String("id"));
  }
  fail(QStringLiteral("the Space has no comment %1").arg(body));
}

// What the MC is told by the scenario's setting up, as a client would ask it.
QJsonObject given(World& world, const QString& method, QJsonObject in) {
  if (method != QLatin1String("create") && !in.contains(QLatin1String("spaceId"))) in.insert(QStringLiteral("spaceId"), current(world));
  const Answer answer = call(world.mc, method, in);
  expect(answer.error.isEmpty(), QStringLiteral("the MC refused space.%1: %2").arg(method, answer.error));
  world.sync();
  return answer.result;
}

void givenSpace(World& world, const QString& name) {
  const QJsonObject space = given(world, QStringLiteral("create"), {{QStringLiteral("name"), name}}).value(QLatin1String("space")).toObject();
  fake(world.mc).current = text(space, QLatin1String("id"));
}

QString givenPage(World& world, const QString& title, const QString& parent = {}) {
  if (const QString id = findPage(world, title); !id.isEmpty()) return id;
  const QJsonObject page = given(world, QStringLiteral("page.create"),
                                 {{QStringLiteral("title"), title}, {QStringLiteral("parentPageId"), parent.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(parent)}})
                               .value(QLatin1String("page"))
                               .toObject();
  name(world, QStringLiteral("page"), title, text(page, QLatin1String("id")));
  return text(page, QLatin1String("id"));
}

void givenBlock(World& world, const QString& page, const QString& kind, const QString& said, bool checked = false) {
  given(world, QStringLiteral("block.insert"),
        {{QStringLiteral("pageId"), givenPage(world, page)}, {QStringLiteral("kind"), kind}, {QStringLiteral("text"), said}, {QStringLiteral("checked"), checked}});
}

QStringList listed(const QString& names) {
  return names.isEmpty() ? QStringList() : names.split(QStringLiteral(", "));
}

QString threadNamed(World& world, const QString& title) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it->value(QLatin1String("title")).toString() == title) return it.key();
  }
  fail(QStringLiteral("the MC has no thread %1").arg(title));
}

// --- The client -------------------------------------------------------------

SpaceController* viewOf(World& world) {
  auto* controller = world.native().controller<SpaceController>();
  if (!controller) fail(QStringLiteral("the shell has no SpaceController"));
  return controller;
}

QStringList column(const SpaceRows* rows, const QString& role) {
  QStringList values;
  for (const QVariantMap& row : rows->rows()) values.append(row.value(role).toString());
  return values;
}

QVariantList listOf(const SpaceRows* rows) {
  QVariantList list;
  for (const QVariantMap& row : rows->rows()) list.append(row);
  return list;
}

QVariantList tableOf(const Table& table) {
  QVariantList list;
  for (const QStringList& row : table) list.append(row);
  return list;
}

QString describe(World& world) {
  SpaceController* view = viewOf(world);
  return QStringLiteral("the Space view shows %1 (%2): spaces %3, pages %4, trash %5, blocks %6, comments %7; it says %8; also here %9")
      .arg(view->spaceName(), view->status(), show(column(view->spaces(), QStringLiteral("name"))), show(column(view->pages(), QStringLiteral("title"))),
           show(column(view->trash(), QStringLiteral("title"))), show(listOf(view->blocks())),
           show(listOf(view->comments())), show(world.state(QStringLiteral("space"))), show(view->viewers()));
}

// The Space view, open and following the MC's Spaces.
void openSpaces(World& world) {
  if (world.shellSubscriptions() == 0) world.connect();
  if (world.native().controller<NavigationController>()->route().kind != QLatin1String("space")) {
    world.bridge().dispatch(SpaceController::kOpen, QVariantMap{});
  }
  world.waitFor([&] { return viewOf(world)->index().live() && viewOf(world)->spaces()->rowCount() > 0; },
                [&] { return QStringLiteral("the Space view to follow the Spaces; %1").arg(describe(world)); });
}

// The Space `id`, shown and followed.
void look(World& world, const QString& id) {
  openSpaces(world);
  world.waitFor([&] { return viewOf(world)->spaces()->indexOf(id) >= 0; }, [&] { return QStringLiteral("the Space to be listed; %1").arg(describe(world)); });
  if (viewOf(world)->spaceId() != id) world.bridge().dispatch(QStringLiteral("space.select"), QVariantMap{{QStringLiteral("spaceId"), id}});
  world.waitFor([&] { return viewOf(world)->spaceId() == id && viewOf(world)->space().live(); },
                [&] { return QStringLiteral("the Space to be followed; %1").arg(describe(world)); });
}

// The page `id` of the scenario's Space, open.
void lookAtPage(World& world, const QString& id) {
  look(world, current(world));
  world.waitFor([&] { return viewOf(world)->space().of(QStringLiteral("page")).contains(id); },
                [&] { return QStringLiteral("the Space's copy to hold the page; %1").arg(describe(world)); });
  if (viewOf(world)->pageId() != id || !viewOf(world)->deckId().isEmpty()) {
    world.bridge().dispatch(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), id}});
  }
  world.waitFor([&] { return viewOf(world)->pageId() == id && viewOf(world)->deckId().isEmpty(); },
                [&] { return QStringLiteral("the page to open; %1").arg(describe(world)); });
}

// The user does `action` on the Space view, and it has the MC's answer.
void act(World& world, const QString& action, const QVariantMap& payload) {
  world.bridge().dispatch(action, payload);
  world.sync();
}

void actOnPage(World& world, const QString& pageId, const QString& action, QVariantMap payload) {
  lookAtPage(world, pageId);
  payload.insert(QStringLiteral("pageId"), pageId);
  act(world, action, payload);
}

void actOnBlock(World& world, const QString& said, const QString& action, QVariantMap payload) {
  const QJsonObject block = blockSaying(world, said);
  lookAtPage(world, text(block, QLatin1String("pageId")));
  payload.insert(QStringLiteral("blockId"), text(block, QLatin1String("id")));
  act(world, action, payload);
}

// The diagram a page holds, as its block's text is now.
struct Diagram {
  QString source;
};

// The item named `objectName` in `item`'s tree (a ListView's delegates are only its items' children).
QQuickItem* findEditor(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = findEditor(child, objectName)) return found;
  }
  return nullptr;
}

void expectShown(World& world, const std::function<bool()>& shown, const QString& wanted) {
  world.waitFor(shown, [&] { return QStringLiteral("%1; %2").arg(wanted, describe(world)); });
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

// The history asked for has come.
QJsonObject askedOn(World& world, const QString& title) {
  return one(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), idOfPage(world, title));
}

// That the page `title`, open, says of its agent what `says` wants.
void expectAgent(World& world, const QString& title, const std::function<bool(const QVariantMap&)>& says, const QString& wanted) {
  lookAtPage(world, idOfPage(world, title));
  expectShown(world, [&] { return says(viewOf(world)->agent()); }, QStringLiteral("the page's agent to be %1, it says %2").arg(wanted, show(viewOf(world)->agent())));
}

void settleHistory(World& world) {
  world.waitFor([&] { return !viewOf(world)->history()->loading(); }, [&] { return QStringLiteral("the history to come; %1").arg(describe(world)); });
}

// The history of the page `id`, open beside it.
void showHistory(World& world, const QString& id) {
  lookAtPage(world, id);
  if (viewOf(world)->history()->pageId() != id) act(world, SpaceController::kHistory, {{QStringLiteral("pageId"), id}});
  settleHistory(world);
}

// The version `back` versions before the newest of the page `title`.
QVariant versionBack(World& world, const QString& title, int back) {
  showHistory(world, idOfPage(world, title));
  SpaceRows* versions = viewOf(world)->history()->versions();
  world.waitFor([&] { return versions->rowCount() > back; }, [&] { return QStringLiteral("%1 versions; %2").arg(back + 1).arg(show(listOf(versions))); });
  return versions->get(back).value(QStringLiteral("version"));
}

void readVersion(World& world, const QVariant& version) {
  act(world, QStringLiteral("space.history.read"), {{QStringLiteral("version"), version}});
  world.waitFor([&] { return !viewOf(world)->history()->version().isEmpty(); }, [&] { return QStringLiteral("the version to come; %1").arg(describe(world)); });
}

bool toldOf(World& world, const QString& start) {
  for (const QVariant& toast : toasts(world)) {
    if (toast.toMap().value(QStringLiteral("title")).toString().startsWith(start)) return true;
  }
  return false;
}

// What the blocks of the open page say, in their order.
QStringList blockTexts(World& world) {
  return column(viewOf(world)->blocks(), QStringLiteral("text"));
}

// The rows of a page's blocks, as the feature's tables write them.
Table blockTable(World& world) {
  Table rows;
  for (const QVariantMap& block : viewOf(world)->blocks()->rows()) {
    const bool item = block.value(QStringLiteral("kind")) == QLatin1String("checklist");
    rows.append({block.value(QStringLiteral("kind")).toString(), block.value(QStringLiteral("text")).toString(),
                 item ? (block.value(QStringLiteral("checked")).toBool() ? QStringLiteral("yes") : QStringLiteral("no")) : QString()});
  }
  return rows;
}

// A cadence as the update dialog and the MC write it.
QJsonObject everyHours(const QString& hours) {
  return {{QStringLiteral("type"), QStringLiteral("interval")}, {QStringLiteral("everyMs"), hours.toDouble() * 3600000.0}};
}

QJsonObject everyDayAt(const QString& time) {
  return {{QStringLiteral("type"), QStringLiteral("fixed_time")}, {QStringLiteral("timeOfDay"), time}, {QStringLiteral("weekdays"), QJsonArray()}};
}

void setUpdate(World& world, const QString& page, const QString& instruction, const QJsonObject& cadence) {
  actOnPage(world, idOfPage(world, page), QStringLiteral("space.page.schedule.set"),
            {{QStringLiteral("instruction"), instruction}, {QStringLiteral("cadence"), cadence.toVariantMap()}});
}

void givenUpdate(World& world, const QString& page, const QJsonObject& rest, const QString& method) {
  QJsonObject in = rest;
  in.insert(QStringLiteral("pageId"), idOfPage(world, page));
  given(world, method, in);
}

// `shown` holds of the page's update, as the page shows it, in time.
void expectUpdate(World& world, const QString& page, const std::function<bool(const QVariantMap& schedule, const QVariantMap& page)>& shown, const QString& wanted) {
  lookAtPage(world, idOfPage(world, page));
  world.waitFor([&] {
    const QVariantMap open = viewOf(world)->page();
    return shown(open.value(QStringLiteral("schedule")).toMap(), open);
  }, [&] { return QStringLiteral("%1 to show %2; the page is %3").arg(page, wanted, show(viewOf(world)->page())); });
}

// What the open page's generated part says, when it has one.
std::optional<QString> generatedText(World& world) {
  for (const QVariantMap& block : viewOf(world)->blocks()->rows()) {
    if (block.value(QStringLiteral("kind")) == kGenerated) return block.value(QStringLiteral("text")).toString();
  }
  return std::nullopt;
}

std::optional<QVariantMap> rowOf(const SpaceRows* rows, const QString& id) {
  const int row = rows->indexOf(id);
  if (row < 0) return std::nullopt;
  return rows->get(row);
}

// Another client of the MC following the Spaces, and the Space `id` when set.
const QString kFromThisPage = QStringLiteral("Numbers from this page");

// A chart with one series, as the MC stores it.
QJsonObject chartOf(const QString& type, const QString& title, const QString& source, const QList<std::pair<QString, int>>& points) {
  QJsonArray labels;
  QJsonArray values;
  for (const auto& [label, value] : points) {
    labels.append(label);
    values.append(value);
  }
  return {{QStringLiteral("type"), type},
          {QStringLiteral("title"), title},
          {QStringLiteral("labels"), labels},
          {QStringLiteral("series"), QJsonArray{QJsonObject{{QStringLiteral("name"), title}, {QStringLiteral("values"), values}}}},
          {QStringLiteral("request"), QStringLiteral("signups")},
          {QStringLiteral("source"), source}};
}

void givenChart(World& world, const QString& page, const QString& first, int a, const QString& next, int b) {
  FakeSpaces& spaces = fake(world.mc);
  spaces.asked = givenPage(world, page);
  spaces.chart = chartOf(QStringLiteral("bar"), QStringLiteral("Signups"), kFromThisPage, {{first, a}, {next, b}});
  given(world, QStringLiteral("block.visualize"), {{QStringLiteral("pageId"), spaces.asked}, {QStringLiteral("request"), QStringLiteral("/visualize signups")}});
  spaces.chart = {};
}

// The same page with a chart missing a number, which the MC would refuse.
void givenUnmatchedChart(World& world, const QString& page) {
  FakeSpaces& spaces = fake(world.mc);
  spaces.asked = givenPage(world, page);
  spaces.chart = chartOf(QStringLiteral("bar"), QStringLiteral("Signups"), kFromThisPage, {{QStringLiteral("May"), 3}, {QStringLiteral("June"), 5}});
  spaces.chart[QStringLiteral("series")] = QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("Signups")}, {QStringLiteral("values"), QJsonArray{3}}}};
  given(world, QStringLiteral("block.visualize"), {{QStringLiteral("pageId"), spaces.asked}, {QStringLiteral("request"), QStringLiteral("/visualize signups")}});
  spaces.chart = {};
}

// The chart row the open page shows, or none.
QVariantMap shownChart(World& world) {
  for (const QVariantMap& row : viewOf(world)->blocks()->rows()) {
    if (row.value(QStringLiteral("kind")) == QLatin1String("chart")) return row;
  }
  return {};
}

bool drawing(World& world) {
  return world.state(QStringLiteral("space")).toMap().value(QStringLiteral("drawing")).toBool();
}

void watch(World& world, const QString& id = {}) {
  FakeSpaces& spaces = fake(world.mc);
  seed(world.mc);
  spaces.second = std::make_unique<SpacePages>();
  SpacePages* second = spaces.second.get();
  for (const QJsonObject& frame : snapshot(world.mc, kIndex)) second->receiveIndex(frame);
  if (id.isEmpty()) return;
  second->selectSpace(id);
  for (const QJsonObject& frame : snapshot(world.mc, streamOf(id))) second->receiveSpace(frame);
  expect(second->spaceId() == id && second->space().live(), QStringLiteral("the second client did not follow the Space"));
}

// Signs addresses for the Space's images, and leaves every other resource to
// whoever fakes it. Registered once a scenario has images, as other domains
// answer `assets.createUrl` too.
void signImages(World& world) {
  world.mc.onRpc(QStringLiteral("assets.createUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
    if (resource.value(QLatin1String("_tag")) != QLatin1String("space-image")) return mc.passOn(rpc);
    const QString id = text(resource, QLatin1String("imageId"));
    fake(mc).signedImages.append(id);
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/assets/space/%1?signature=x").arg(id)}, {QStringLiteral("expiresAt"), 4102444800000.0}});
  });
}

// The image the user calls `said`, in or out of the trash; it is remembered
// after it goes.
QString idOfImage(World& world, const QString& said) {
  const QString known = fake(world.mc).named.value(QStringLiteral("image\n") + said);
  if (!known.isEmpty()) return known;
  for (const QJsonObject& image : all(world.mc, streamOf(current(world)), QStringLiteral("image"))) {
    if (text(image, QLatin1String("name")) == said) {
      name(world, QStringLiteral("image"), said, text(image, QLatin1String("id")));
      return text(image, QLatin1String("id"));
    }
  }
  fail(QStringLiteral("the Space has no image %1").arg(said));
}

QString givenImage(World& world, const QString& said) {
  signImages(world);
  const QJsonObject image = given(world, QStringLiteral("image.add"), {{QStringLiteral("attachmentId"), QStringLiteral("given")}, {QStringLiteral("name"), said}})
                                .value(QLatin1String("image"))
                                .toObject();
  name(world, QStringLiteral("image"), said, text(image, QLatin1String("id")));
  return text(image, QLatin1String("id"));
}

// A file in the scenario's home, as the user would pick it.
QString givenFile(World& world, const QString& said, const QByteArray& bytes) {
  const QString path = world.homeDir() + QLatin1Char('/') + said;
  QFile file(path);
  expect(file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size(), QStringLiteral("could not write %1").arg(path));
  return QUrl::fromLocalFile(path).toString();
}

QByteArray pngBytes() {
  QImage image(4, 3, QImage::Format_RGB32);
  image.fill(Qt::red);
  QBuffer buffer;
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return buffer.data();
}

// The image block of the open page saying `said`, once there is one.
std::optional<QVariantMap> imageBlock(World& world, const QString& said) {
  for (const QVariantMap& block : viewOf(world)->blocks()->rows()) {
    if (block.value(QStringLiteral("kind")) == QLatin1String("image") && block.value(QStringLiteral("text")) == said) return block;
  }
  return std::nullopt;
}

// The block of the version being read that shows the image; empty when none does.
QVariantMap versionImage(World& world, const QString& said) {
  for (const QVariantMap& block : viewOf(world)->history()->blocks()->rows()) {
    if (block.value(QStringLiteral("kind")) == QLatin1String("image") && block.value(QStringLiteral("text")) == said) return block;
  }
  return {};
}

void expectImageState(World& world, const QString& page, const QString& said, const QString& state) {
  lookAtPage(world, idOfPage(world, page));
  expectShown(world, [&] {
    const auto block = imageBlock(world, said);
    return block && block->value(QStringLiteral("imageState")) == state;
  }, QStringLiteral("%1 to show the image %2 as %3").arg(page, said, state));
}

SpacePages& second(World& world) {
  SpacePages* pages = fake(world.mc).second.get();
  if (!pages) fail(QStringLiteral("no second client is watching"));
  return *pages;
}

// The deck `title` of the scenario's Space, or "" when there is none.
QString findDeck(World& world, const QString& title) {
  for (const QJsonObject& deck : all(world.mc, streamOf(current(world)), QStringLiteral("deck"))) {
    if (text(deck, QLatin1String("title")) == title) return text(deck, QLatin1String("id"));
  }
  return {};
}

QString idOfDeck(World& world, const QString& title) {
  const QString id = findDeck(world, title);
  expect(!id.isEmpty(), QStringLiteral("the Space has no deck %1").arg(title));
  return id;
}

QString givenDeck(World& world, const QString& title) {
  if (const QString id = findDeck(world, title); !id.isEmpty()) return id;
  return text(given(world, QStringLiteral("deck.create"), {{QStringLiteral("title"), title}}).value(QLatin1String("deck")).toObject(), QLatin1String("id"));
}

QJsonObject slideTitled(World& world, const QString& title) {
  for (const QJsonObject& slide : all(world.mc, streamOf(current(world)), QStringLiteral("slide"))) {
    if (text(slide, QLatin1String("title")) == title) return slide;
  }
  fail(QStringLiteral("the Space has no slide %1").arg(title));
}

QString idOfSlide(World& world, const QString& title) {
  return text(slideTitled(world, title), QLatin1String("id"));
}

// The deck `id` of the scenario's Space, open.
void lookAtDeck(World& world, const QString& id) {
  look(world, current(world));
  world.waitFor([&] { return viewOf(world)->space().of(QStringLiteral("deck")).contains(id); },
                [&] { return QStringLiteral("the Space's copy to hold the deck; %1").arg(describe(world)); });
  world.bridge().dispatch(QStringLiteral("space.selectDeck"), QVariantMap{{QStringLiteral("deckId"), id}});
  world.waitFor([&] { return viewOf(world)->deckId() == id; }, [&] { return QStringLiteral("the deck to open; %1").arg(describe(world)); });
}

void actOnDeck(World& world, const QString& title, const QString& action, QVariantMap payload) {
  const QString id = idOfDeck(world, title);
  lookAtDeck(world, id);
  payload.insert(QStringLiteral("deckId"), id);
  act(world, action, payload);
}

void actOnSlide(World& world, const QString& title, const QString& action, QVariantMap payload) {
  const QJsonObject slide = slideTitled(world, title);
  lookAtDeck(world, text(slide, QLatin1String("deckId")));
  payload.insert(QStringLiteral("slideId"), text(slide, QLatin1String("id")));
  act(world, action, payload);
}

// Waits for what the open page `title` shows of its site to be `wanted`.
void expectSite(World& world, const QString& title, const std::function<bool(const QVariantMap&)>& shown, const QString& wanted) {
  lookAtPage(world, idOfPage(world, title));
  expectShown(world, [&] { return shown(viewOf(world)->page().value(QStringLiteral("site")).toMap()); }, QStringLiteral("%1 to %2").arg(title, wanted));
}

// The link the page was last published on, working or not.
QString linkOf(World& world, const QString& title) {
  const QString link = fake(world.mc).links.value(idOfPage(world, title));
  expect(!link.isEmpty(), QStringLiteral("the page %1 was never published").arg(title));
  return link;
}


}  // namespace

bool spaceOpens(World& world, const QString& title) {
  if (fake(world.mc).current.isEmpty()) return false;
  const QString id = findPage(world, title);
  if (id.isEmpty()) return false;
  lookAtPage(world, id);
  return true;
}

bool spaceTick(World& world, const QString& said, bool checked) {
  if (fake(world.mc).current.isEmpty()) return false;
  actOnBlock(world, said, QStringLiteral("space.block.setChecked"), {{QStringLiteral("checked"), checked}});
  return true;
}

namespace {

// --- Project files, as the client offers them --------------------------------

// The project `id` on this MC, with a thread of it the user could show its files in.
void ensureProject(World& world, const QString& id) {
  if (world.shellSubscriptions() == 0) world.connect();
  if (!world.mc.projects.contains(id)) {
    world.mc.projects.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
                                  {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.sendRow(id, world.mc.projects.value(id), QStringLiteral("project"));
  }
  if (!world.mc.threads.contains(kThread)) {
    world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), id},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(kThread, world.mc.threads.value(kThread));
  }
  world.sync();
}

// The Space files of `project` the client was last told of: {relativePath: {kind, spaceId, pageId, title}}.
QVariantMap listedFiles(World& world, const QString& project) {
  return at(world.state(QStringLiteral("space")), QStringLiteral("files")).toMap().value(project).toMap().value(QStringLiteral("paths")).toMap();
}

void waitForFiles(World& world, const QString& project) {
  world.waitFor([&] { return !listedFiles(world, project).isEmpty(); },
                [&] { return QStringLiteral("the Space files of %1 to be listed; %2").arg(project, describe(world)); });
}

// The Files tab of a thread of `project`, on a worktree of it when `worktree`, with its Space files known.
void browseFiles(World& world, const QString& project, bool worktree = false) {
  lookAtThread(world, project, worktree ? QJsonObject{{QStringLiteral("worktreePath"), QStringLiteral("/work/%1-worktree").arg(project)}} : QJsonObject());
  filesteps::showPanel(world);
  waitForFiles(world, project);
}

// The Space `name`, made when the MC has none, as the scenario's.
QString spaceNamed(World& world, const QString& name) {
  for (const QJsonObject& space : all(world.mc, kIndex, QStringLiteral("space"))) {
    if (text(space, QLatin1String("name")) == name) return fake(world.mc).current = text(space, QLatin1String("id"));
  }
  givenSpace(world, name);
  return current(world);
}

// The page open in the Space view is `title`, in the Space `space` when one is named.
void expectOpened(World& world, const QString& title, const QString& space = {}) {
  expectShown(world, [&] {
    return world.native().controller<NavigationController>()->route().kind == QLatin1String("space") &&
           viewOf(world)->page().value(QStringLiteral("title")).toString() == title && (space.isEmpty() || viewOf(world)->spaceName() == space);
  }, QStringLiteral("the page %1 to be open%2").arg(title, space.isEmpty() ? QString() : QStringLiteral(" in ") + space));
}

QVariantMap shownFile(World& world) {
  return viewOf(world)->page().value(QStringLiteral("file")).toMap();
}

void lookAtFilePage(World& world, const QString& title) {
  lookAtPage(world, idOfPage(world, title));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Spaces.
  step(QStringLiteral("the user lists their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
  });
  step(QStringLiteral("the user has listed their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
    // Another start of the app lists them again.
    world.restart();
    world.connect();
  });
  step(QStringLiteral("the Spaces are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    expectShown(world, [&] { return column(viewOf(world)->spaces(), QStringLiteral("name")) == listed(c[0]); }, QStringLiteral("the Spaces to be %1").arg(c[0]));
    expect(column(viewOf(world)->spaces(), QStringLiteral("name")) == listed(c[0]), describe(world));
  });
  step(QStringLiteral("the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenSpace(world, c[0]);
  });
  step(QStringLiteral("the Space %1 with the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenSpace(world, c[0]);
    givenPage(world, c[1]);
  });
  // Who else is on the page.
  // Opened, it holds whoever the MC has on the page, so a later change is one it sees.
  step(QStringLiteral("the user opens the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    lookAtPage(world, page);
    expectShown(world, [&] {
      QStringList devices = fake(world.mc).devices.value(page);
      devices.sort();
      const QVariantMap got = viewOf(world)->viewers();
      return got.value(QStringLiteral("devices")).toStringList() == devices && got.value(QStringLiteral("agents")).toStringList() == fake(world.mc).agents.value(page);
    }, QStringLiteral("the page to hold who is on it"));
  });
  step(QStringLiteral("the Space's page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
  });
  step(QStringLiteral("a thread %1").arg(q), [](World&, const Captures&, const Table&) {});
  const auto arrive = [](World& world, const Captures& c) {
    const QString page = idOfPage(world, c[1]);
    fake(world.mc).devices[page].append(c[0]);
    tellViewers(world.mc, page);
  };
  step(QStringLiteral("the page %1 is open on the device %1").arg(q), [arrive](World& world, const Captures& c, const Table&) {
    arrive(world, {c[1], c[0]});
  });
  step(QStringLiteral("the device %1 opens the page %1").arg(q), [arrive](World& world, const Captures& c, const Table&) {
    arrive(world, c);
  });
  const auto gone = [](World& world, const Captures& c, const Table&) {
    FakeSpaces& spaces = fake(world.mc);
    for (auto it = spaces.devices.begin(); it != spaces.devices.end(); ++it) {
      if (it->removeAll(c[0])) tellViewers(world.mc, it.key());
    }
  };
  step(QStringLiteral("the device %1 leaves the page %1").arg(q), gone);
  step(QStringLiteral("the connection of the device %1 drops").arg(q), gone);
  step(QStringLiteral("the agent in %1 is working on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[1]);
    fake(world.mc).agents[page].append(c[0]);
    tellViewers(world.mc, page);
  });
  step(QStringLiteral("the turn of the agent in %1 ends").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeSpaces& spaces = fake(world.mc);
    for (auto it = spaces.agents.begin(); it != spaces.agents.end(); ++it) {
      if (it->removeAll(c[0])) tellViewers(world.mc, it.key());
    }
  });
  const auto shows = [](World& world, const QStringList& devices, const QStringList& agents) {
    expectShown(world, [&] {
      const QVariantMap got = viewOf(world)->viewers();
      return got.value(QStringLiteral("devices")).toStringList() == devices && got.value(QStringLiteral("agents")).toStringList() == agents;
    }, QStringLiteral("the page to show the devices %1 and the agents %2").arg(devices.join(QLatin1Char(',')), agents.join(QLatin1Char(','))));
  };
  step(QStringLiteral("the MC can say who is on a page"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the MC can no longer say who is on a page"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).viewersRefused = true;
    for (const int id : world.mc.subscribers(QStringLiteral("spacePresence"))) refuseViewers(world.mc, id);
  });
  step(QStringLiteral("the MC can say who is on a page again"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).viewersRefused = false;
  });
  step(QStringLiteral("the page shows nobody else"), [shows](World& world, const Captures&, const Table&) {
    shows(world, {}, {});
  });
  step(QStringLiteral("the page shows the user also on %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, {c[0]}, {});
  });
  step(QStringLiteral("the page shows one person, also on %1 and %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, {c[0], c[1]}, {});
  });
  step(QStringLiteral("the page shows the agent of %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, {}, {c[0]});
  });
  step(QStringLiteral("the user leaves the page"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("usage")));
  });
  step(QStringLiteral("the user opens the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtDeck(world, idOfDeck(world, c[0]));
  });
  step(QStringLiteral("the user is no longer on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    expectShown(world, [&] {
      for (const int id : world.mc.subscribers(QStringLiteral("spacePresence"))) {
        if (world.mc.shapeOf(id).value(QLatin1String("pageId")).toString() == page) return false;
      }
      return true;
    }, QStringLiteral("the client to stop following who is on the page"));
    expect(viewOf(world)->viewers().value(QStringLiteral("devices")).toStringList().isEmpty(), describe(world));
  });
  step(QStringLiteral("the user makes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    act(world, QStringLiteral("space.create"), {{QStringLiteral("name"), c[0]}});
  });
  step(QStringLiteral("the user renames the Space %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.rename"), {{QStringLiteral("spaceId"), idOfSpace(world, c[0])}, {QStringLiteral("name"), c[1]}});
  });
  step(QStringLiteral("the user deletes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.delete"), {{QStringLiteral("spaceId"), idOfSpace(world, c[0])}});
  });
  step(QStringLiteral("(?:the (?:Space|page|deck) request is refused|the user is told only a checklist item can be ticked)"), [](World& world, const Captures&, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    expect(!spaces.last.error.isEmpty(), QStringLiteral("the MC answered %1 with %2").arg(spaces.lastMethod, show(spaces.last.result.toVariantMap())));
    const QString said = world.state(QStringLiteral("space")).toMap().value(QStringLiteral("error")).toString();
    expect(said == spaces.last.error && toldOf(world, said),
           QStringLiteral("the user is not told \"%1\": %2, toasts %3").arg(spaces.last.error, describe(world), show(toasts(world))));
  });
  step(QStringLiteral("a second client watching the Spaces"), [](World& world, const Captures&, const Table&) {
    watch(world);
  });
  step(QStringLiteral("the second client sees the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList names = column(second(world).spaces(), QStringLiteral("name"));
    expect(names.contains(c[0]), QStringLiteral("the second client shows the Spaces %1").arg(show(names)));
  });

  // Pages and their places.
  step(QStringLiteral("the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
  });
  step(QStringLiteral("the pages %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
    givenPage(world, c[1]);
  });
  step(QStringLiteral("the page %1 inside %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0], givenPage(world, c[1]));
  });
  step(QStringLiteral("the user makes the page %1(?: inside %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString parent = c.value(1).isEmpty() ? QString() : idOfPage(world, c[1]);
    look(world, current(world));
    act(world, QStringLiteral("space.page.create"), {{QStringLiteral("title"), c[0]}, {QStringLiteral("parentPageId"), parent}});
  });
  step(QStringLiteral("the pages of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->pages(), QStringLiteral("title")) == listed(c[1]); }, QStringLiteral("the pages to be %1").arg(c[1]));
  });
  step(QStringLiteral("%1 is a subpage of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString child = idOfPage(world, c[0]);
    const QString parent = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), child);
      const auto above = rowOf(viewOf(world)->pages(), parent);
      return row && above && row->value(QStringLiteral("parentPageId")) == parent &&
             row->value(QStringLiteral("depth")).toInt() == above->value(QStringLiteral("depth")).toInt() + 1;
    }, QStringLiteral("%1 to sit inside %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("%1 is not inside another page").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString page = idOfPage(world, c[0]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), page);
      return row && row->value(QStringLiteral("parentPageId")).toString().isEmpty() && row->value(QStringLiteral("depth")).toInt() == 0;
    }, QStringLiteral("%1 to sit at the top of the Space").arg(c[0]));
  });
  step(QStringLiteral("the user renames the page %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.rename"), {{QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("the user moves the page %1 to the top of the Space").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.move"), {{QStringLiteral("parentPageId"), QString()}});
  });
  step(QStringLiteral("the user moves the page %1 into %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.move"), {{QStringLiteral("parentPageId"), idOfPage(world, c[1])}});
  });
  step(QStringLiteral("the page %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("paragraph"), c[1]);
  });
  step(QStringLiteral("the MC restarts"), [](World& world, const Captures&, const Table&) {
    look(world, current(world));
    // What it kept is all a restarted MC has: no follower's offset resumes it.
    world.mc.part<FakeStreams>().handle = QStringLiteral("log-2.1");
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the MC go"));
  });
  step(QStringLiteral("the page %1 still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().client()->isReady(); }, QStringLiteral("the shell to reconnect"));
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world).contains(c[1]); }, QStringLiteral("%1 to read %2").arg(c[0], c[1]));
  });

  // Trash.
  step(QStringLiteral("the user moves the page %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.trash"), {});
  });
  step(QStringLiteral("the page %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("page.trash"), {{QStringLiteral("pageId"), givenPage(world, c[0])}});
  });
  step(QStringLiteral("the trash of %1 holds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->trash(), QStringLiteral("title")) + column(viewOf(world)->deckTrash(), QStringLiteral("title")) == listed(c[1]); },
                QStringLiteral("the trash to hold %1").arg(c[1]));
  });
  step(QStringLiteral("the user restores the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.restore"), {});
  });
  step(QStringLiteral("the user writes %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.block.insert"), {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[0]}});
  });
  step(QStringLiteral("the user deletes the page %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.delete"), {});
  });
  step(QStringLiteral("no blocks or comments of %1 or %1 remain").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    const QSet<QString> gone{spaces.named.value(QStringLiteral("page\n") + c[0]), spaces.named.value(QStringLiteral("page\n") + c[1])};
    look(world, current(world));
    const SpaceStream& copy = viewOf(world)->space();
    for (const QString& kind : {QStringLiteral("page"), QStringLiteral("block"), QStringLiteral("comment")}) {
      for (const QJsonObject& entity : copy.of(kind)) {
        const bool left = gone.contains(text(entity, kind == QLatin1String("page") ? QLatin1String("id") : QLatin1String("pageId")));
        expect(!left, QStringLiteral("the client still holds the %1 %2").arg(kind, show(entity.toVariantMap())));
      }
    }
  });

  // Blocks.
  step(QStringLiteral("the user adds a (paragraph|heading|checklist|callout) block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[2]), QStringLiteral("space.block.insert"), {{QStringLiteral("kind"), c[0]}, {QStringLiteral("text"), c[1]}});
  });
  step(QStringLiteral("%1 has a (paragraph|heading|checklist|callout) block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(QStringLiteral("kind")) == c[1] && block.value(QStringLiteral("text")) == c[2];
      });
    }, QStringLiteral("a %1 block %2").arg(c[1], c[2]));
  });
  // Markdown a page keeps as written, and headings by level (markdown.feature):
  // drawn by the page as the Space view draws it, from the rows the MC's blocks make.
  static const QString kTable = QStringLiteral("| Step | Owner |\n| ---- | ----- |\n|   MC | Ada   |");
  const auto drawPage = [](World& world) {
    return std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nSpacePage { width: 900; height: 700 }\n", QSize(900, 700));
  };
  const auto editorOf = [](Brick& brick, World& world, const QString& said) {
    QQuickItem* editor = nullptr;
    world.waitFor([&] {
      brick.grab();
      editor = brick.root() ? findEditor(brick.root(), QStringLiteral("spaceBlockEditor:") + said) : nullptr;
      return editor != nullptr;
    }, [&] { return QStringLiteral("the page to show the block %1; %2").arg(said, describe(world)); });
    return editor;
  };
  // Mermaid diagrams on a page: imported as the MC reads a "mermaid" fence (a
  // code block in "mermaid" holding the bare source), and drawn by the page
  // through the fake renderer (MermaidSteps.cpp).
  static const QMap<QString, QString> kDiagrams{
      {QStringLiteral("flowchart"), mermaid::kFlowchart},
      {QStringLiteral("graph"), QStringLiteral("graph TD\n  Cart --> Pay")},
      {QStringLiteral("sequenceDiagram"), QStringLiteral("sequenceDiagram\n  Cart->>Pay: order")},
      {QStringLiteral("stateDiagram-v2"), QStringLiteral("stateDiagram-v2\n  [*] --> Cart")},
      {QStringLiteral("gantt"), QStringLiteral("gantt\n  title Launch\n  section Build\n  MC :a1, 2026-11-01, 3d")},
      {QStringLiteral("block-beta"), QStringLiteral("block-beta\n  columns 2\n  Cart Pay")}};
  // Imports a page holding `source`, then `after` paragraphs, and shows it.
  const auto importDiagram = [drawPage](World& world, const QString& source, int after) {
    QString markdown = QStringLiteral("# Ordering\n\nHow an order is paid:\n\n```mermaid\n%1\n```\n").arg(source);
    for (int step = 1; step <= after; ++step) markdown += QStringLiteral("\nStep %1 of paying.\n").arg(step);
    world.mc.part<Diagram>().source = source;
    look(world, current(world));
    act(world, QStringLiteral("space.page.importMarkdown"), {{QStringLiteral("markdown"), markdown}});
    expectShown(world, [&] { return column(viewOf(world)->blocks(), QStringLiteral("text")).contains(source); }, QStringLiteral("the imported page"));
    world.brick = drawPage(world);
  };
  const auto sourceEditor = [](World& world) {
    return findEditor(world.brick->root(), QStringLiteral("spaceBlockEditor:") + world.mc.part<Diagram>().source);
  };
  step(QStringLiteral("the user imports a page holding a %1 Mermaid diagram").arg(q), [importDiagram](World& world, const Captures& c, const Table&) {
    expect(kDiagrams.contains(c[0]), QStringLiteral("no %1 diagram to import").arg(c[0]));
    importDiagram(world, kDiagrams.value(c[0]), 0);
  });
  step(QStringLiteral("the user imports a page holding a flowchart with an unclosed bracket"), [importDiagram](World& world, const Captures&, const Table&) {
    importDiagram(world, mermaid::kBrokenFlowchart, 0);
  });
  // Paragraphs after it, enough to scroll it out of the page.
  step(QStringLiteral("a page with a flowchart"), [importDiagram](World& world, const Captures&, const Table&) {
    importDiagram(world, mermaid::kFlowchart, 40);
  });
  step(QStringLiteral("the page has a diagram block of the type %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString source = world.mc.part<Diagram>().source;
    expect(source.section(QLatin1Char('\n'), 0, 0).section(QLatin1Char(' '), 0, 0) == c[0], QStringLiteral("the page holds a %1 diagram, not %2").arg(c[0], source));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(QStringLiteral("kind")) == QLatin1String("code") && block.value(QStringLiteral("language")) == QLatin1String("mermaid") &&
               block.value(QStringLiteral("text")) == source;
      });
    }, QStringLiteral("a code block in \"mermaid\" holding the diagram"));
  });
  step(QStringLiteral("on the desktop and the phone the diagram is drawn"), [sourceEditor](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, [&] { return QStringLiteral("the diagram to be drawn; %1").arg(describe(world)); });
    expect(mermaid::drawn(world).first()->property("width").toReal() > 0, QStringLiteral("the diagram is drawn with no width"));
    expect(!sourceEditor(world)->isVisible(), QStringLiteral("the diagram's source shows with its picture"));
  });
  step(QStringLiteral("the user is told %1 diagrams cannot be drawn yet").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = c[0] + QStringLiteral(" diagrams cannot be drawn yet.");
    world.waitFor([&] {
      const QList<QQuickItem*> notes = mermaid::shown(world, QStringLiteral("mermaidStatus"));
      return notes.size() == 1 && notes.first()->property("text") == wanted;
    }, QStringLiteral("the user to be told \"%1\"").arg(wanted));
  });
  step(QStringLiteral("the user adds a node to its source"), [sourceEditor](World& world, const Captures&, const Table&) {
    Diagram& diagram = world.mc.part<Diagram>();
    Brick& page = *world.brick;
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, QStringLiteral("the diagram to be drawn"));
    QQuickItem* toggle = findEditor(page.root(), QStringLiteral("spaceDiagramSource:") + diagram.source);
    expect(toggle && toggle->isVisible(), QStringLiteral("no way to the diagram's source"));
    QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(toggle));
    QQuickItem* editor = sourceEditor(world);
    world.waitFor([&] { return editor->isVisible(); }, QStringLiteral("the diagram's source to show"));
    QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(editor, 0.05, 0.2));
    world.waitFor([&] { return editor->hasActiveFocus(); }, QStringLiteral("the source to take the keyboard"));
    QTest::keyClick(&page.window(), Qt::Key_End, Qt::ControlModifier);
    QTest::keyClick(&page.window(), Qt::Key_Return);
    for (const QChar character : QStringLiteral("  Pay --> Done")) QTest::keyClick(&page.window(), character.toLatin1());
    QTest::keyClick(&page.window(), Qt::Key_Return, Qt::ControlModifier);
    diagram.source += QStringLiteral("\n  Pay --> Done");
  });
  step(QStringLiteral("the diagram is drawn again with the new node"), [sourceEditor](World& world, const Captures&, const Table&) {
    const QString source = world.mc.part<Diagram>().source;
    world.waitFor([&] {
      const QList<QQuickItem*> drawn = mermaid::drawn(world);
      return drawn.size() == 1 && findEditor(world.brick->root(), QStringLiteral("spaceDiagram:") + source) && !sourceEditor(world)->isVisible();
    }, [&] { return QStringLiteral("the new source to be drawn; %1").arg(describe(world)); });
    expect(mermaid::asked(world) == 2, QStringLiteral("the MC was asked %1 times, not for the first and the new source").arg(mermaid::asked(world)));
  });
  step(QStringLiteral("the export writes the new source"), [](World& world, const Captures&, const Table&) {
    world.clipboard.clear();
    actOnPage(world, viewOf(world)->pageId(), QStringLiteral("space.page.copyMarkdown"), {});
    const QString fence = QStringLiteral("```mermaid\n%1\n```").arg(world.mc.part<Diagram>().source);
    world.waitFor([&] { return world.clipboard.contains(fence); }, [&] { return QStringLiteral("the export to hold %1; it holds \"%2\"").arg(fence, world.clipboard); });
  });
  step(QStringLiteral("the user scrolls the page past it and back"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, QStringLiteral("the diagram to be drawn"));
    QQuickItem* list = findEditor(world.brick->root(), QStringLiteral("spaceBlocks"));
    QMetaObject::invokeMethod(list, "positionViewAtEnd");
    world.waitFor([&] { return mermaid::drawn(world).isEmpty(); }, QStringLiteral("the page to scroll past the diagram"));
    QMetaObject::invokeMethod(list, "positionViewAtBeginning");
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, QStringLiteral("the diagram to be back"));
  });
  step(QStringLiteral("the diagram is not drawn again"), [](World& world, const Captures&, const Table&) {
    expect(mermaid::asked(world) == 1, QStringLiteral("the MC was asked to draw it %1 times").arg(mermaid::asked(world)));
  });
  step(QStringLiteral("the page %1 holds a table the page does not model yet").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("raw"), kTable);
  });
  // A table and a code block, which the page shows as their source until #854 draws them.
  static const QString kModelledTable = QStringLiteral("| Step | Owner |\n| ---- | ----- |\n| MC   | Ada   |");
  static const QString kCode = QStringLiteral("run()\n    done()");
  step(QStringLiteral("the page %1 holds a table and a code block").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("table"), kModelledTable);
    givenBlock(world, c[0], QStringLiteral("code"), kCode);
  });
  step(QStringLiteral("the table and the code are each shown line for line in a fixed-width face"), [drawPage, editorOf](World& world, const Captures&, const Table&) {
    const std::unique_ptr<Brick> page = drawPage(world);
    const QString mono = world.theme().fontMono().isEmpty() ? QStringLiteral("monospace") : world.theme().fontMono();
    for (const QString& said : {kModelledTable, kCode}) {
      QQuickItem* editor = editorOf(*page, world, said);
      expect(editor->property("text").toString() == said, QStringLiteral("the block reads %1").arg(show(editor->property("text"))));
      expect(editor->property("wrapMode").toInt() == 0, QStringLiteral("%1 wraps (wrapMode %2)").arg(said).arg(editor->property("wrapMode").toInt()));
      expect(editor->property("font").value<QFont>().family() == mono, QStringLiteral("%1 is not in %2").arg(said, mono));
    }
  });
  step(QStringLiteral("the page %1 with headings of every level from 1 to 6").arg(q), [](World& world, const Captures& c, const Table&) {
    for (int level = 1; level <= 6; ++level) {
      given(world, QStringLiteral("block.insert"),
            {{QStringLiteral("pageId"), givenPage(world, c[0])}, {QStringLiteral("kind"), QStringLiteral("heading")},
             {QStringLiteral("text"), QStringLiteral("Level %1").arg(level)}, {QStringLiteral("level"), level}});
    }
  });
  step(QStringLiteral("the table is shown as its Markdown, exactly as written, in a fixed-width face"), [drawPage, editorOf](World& world, const Captures&, const Table&) {
    const std::unique_ptr<Brick> page = drawPage(world);
    QQuickItem* editor = editorOf(*page, world, kTable);
    expect(editor->isVisible(), QStringLiteral("the table's source is not shown"));
    expect(editor->property("text").toString() == kTable, QStringLiteral("the table reads %1").arg(show(editor->property("text"))));
    // Its lines as written: never wrapped, and the text as plain text.
    expect(editor->property("wrapMode").toInt() == 0, QStringLiteral("the table's lines wrap (wrapMode %1)").arg(editor->property("wrapMode").toInt()));
    expect(editor->property("textFormat").toInt() == 0, QStringLiteral("the table is not shown as plain text"));
    // In the code face, as code in a reply is.
    const QFont font = editor->property("font").value<QFont>();
    const QString mono = world.theme().fontMono().isEmpty() ? QStringLiteral("monospace") : world.theme().fontMono();
    expect(font.family() == mono && font.pixelSize() == world.theme().fontSizeCode(),
           QStringLiteral("the table is in %1 at %2, not %3 at %4").arg(font.family()).arg(font.pixelSize()).arg(mono).arg(world.theme().fontSizeCode()));
  });
  step(QStringLiteral("the user can edit it as text"), [drawPage, editorOf](World& world, const Captures&, const Table&) {
    const std::unique_ptr<Brick> page = drawPage(world);
    QQuickItem* editor = editorOf(*page, world, kTable);
    QTest::mouseClick(&page->window(), Qt::LeftButton, Qt::NoModifier, page->at(editor, 0.05, 0.2));
    world.waitFor([&] { return editor->hasActiveFocus(); }, QStringLiteral("the table to take the keyboard"));
    QTest::keyClick(&page->window(), Qt::Key_End, Qt::ControlModifier);
    // Return starts a line in it; Ctrl+Return writes it.
    QTest::keyClick(&page->window(), Qt::Key_Return);
    for (const char key : QByteArrayLiteral("| Ops  | Bo    |")) QTest::keyClick(&page->window(), key);
    QTest::keyClick(&page->window(), Qt::Key_Return, Qt::ControlModifier);
    const QString edited = kTable + QStringLiteral("\n| Ops  | Bo    |");
    world.waitFor([&] { return !findBlock(world, edited).isEmpty(); },
                  [&] { return QStringLiteral("the MC to hold the edited table; it holds %1").arg(show(editor->property("text"))); });
    expect(text(findBlock(world, edited), QLatin1String("kind")) == QLatin1String("raw"), QStringLiteral("the edited table is no longer kept as written"));
  });
  step(QStringLiteral("each heading is smaller than the one of the level above it"), [drawPage, editorOf](World& world, const Captures&, const Table&) {
    const std::unique_ptr<Brick> page = drawPage(world);
    QList<int> sizes;
    QStringList said;
    for (int level = 1; level <= 6; ++level) {
      sizes.append(editorOf(*page, world, QStringLiteral("Level %1").arg(level))->property("font").value<QFont>().pixelSize());
      said.append(QString::number(sizes.last()));
    }
    for (int i = 1; i < sizes.size(); ++i) {
      expect(sizes[i] < sizes[i - 1], QStringLiteral("level %1 is not smaller than level %2: %3").arg(i + 1).arg(i).arg(said.join(QStringLiteral(", "))));
    }
  });
  step(QStringLiteral("the user links %1 from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.block.insert"),
              {{QStringLiteral("kind"), QStringLiteral("subpage_link")}, {QStringLiteral("text"), c[0]}, {QStringLiteral("linkedPageId"), idOfPage(world, c[0])}});
  });
  step(QStringLiteral("the user makes the subpage %1 from a link on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[1]));
    act(world, QStringLiteral("space.page.create"),
        {{QStringLiteral("title"), c[0]}, {QStringLiteral("parentPageId"), idOfPage(world, c[1])}, {QStringLiteral("link"), true}});
  });
  step(QStringLiteral("%1 links to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    const QString linked = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(QStringLiteral("kind")) == QLatin1String("subpage_link") && block.value(QStringLiteral("linkedPageId")) == linked &&
               block.value(QStringLiteral("linkedTitle")) == c[1];
      });
    }, QStringLiteral("a link to %1").arg(c[1]));
  });
  step(QStringLiteral("%1 has the blocks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& said : listed(c[1])) givenBlock(world, c[0], QStringLiteral("paragraph"), said);
  });
  step(QStringLiteral("%1 has the checklist item %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("checklist"), c[1]);
  });
  step(QStringLiteral("the user adds %1 after %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[2]), QStringLiteral("space.block.insert"),
              {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[0]},
               {QStringLiteral("afterBlockId"), text(blockSaying(world, c[1]), QLatin1String("id"))}});
  });
  step(QStringLiteral("the blocks of %1 read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world) == listed(c[1]); }, QStringLiteral("the blocks to read %1").arg(c[1]));
  });
  step(QStringLiteral("the user changes the block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnBlock(world, c[0], QStringLiteral("space.block.update"), {{QStringLiteral("text"), c[1]}});
  });
  step(QStringLiteral("%1 is (not )?ticked").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const bool wanted = c.value(1).isEmpty();
    lookAtPage(world, text(blockSaying(world, c[0]), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->blocks(), id);
      // What the MC wrote, not only what the user asked for.
      return row && row->value(QStringLiteral("checked")).toBool() == wanted && !viewOf(world)->pending(id, QStringLiteral("checked")) &&
             viewOf(world)->space().entity(QStringLiteral("block"), id).value(QLatin1String("checked")).toBool() == wanted;
    }, QStringLiteral("%1 to be %2").arg(c[0], wanted ? QStringLiteral("ticked") : QStringLiteral("unticked")));
  });
  step(QStringLiteral("the user moves the block %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject before = blockSaying(world, c[1]);
    lookAtPage(world, text(before, QLatin1String("pageId")));
    // The block above the one it goes before, if any.
    const QStringList ids = column(viewOf(world)->blocks(), QStringLiteral("id"));
    const qsizetype at = ids.indexOf(text(before, QLatin1String("id")));
    expect(at >= 0, describe(world));
    // What the move changes, on the MC and in the client's rows.
    FakeSpaces& spaces = fake(world.mc);
    spaces.mark = world.mc.part<FakeStreams>().log.value(streamOf(current(world))).size();
    spaces.seen.clear();
    SpaceRows* rows = viewOf(world)->blocks();
    const auto idAt = [rows](int row) { return rows->get(row).value(QStringLiteral("id")).toString(); };
    QObject::connect(rows, &QAbstractItemModel::rowsAboutToBeMoved, rows, [&spaces, idAt](const QModelIndex&, int first, int, const QModelIndex&, int) {
      spaces.seen.append(QStringLiteral("moved ") + idAt(first));
    });
    QObject::connect(rows, &QAbstractItemModel::dataChanged, rows, [&spaces, idAt](const QModelIndex& first, const QModelIndex& last) {
      for (int row = first.row(); row <= last.row(); ++row) spaces.seen.append(QStringLiteral("changed ") + idAt(row));
    });
    for (const auto signal : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
      QObject::connect(rows, signal, rows, [&spaces] { spaces.seen.append(QStringLiteral("rows came or went")); });
    }
    QObject::connect(rows, &QAbstractItemModel::modelReset, rows, [&spaces] { spaces.seen.append(QStringLiteral("reset")); });
    actOnBlock(world, c[0], QStringLiteral("space.block.move"), {{QStringLiteral("afterBlockId"), at > 0 ? ids.at(at - 1) : QString()}});
  });
  step(QStringLiteral("only the block %1 changed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const FakeSpaces& spaces = fake(world.mc);
    const QList<FakeStreams::Change> log = world.mc.part<FakeStreams>().log.value(streamOf(current(world)));
    expect(log.size() > spaces.mark, QStringLiteral("the MC wrote nothing"));
    for (qsizetype i = spaces.mark; i < log.size(); ++i) {
      expect(log.at(i).kind == QLatin1String("block") && log.at(i).id == id,
             QStringLiteral("the MC also wrote the %1 %2: %3").arg(log.at(i).kind, log.at(i).id, show(log.at(i).patch.toVariantMap())));
    }
    expect(spaces.seen == QStringList{QStringLiteral("moved ") + id}, QStringLiteral("the client's blocks: %1").arg(show(spaces.seen)));
  });
  step(QStringLiteral("the user deletes the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnBlock(world, c[0], QStringLiteral("space.block.delete"), {});
  });
  step(QStringLiteral("a second client watching the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    watch(world, idOfSpace(world, c[0]));
  });
  step(QStringLiteral("the second client sees the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList texts = column(second(world).blocks(), QStringLiteral("text"));
    expect(texts.contains(c[0]), QStringLiteral("the second client shows the blocks %1").arg(show(texts)));
  });

  // A page's agent.
  step(QStringLiteral("the user asks %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeSpaces& spaces = fake(world.mc);
    const auto heard = QObject::connect(viewOf(world), &SpaceController::agentAskAnswered, viewOf(world), [&spaces](const QString&, const QString& request, bool taken) {
      if (!taken) spaces.keptWords = request;
    });
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.agent.ask"), {{QStringLiteral("request"), c[0]}});
    QObject::disconnect(heard);
  });
  step(QStringLiteral("the MC refuses the next ask"), [](World& world, const Captures&, const Table&) { fake(world.mc).refuseAsk = true; });
  step(QStringLiteral("the words %1 are kept to ask again").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world.mc).keptWords == c[0], QStringLiteral("the words kept are \"%1\"").arg(fake(world.mc).keptWords));
  });
  step(QStringLiteral("the agent of %1 does not stop when asked").arg(q), [](World& world, const Captures&, const Table&) { fake(world.mc).ignoresStop = true; });
  step(QStringLiteral("%1 says its agent is stopping").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("stopping"); }, QStringLiteral("stopping"));
  });
  step(QStringLiteral("the user can stop the agent of %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    const int before = fake(world.mc).stops;
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.agent.stop"), {});
    world.waitFor([&] { return fake(world.mc).stops == before + 1; }, [] { return QStringLiteral("a second stop to reach the MC"); });
  });
  step(QStringLiteral("the thread of the agent of %1 is deleted").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), idOfPage(world, c[0]), {{QStringLiteral("status"), QStringLiteral("stopped")}, {QStringLiteral("error"), QStringLiteral("its thread was deleted")}, {QStringLiteral("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(QStringLiteral("%1 says its agent stopped because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("stopped") && agent.value(QStringLiteral("error")) == c[1]; }, QStringLiteral("stopped because %1").arg(c[1]));
  });
  step(QStringLiteral("%1 says its agent is working on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("running") && agent.value(QStringLiteral("request")) == c[1]; }, QStringLiteral("working on %1").arg(c[1]));
  });
  step(QStringLiteral("%1 links to its agent's thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString thread = text(askedOn(world, c[0]), QLatin1String("threadId"));
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(QStringLiteral("threadId")) == thread && agent.value(QStringLiteral("threadTitle")) == QLatin1String("Page agent"); }, QStringLiteral("linked to its thread"));
    act(world, QStringLiteral("space.agent.openThread"), {});
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(key.endsWith(QLatin1Char(':') + thread), QStringLiteral("the link opened %1").arg(key));
    lookAtPage(world, idOfPage(world, c[0]));
  });
  step(QStringLiteral("the agent of %1 names a thread this client does not have").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), idOfPage(world, c[0]), {{QStringLiteral("threadId"), QStringLiteral("gone")}});
    world.sync();
  });
  step(QStringLiteral("the user follows the agent of %1 to its thread").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    act(world, QStringLiteral("space.agent.openThread"), {});
  });
  step(QStringLiteral("the user is told the agent's thread is not available"), [](World& world, const Captures&, const Table&) {
    expect(toldOf(world, QStringLiteral("The agent's thread is not available.")), QStringLiteral("the user is not told: %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the agent of %1 adds the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    const QJsonObject author = agent(text(askedOn(world, c[0]), QLatin1String("threadId")));
    insertBlock(world.mc, current(world), page, {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[1]}, {QStringLiteral("checked"), false}},
                QJsonValue::Undefined, author);
    noteEdits(world.mc, current(world), author);
    set(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), page, {{QStringLiteral("edited"), true}});
    world.sync();
  });
  step(QStringLiteral("the block %1 was written by the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[0]);
    expect(block.value(QLatin1String("createdBy")).toObject() == agent(text(askedOn(world, c[1]), QLatin1String("threadId"))), QStringLiteral("the block says %1").arg(show(block)));
  });
  step(QStringLiteral("the agent of %1 finishes").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), idOfPage(world, c[0]), {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(QStringLiteral("the agent of %1 fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), QStringLiteral("pageAgent"), idOfPage(world, c[0]), {{QStringLiteral("status"), QStringLiteral("failed")}, {QStringLiteral("error"), c[1]}, {QStringLiteral("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(QStringLiteral("the user stops the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.agent.stop"), {});
  });
  step(QStringLiteral("the user dismisses the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.agent.dismiss"), {});
  });
  step(QStringLiteral("%1 says its agent finished and changed the page").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("completed") && agent.value(QStringLiteral("edited")).toBool(); }, QStringLiteral("finished with changes"));
  });
  step(QStringLiteral("%1 says its agent finished without changing the page").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("completed") && !agent.value(QStringLiteral("edited")).toBool(); }, QStringLiteral("finished without changes"));
  });
  step(QStringLiteral("%1 says its agent was stopped").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("stopped"); }, QStringLiteral("stopped"));
  });
  step(QStringLiteral("%1 says its agent failed with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(QStringLiteral("status")) == QLatin1String("failed") && agent.value(QStringLiteral("error")) == c[1]; }, QStringLiteral("failed with %1").arg(c[1]));
  });
  step(QStringLiteral("%1 says nothing about an agent").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.isEmpty(); }, QStringLiteral("saying nothing"));
  });

  // A page's history.
  step(QStringLiteral("a while passes"), [](World& world, const Captures&, const Table&) { fake(world.mc).paused = true; });
  step(QStringLiteral("the agent in %1 adds the block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject author = agent(threadNamed(world, c[0]));
    insertBlock(world.mc, current(world), idOfPage(world, c[2]), {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[1]}, {QStringLiteral("checked"), false}},
                QJsonValue::Undefined, author);
    noteEdits(world.mc, current(world), author);
    world.sync();
  });
  step(QStringLiteral("the user opens the history of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showHistory(world, idOfPage(world, c[0]));
  });
  step(QStringLiteral("the history has (\\d+) versions?"), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] { return viewOf(world)->history()->versions()->rowCount() == c[0].toInt(); }, QStringLiteral("the history to have %1 versions").arg(c[0]));
  });
  step(QStringLiteral("each version says when it was written and by the user"), [](World& world, const Captures&, const Table&) {
    for (const QVariantMap& row : viewOf(world)->history()->versions()->rows()) {
      expect(!row.value(QStringLiteral("at")).toString().isEmpty() && !row.value(QStringLiteral("byAgent")).toBool() && !row.value(QStringLiteral("byUpdate")).toBool(), QStringLiteral("a version says %1").arg(show(row)));
    }
  });
  step(QStringLiteral("the newest version is the page as it is now"), [](World& world, const Captures&, const Table&) {
    SpaceHistory* history = viewOf(world)->history();
    readVersion(world, history->versions()->rows().first().value(QStringLiteral("version")));
    expect(column(history->blocks(), QStringLiteral("text")) == column(viewOf(world)->blocks(), QStringLiteral("text")), QStringLiteral("the newest version reads %1").arg(show(listOf(history->blocks()))));
    act(world, QStringLiteral("space.history.back"), {});
  });
  step(QStringLiteral("the newest version was written by the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(newest.value(QStringLiteral("byAgent")).toBool() && newest.value(QStringLiteral("threadTitle")).toString() == c[0], QStringLiteral("the newest version says %1").arg(show(newest)));
  });
  step(QStringLiteral("the newest version was written by the page's update"), [](World& world, const Captures&, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(newest.value(QStringLiteral("byUpdate")).toBool() && !newest.value(QStringLiteral("byAgent")).toBool(), QStringLiteral("the newest version says %1").arg(show(newest)));
  });
  step(QStringLiteral("the user reads the version (\\d+) back on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    readVersion(world, versionBack(world, c[1], c[0].toInt()));
  });
  step(QStringLiteral("the version reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList texts = column(viewOf(world)->history()->blocks(), QStringLiteral("text"));
    expect(texts == listed(c[0]), QStringLiteral("the version reads %1").arg(show(texts)));
  });
  step(QStringLiteral("the version draws a chart of %1 (\\d+) and %1 (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    SpaceRows* blocks = viewOf(world)->history()->blocks();
    const QVariantList labels{c[0], c[2]};
    const QVariantList values{c[1].toDouble(), c[3].toDouble()};
    for (const QVariantMap& row : blocks->rows()) {
      if (row.value(QStringLiteral("kind")) != QLatin1String("chart")) continue;
      const QVariantMap chart = row.value(QStringLiteral("chart")).toMap();
      expect(chart.value(QStringLiteral("labels")).toList() == labels && chart.value(QStringLiteral("series")).toList().value(0).toMap().value(QStringLiteral("values")).toList() == values, QStringLiteral("the version's chart reads %1").arg(show(chart.value(QStringLiteral("labels")).toStringList())));
      return;
    }
    expect(false, QStringLiteral("no chart in the version"));
  });
  step(QStringLiteral("the version shows the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QVariantMap block = versionImage(world, c[0]);
      return block.value(QStringLiteral("imageState")) == QLatin1String("shown") && block.value(QStringLiteral("imageUrl")).toString().contains(QLatin1String("/assets/space/"));
    }, QStringLiteral("the version to show the image %1").arg(c[0]));
  });
  step(QStringLiteral("the version says the image %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] { return versionImage(world, c[0]).value(QStringLiteral("imageState")) == QLatin1String("trashed"); }, QStringLiteral("the version to say the image %1 is in the trash").arg(c[0]));
  });
  step(QStringLiteral("the user goes back to the list of versions"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("space.history.back"), {});
  });
  step(QStringLiteral("the history is closed"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return !viewOf(world)->history()->shown(); }, QStringLiteral("the history to close"));
  });
  step(QStringLiteral("no version is being read"), [](World& world, const Captures&, const Table&) {
    expect(!viewOf(world)->history()->reading() && viewOf(world)->history()->blocks()->rowCount() == 0, QStringLiteral("a version is still being read"));
  });
  step(QStringLiteral("the user restores the version (\\d+) back on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    act(world, QStringLiteral("space.history.restore"), {{QStringLiteral("version"), versionBack(world, c[1], c[0].toInt())}});
    settleHistory(world);
  });
  step(QStringLiteral("the newest version says it restored an earlier one"), [](World& world, const Captures&, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(!newest.value(QStringLiteral("restoredFromAt")).toString().isEmpty(), QStringLiteral("the newest version says %1").arg(show(newest)));
  });
  step(QStringLiteral("the user cannot restore a version of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(viewOf(world)->page().value(QStringLiteral("trashed")).toBool(), QStringLiteral("the page does not say it is in the trash, which takes away its Restore"));
    act(world, QStringLiteral("space.history.restore"), {{QStringLiteral("version"), versionBack(world, c[0], 1)}});
    const FakeSpaces& spaces = fake(world.mc);
    expect(!spaces.last.error.isEmpty() && toldOf(world, spaces.last.error), QStringLiteral("the user is not told the restore was refused; toasts %1").arg(show(toasts(world))));
  });
  // Sites (features/space/sites.feature).
  step(QStringLiteral("the user publishes the page %1 as a site").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.publish"), {});
  });
  step(QStringLiteral("the user publishes the page %1 over Tailscale").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.publish"), {{QStringLiteral("tailscale"), true}});
  });
  step(QStringLiteral("the page %1 is published as a site").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("page.publish"), {{QStringLiteral("pageId"), givenPage(world, c[0])}});
    fake(world.mc).named.insert(QStringLiteral("link\n") + c[0], linkOf(world, c[0]));
  });
  step(QStringLiteral("the user unpublishes the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.unpublish"), {});
  });
  step(QStringLiteral("the user copies the site link of the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return !site.isEmpty(); }, QStringLiteral("show it is published"));
    world.clipboard.clear();
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.copySiteLink"), {});
  });
  step(QStringLiteral("the site link of the page %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.clipboard == linkOf(world, c[0]), QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the page %1 shows it is published with a link").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString link = linkOf(world, c[0]);
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(QStringLiteral("url")).toString() == link; }, QStringLiteral("show its link"));
  });
  step(QStringLiteral("the page %1 shows it is not published").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.isEmpty(); }, QStringLiteral("show it is not published"));
  });
  // The fake serves no pages, so what stops a link here is its site being gone from the MC.
  step(QStringLiteral("the site link of the page %1 no longer opens").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(siteOfPage(world.mc, current(world), idOfPage(world, c[0])).isEmpty(), QStringLiteral("the MC still has the site of %1").arg(c[0]));
  });
  step(QStringLiteral("the second client sees the page %1 published").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!second(world).siteOf(idOfPage(world, c[0])).isEmpty(), QStringLiteral("the second client does not show %1 published").arg(c[0]));
  });
  step(QStringLiteral("the page %1 shows its site is behind").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.value(QStringLiteral("behind")).toBool(); }, QStringLiteral("show its site is behind"));
  });
  step(QStringLiteral("the page %1 shows its site is up to date").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return !site.isEmpty() && !site.value(QStringLiteral("behind")).toBool(); }, QStringLiteral("show its site is up to date"));
  });
  step(QStringLiteral("the page %1 has the same site link").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString earlier = fake(world.mc).named.value(QStringLiteral("link\n") + c[0]);
    expect(!earlier.isEmpty(), QStringLiteral("the page %1 had no link").arg(c[0]));
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(QStringLiteral("url")).toString() == earlier; }, QStringLiteral("keep the link %1").arg(earlier));
  });
  step(QStringLiteral("the MC listens only on this machine"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).address = world.mc.origin().toString();
    fake(world.mc).localOnly = true;
  });
  step(QStringLiteral("the page %1 says only this machine can open its site link").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.value(QStringLiteral("localOnly")).toBool(); }, QStringLiteral("say only this machine can open its link"));
  });
  step(QStringLiteral("Tailscale names the MC's machine %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).tailnet = c[0];
  });
  step(QStringLiteral("the site link of the page %1 starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(QStringLiteral("url")).toString().startsWith(c[1]); }, QStringLiteral("have a link starting with %1").arg(c[1]));
  });

  // Comments.
  step(QStringLiteral("the user comments %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[1]);
    actOnBlock(world, c[1], QStringLiteral("space.comment.add"), {{QStringLiteral("pageId"), text(block, QLatin1String("pageId"))}, {QStringLiteral("body"), c[0]}});
  });
  step(QStringLiteral("the comment %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[1]);
    given(world, QStringLiteral("comment.add"),
          {{QStringLiteral("pageId"), text(block, QLatin1String("pageId"))}, {QStringLiteral("blockId"), text(block, QLatin1String("id"))}, {QStringLiteral("body"), c[0]}});
  });
  step(QStringLiteral("the comment %1 is resolved already").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("comment.resolve"), {{QStringLiteral("commentId"), idOfComment(world, c[0])}});
  });
  step(QStringLiteral("the user (resolves|reopens) the comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[1]);
    lookAtPage(world, text(one(world.mc, streamOf(current(world)), QStringLiteral("comment"), id), QLatin1String("pageId")));
    act(world, c[0] == QLatin1String("resolves") ? QStringLiteral("space.comment.resolve") : QStringLiteral("space.comment.reopen"), {{QStringLiteral("commentId"), id}});
  });
  step(QStringLiteral("the block %1 has the open comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[0]);
    lookAtPage(world, text(block, QLatin1String("pageId")));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->comments()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& comment) {
        return comment.value(QStringLiteral("body")) == c[1] && comment.value(QStringLiteral("blockId")) == text(block, QLatin1String("id")) &&
               comment.value(QStringLiteral("blockText")) == c[0] && !comment.value(QStringLiteral("resolved")).toBool();
      });
    }, QStringLiteral("the open comment %1 on %2").arg(c[1], c[0]));
    const auto row = rowOf(viewOf(world)->blocks(), text(block, QLatin1String("id")));
    expect(row && row->value(QStringLiteral("openComments")).toInt() == 1, QStringLiteral("the block does not count its open comment: %1").arg(describe(world)));
  });
  step(QStringLiteral("the comment %1 is resolved").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[0]);
    lookAtPage(world, text(one(world.mc, streamOf(current(world)), QStringLiteral("comment"), id), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->comments(), id);
      return row && row->value(QStringLiteral("resolved")).toBool();
    }, QStringLiteral("the comment %1 to be resolved").arg(c[0]));
  });

  // Markdown.
  step(QStringLiteral("the page %1 with the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    for (const QStringList& row : table.mid(1)) givenBlock(world, c[0], row.value(0), row.value(1), row.value(2) == QLatin1String("yes"));
  });
  step(QStringLiteral("the user exports %1 as Markdown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.copyMarkdown"), {});
  });
  step(QStringLiteral("the Markdown is:"), [](World& world, const Captures&, const Table& doc) {
    const QString wanted = doc.value(0).value(0) + QLatin1Char('\n');
    world.waitFor([&] { return world.clipboard == wanted; }, [&] { return QStringLiteral("the clipboard to hold the page; it holds \"%1\"").arg(world.clipboard); });
    expect(toldOf(world, QStringLiteral("Page copied as Markdown")), QStringLiteral("the user is not told: %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the user imports this Markdown into %1:").arg(q), [](World& world, const Captures& c, const Table& doc) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.page.importMarkdown"), {{QStringLiteral("markdown"), doc.value(0).value(0)}});
  });
  step(QStringLiteral("the page %1 has the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QString page = idOfPage(world, c[0]);
    look(world, current(world));
    // The page imported is the one the user is shown.
    expectShown(world, [&] { return viewOf(world)->pageId() == page; }, QStringLiteral("%1 to open").arg(c[0]));
    const Table wanted = table.mid(1);
    expectShown(world, [&] { return blockTable(world) == wanted; }, QStringLiteral("the blocks %1").arg(show(tableOf(wanted))));
  });

  // Charts on a page (space/visualize.feature).
  step(QStringLiteral("this MC's threads took turns this week"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("text generation charts the request from the MC's threads"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).chart = chartOf(QStringLiteral("bar"), QStringLiteral("Weekly turns"), QStringLiteral("Counted by this MC from its 2 threads, 12 weeks to 2026-11-01"),
                                   {{QStringLiteral("10-26"), 4}, {QStringLiteral("11-02"), 7}});
  });
  step(QStringLiteral("text generation answers with a (bar|line) chart of %1 (\\d+)(?: and %1 (\\d+))?").arg(q), [](World& world, const Captures& c, const Table&) {
    QList<std::pair<QString, int>> points{{c[1], c[2].toInt()}};
    if (!c.value(3).isEmpty()) points.append({c[3], c[4].toInt()});
    fake(world.mc).chart = chartOf(c[0], QStringLiteral("Signups"), kFromThisPage, points);
  });
  step(QStringLiteral("text generation says the request cannot be answered"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).chart = {};
  });
  step(QStringLiteral("the page %1 has a chart of %1 (\\d+) and %1 (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    givenChart(world, c[0], c[1], c[2].toInt(), c[3], c[4].toInt());
  });
  step(QStringLiteral("the page %1 has a chart with 2 labels and 1 number").arg(q), [](World& world, const Captures& c, const Table&) {
    givenUnmatchedChart(world, c[0]);
  });
  step(QStringLiteral("the page %1 has the blocks %1 and a chart of %1 (\\d+) and %1 (\\d+) and the blocks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("paragraph"), c[1]);
    givenChart(world, c[0], c[2], c[3].toInt(), c[4], c[5].toInt());
    givenBlock(world, c[0], QStringLiteral("paragraph"), c[6]);
  });
  step(QStringLiteral("%1 also says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("paragraph"), c[1]);
  });
  step(QStringLiteral("the user asks for %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).asked = idOfPage(world, c[1]);
    actOnPage(world, fake(world.mc).asked, QStringLiteral("space.block.visualize"), {{QStringLiteral("request"), c[0]}});
  });
  step(QStringLiteral("the user asks again for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    actOnPage(world, fake(world.mc).asked, QStringLiteral("space.block.visualize"),
              {{QStringLiteral("request"), c[0]}, {QStringLiteral("blockId"), shownChart(world).value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("the page shows a (bar|line) chart titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] {
      const QVariantMap chart = shownChart(world).value(QStringLiteral("chart")).toMap();
      return chart.value(QStringLiteral("type")) == c[0] && chart.value(QStringLiteral("title")) == c[1];
    }, QStringLiteral("a %1 chart titled %2").arg(c[0], c[1]));
    expect(!drawing(world), QStringLiteral("the page still says a chart is being drawn"));
  });
  step(QStringLiteral("the chart says its numbers came from (this MC's threads|this page)"), [](World& world, const Captures& c, const Table&) {
    const QString source = shownChart(world).value(QStringLiteral("chart")).toMap().value(QStringLiteral("source")).toString();
    const QString start = c[0] == QLatin1String("this page") ? kFromThisPage : QStringLiteral("Counted by this MC");
    expect(source.startsWith(start), QStringLiteral("the chart says its numbers came from \"%1\"").arg(source));
  });
  step(QStringLiteral("the second client sees a chart titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    second(world).selectPage(fake(world.mc).asked);
    QStringList titles;
    for (const QVariantMap& row : second(world).blocks()->rows()) titles.append(row.value(QStringLiteral("chart")).toMap().value(QStringLiteral("title")).toString());
    expect(titles.contains(c[0]), QStringLiteral("the second client shows the charts %1").arg(show(titles)));
  });
  // The toggle is the brick's; tst_Space.qml presses it. What it reads is the row asserted below.
  step(QStringLiteral("the user asks to see the numbers behind the chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return !shownChart(world).isEmpty(); }, QStringLiteral("a chart on the page"));
  });
  step(QStringLiteral("the chart's numbers are not shown"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return !shownChart(world).isEmpty(); }, QStringLiteral("a chart on the page"));
    // Drawn by the brick from what the page holds, as the page draws it.
    Brick brick(world, "import QtQuick\nimport HalC2.Bricks\nSpaceChart { width: 480 }\n", QSize(480, 320));
    brick.item(QStringLiteral("spaceChart"))->setProperty("chart", shownChart(world).value(QStringLiteral("chart")));
    expect(brick.item(QStringLiteral("spaceChartUnmatched"))->isVisible(), QStringLiteral("the chart does not say its numbers do not match"));
    expect(!brick.item(QStringLiteral("spaceChartNumbers"))->isVisible(), QStringLiteral("the chart offers its numbers"));
  });
  step(QStringLiteral("the numbers read %1 (\\d+)(?: and %1 (\\d+))?").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    QVariantList labels{c[0]};
    QVariantList values{c[1].toDouble()};
    if (!c.value(2).isEmpty()) {
      labels.append(c[2]);
      values.append(c[3].toDouble());
    }
    expectShown(world, [&] {
      const QVariantMap chart = shownChart(world).value(QStringLiteral("chart")).toMap();
      const QVariantList series = chart.value(QStringLiteral("series")).toList();
      return chart.value(QStringLiteral("labels")).toList() == labels && series.size() == 1 && series.first().toMap().value(QStringLiteral("values")).toList() == values;
    }, QStringLiteral("the numbers to read %1").arg(c.join(QLatin1Char(' '))));
  });
  step(QStringLiteral("the page shows one chart, between %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QStringList kinds = column(viewOf(world)->blocks(), QStringLiteral("kind"));
      const QStringList texts = column(viewOf(world)->blocks(), QStringLiteral("text"));
      const qsizetype at = kinds.indexOf(QStringLiteral("chart"));
      return kinds.count(QStringLiteral("chart")) == 1 && at > 0 && at + 1 < texts.size() && texts.at(at - 1) == c[0] && texts.at(at + 1) == c[1];
    }, QStringLiteral("one chart between %1 and %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("the user deletes the chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    act(world, QStringLiteral("space.block.delete"), {{QStringLiteral("blockId"), shownChart(world).value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("the page shows no chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return shownChart(world).isEmpty(); }, QStringLiteral("no chart on the page"));
  });
  step(QStringLiteral("the user is told no chart was drawn"), [](World& world, const Captures&, const Table&) {
    const QString start = QStringLiteral("No chart was drawn");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return QStringLiteral("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    expect(!drawing(world), QStringLiteral("the page still says a chart is being drawn"));
  });

  // A page from a thread.
  step(QStringLiteral("the thread %1 talked about a release plan").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).talked.insert(threadNamed(world, c[0]));
  });
  // A page that updates itself.
  step(QStringLiteral("the user has %1 update itself with %1 every (\\d+) hours").arg(q), [](World& world, const Captures& c, const Table&) {
    setUpdate(world, c[0], c[1], everyHours(c[2]));
  });
  step(QStringLiteral("the user has %1 update itself with %1 every day at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setUpdate(world, c[0], c[1], everyDayAt(c[2]));
  });
  step(QStringLiteral("%1 updates itself with %1 every (\\d+) hours").arg(q), [](World& world, const Captures& c, const Table&) {
    givenUpdate(world, c[0], {{QStringLiteral("instruction"), c[1]}, {QStringLiteral("cadence"), everyHours(c[2])}}, QStringLiteral("page.schedule.set"));
  });
  step(QStringLiteral("the updates of %1 are paused").arg(q), [](World& world, const Captures& c, const Table&) {
    givenUpdate(world, c[0], {{QStringLiteral("enabled"), false}}, QStringLiteral("page.schedule.setEnabled"));
  });
  step(QStringLiteral("the update of %1 has run").arg(q), [](World& world, const Captures& c, const Table&) {
    givenUpdate(world, c[0], {}, QStringLiteral("page.schedule.runNow"));
  });
  step(QStringLiteral("text generation writes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).generation = QStringLiteral("available");
    fake(world.mc).writes = c[0];
  });
  step(QStringLiteral("the user pauses the updates of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.schedule.setEnabled"), {{QStringLiteral("enabled"), false}});
  });
  step(QStringLiteral("the user resumes the updates of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.schedule.setEnabled"), {{QStringLiteral("enabled"), true}});
  });
  step(QStringLiteral("the user runs the update of %1 now").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.schedule.runNow"), {});
  });
  step(QStringLiteral("the user removes the update of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.schedule.remove"), {});
  });
  step(QStringLiteral("the user tries to edit the generated part of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = generatedOf(world.mc, current(world), idOfPage(world, c[0]));
    expect(!block.isEmpty(), QStringLiteral("%1 has no generated part").arg(c[0]));
    actOnBlock(world, text(block, QLatin1String("text")), QStringLiteral("space.block.update"), {{QStringLiteral("text"), QStringLiteral("Edited by hand")}});
  });
  step(QStringLiteral("%1 shows the instruction %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [&](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("instruction")) == c[1]; },
                 QStringLiteral("the instruction %1").arg(c[1]));
  });
  step(QStringLiteral("%1 shows no instruction").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap& update, const QVariantMap&) { return update.isEmpty(); }, QStringLiteral("no instruction"));
  });
  step(QStringLiteral("%1 shows it updates every (\\d+) hours").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = QStringLiteral("Every %1 hours").arg(c[1]);
    expectUpdate(world, c[0], [&](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("cadenceLabel")) == label; }, label);
  });
  step(QStringLiteral("%1 shows it updates every day at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = QStringLiteral("Every day at %1").arg(c[1]);
    expectUpdate(world, c[0], [&](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("cadenceLabel")) == label; }, label);
  });
  step(QStringLiteral("%1 shows when it next runs").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap& update, const QVariantMap&) { return !update.value(QStringLiteral("nextRunAt")).toString().isEmpty(); },
                 QStringLiteral("its next run"));
  });
  step(QStringLiteral("%1 shows no next run").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("nextRunAt")).toString().isEmpty(); },
                 QStringLiteral("no next run"));
  });
  step(QStringLiteral("%1 has not been written yet").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap&, const QVariantMap& page) { return page.value(QStringLiteral("writtenAt")).toString().isEmpty(); },
                 QStringLiteral("it has not been written"));
  });
  step(QStringLiteral("%1 shows when it was last written").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap&, const QVariantMap& page) { return !page.value(QStringLiteral("writtenAt")).toString().isEmpty(); },
                 QStringLiteral("when it was last written"));
  });
  step(QStringLiteral("%1 shows its updates are paused").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("enabled")) == false; }, QStringLiteral("it is paused"));
  });
  step(QStringLiteral("%1 shows its updates are not paused").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [](const QVariantMap& update, const QVariantMap&) { return update.value(QStringLiteral("enabled")) == true; }, QStringLiteral("it is not paused"));
  });
  step(QStringLiteral("%1 shows its last run failed with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectUpdate(world, c[0], [&](const QVariantMap& update, const QVariantMap&) {
      return update.value(QStringLiteral("lastRunStatus")) == QLatin1String("failed") && update.value(QStringLiteral("lastRunError")) == c[1];
    }, QStringLiteral("a failed run saying %1").arg(c[1]));
  });
  step(QStringLiteral("the generated part of %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return generatedText(world) == c[1]; }, QStringLiteral("the generated part to read %1").arg(c[1]));
  });
  step(QStringLiteral("%1 has no generated part").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return !generatedText(world).has_value(); }, QStringLiteral("no generated part"));
  });

  step(QStringLiteral("text generation is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("available");
  });
  step(QStringLiteral("no text generation provider is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("unavailable");
  });
  step(QStringLiteral("text generation fails"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("failed");
  });
  step(QStringLiteral("the user makes a page in %1 from the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The Space the page goes in is the one the user last had open.
    look(world, idOfSpace(world, c[0]));
    const QString key = world.mc.environmentId + QLatin1Char(':') + threadNamed(world, c[1]);
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
    world.sync();
    // From the thread's menu.
    world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no thread menu opened"));
    world.bridge().dispatch(QStringLiteral("menu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), QStringLiteral("page-from-thread")}});
    world.sync();
  });
  step(QStringLiteral("the new page holds the generated summary"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] {
      return world.native().controller<NavigationController>()->route().kind == QLatin1String("space") && viewOf(world)->spaceId() == current(world) &&
             viewOf(world)->page().value(QStringLiteral("title")) == kSummaryTitle && blockTexts(world) == QStringList{kSummary};
    }, QStringLiteral("the summary to open as a page"));
    const QVariantMap block = viewOf(world)->blocks()->get(0);
    expect(block.value(QStringLiteral("byAgent")).toBool(), QStringLiteral("the summary is not shown as the agent's: %1").arg(show(block)));
  });
  step(QStringLiteral("the new page remembers it came from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap page = viewOf(world)->page();
    expect(page.value(QStringLiteral("sourceThreadId")) == threadNamed(world, c[0]) && page.value(QStringLiteral("sourceThreadTitle")) == c[0],
           QStringLiteral("the page shows %1").arg(show(page)));
  });
  step(QStringLiteral("the summary was written in the project's folder"), [](World& world, const Captures&, const Table&) {
    // The client names the thread; the MC finds its folder.
    const FakeSpaces& spaces = fake(world.mc);
    const QJsonObject thread = world.mc.threads.value(spaces.summarised);
    const QString folder = world.mc.projects.value(thread.value(QLatin1String("projectId")).toString()).value(QLatin1String("workspaceRoot")).toString();
    expect(!spaces.summarised.isEmpty() && !folder.isEmpty() && spaces.cwd == folder,
           QStringLiteral("the summary of %1 was written in \"%2\", not \"%3\"").arg(spaces.summarised, spaces.cwd, folder));
  });
  step(QStringLiteral("the user is told text generation (is unavailable|failed)"), [](World& world, const Captures& c, const Table&) {
    const QString start = c[0] == QLatin1String("failed") ? QStringLiteral("Text generation failed, so no page was written: The provider stopped answering.")
                                                          : QStringLiteral("Text generation is unavailable, so no page was written.");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return QStringLiteral("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    expect(!world.state(QStringLiteral("space")).toMap().value(QStringLiteral("busy")).toBool(), QStringLiteral("the Space view still says it is writing"));
  });

  // Decks and their slides (features/space/slides.feature).
  step(QStringLiteral("the user makes the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    act(world, QStringLiteral("space.deck.create"), {{QStringLiteral("title"), c[0]}});
  });
  step(QStringLiteral("the user makes a deck from the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.deck.createFromPage"), {});
  });
  step(QStringLiteral("the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenDeck(world, c[0]);
  });
  step(QStringLiteral("the deck %1 with the slides %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = givenDeck(world, c[0]);
    for (const QJsonObject& slide : slidesOf(world.mc, streamOf(current(world)), deck)) {
      given(world, QStringLiteral("slide.delete"), {{QStringLiteral("slideId"), text(slide, QLatin1String("id"))}});
    }
    for (const QString& title : listed(c[1])) given(world, QStringLiteral("slide.insert"), {{QStringLiteral("deckId"), deck}, {QStringLiteral("title"), title}});
  });
  step(QStringLiteral("the deck %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("deck.trash"), {{QStringLiteral("deckId"), givenDeck(world, c[0])}});
  });
  step(QStringLiteral("the decks of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->decks(), QStringLiteral("title")) == listed(c[1]); }, QStringLiteral("the decks to be %1").arg(c[1]));
  });
  step(QStringLiteral("the deck %1 has the slides:").arg(q), [](World& world, const Captures& c, const Table& table) {
    lookAtDeck(world, idOfDeck(world, c[0]));
    Table wanted;
    for (const QStringList& row : table.mid(1)) wanted.append({row.value(0), row.value(1)});
    const auto shown = [&] {
      Table rows;
      for (const QVariantMap& slide : viewOf(world)->slides()->rows()) {
        rows.append({slide.value(QStringLiteral("title")).toString(), slide.value(QStringLiteral("body")).toString().replace(QLatin1Char('\n'), QStringLiteral(" / "))});
      }
      return rows;
    };
    world.waitFor([&] { return shown() == wanted; }, [&] { return QStringLiteral("the slides %1, shown %2").arg(show(tableOf(wanted)), show(tableOf(shown()))); });
  });
  step(QStringLiteral("the slides of %1 are( still)? %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().client()->isReady(); }, QStringLiteral("the shell to reconnect"));
    lookAtDeck(world, idOfDeck(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->slides(), QStringLiteral("title")) == listed(c[2]); },
                QStringLiteral("the slides to be %1, shown %2").arg(c[2], show(column(viewOf(world)->slides(), QStringLiteral("title")))));
  });
  step(QStringLiteral("the user renames the deck %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[0], QStringLiteral("space.deck.rename"), {{QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("the title %1 written for the deck %1 lands once the Space %1 is on show").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = idOfDeck(world, c[1]);
    const QString space = current(world);
    givenSpace(world, c[2]);
    look(world, idOfSpace(world, c[2]));
    act(world, QStringLiteral("space.deck.rename"), {{QStringLiteral("spaceId"), space}, {QStringLiteral("deckId"), deck}, {QStringLiteral("title"), c[0]}});
  });
  step(QStringLiteral("the user moves the deck %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[0], QStringLiteral("space.deck.trash"), {});
  });
  step(QStringLiteral("the user restores the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[0], QStringLiteral("space.deck.restore"), {});
  });
  step(QStringLiteral("the user deletes the deck %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[0], QStringLiteral("space.deck.delete"), {});
  });
  step(QStringLiteral("no slides remain in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return viewOf(world)->space().of(QStringLiteral("slide")).isEmpty(); }, QStringLiteral("no slides to remain"));
  });
  step(QStringLiteral("the user adds the slide %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[1], QStringLiteral("space.slide.insert"), {{QStringLiteral("title"), c[0]}, {QStringLiteral("body"), QString()}});
  });
  step(QStringLiteral("the user adds the slide %1 after %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnDeck(world, c[2], QStringLiteral("space.slide.insert"), {{QStringLiteral("title"), c[0]}, {QStringLiteral("body"), QString()}, {QStringLiteral("afterSlideId"), idOfSlide(world, c[1])}});
  });
  step(QStringLiteral("the user changes the slide %1 to %1 reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnSlide(world, c[0], QStringLiteral("space.slide.update"), {{QStringLiteral("title"), c[1]}, {QStringLiteral("body"), c[2]}});
  });
  step(QStringLiteral("the user moves the slide %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject before = slideTitled(world, c[1]);
    QString after;
    for (const QJsonObject& slide : slidesOf(world.mc, streamOf(current(world)), text(before, QLatin1String("deckId")))) {
      if (text(slide, QLatin1String("id")) == text(before, QLatin1String("id"))) break;
      after = text(slide, QLatin1String("id"));
    }
    actOnSlide(world, c[0], QStringLiteral("space.slide.move"), {{QStringLiteral("afterSlideId"), after}});
  });
  step(QStringLiteral("the user deletes the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnSlide(world, c[0], QStringLiteral("space.slide.delete"), {});
  });
  step(QStringLiteral("the second client sees the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList titles = column(second(world).decks(), QStringLiteral("title"));
    expect(titles.contains(c[0]), QStringLiteral("the second client shows the decks %1").arg(show(titles)));
  });
  step(QStringLiteral("the second client sees the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = text(slideTitled(world, c[0]), QLatin1String("deckId"));
    second(world).selectDeck(deck);
    const QStringList titles = column(second(world).slides(), QStringLiteral("title"));
    expect(titles.contains(c[0]), QStringLiteral("the second client shows the slides %1").arg(show(titles)));
  });

  // Presenting.
  step(QStringLiteral("the user presents the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString id = idOfDeck(world, c[0]);
    world.waitFor([&] { return viewOf(world)->space().of(QStringLiteral("deck")).contains(id); }, QStringLiteral("the Space's copy to hold the deck"));
    act(world, QStringLiteral("space.deck.present"), {{QStringLiteral("deckId"), id}});
  });
  step(QStringLiteral("the presenter shows %1, slide (\\d+) of (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    SpaceController* view = viewOf(world);
    world.waitFor([&] {
      return view->presenting() && view->slide().value(QStringLiteral("title")) == c[0] && view->slideNumber() == c[1].toInt() && view->slideCount() == c[2].toInt();
    }, [&] { return QStringLiteral("the presenter to show %1, %2 of %3; it shows %4, %5 of %6").arg(c[0], c[1], c[2], show(view->slide())).arg(view->slideNumber()).arg(view->slideCount()); });
  });
  step(QStringLiteral("the user steps (forward|back)"), [](World& world, const Captures& c, const Table&) {
    act(world, QStringLiteral("space.deck.step"), {{QStringLiteral("by"), c[0] == QLatin1String("back") ? -1 : 1}});
  });
  step(QStringLiteral("the user leaves the presenter"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("space.deck.leave"), {});
  });
  step(QStringLiteral("nothing is being presented"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return !viewOf(world)->presenting(); }, QStringLiteral("the presenter to be closed"));
  });
  step(QStringLiteral("the user is told the deck has no slides"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toldOf(world, QStringLiteral("This deck has no slides")); }, [&] { return QStringLiteral("the user to be told; toasts %1").arg(show(toasts(world))); });
  });
  step(QStringLiteral("another client changes the slide %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("slide.update"), {{QStringLiteral("slideId"), idOfSlide(world, c[0])}, {QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("another client moves the slide %1 after %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("slide.move"), {{QStringLiteral("slideId"), idOfSlide(world, c[0])}, {QStringLiteral("afterSlideId"), idOfSlide(world, c[1])}});
  });
  step(QStringLiteral("another client deletes the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("slide.delete"), {{QStringLiteral("slideId"), idOfSlide(world, c[0])}});
  });
  step(QStringLiteral("another client moves the deck %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("deck.trash"), {{QStringLiteral("deckId"), idOfDeck(world, c[0])}});
  });
  // Images.
  step(QStringLiteral("the user adds the image %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    signImages(world);
    look(world, idOfSpace(world, c[1]));
    act(world, QStringLiteral("space.image.addFile"), {{QStringLiteral("url"), givenFile(world, c[0], pngBytes())}});
  });
  step(QStringLiteral("the user adds the file %1 holding plain text to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[1]));
    act(world, QStringLiteral("space.image.addFile"), {{QStringLiteral("url"), givenFile(world, c[0], "Plain words, whatever the name says.")}});
  });
  step(QStringLiteral("the image request is refused"), [](World& world, const Captures&, const Table&) {
    const auto said = [&] { return world.state(QStringLiteral("space")).toMap().value(QStringLiteral("error")).toString(); };
    world.waitFor([&] { return !said().isEmpty() && toldOf(world, said()); }, [&] { return QStringLiteral("the user to be told why; %1, toasts %2").arg(describe(world), show(toasts(world))); });
  });
  step(QStringLiteral("the images of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->images(), QStringLiteral("name")) == listed(c[1]); }, QStringLiteral("the images to be %1").arg(c[1]));
  });
  step(QStringLiteral("the image trash of %1 holds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->imageTrash(), QStringLiteral("name")) == listed(c[1]); }, QStringLiteral("the image trash to hold %1").arg(c[1]));
  });
  step(QStringLiteral("the second client sees the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return column(second(world).images(), QStringLiteral("name")).contains(c[0]); }, [&] { return QStringLiteral("the second client to show the image %1").arg(c[0]); });
  });
  step(QStringLiteral("image generation is available"), [](World& world, const Captures&, const Table&) {
    signImages(world);
    fake(world.mc).imageGeneration = QStringLiteral("available");
  });
  step(QStringLiteral("no image generation provider is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).imageGeneration = QStringLiteral("unavailable");
  });
  step(QStringLiteral("image generation fails"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).imageGeneration = QStringLiteral("failed");
  });
  step(QStringLiteral("the user generates an image of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[1]));
    act(world, QStringLiteral("space.image.generate"), {{QStringLiteral("prompt"), c[0]}});
  });
  step(QStringLiteral("%1 has a generated image of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->images(), QStringLiteral("prompt")).contains(c[1]); }, QStringLiteral("a generated image of %1").arg(c[1]));
    expect(!world.state(QStringLiteral("space")).toMap().value(QStringLiteral("generatingImage")).toBool(), QStringLiteral("the Space view still says it is generating"));
  });
  step(QStringLiteral("the user is told image generation (is unavailable|failed)"), [](World& world, const Captures& c, const Table&) {
    const QString start = c[0] == QLatin1String("failed") ? QStringLiteral("Image generation failed, so no image was made: The provider left no image.")
                                                          : QStringLiteral("Image generation is unavailable, so no image was made.");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return QStringLiteral("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    expect(!world.state(QStringLiteral("space")).toMap().value(QStringLiteral("generatingImage")).toBool(), QStringLiteral("the Space view still says it is generating"));
  });
  step(QStringLiteral("the image providers on offer say which can generate"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
    act(world, QStringLiteral("space.image.providers"), {});
    QVariantMap status;
    world.waitFor([&] {
      for (const QVariant& provider : world.state(QStringLiteral("space")).toMap().value(QStringLiteral("imageProviders")).toMap().value(QStringLiteral("providers")).toList()) {
        status.insert(provider.toMap().value(QStringLiteral("instanceId")).toString(), provider.toMap().value(QStringLiteral("status")));
      }
      return status.value(QStringLiteral("codex")) == QLatin1String("ready") && status.value(QStringLiteral("claudeAgent")) == QLatin1String("unsupported");
    }, [&] { return QStringLiteral("the providers to say which can generate; they say %1").arg(show(status)); });
  });
  step(QStringLiteral("the image %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(idOfSpace(world, c[1]) == current(world), QStringLiteral("%1 is not the scenario's Space").arg(c[1]));
    givenImage(world, c[0]);
  });
  step(QStringLiteral("the user places the image %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.block.insert"), {{QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("text"), c[0]}, {QStringLiteral("imageId"), idOfImage(world, c[0])}});
  });
  step(QStringLiteral("%1 shows the image %1 already").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("block.insert"), {{QStringLiteral("pageId"), idOfPage(world, c[0])}, {QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("text"), c[1]}, {QStringLiteral("imageId"), idOfImage(world, c[1])}});
  });
  step(QStringLiteral("%1 shows the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectImageState(world, c[0], c[1], QStringLiteral("shown"));
    // Its bytes come by a signed address, on the MC this client talks to.
    expectShown(world, [&] { return imageBlock(world, c[1])->value(QStringLiteral("imageUrl")).toString().contains(QLatin1String("/assets/space/")); }, QStringLiteral("the image to have an address"));
  });
  step(QStringLiteral("%1 says the image %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    expectImageState(world, c[0], c[1], QStringLiteral("trashed"));
  });
  step(QStringLiteral("%1 says the image %1 was deleted").arg(q), [](World& world, const Captures& c, const Table&) {
    expectImageState(world, c[0], c[1], QStringLiteral("deleted"));
  });
  step(QStringLiteral("the image %1 is in the image trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("image.trash"), {{QStringLiteral("imageId"), idOfImage(world, c[0])}});
  });
  step(QStringLiteral("the user moves the image %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    act(world, QStringLiteral("space.image.trash"), {{QStringLiteral("imageId"), idOfImage(world, c[0])}});
  });
  step(QStringLiteral("the user restores the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    act(world, QStringLiteral("space.image.restore"), {{QStringLiteral("imageId"), idOfImage(world, c[0])}});
  });
  step(QStringLiteral("the user deletes the image %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    act(world, QStringLiteral("space.image.delete"), {{QStringLiteral("imageId"), idOfImage(world, c[0])}});
  });
  step(QStringLiteral("the user opens the images of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.images.show"), {{QStringLiteral("shown"), true}});
  });
  step(QStringLiteral("the user closes the images"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("space.images.show"), {{QStringLiteral("shown"), false}});
  });
  step(QStringLiteral("the user sees the image %1 with its name").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->images(), idOfImage(world, c[0]));
      return row && row->value(QStringLiteral("name")) == c[0] && !row->value(QStringLiteral("url")).toString().isEmpty();
    }, QStringLiteral("the image %1 with a name and an address").arg(c[0]));
  });
  step(QStringLiteral("no address has been signed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!fake(world.mc).signedImages.contains(idOfImage(world, c[0])), QStringLiteral("the client signed an address for %1 before it was shown").arg(c[0]));
  });
  step(QStringLiteral("an address has been signed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fake(world.mc).signedImages.contains(idOfImage(world, c[0])); }, [&] { return QStringLiteral("an address to be signed for %1").arg(c[0]); });
  });

  // Project files as pages (features/space/project-files.feature, "Opening project files from the clients").
  step(QStringLiteral("%1 has the file %1 reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureProject(world, c[0]);
    fakeFiles(world.mc).files.insert(c[1], QString(c[2]).replace(QStringLiteral("\\n"), QStringLiteral("\n")));
  });
  step(QStringLiteral("the user is browsing the files of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world, c[0], fake(world.mc).onWorktree);
  });
  step(QStringLiteral("the user opens %1 in a Space from its menu").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world, kProject);
    filesteps::choose(world, c[0], QStringLiteral("fileEntryOpenInSpace"));
    world.sync();
  });
  step(QStringLiteral("the Space shows the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectOpened(world, c[0]);
  });
  step(QStringLiteral("the user is reading %1 in the file viewer").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world, kProject);
    filesteps::openFile(world, c[0]);
  });
  step(QStringLiteral("the user opens it in a Space"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->item(QStringLiteral("fileOpenInSpace"))->isVisible(); }, QStringLiteral("the viewer to offer opening the file in a Space"));
    world.brick->click(QStringLiteral("fileOpenInSpace"));
    world.sync();
  });
  step(QStringLiteral("the agent's message in a thread of %1 links %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    waitForFiles(world, c[0]);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("See [the guide](%1).").arg(c[1])}});
    fake(world.mc).link = c[1];
  });
  step(QStringLiteral("the user opens that link in a Space"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("link.menu"), QVariantMap{{QStringLiteral("url"), fake(world.mc).link}, {QStringLiteral("x"), 10}, {QStringLiteral("y"), 10}});
    world.waitFor([&] { return !at(world.state(QStringLiteral("menu")), QStringLiteral("items")).toList().isEmpty(); }, QStringLiteral("the link's menu to open"));
    const QVariant menu = world.state(QStringLiteral("menu"));
    const QVariantList items = at(menu, QStringLiteral("items")).toList();
    expect(std::any_of(items.cbegin(), items.cend(), [](const QVariant& item) { return item.toMap().value(QStringLiteral("id")) == QLatin1String("open-in-space"); }),
           QStringLiteral("the link's menu offers %1").arg(show(items)));
    world.bridge().dispatch(QStringLiteral("menu.select"), QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), QStringLiteral("open-in-space")}});
    world.sync();
  });
  step(QStringLiteral("the user is in the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, spaceNamed(world, c[0]));
  });
  step(QStringLiteral("the user adds a page from the files of %1 and picks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    act(world, SpaceController::kPickFile, {{QStringLiteral("projectId"), c[0]}});
    world.waitFor([&] { return at(world.state(QStringLiteral("space")), QStringLiteral("picking")).toString() == c[0]; },
                  [&] { return QStringLiteral("the files of %1 to be offered; %2").arg(c[0], describe(world)); });
    waitForFiles(world, c[0]);
    expect(listedFiles(world, c[0]).contains(c[1]), QStringLiteral("%1 is not offered: %2").arg(c[1], show(listedFiles(world, c[0]))));
    act(world, QStringLiteral("space.openFile"), {{QStringLiteral("projectId"), c[0]}, {QStringLiteral("relativePath"), c[1]}});
  });
  step(QStringLiteral("the user asks the command palette to open %1 in a Space").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.native().controller<KeybindingController>()->commands()->run(SpaceController::kPickFile), QStringLiteral("the palette has no command to open a file in a Space"));
    world.waitFor([&] { return !at(world.state(QStringLiteral("space")), QStringLiteral("picking")).toString().isEmpty(); },
                  [&] { return QStringLiteral("a project's files to be offered; %1").arg(describe(world)); });
    const QString project = at(world.state(QStringLiteral("space")), QStringLiteral("picking")).toString();
    waitForFiles(world, project);
    act(world, QStringLiteral("space.openFile"), {{QStringLiteral("projectId"), project}, {QStringLiteral("relativePath"), c[0]}});
  });
  step(QStringLiteral("the user asks the command palette to scan %1 for Space files").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureProject(world, c[0]);
    expect(world.native().controller<KeybindingController>()->commands()->run(SpaceController::kScanFiles), QStringLiteral("the palette has no command to scan for Space files"));
    world.sync();
  });
  step(QStringLiteral("the user is told the scan wrote the spaces section"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return toldOf(world, QStringLiteral("Wrote the spaces section")); }, QStringLiteral("a toast that the scan wrote the spaces section"));
  });
  step(QStringLiteral("%1 offers no way to open it in a Space").arg(q), [](World& world, const Captures& c, const Table&) {
    QObject* menu = world.brick->root()->findChild<QObject*>(QStringLiteral("fileEntryMenu"));
    expect(menu != nullptr, QStringLiteral("the Files tab has no entry menu"));
    menu->setProperty("path", c[0]);
    QQuickItem* item = filesteps::menuEntry(world, QStringLiteral("fileEntryMenu"), QStringLiteral("fileEntryOpenInSpace"));
    expect(item == nullptr || (!item->isVisible() && !item->isEnabled()), QStringLiteral("the menu of %1 offers opening it in a Space").arg(c[0]));
    // The Markdown beside it is offered, so the menu is not merely waiting.
    menu->setProperty("path", QStringLiteral("docs/guide.md"));
    expect(item != nullptr && item->isEnabled(), QStringLiteral("the menu of docs/guide.md does not offer opening it in a Space"));
  });
  step(QStringLiteral("every Space was deleted"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& space : all(world.mc, kIndex, QStringLiteral("space"))) remove(world.mc, kIndex, QStringLiteral("space"), text(space, QLatin1String("id")));
  });
  step(QStringLiteral("the user last had the Space %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, spaceNamed(world, c[0]));
  });
  step(QStringLiteral("the page %1 is in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectOpened(world, c[0], c[1]);
  });
  step(QStringLiteral("the user has opened %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    spaceNamed(world, c[2]);
    const QJsonObject page = given(world, QStringLiteral("page.openFile"), {{QStringLiteral("projectId"), c[1]}, {QStringLiteral("relativePath"), c[0]}})
                                 .value(QLatin1String("page"))
                                 .toObject();
    name(world, QStringLiteral("page"), text(page, QLatin1String("title")), text(page, QLatin1String("id")));
  });
  step(QStringLiteral("the user shows the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtFilePage(world, c[0]);
  });
  step(QStringLiteral("the page says it is the file %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QVariantMap file = shownFile(world);
      return file.value(QStringLiteral("path")) == c[0] && file.value(QStringLiteral("projectTitle")) == c[1] && !file.value(QStringLiteral("missing")).toBool() &&
             file.value(QStringLiteral("conflictAt")).toString().isEmpty();
    }, QStringLiteral("the page to say it is %1 of %2").arg(c[0], c[1]));
    world.waitFor([&] { return fake(world.mc).syncs >= 1; }, QStringLiteral("showing the page to read its file again"));
  });
  step(QStringLiteral("the user shows the file of the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    lookAtPage(world, page);
    expectShown(world, [&] { return !shownFile(world).isEmpty(); }, QStringLiteral("the page to say it is a file"));
    actOnPage(world, page, QStringLiteral("space.page.showFile"), {});
  });
  step(QStringLiteral("the file viewer shows %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return world.native().controller<NavigationController>()->route().kind == QLatin1String("thread") && filesteps::panel(world)->projectId() == c[1] &&
             filesteps::files(world).openPath() == c[0];
    }, [&] { return QStringLiteral("the Files tab of %1 to show %2; it shows \"%3\" of %4").arg(c[1], c[0], filesteps::files(world).openPath(), filesteps::panel(world)->projectId()); });
  });
  step(QStringLiteral("the thread's row changes (\\d+) times"), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).listings = 0;
    for (int i = 0; i < c[0].toInt(); ++i) {
      QJsonObject row = world.mc.threads.value(kThread);
      row.insert(QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:%1:00Z").arg(i + 1, 2, 10, QLatin1Char('0')));
      world.mc.threads.insert(kThread, row);
      world.mc.sendRow(kThread, row);
    }
    world.sync();
  });
  step(QStringLiteral("the MC is not asked for the files of %1 again").arg(q), [](World& world, const Captures&, const Table&) {
    world.sync();
    if (fake(world.mc).listings != 0) fail(QStringLiteral("the MC was asked for them %1 more times").arg(fake(world.mc).listings));
  });
  step(QStringLiteral("a newer thread of %1 works in a worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureProject(world, c[0]);
    const QString id = QStringLiteral("thread-worktree");
    world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Draft")}, {QStringLiteral("projectId"), c[0]},
                                 {QStringLiteral("worktreePath"), QStringLiteral("/work/%1-worktree").arg(c[0])},
                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")}});
    world.mc.sendRow(id, world.mc.threads.value(id));
    world.sync();
  });
  step(QStringLiteral("the file viewer shows the project's own %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.mc.environmentId + QLatin1Char(':') + kThread;
    world.waitFor([&] {
      const auto route = world.native().controller<NavigationController>()->route();
      return route.kind == QLatin1String("thread") && route.threadKey == key && filesteps::files(world).openPath() == c[0];
    }, [&] {
      return QStringLiteral("the Files tab of %1's thread on its folder (%2) to show %3; the route is %4, showing \"%5\"")
          .arg(c[1], key, c[0], world.native().controller<NavigationController>()->route().threadKey, filesteps::files(world).openPath());
    });
  });
  step(QStringLiteral("an agent in %1 deleted %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.remove(c[1]);
    // As the MC's watcher sees it go.
    const auto [space, page] = pageOfFile(world.mc, c[0], c[1]);
    if (!page.isEmpty()) loseFile(world.mc, space, page);
    world.sync();
  });
  step(QStringLiteral("the page says its file is gone"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return shownFile(world).value(QStringLiteral("missing")).toBool(); }, QStringLiteral("the page to say its file is gone"));
  });
  step(QStringLiteral("the file won over the user's edit of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("paragraph"), QStringLiteral("An edit of mine."));
    const QString space = current(world);
    const QString page = idOfPage(world, c[0]);
    QString& contents = fakeFiles(world.mc).files[text(one(world.mc, streamOf(space), QStringLiteral("page"), page).value(QLatin1String("file")).toObject(), QLatin1String("path"))];
    contents += QStringLiteral("\n\nAn agent's line.");
    takeFile(world.mc, space, page, {{QStringLiteral("conflictAt"), stamp(world.mc)}});
    noteEdits(world.mc, space, kFile);
    world.sync();
  });
  step(QStringLiteral("the page says the file changed under the user's edit and the edit is in its history"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return !shownFile(world).value(QStringLiteral("conflictAt")).toString().isEmpty(); }, QStringLiteral("the page to say the file won"));
    showHistory(world, viewOf(world)->pageId());
    expectShown(world, [&] {
      const QList<QVariantMap> versions = viewOf(world)->history()->versions()->rows();
      return versions.size() >= 2 && versions.first().value(QStringLiteral("byFile")).toBool() && !versions.at(1).value(QStringLiteral("byFile")).toBool();
    }, QStringLiteral("the history to hold the file's version over the user's edit"));
  });
  step(QStringLiteral("the user unlinks the page %1 from its file").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    lookAtPage(world, page);
    expectShown(world, [&] { return !shownFile(world).isEmpty(); }, QStringLiteral("the page to say it is a file"));
    actOnPage(world, page, QStringLiteral("space.page.unlinkFile"), {});
  });
  step(QStringLiteral("the page no longer says it is a file"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return shownFile(world).isEmpty(); }, QStringLiteral("the page to be an ordinary page"));
    expect(fakeFiles(world.mc).files.contains(QStringLiteral("docs/guide.md")), QStringLiteral("unlinking the page deleted its file"));
  });
  step(QStringLiteral("%1 of %1 was rewritten outside HAL-C2 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QString(c[2]).replace(QStringLiteral("\\n"), QStringLiteral("\n")));
  });
  // The worktree's copy is the thread's alone; the MC lists and opens the project folder's files.
  step(QStringLiteral("a thread of %1 works in a worktree where %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureProject(world, c[0]);
    fake(world.mc).onWorktree = true;
  });
  step(QStringLiteral("the user opens the project's copy of %1 in a Space from its menu").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world, kProject, fake(world.mc).onWorktree);
    filesteps::choose(world, c[0], QStringLiteral("fileEntryOpenInSpace"));
    QQuickItem* item = filesteps::menuEntry(world, QStringLiteral("fileEntryMenu"), QStringLiteral("fileEntryOpenInSpace"));
    expect(item != nullptr && item->property("text").toString().contains(QStringLiteral("project's copy")),
           QStringLiteral("the entry did not say it opens the project's copy: %1").arg(item ? item->property("text").toString() : QString()));
    world.sync();
  });
  step(QStringLiteral("the page %1 shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Already open where the file opened it, which may be another Space than the scenario's.
    if (viewOf(world)->page().value(QStringLiteral("title")).toString() != c[0]) lookAtFilePage(world, c[0]);
    expectShown(world, [&] { return blockTexts(world).contains(c[1]); }, QStringLiteral("the page %1 to say %2").arg(c[0], c[1]));
  });
});

}  // namespace

namespace mermaid {

bool onPage(World& world) {
  return world.brick && findEditor(world.brick->root(), QStringLiteral("spaceBlocks"));
}

void expectPageSource(World& world) {
  const QString source = world.mc.part<Diagram>().source;
  world.waitFor([&] {
    QQuickItem* editor = findEditor(world.brick->root(), QStringLiteral("spaceBlockEditor:") + source);
    return editor && editor->isVisible() && editor->property("text") == source && asked(world) == 1;
  }, [&] { return QStringLiteral("the diagram's source; %1").arg(describe(world)); });
  expect(drawn(world).isEmpty(), QStringLiteral("a picture is drawn"));
}

}  // namespace mermaid
