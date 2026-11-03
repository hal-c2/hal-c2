// Pages in a Space on the phone (features/space/pages.feature, self-updating-pages.feature, visualize.feature, markdown.feature,
// project-files.feature): the screens of
// SpaceScreen.qml, tapped and typed into as the user does, against the MC's
// `space.*` calls. The MC's side is the desktop's fake (its SpaceSteps.cpp) over
// this client's streams (FakeThreads.h, served by ComposerSteps.cpp). What the
// screens do not let a user try (a blank name, ticking a paragraph, writing on a
// page in the trash) is dispatched as an action, which is what the scenario is
// about: how the MC's refusal reaches the user.

#include <QAbstractItemModel>
#include <QBuffer>
#include <QDateTime>
#include <QFile>
#include <QFontInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSet>
#include <QTest>

#include <algorithm>
#include <memory>
#include <optional>
#include <utility>

#include "CodeFence.h"
#include "CommandRegistry.h"
#include "FakeFiles.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Mermaid.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "Space.h"
#include "SpaceController.h"
#include "WorkspaceFiles.h"
#include "World.h"

// ComposerSteps.cpp's: the providers the MC offers, pushed to the phone.
void offerProviders(FakeMc& mc, const QJsonArray& providers);

namespace {

using S = QString;

const QString kIndex = QStringLiteral("spaces");
// The project of the phone's threads, whose files are the Files tab's.
const QString kProject = QStringLiteral("shop");
const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

// The page's prompt (space/prompt.feature), which the agent's steps ask through.
QVariantMap prompt(World& world);
QQuickItem* promptEditor(QQuickItem* composer);
QQuickItem* typeInPrompt(World& world, const QString& title, const QString& text);
void sendPrompt(World& world, QQuickItem* composer);

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
  bool ignoresStop = false;
  int stops = 0;
  // What the last ask carried, as the MC was sent it.
  QJsonObject lastAsk;
  // Who is on each page: the other devices, and the agents by thread title.
  QHash<QString, QStringList> devices;
  QHash<QString, QStringList> agents;
  // Whether a client asking who is on a page is turned down.
  bool viewersRefused = false;
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
  // What each stream was sent, where the current Space's log stood when a
  // block moved, and what the client's blocks did since.
  struct Change {
    QString kind;
    QString id;
    QJsonObject patch;
  };
  QHash<QString, QList<Change>> log;
  qsizetype mark = 0;
  QStringList seen;
  // Another client following the Spaces (and, once it chose one, a Space).
  std::unique_ptr<SpacePages> second;
  // How the next scan of a project's files answers, and the files read again
  // because a client showed their page.
  QString scan = QStringLiteral("written");
  int syncs = 0;
  // How many times a client asked for a project's files.
  int listings = 0;
  // The link the agent's message has.
  QString link;
  // Whether the thread whose files the user browses works in a worktree of the
  // project, and the files only that worktree has: its Files tab shows them,
  // the MC neither lists nor opens them.
  bool onWorktree = false;
  QSet<QString> worktreeOnly;
  // The files of each project but the scenario's, whose are the Files tab's.
  QHash<QString, QMap<QString, QString>> projectFiles;
};

FakeSpaces& fake(FakeMc& mc) {
  return mc.part<FakeSpaces>();
}

QString stamp(FakeMc& mc) {
  return QDateTime::fromString(kNow, Qt::ISODate).addSecs(++fake(mc).clock).toString(Qt::ISODate);
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
           {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}},
          {{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), streams.seq}}};
}

// One change to an entity of `stream`, kept in its log and sent to whoever
// follows it ({"s": set, "d": delete}).
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
  fake(mc).log[stream].append({kind, id, patch});
  QJsonObject events{{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq},
                     {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, kNow})}}};
  for (const int follower : mc.subscribers(QStringLiteral("stream"))) {
    if (mc.shapeOf(follower).value(QLatin1String("stream")).toString() != stream) continue;
    events.insert(QStringLiteral("id"), follower);
    mc.send(events);
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
      line = QString(block.value(QLatin1String("level")).toInt(2), QLatin1Char('#')) + QLatin1Char(' ') + said;
    } else if (kind == QLatin1String("checklist")) {
      line = (block.value(QLatin1String("checked")).toBool() ? QStringLiteral("- [x] ") : QStringLiteral("- [ ] ")) + said;
    } else if (kind == QLatin1String("callout")) {
      QStringList quoted;
      for (const QString& part : said.split(QLatin1Char('\n'))) quoted.append((QStringLiteral("> ") + part).trimmed());
      line = quoted.join(QLatin1Char('\n'));
    } else if (kind == QLatin1String("code")) {
      line = codeFence::write(block);
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
  static const QRegularExpression notParagraph(QStringLiteral("^(#{1,6}\\s|>|\\s*[-*]\\s+\\[[ xX]\\])"));
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
    } else if (!codeFence::opens(line).isEmpty()) {
      const auto [fenced, next] = codeFence::read(lines, i, block);
      blocks.append(fenced);
      i = next;
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
      for (; i < lines.size() && !lines.at(i).trimmed().isEmpty() && !notParagraph.match(lines.at(i)).hasMatch() &&
             codeFence::opens(lines.at(i)).isEmpty();
           ++i) {
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
  static const QStringList kinds{QStringLiteral("paragraph"), QStringLiteral("heading"), QStringLiteral("checklist"), QStringLiteral("bullet"),
                                 QStringLiteral("numbered"), QStringLiteral("callout"), QStringLiteral("divider"), QStringLiteral("subpage_link"),
                                 QStringLiteral("image"), QStringLiteral("raw"), QStringLiteral("table"), QStringLiteral("code"),
                                 QStringLiteral("footnote"), QStringLiteral("details"), QStringLiteral("details_end")};
  const QString kind = text(spec, QLatin1String("kind"));
  if (!kinds.contains(kind)) return refused(QStringLiteral("invalid"), QStringLiteral("There is no block kind %1.").arg(kind));
  const QString linked = text(spec, QLatin1String("linkedPageId"));
  if (kind == QLatin1String("subpage_link") && one(mc, streamOf(space), QStringLiteral("page"), linked).isEmpty()) {
    return refused(QStringLiteral("notFound"), QStringLiteral("A subpage link needs a page to link to."));
  }
  const QString imageId = text(spec, QLatin1String("imageId"));
  const QJsonObject image = one(mc, streamOf(space), QStringLiteral("image"), imageId);
  const QString url = text(spec, QLatin1String("url"));
  if (kind == QLatin1String("image") && url.isEmpty()) {
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
  if (kind == QLatin1String("heading") && spec.contains(QLatin1String("level"))) block.insert(QStringLiteral("level"), spec.value(QLatin1String("level")));
  if (kind == QLatin1String("subpage_link")) block.insert(QStringLiteral("linkedPageId"), linked);
  if (kind == QLatin1String("image") && !url.isEmpty()) {
    block.insert(QStringLiteral("url"), url);
  } else if (kind == QLatin1String("image")) {
    block.insert(QStringLiteral("imageId"), imageId);
    if (text(block, QLatin1String("text")).isEmpty()) block.insert(QStringLiteral("text"), image.value(QLatin1String("name")));
  }
  // The fields only some kinds keep, as the MC's `with_extras` keeps them.
  const bool code = kind == QLatin1String("code");
  const bool item = kind == QLatin1String("bullet") || kind == QLatin1String("numbered") || kind == QLatin1String("checklist");
  const std::pair<QLatin1String, bool> extras[] = {
      {QLatin1String("language"), code},
      {QLatin1String("fence"), code},
      {QLatin1String("info"), code},
      {QLatin1String("depth"), item && spec.value(QLatin1String("depth")).toInt() != 0},
      {QLatin1String("indent"), item},
      {QLatin1String("marker"), QStringList{QStringLiteral("bullet"), QStringLiteral("numbered"), QStringLiteral("divider"), QStringLiteral("callout"),
                                            QStringLiteral("details")}.contains(kind)},
      {QLatin1String("start"), kind == QLatin1String("numbered") && spec.value(QLatin1String("start")).toInt(1) != 1},
      {QLatin1String("alert"), kind == QLatin1String("callout")},
      {QLatin1String("label"), kind == QLatin1String("footnote")},
  };
  for (const auto& [field, kept] : extras) {
    if (kept && spec.contains(field) && !spec.value(field).isNull()) block.insert(field, spec.value(field));
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

// What the files of `project` say, by path.
QMap<QString, QString>& filesOf(FakeMc& mc, const QString& project) {
  return project == kProject ? fakeFiles(mc).files : fake(mc).projectFiles[project];
}

// The project's own Space (`HalC2.Space.project_space/2`), made the first time one of its files opens.
QString projectSpace(FakeMc& mc, const QString& project, bool make = false) {
  for (const QJsonObject& space : all(mc, kIndex, QStringLiteral("projectSpace"))) {
    if (text(space, QLatin1String("projectId")) == project) return text(space, QLatin1String("id"));
  }
  if (!make) return {};
  const QString id = newId(mc, QStringLiteral("space"));
  const QString at = stamp(mc);
  set(mc, kIndex, QStringLiteral("projectSpace"), id,
      {{QStringLiteral("id"), id}, {QStringLiteral("name"), text(mc.projects.value(project), QLatin1String("title"))}, {QStringLiteral("projectId"), project},
       {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}});
  return id;
}

// The page that is `path` of `project`, with its Space, the project's; none when no page is.
std::pair<QString, QJsonObject> pageOfFile(FakeMc& mc, const QString& project, const QString& path) {
  for (const QJsonObject& space : all(mc, kIndex, QStringLiteral("projectSpace"))) {
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
  const QString contents = filesOf(mc, text(file, QLatin1String("projectId"))).value(text(file, QLatin1String("path")));
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
    const QMap<QString, QString>& contents = filesOf(mc, project);
    for (auto it = contents.cbegin(); it != contents.cend(); ++it) {
      if (!spaceFile(it.key()) || fake(mc).worktreeOnly.contains(it.key())) continue;
      const auto [space, page] = pageOfFile(mc, project, it.key());
      const QJsonValue open = page.isEmpty() ? QJsonValue(QJsonValue::Null)
                                             : QJsonValue(QJsonObject{{QStringLiteral("spaceId"), space}, {QStringLiteral("pageId"), page.value(QLatin1String("id"))},
                                                                      {QStringLiteral("title"), page.value(QLatin1String("title"))}});
      files.append(QJsonObject{{QStringLiteral("relativePath"), it.key()}, {QStringLiteral("kind"), QStringLiteral("page")}, {QStringLiteral("page"), open}});
    }
    const QString space = projectSpace(mc, project);
    return {{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), files},
             {QStringLiteral("spaceId"), space.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(space)}}};
  }
  if (method == QLatin1String("files.scan")) {
    return {{{QStringLiteral("status"), fake(mc).scan},
             {QStringLiteral("entries"), QJsonArray{QJsonObject{{QStringLiteral("path"), QStringLiteral("**/*.md")}, {QStringLiteral("kind"), QStringLiteral("page")}}}}}};
  }
  return refused(QStringLiteral("invalid"), QStringLiteral("space.%1 is missing a required field.").arg(method));
}

// `space.page.syncFile`: the file read again; what changed in it is the page's.
Answer syncFile(FakeMc& mc, const QString& space, const QJsonObject& page) {
  ++fake(mc).syncs;
  const QJsonObject file = page.value(QLatin1String("file")).toObject();
  if (file.isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("The page is not a project file."));
  const QString id = text(page, QLatin1String("id"));
  const QMap<QString, QString>& files = filesOf(mc, text(file, QLatin1String("projectId")));
  const QString path = text(file, QLatin1String("path"));
  if (!files.contains(path)) {
    loseFile(mc, space, page);
  } else if (hashOf(files.value(path)) != text(file, QLatin1String("hash")) || file.value(QLatin1String("missing")).toBool()) {
    takeFile(mc, space, id);
  }
  return {{{QStringLiteral("page"), one(mc, streamOf(space), QStringLiteral("page"), id)}}};
}

// `space.page.openFile`: the file's page, made in the project's Space unless it has one.
Answer openFile(FakeMc& mc, const QJsonObject& in) {
  const QString project = text(in, QLatin1String("projectId"));
  const QString path = text(in, QLatin1String("relativePath"));
  if (path.startsWith(QLatin1Char('/')) || path.split(QLatin1Char('/')).contains(QStringLiteral(".."))) {
    return refused(QStringLiteral("invalid"), QStringLiteral("%1 is outside the project.").arg(path));
  }
  if (!mc.projects.contains(project)) return refused(QStringLiteral("notFound"), QStringLiteral("There is no project %1 on this MC.").arg(project));
  if (!spaceFile(path)) return refused(QStringLiteral("notSpaceFile"), QStringLiteral("%1 is not in the spaces section of the project.").arg(path));
  // The page the file already is, read again: one whose file is gone says so.
  if (const auto [where, page] = pageOfFile(mc, project, path); !page.isEmpty()) {
    const QJsonObject synced = syncFile(mc, where, page).result.value(QLatin1String("page")).toObject();
    return {{{QStringLiteral("spaceId"), where}, {QStringLiteral("page"), synced}, {QStringLiteral("created"), false}}};
  }
  if (!filesOf(mc, project).contains(path) || fake(mc).worktreeOnly.contains(path)) {
    return refused(QStringLiteral("notFound"), QStringLiteral("There is no file %1 in the project %2.").arg(path, project));
  }
  const QString contents = filesOf(mc, project).value(path);
  const QString space = projectSpace(mc, project, true);
  const QJsonObject file{{QStringLiteral("projectId"), project},  {QStringLiteral("path"), path},       {QStringLiteral("hash"), hashOf(contents)},
                         {QStringLiteral("size"), contents.toUtf8().size()}, {QStringLiteral("missing"), false}, {QStringLiteral("conflictAt"), QJsonValue::Null}};
  Answer made = importMarkdown(mc, space, contents, {}, QJsonValue::Null, {{QStringLiteral("file"), file}}, kFile);
  if (!made.error.isEmpty()) return made;
  made.result.insert(QStringLiteral("spaceId"), space);
  made.result.insert(QStringLiteral("created"), true);
  return made;
}

// The summary text generation writes of a thread.
const QString kSummaryTitle = QStringLiteral("Release plan");
const QString kSummary = QStringLiteral("Ship pages on Friday, once the Space streams are in.");

QJsonObject spaceOf(FakeMc& mc, const QString& id) {
  return one(mc, kIndex, QStringLiteral("space"), id);
}

// A Space of the user's or of a project, for what any page does.
bool anySpace(FakeMc& mc, const QString& id) {
  return !spaceOf(mc, id).isEmpty() || !one(mc, kIndex, QStringLiteral("projectSpace"), id).isEmpty();
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
    fake(mc).lastAsk = in;
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
  const auto nextRun = [&] { return QDateTime::fromString(kNow, Qt::ISODate).addSecs(3600 + ++fake(mc).clock).toString(Qt::ISODate); };
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
// Where an ask from a page would run: the project of the thread the user last worked in.
Answer agentTarget(FakeMc& mc) {
  QJsonValue project = mc.projects.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(mc.projects.firstKey());
  QString latest;
  for (const QJsonObject& thread : std::as_const(mc.threads)) {
    const QString at = text(thread, QLatin1String("updatedAt"));
    if (at < latest || !mc.projects.contains(text(thread, QLatin1String("projectId")))) continue;
    latest = at;
    project = thread.value(QLatin1String("projectId"));
  }
  return {{{QStringLiteral("projectId"), project}}};
}

Answer call(FakeMc& mc, const QString& method, const QJsonObject& in) {
  if (method == QLatin1String("page.agentTarget")) return agentTarget(mc);
  if (method.endsWith(QLatin1String("Agent"))) return agentCall(mc, method, in);
  const bool history = method == QLatin1String("page.history") || method == QLatin1String("page.version") || method == QLatin1String("page.restoreVersion");
  const Answer answer = history ? historyCall(mc, method, in) : decide(mc, method, in);
  const bool fromFile = method == QLatin1String("page.openFile") || method == QLatin1String("page.syncFile");
  // A file opens in its project's Space, which the answer names.
  const QString space = method == QLatin1String("page.openFile") ? text(answer.result, QLatin1String("spaceId")) : text(in, QLatin1String("spaceId"));
  if (space.isEmpty()) return answer;
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
  if (method == QLatin1String("page.openFile")) return openFile(mc, in);
  if (!anySpace(mc, space)) return refused(QStringLiteral("notFound"), QStringLiteral("There is no Space %1.").arg(space));
  if (method.startsWith(QLatin1String("image."))) return imageCall(mc, space, method, in);
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
  if (method == QLatin1String("block.insert")) {
    return insertBlock(mc, space, pageId, in, in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined, kUser);
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
  mc.send(QJsonObject{{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("MC unavailable: noconnection")}});
  mc.forget(id);
}

// Whoever has `page` open hears who is on it now.
void tellViewers(FakeMc& mc, const QString& page) {
  for (const int id : mc.subscribers(QStringLiteral("spacePresence"))) {
    if (mc.connected() && mc.shapeOf(id).value(QLatin1String("pageId")).toString() == page) mc.send(viewersFrame(mc, id, page));
  }
}

const FakeMc::Extension spaceCalls([](FakeMc& mc) {
  mc.onShape(QStringLiteral("spacePresence"), [&mc](int id, const QJsonObject& shape) {
    if (fake(mc).viewersRefused) return refuseViewers(mc, id);
    mc.send(viewersFrame(mc, id, shape.value(QLatin1String("pageId")).toString()));
  });
  mc.onRpc(QStringLiteral("space."), [&mc](const FakeMc::Rpc& rpc) {
    const auto respond = [&mc, rpc] {
      const Answer answer = call(mc, rpc.method.mid(6), rpc.payload);
      fake(mc).lastMethod = rpc.method;
      fake(mc).last = answer;
      if (answer.error.isEmpty()) {
        mc.reply(rpc, answer.result);
      } else {
        mc.refuse(rpc, answer.error, answer.detail);
      }
    };
    // A page from a thread waits on text generation: nothing is written until then.
    if (rpc.method == QLatin1String("space.page.createFromThread") && mc.holding(QStringLiteral("pageFromThread"))) return mc.defer(respond);
    respond();
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

// The item named `objectName` in `item`'s tree, or null.
QQuickItem* named(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = named(child, objectName)) return found;
  }
  return nullptr;
}

// The visible blocks of a page, top to bottom, each as the lines of Markdown it shows.
QStringList shownMarkdown(QQuickItem* root) {
  QList<QQuickItem*> blocks;
  const std::function<void(QQuickItem*)> collect = [&](QQuickItem* item) {
    if (item->objectName().startsWith(QLatin1String("spaceBlock:")) && item->isVisible()) blocks.append(item);
    for (QQuickItem* child : item->childItems()) collect(child);
  };
  collect(root);
  std::sort(blocks.begin(), blocks.end(), [](QQuickItem* a, QQuickItem* b) { return a->mapToScene({}).y() < b->mapToScene({}).y(); });
  QStringList lines;
  for (QQuickItem* block : blocks) {
    const QString said = block->property("text").toString();
    const auto shown = [&](const QString& name) {
      QQuickItem* item = named(block, name + said);
      return item && item->isVisible() ? item->property("text").toString() : QString();
    };
    QQuickItem* tick = named(block, S("spaceTick:") + said);
    const QString ticked = tick && tick->isVisible() ? (block->property("checked").toBool() ? S("- [x] ") : S("- [ ] ")) : QString();
    QStringList own;
    if (const QString above = shown(S("spaceMarkdownAbove:")); !above.isEmpty()) own.append(above);
    own.append((shown(S("spaceMarkdownLead:")) + ticked + shown(S("spaceBlockEditor:")) + shown(S("spaceBlockText:")) + shown(S("spaceMarkdownTail:")))
                   .split(QLatin1Char('\n')));
    if (const QString below = shown(S("spaceMarkdownBelow:")); !below.isEmpty()) own.append(below);
    for (const QString& line : own) {
      if (line.isEmpty()) continue;
      lines.append(block->property("kind").toString() == QLatin1String("callout") ? S("> ") + line : line);
    }
  }
  return lines;
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

// The diagram a page holds, as its block's text is now.
struct Diagram {
  QString source;
};

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

void expectShown(World& world, const std::function<bool()>& shown, const QString& wanted) {
  world.waitFor(shown, [&] { return QStringLiteral("%1; %2").arg(wanted, describe(world)); });
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
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

std::optional<QVariantMap> rowOf(const SpaceRows* rows, const QString& id) {
  const int row = rows->indexOf(id);
  if (row < 0) return std::nullopt;
  return rows->get(row);
}

// Another client of the MC following the Spaces, and the Space `id` when set.
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

// `attachments.createUploadUrl` and the upload it hands out: the phone's scenarios
// have no other use for them, and what the bytes are is the MC's to check.
void takeUploads(World& world) {
  const QString url = QStringLiteral("/api/attachments/upload/token");
  world.mc.onHttp(url, [](const QJsonObject&, std::function<void(int, const QJsonObject&)> respond) { respond(204, {}); });
  world.mc.onRpc(QStringLiteral("attachments.createUploadUrl"), [&mc = world.mc, url](const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{QStringLiteral("attachmentId"), QStringLiteral("pending-1")}, {QStringLiteral("relativeUrl"), url}, {QStringLiteral("expiresAt"), 4102444800000.0}});
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

SpacePages& second(World& world) {
  SpacePages* pages = fake(world.mc).second.get();
  if (!pages) fail(QStringLiteral("no second client is watching"));
  return *pages;
}

// --- The screens ------------------------------------------------------------

NavigationController* navigation(World& world) {
  return world.native().controller<NavigationController>();
}

// The step of the Space screen on show, "" when it is not.
QString shown(World& world) {
  QQuickItem* screen = world.find(S("spaceScreen"));
  return screen ? screen->property("view").toString() : QString();
}

void expectStep(World& world, const QString& wanted) {
  world.waitFor([&] { return shown(world) == wanted; }, [&] { return S("the screen to show %1, not \"%2\"; %3").arg(wanted, shown(world), describe(world)); });
}

// The user takes Android's Back until the screen shows `wanted`.
void backTo(World& world, const QString& wanted) {
  static const QStringList order{S("spaces"), S("pages"), S("images"), S("page"), S("deck"), S("comments"), S("history"), S("version")};
  while (order.indexOf(shown(world)) > order.indexOf(wanted)) {
    const QString was = shown(world);
    world.back();
    world.waitFor([&] { return shown(world) != was; }, [&] { return S("Back to leave %1").arg(was); });
  }
  expectStep(world, wanted);
}

// The Space screen, open and following the MC's Spaces: from home by its button.
void openSpaces(World& world) {
  if (navigation(world)->route().kind != QLatin1String("space")) {
    if (QQuickItem* button = world.find(S("spaces"))) {
      world.tap(button);
    } else {
      world.bridge().dispatch(SpaceController::kOpen, QVariantMap{});
    }
  }
  world.waitFor([&] { return viewOf(world)->index().live() && viewOf(world)->spaces()->rowCount() > 0; },
                [&] { return S("the Space view to follow the Spaces; %1").arg(describe(world)); });
  world.waitFor([&] { return !shown(world).isEmpty(); }, S("the Space screen"));
}

// Everything the user chose is on its way: no sheet or dialog in front.
void settle(World& world) {
  world.awaitPopup(S("spaceSheet"), false);
  world.awaitPopup(S("spaceTextDialog"), false);
  world.sync();
}

void choose(World& world, const QString& id) {
  world.awaitPopup(S("spaceSheet"));
  world.tap(S("spaceSheetItem:") + id);
}

// What the user writes in the dialog that asked, and its action.
void answer(World& world, const QString& written) {
  world.awaitPopup(S("spaceTextDialog"));
  world.type(written);
  world.tap(S("spaceTextSave"));
  settle(world);
}

// The pages of the Space `id`, on screen.
void look(World& world, const QString& id) {
  openSpaces(world);
  world.waitFor([&] { return viewOf(world)->spaces()->indexOf(id) >= 0; }, [&] { return S("the Space to be listed; %1").arg(describe(world)); });
  if (shown(world) != QLatin1String("spaces") && viewOf(world)->spaceId() == id) {
    backTo(world, S("pages"));
  } else {
    backTo(world, S("spaces"));
    const QString name = viewOf(world)->spaces()->get(viewOf(world)->spaces()->indexOf(id)).value(S("name")).toString();
    world.tap(S("spaceRow:") + name);
    expectStep(world, S("pages"));
  }
  world.waitFor([&] { return viewOf(world)->spaceId() == id && viewOf(world)->space().live(); },
                [&] { return S("the Space to be followed; %1").arg(describe(world)); });
}

// The page `id` of the scenario's Space, opened from the tree or the trash.
void lookAtPage(World& world, const QString& id) {
  static const QStringList onPage{S("page"), S("comments"), S("history"), S("version")};
  if (viewOf(world)->pageId() == id && onPage.contains(shown(world))) {
    backTo(world, S("page"));
    return;
  }
  look(world, current(world));
  world.waitFor([&] { return viewOf(world)->pages()->indexOf(id) >= 0 || viewOf(world)->trash()->indexOf(id) >= 0; },
                [&] { return S("the Space to list the page; %1").arg(describe(world)); });
  const int row = viewOf(world)->pages()->indexOf(id);
  world.tap(row >= 0 ? S("spacePage:") + viewOf(world)->pages()->get(row).value(S("title")).toString()
                     : S("spaceTrashRow:") + viewOf(world)->trash()->get(viewOf(world)->trash()->indexOf(id)).value(S("title")).toString());
  expectStep(world, S("page"));
  expect(viewOf(world)->pageId() == id, S("another page opened: %1").arg(describe(world)));
}

// The deck `title` of the scenario's Space, or "" when there is none.
QString findDeck(World& world, const QString& title) {
  for (const QJsonObject& deck : all(world.mc, streamOf(current(world)), S("deck"))) {
    if (text(deck, QLatin1String("title")) == title) return text(deck, QLatin1String("id"));
  }
  return {};
}

QString idOfDeck(World& world, const QString& title) {
  const QString id = findDeck(world, title);
  expect(!id.isEmpty(), S("the Space has no deck %1").arg(title));
  return id;
}

QString givenDeck(World& world, const QString& title) {
  if (const QString id = findDeck(world, title); !id.isEmpty()) return id;
  return text(given(world, S("deck.create"), {{S("title"), title}}).value(QLatin1String("deck")).toObject(), QLatin1String("id"));
}

QJsonObject slideTitled(World& world, const QString& title) {
  for (const QJsonObject& slide : all(world.mc, streamOf(current(world)), S("slide"))) {
    if (text(slide, QLatin1String("title")) == title) return slide;
  }
  fail(S("the Space has no slide %1").arg(title));
}

QString idOfSlide(World& world, const QString& title) {
  return text(slideTitled(world, title), QLatin1String("id"));
}

// The deck `id` of the scenario's Space, opened from its list or the trash.
void lookAtDeck(World& world, const QString& id) {
  if (viewOf(world)->deckId() == id && shown(world) == QLatin1String("deck")) return;
  look(world, current(world));
  SpaceController* view = viewOf(world);
  world.waitFor([&] { return view->decks()->indexOf(id) >= 0 || view->deckTrash()->indexOf(id) >= 0; },
                [&] { return S("the Space to list the deck; %1").arg(describe(world)); });
  const int row = view->decks()->indexOf(id);
  world.tap(row >= 0 ? S("spaceDeck:") + view->decks()->get(row).value(S("title")).toString()
                     : S("spaceDeckTrashRow:") + view->deckTrash()->get(view->deckTrash()->indexOf(id)).value(S("title")).toString());
  expectStep(world, S("deck"));
  expect(view->deckId() == id, S("another deck opened: %1").arg(describe(world)));
}

// The row of the slide `title` on its open deck.
QString openSlide(World& world, const QString& title) {
  const QJsonObject slide = slideTitled(world, title);
  lookAtDeck(world, text(slide, QLatin1String("deckId")));
  const QString id = text(slide, QLatin1String("id"));
  world.waitFor([&] { return viewOf(world)->slides()->indexOf(id) >= 0; }, [&] { return S("the deck to list the slide %1").arg(title); });
  return QString::number(viewOf(world)->slides()->indexOf(id));
}

// The menu of the slide `title`, `choice` taken from it.
void slideMenu(World& world, const QString& title, const QString& choice) {
  world.tap(S("spaceSlideMenu:") + openSlide(world, title));
  choose(world, choice);
}

// The menu of a deck in the list, `choice` taken from it.
void deckMenu(World& world, const QString& title, const QString& choice) {
  look(world, current(world));
  world.tap(S("spaceDeckMenu:") + title);
  choose(world, choice);
}

// The user does what no screen offers, to see the MC's answer reach them.
void act(World& world, const QString& action, const QVariantMap& payload) {
  world.bridge().dispatch(action, payload);
  world.sync();
}

QJsonObject everyHours(const QString& hours) {
  return {{QStringLiteral("type"), QStringLiteral("interval")}, {QStringLiteral("everyMs"), hours.toDouble() * 3600000.0}};
}

// The open page's update, as its menu asks for it: the instruction, then `cadence`
// from what the sheet offers.
void askUpdate(World& world, const QString& page, const QString& instruction, const std::function<void()>& cadence) {
  lookAtPage(world, idOfPage(world, page));
  world.tap(S("spacePageActions"));
  choose(world, S("update"));
  world.awaitPopup(S("spaceTextDialog"));
  world.type(instruction);
  world.tap(S("spaceTextSave"));
  cadence();
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

// The open page's menu, once the page shows `ready` of its update, `choice` taken.
void updateMenu(World& world, const QString& page, const std::function<bool(const QVariantMap& schedule)>& ready, const QString& choice) {
  expectUpdate(world, page, [&](const QVariantMap& update, const QVariantMap&) { return ready(update); }, QStringLiteral("its update as it stands"));
  world.tap(S("spacePageActions"));
  choose(world, choice);
  settle(world);
}

// The menu of a page in the tree, `choice` taken from it.
void pageMenu(World& world, const QString& title, const QString& choice) {
  look(world, current(world));
  world.tap(S("spacePageMenu:") + title);
  choose(world, choice);
}

void trashMenu(World& world, const QString& title, const QString& choice) {
  look(world, current(world));
  world.tap(S("spaceTrashMenu:") + title);
  choose(world, choice);
}

// The menu of the open page `id`, `choice` taken from it.
void openPageMenu(World& world, const QString& id, const QString& choice) {
  lookAtPage(world, id);
  world.tap(S("spacePageActions"));
  choose(world, choice);
  settle(world);
}

// Waits for what the open page `title` shows of its site to be `wanted`.
void expectSite(World& world, const QString& title, const std::function<bool(const QVariantMap&)>& shown, const QString& wanted) {
  lookAtPage(world, idOfPage(world, title));
  expectShown(world, [&] { return shown(viewOf(world)->page().value(S("site")).toMap()); }, S("%1 to %2").arg(title, wanted));
}

// The link the page was last published on, working or not.
QString linkOf(World& world, const QString& title) {
  const QString link = fake(world.mc).links.value(idOfPage(world, title));
  expect(!link.isEmpty(), S("the page %1 was never published").arg(title));
  return link;
}

// The menu of the block saying `said`, on its page, `choice` taken from it.
void blockMenu(World& world, const QString& said, const QString& choice) {
  lookAtPage(world, text(blockSaying(world, said), QLatin1String("pageId")));
  world.tap(S("spaceBlockMenu:") + said);
  choose(world, choice);
}

// The image block of the open page saying `said`, once there is one.
std::optional<QVariantMap> imageBlock(World& world, const QString& said) {
  for (const QVariantMap& block : viewOf(world)->blocks()->rows()) {
    if (block.value(S("kind")) == QLatin1String("image") && block.value(S("text")) == said) return block;
  }
  return std::nullopt;
}

// The block of the version being read that shows the image; empty when none does.
QVariantMap versionImage(World& world, const QString& said) {
  for (const QVariantMap& block : viewOf(world)->history()->blocks()->rows()) {
    if (block.value(S("kind")) == QLatin1String("image") && block.value(S("text")) == said) return block;
  }
  return {};
}

void expectImageState(World& world, const QString& page, const QString& said, const QString& state) {
  lookAtPage(world, idOfPage(world, page));
  expectShown(world, [&] {
    const auto block = imageBlock(world, said);
    return block && block->value(S("imageState")) == state;
  }, S("%1 to show the image %2 as %3").arg(page, said, state));
}

// The images of the scenario's Space on screen, or those in its trash.
void lookAtImages(World& world, const QString& space, bool trash) {
  if (shown(world) != QLatin1String("images") || viewOf(world)->spaceId() != space) {
    look(world, space);
    world.tap(S("spaceImages"));
    expectStep(world, S("images"));
  }
  QQuickItem* images = world.find(S("spaceImagesView"));
  if (images->property("trashShown").toBool() != trash) world.tap(S("spaceImagesTrash"));
  world.waitFor([&] { return images->property("trashShown").toBool() == trash; }, S("the images to show the wanted list"));
}

// The menu of the image `said`, `choice` taken from it.
void imageMenu(World& world, const QString& said, bool trash, const QString& choice) {
  lookAtImages(world, current(world), trash);
  world.waitFor([&] { return world.find(S("spaceImageMenu:") + said) != nullptr; }, [&] { return S("the image %1 to be listed; %2").arg(said, describe(world)); });
  world.tap(S("spaceImageMenu:") + said);
  choose(world, choice);
  settle(world);
}

bool imageTrashed(World& world, const QString& id) {
  return viewOf(world)->imageTrash()->indexOf(id) >= 0;
}

// The comments of the page `id`, on screen.
void lookAtComments(World& world, const QString& id) {
  lookAtPage(world, id);
  world.tap(S("spaceComments"));
  expectStep(world, S("comments"));
}

void settleHistory(World& world) {
  world.waitFor([&] { return !viewOf(world)->history()->loading(); }, [&] { return S("the history to come; %1").arg(describe(world)); });
}

QJsonObject askedOn(World& world, const QString& title) {
  return one(world.mc, streamOf(current(world)), S("pageAgent"), idOfPage(world, title));
}

// That the page `title`, on screen, says of its agent what `says` wants.
void expectAgent(World& world, const QString& title, const std::function<bool(const QVariantMap&)>& says, const QString& wanted) {
  lookAtPage(world, idOfPage(world, title));
  expectShown(world, [&] { return says(viewOf(world)->agent()); }, S("the page's agent to be %1, it says %2").arg(wanted, show(viewOf(world)->agent())));
}

// The history of the page `id` on screen, opened from the page's menu.
void showHistory(World& world, const QString& id) {
  if (viewOf(world)->pageId() == id && shown(world) == QLatin1String("version")) backTo(world, S("history"));
  if (viewOf(world)->pageId() != id || shown(world) != QLatin1String("history")) {
    lookAtPage(world, id);
    world.tap(S("spacePageActions"));
    choose(world, S("history"));
    settle(world);
    expectStep(world, S("history"));
  }
  settleHistory(world);
}

// The row of the version `back` versions before the newest of the page `title`.
QString versionRow(World& world, const QString& title, int back) {
  showHistory(world, idOfPage(world, title));
  SpaceRows* versions = viewOf(world)->history()->versions();
  world.waitFor([&] { return versions->rowCount() > back; }, [&] { return S("%1 versions; %2").arg(back + 1).arg(show(listOf(versions))); });
  return QString::number(back);
}

void readVersion(World& world, const QString& row) {
  world.tap(S("spaceHistoryRow:") + row);
  expectStep(world, S("version"));
  world.waitFor([&] { return !viewOf(world)->history()->version().isEmpty(); }, [&] { return S("the version to come; %1").arg(describe(world)); });
}

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
  given(world, QStringLiteral("block.visualize"), {{QStringLiteral("pageId"), spaces.asked}, {QStringLiteral("request"), QStringLiteral("signups")}});
  spaces.chart = {};
}

// The same page with a chart missing a number, which the MC would refuse.
void givenUnmatchedChart(World& world, const QString& page) {
  FakeSpaces& spaces = fake(world.mc);
  spaces.asked = givenPage(world, page);
  spaces.chart = chartOf(QStringLiteral("bar"), QStringLiteral("Signups"), kFromThisPage, {{QStringLiteral("May"), 3}, {QStringLiteral("June"), 5}});
  spaces.chart[QStringLiteral("series")] = QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("Signups")}, {QStringLiteral("values"), QJsonArray{3}}}};
  given(world, QStringLiteral("block.visualize"), {{QStringLiteral("pageId"), spaces.asked}, {QStringLiteral("request"), QStringLiteral("signups")}});
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

// The words the dialog asks for: there, the feature's "/visualize" is already said.
QString wordsOf(const QString& request) {
  return QString(request).remove(QRegularExpression(QStringLiteral("^/visualize\\s*")));
}

// --- Project files, as the phone offers them --------------------------------

// The thread whose files the user browses, made with the project's first file.
const QString kFilesThread = S("Tax line");

// The Space files of `project` the client was last told of: {relativePath: {kind, spaceId, pageId, title}}.
QVariantMap listedFiles(World& world, const QString& project) {
  return at(world.state(S("space")), S("files")).toMap().value(project).toMap().value(S("paths")).toMap();
}

void waitForFiles(World& world, const QString& project) {
  world.waitFor([&] { return !listedFiles(world, project).isEmpty(); },
                [&] { return S("the Space files of %1 to be listed; %2").arg(project, describe(world)); });
}

WorkspaceFiles& viewerOf(World& world) {
  return *world.native().controller<RightPanelController>()->files();
}

// The thread of "shop" on screen, reached from wherever the user is.
void inFilesThread(World& world) {
  world.thread = haveThread(world, kFilesThread);
  if (shownThread(world) == kFilesThread) return;
  if (!shown(world).isEmpty()) {
    backTo(world, S("spaces"));
    world.back();
    world.waitFor([&] { return shown(world).isEmpty(); }, S("Back to leave the Spaces"));
  }
  if (shownThread(world) != kFilesThread) openThread(world, kFilesThread);
}

// The thread's Files screen, with its project's Space files known.
void browseFiles(World& world) {
  inFilesThread(world);
  if (!world.find(S("filesPanel"))) world.tap(S("openFiles"));
  world.item(S("filesPanel"));
  waitForFiles(world, S("shop"));
}

// The entry of `path` in the Files screen's tree, its folders opened by a tap each.
QQuickItem* fileEntry(World& world, const QString& path) {
  const QStringList parts = path.split(QLatin1Char('/'));
  for (qsizetype i = 1; i < parts.size(); ++i) {
    QQuickItem* folder = world.item(S("filesEntry-") + parts.mid(0, i).join(QLatin1Char('/')));
    if (!folder->property("expanded").toBool()) world.tap(folder);
  }
  return world.item(S("filesEntry-") + path);
}

// A finger held on the entry of `path` until its menu is up.
void holdEntry(World& world, const QString& path) {
  world.hold(fileEntry(world, path), [&] { return world.popupShowing(S("fileEntryMenu")); }, S("the menu of %1").arg(path));
  world.awaitPopup(S("fileEntryMenu"));
}

void closeEntryMenu(World& world) {
  QObject* menu = world.popup(S("fileEntryMenu"));
  expect(menu != nullptr, S("the Files screen has no entry menu"));
  QMetaObject::invokeMethod(menu, "close");
  world.awaitPopup(S("fileEntryMenu"), false);
}

// The Space `name`, made when the MC has none, as the scenario's.
QString spaceNamed(World& world, const QString& name) {
  for (const QJsonObject& space : all(world.mc, kIndex, S("space"))) {
    if (text(space, QLatin1String("name")) == name) return fake(world.mc).current = text(space, QLatin1String("id"));
  }
  givenSpace(world, name);
  return current(world);
}

// The page open in the Space screen is `title`, in the Space `space` when one is named.
void expectOpened(World& world, const QString& title, const QString& space = {}) {
  expectShown(world, [&] {
    return navigation(world)->route().kind == QLatin1String("space") && viewOf(world)->page().value(S("title")).toString() == title &&
           (space.isEmpty() || viewOf(world)->spaceName() == space) && (!world.find(S("phoneLayout")) || shown(world) == QLatin1String("page"));
  }, S("the page %1 to be open%2").arg(title, space.isEmpty() ? QString() : S(" in ") + space));
}

QVariantMap shownFile(World& world) {
  return viewOf(world)->page().value(S("file")).toMap();
}

// `path` tapped in the file picker, once its project's files are listed and
// the dialog has grown around them: a tap while it re-centres lands beside it.
void pickFile(World& world, const QString& path) {
  world.awaitPopup(S("spaceFilePicker"));
  world.waitFor([&] { return !at(world.state(S("space")), S("picking")).toString().isEmpty(); },
                [&] { return S("a project's files to be offered; %1").arg(describe(world)); });
  waitForFiles(world, at(world.state(S("space")), S("picking")).toString());
  world.sync();
  world.tap(world.item(S("spaceFilePickerFile:") + path));
}

// A tablet's window, where the palette is: the phone layout has none.
void runCommand(World& world, const QString& title) {
  world.resize(1024, 768);
  world.item(S("desktopLayout"));
  world.press(S("mod+k"));
  world.awaitPopup(S("commandPalette"));
  world.type(title);
  world.waitFor([&] { return world.shows(title); }, [&] { return S("the palette to offer %1; it shows %2").arg(title, world.texts().join(S(" | "))); });
  world.press(S("Return"));
  world.awaitPopup(S("commandPalette"), false);
}

// The project `id` on the MC, beside "shop".
void haveProject(World& world, const QString& id) {
  if (world.mc.projects.contains(id)) return;
  world.mc.projects.insert(id, {{S("id"), id}, {S("title"), id}, {S("workspaceRoot"), S("/work/") + id}, {S("scripts"), QJsonArray()},
                                {S("createdAt"), kNow}, {S("updatedAt"), kNow}});
  world.mc.sendRow(id, world.mc.projects.value(id), S("project"));
  world.sync();
}

// The page `title` of a project's Space, with that Space.
std::pair<QString, QJsonObject> filePage(World& world, const QString& title) {
  for (const QJsonObject& space : all(world.mc, kIndex, S("projectSpace"))) {
    const QString id = text(space, QLatin1String("id"));
    for (const QJsonObject& page : all(world.mc, streamOf(id), S("page"))) {
      if (text(page, QLatin1String("title")) == title) return {id, page};
    }
  }
  fail(S("no project's Space has the page %1").arg(title));
}

// The rows of the project sections under the Space's pages.
QList<QVariantMap> sectionRows(World& world) {
  return viewOf(world)->projects()->rows();
}

std::optional<QVariantMap> sectionRow(World& world, const QString& kind, const QString& project, const QString& path = {}) {
  for (const QVariantMap& row : sectionRows(world)) {
    if (row.value(S("kind")) == kind && row.value(S("projectId")) == project && row.value(S("path")) == path) return row;
  }
  return std::nullopt;
}

QString describeSections(World& world) {
  QStringList rows;
  for (const QVariantMap& row : sectionRows(world)) {
    rows.append(S("%1 %2 %3%4").arg(row.value(S("kind")).toString(), row.value(S("projectId")).toString(), row.value(S("path")).toString(),
                                    row.value(S("expanded")).toBool() ? S(" (expanded)") : QString()));
  }
  return S("the sections are [%1]; %2").arg(rows.join(S(", ")), describe(world));
}

// The row of the sections for `kind`, `project` and `path`, scrolled into the
// sections' list first: it builds only the rows on screen.
QQuickItem* sectionItem(World& world, const QString& kind, const QString& project, const QString& path = {}) {
  const QList<QVariantMap> rows = sectionRows(world);
  for (qsizetype i = 0; i < rows.size(); ++i) {
    const QVariantMap& row = rows.at(i);
    if (row.value(S("kind")) != kind || row.value(S("projectId")) != project || row.value(S("path")) != path) continue;
    QMetaObject::invokeMethod(world.item(S("spaceProjects")), "positionViewAtIndex", Q_ARG(int, int(i)), Q_ARG(int, 4 /* ListView.Contain */));
    break;
  }
  const QString name = kind == QLatin1String("project") ? S("spaceProject:") + project
                       : S("spaceProject%1:%2:%3").arg(kind == QLatin1String("file") ? S("File") : S("Folder"), project, path);
  return world.item(name);
}

// The pages of the scenario's Space, or of the first the MC has, where the sections are.
void lookAtSidebar(World& world) {
  // The palette is a tablet's; the sections under test are the phone's.
  if (world.find(S("desktopLayout"))) {
    world.resize(412, 915);
    world.item(S("phoneLayout"));
  }
  if (!fake(world.mc).current.isEmpty()) {
    look(world, current(world));
    return;
  }
  openSpaces(world);
  look(world, viewOf(world)->spaceId().isEmpty() ? viewOf(world)->spaces()->get(0).value(S("id")).toString() : viewOf(world)->spaceId());
}

// The section of `project`, on screen.
QQuickItem* lookAtSection(World& world, const QString& project) {
  lookAtSidebar(world);
  world.waitFor([&] { return sectionRow(world, S("project"), project).has_value(); },
                [&] { return S("a section of %1; %2").arg(project, describeSections(world)); });
  return sectionItem(world, S("project"), project);
}

bool expanded(World& world, const QString& project) {
  const auto row = sectionRow(world, S("project"), project);
  return row && row->value(S("expanded")).toBool();
}

// A tap on the section of `project` when it is not already `open`.
void setSection(World& world, const QString& project, bool open) {
  QQuickItem* section = lookAtSection(world, project);
  if (expanded(world, project) != open) world.tap(section);
  world.waitFor([&] { return expanded(world, project) == open; },
                [&] { return S("the section of %1 to be %2; %3").arg(project, open ? S("expanded") : S("collapsed"), describeSections(world)); });
}

bool folderOpen(World& world, const QString& project, const QString& path) {
  const auto row = sectionRow(world, S("folder"), project, path);
  return row && row->value(S("expanded")).toBool();
}

// The folder's row on screen, in its expanded section.
QQuickItem* lookAtFolder(World& world, const QString& project, const QString& path) {
  lookAtSection(world, project);
  world.waitFor([&] { return sectionRow(world, S("folder"), project, path).has_value(); },
                [&] { return S("the section of %1 to show the folder %2; %3").arg(project, path, describeSections(world)); });
  return sectionItem(world, S("folder"), project, path);
}

void waitForFolder(World& world, const QString& project, const QString& path, bool open) {
  world.waitFor([&] { return sectionRow(world, S("folder"), project, path).has_value() && folderOpen(world, project, path) == open; },
                [&] { return S("the folder %1 of %2 to be %3; %4").arg(path, project, open ? S("expanded") : S("collapsed"), describeSections(world)); });
}

// A tap on the folder when it is not already `open`, or Right or Left on a hardware keyboard.
void setFolder(World& world, const QString& project, const QString& path, bool open, bool keyboard = false) {
  QQuickItem* folder = lookAtFolder(world, project, path);
  if (keyboard) {
    folder->forceActiveFocus(Qt::TabFocusReason);
    expect(folder->hasActiveFocus(), S("the folder %1 of %2 took no keyboard focus").arg(path, project));
    world.press(open ? S("Right") : S("Left"));
  } else if (folderOpen(world, project, path) != open) {
    world.tap(folder);
  }
  waitForFolder(world, project, path, open);
}

// `path` tapped in the expanded section of `project`, through its folders.
void pickInSection(World& world, const QString& project, const QString& path) {
  setSection(world, project, true);
  const QStringList parts = path.split(QLatin1Char('/'));
  for (qsizetype i = 1; i < parts.size(); ++i) setFolder(world, project, parts.mid(0, i).join(QLatin1Char('/')), true);
  world.waitFor([&] { return sectionRow(world, S("file"), project, path).has_value(); },
                [&] { return S("the section of %1 to show %2; %3").arg(project, path, describeSections(world)); });
  world.tap(sectionItem(world, S("file"), project, path));
}

// The file's page on show, from its project's Space, its row showing in its section.
void expectFilePage(World& world, const QString& title, const QString& project) {
  expectOpened(world, title);
  expectShown(world, [&] {
    const QString space = projectSpace(world.mc, project);
    const QString path = shownFile(world).value(S("path")).toString();
    return !space.isEmpty() && viewOf(world)->fileSpaceId() == space && expanded(world, project) && viewOf(world)->projects()->isExpanded(project) &&
           !path.isEmpty() && sectionRow(world, S("file"), project, path).has_value();
  }, S("the page %1 to be shown from its row in the section of %2; %3").arg(title, project, describeSections(world)));
}

// The user picks the page's file in its project's section, the phone's way to
// a file's page; the MC reads the file again each time.
void lookAtFilePage(World& world, const QString& title) {
  const auto [space, page] = filePage(world, title);
  const QString id = text(page, QLatin1String("id"));
  const QJsonObject file = page.value(QLatin1String("file")).toObject();
  const QString project = text(file, QLatin1String("projectId"));
  const QString path = text(file, QLatin1String("path"));
  if (filesOf(world.mc, project).contains(path)) {
    pickInSection(world, project, path);
  } else {
    // A file that is gone has no row, and its page says so: as the row's tap asks for it.
    lookAtSidebar(world);
    act(world, S("space.openFile"), {{S("projectId"), project}, {S("relativePath"), path}});
  }
  expectStep(world, S("page"));
  world.waitFor([&] { return viewOf(world)->fileSpaceId() == space && viewOf(world)->pageId() == id; },
                [&] { return S("the page %1 to be shown from its project's Space; %2").arg(title, describe(world)); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("a connected environment"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    threadList(world);
  });

  // Spaces.
  step(S("the user lists their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
  });
  step(S("the user has listed their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
    // Another start of the app lists them again.
    world.close();
    world.open();
    world.waitFor([&] { return world.native().client()->isReady(); }, S("the app to reconnect"));
  });
  step(S("the Spaces are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    backTo(world, S("spaces"));
    expectShown(world, [&] { return column(viewOf(world)->spaces(), S("name")) == listed(c[0]); }, S("the Spaces to be %1").arg(c[0]));
    for (const QString& name : listed(c[0])) world.item(S("spaceRow:") + name);
  });
  step(S("the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenSpace(world, c[0]);
  });
  step(S("the Space %1 with the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // A Space the Background made already is the one meant.
    spaceNamed(world, c[0]);
    givenPage(world, c[1]);
  });
  // Who else is on the page.
  // Opened, it holds whoever the MC has on the page, so a later change is one it sees.
  step(S("the user opens the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    lookAtPage(world, page);
    expectShown(world, [&] {
      QStringList devices = fake(world.mc).devices.value(page);
      devices.sort();
      const QVariantMap got = viewOf(world)->viewers();
      return got.value(S("devices")).toStringList() == devices && got.value(S("agents")).toStringList() == fake(world.mc).agents.value(page);
    }, S("the page to hold who is on it"));
  });
  step(S("the Space's page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
  });
  step(S("a thread %1").arg(q), [](World&, const Captures&, const Table&) {});
  const auto arrive = [](World& world, const Captures& c) {
    const QString page = idOfPage(world, c[1]);
    fake(world.mc).devices[page].append(c[0]);
    tellViewers(world.mc, page);
  };
  step(S("the page %1 is open on the device %1").arg(q), [arrive](World& world, const Captures& c, const Table&) {
    arrive(world, {c[1], c[0]});
  });
  step(S("the device %1 opens the page %1").arg(q), [arrive](World& world, const Captures& c, const Table&) {
    arrive(world, c);
  });
  const auto gone = [](World& world, const Captures& c, const Table&) {
    FakeSpaces& spaces = fake(world.mc);
    for (auto it = spaces.devices.begin(); it != spaces.devices.end(); ++it) {
      if (it->removeAll(c[0])) tellViewers(world.mc, it.key());
    }
  };
  step(S("the device %1 leaves the page %1").arg(q), gone);
  step(S("the connection of the device %1 drops").arg(q), gone);
  step(S("the agent in %1 is working on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[1]);
    fake(world.mc).agents[page].append(c[0]);
    tellViewers(world.mc, page);
  });
  step(S("the turn of the agent in %1 ends").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeSpaces& spaces = fake(world.mc);
    for (auto it = spaces.agents.begin(); it != spaces.agents.end(); ++it) {
      if (it->removeAll(c[0])) tellViewers(world.mc, it.key());
    }
  });
  // What the page's line says, on the screen the user has.
  const auto shows = [](World& world, const QString& said) {
    expectShown(world, [&] {
      QQuickItem* line = world.find(S("spaceViewers"));
      return said.isEmpty() ? !line || !line->isVisible() : line && line->isVisible() && line->property("text").toString() == said;
    }, S("the page to say \"%1\"").arg(said));
  };
  step(S("the MC can say who is on a page"), [](World&, const Captures&, const Table&) {});
  step(S("the MC can no longer say who is on a page"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).viewersRefused = true;
    for (const int id : world.mc.subscribers(S("spacePresence"))) refuseViewers(world.mc, id);
  });
  step(S("the MC can say who is on a page again"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).viewersRefused = false;
  });
  step(S("the page shows nobody else"), [shows](World& world, const Captures&, const Table&) {
    shows(world, {});
  });
  step(S("the page shows the user also on %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, S("Also here: %1").arg(c[0]));
  });
  step(S("the page shows one person, also on %1 and %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, S("Also here: %1, %2").arg(c[0], c[1]));
  });
  step(S("the page shows the agent of %1").arg(q), [shows](World& world, const Captures& c, const Table&) {
    shows(world, S("Also here: the agent of “%1”").arg(c[0]));
  });
  step(S("the user leaves the page"), [](World& world, const Captures&, const Table&) {
    backTo(world, S("pages"));
  });
  // In the wide layout the deck takes the page's place beside the sidebar.
  step(S("the user opens the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (world.find(S("desktopLayout"))) {
      world.tap(S("spaceDeckRow:") + c[0]);
      world.waitFor([&] { return viewOf(world)->deckId() == idOfDeck(world, c[0]); }, [&] { return S("the deck to open; %1").arg(describe(world)); });
    } else {
      lookAtDeck(world, idOfDeck(world, c[0]));
    }
  });
  step(S("the user is no longer on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString page = idOfPage(world, c[0]);
    expectShown(world, [&] {
      for (const int id : world.mc.subscribers(S("spacePresence"))) {
        if (world.mc.shapeOf(id).value(QLatin1String("pageId")).toString() == page) return false;
      }
      return true;
    }, S("the client to stop following who is on the page"));
  });
  step(S("the user makes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    backTo(world, S("spaces"));
    if (c[0].isEmpty()) {
      // The dialog's action waits for a name.
      world.tap(S("spaceNew"));
      world.awaitPopup(S("spaceTextDialog"));
      expect(!world.item(S("spaceTextSave"))->isEnabled(), S("a Space can be made with no name"));
      world.tap(S("spaceTextCancel"));
      settle(world);
      act(world, S("space.create"), {{S("name"), c[0]}});
      return;
    }
    world.tap(S("spaceNew"));
    answer(world, c[0]);
  });
  step(S("the user renames the Space %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    backTo(world, S("spaces"));
    world.tap(S("spaceMenu:") + c[0]);
    choose(world, S("rename"));
    answer(world, c[1]);
  });
  step(S("the user deletes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    backTo(world, S("spaces"));
    world.tap(S("spaceMenu:") + c[0]);
    choose(world, S("delete"));
    settle(world);
  });
  step(S("(?:the (?:Space|page|deck) request is refused|the user is told only a checklist item can be ticked)"), [](World& world, const Captures&, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    expect(!spaces.last.error.isEmpty(), S("the MC answered %1 with %2").arg(spaces.lastMethod, show(spaces.last.result.toVariantMap())));
    const QString said = world.state(S("space")).toMap().value(S("error")).toString();
    expect(said == spaces.last.error && toldOf(world, said), S("the user is not told \"%1\": %2, toasts %3").arg(spaces.last.error, describe(world), show(toasts(world))));
  });
  step(S("a second client watching the Spaces"), [](World& world, const Captures&, const Table&) {
    watch(world);
  });
  step(S("the second client sees the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList names = column(second(world).spaces(), S("name"));
    expect(names.contains(c[0]), S("the second client shows the Spaces %1").arg(show(names)));
  });

  // Pages and their places.
  step(S("the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
  });
  step(S("the pages %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
    givenPage(world, c[1]);
  });
  step(S("the page %1 inside %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0], givenPage(world, c[1]));
  });
  step(S("the user makes the page %1(?: inside %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c.value(1).isEmpty()) {
      look(world, current(world));
      world.tap(S("spaceNewPage"));
    } else {
      pageMenu(world, c[1], S("subpage"));
    }
    answer(world, c[0]);
    // The page made is the one the user lands on.
    expectStep(world, S("page"));
    expect(viewOf(world)->page().value(S("title")) == c[0], S("another page opened: %1").arg(describe(world)));
  });
  step(S("the pages of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->pages(), S("title")) == listed(c[1]); }, S("the pages to be %1").arg(c[1]));
    for (const QString& title : listed(c[1])) world.item(S("spacePage:") + title);
    if (listed(c[1]).isEmpty()) world.item(S("spaceEmptyText"));
  });
  step(S("%1 is a subpage of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString child = idOfPage(world, c[0]);
    const QString parent = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), child);
      const auto above = rowOf(viewOf(world)->pages(), parent);
      return row && above && row->value(S("parentPageId")) == parent && row->value(S("depth")).toInt() == above->value(S("depth")).toInt() + 1;
    }, S("%1 to sit inside %2").arg(c[0], c[1]));
    // Its row says so, by standing further in than its parent's.
    const auto leftOf = [&](const QString& title) { return world.item(S("spacePage:") + title)->property("leftPadding").toReal(); };
    expect(leftOf(c[0]) > leftOf(c[1]), S("%1 is not indented under %2").arg(c[0], c[1]));
  });
  step(S("%1 is not inside another page").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString page = idOfPage(world, c[0]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), page);
      return row && row->value(S("parentPageId")).toString().isEmpty() && row->value(S("depth")).toInt() == 0;
    }, S("%1 to sit at the top of the Space").arg(c[0]));
  });
  step(S("the user renames the page %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pageMenu(world, c[0], S("rename"));
    answer(world, c[1]);
  });
  step(S("the user moves the page %1 to the top of the Space").arg(q), [](World& world, const Captures& c, const Table&) {
    pageMenu(world, c[0], S("top"));
    settle(world);
  });
  step(S("the user moves the page %1 into %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString parent = idOfPage(world, c[1]);
    const QString moved = idOfPage(world, c[0]);
    pageMenu(world, c[0], S("into"));
    world.awaitPopup(S("spaceSheet"));
    // The picker holds no page the move would put inside itself.
    if (QQuickItem* offered = world.find(S("spaceSheetItem:") + parent); offered) {
      world.tap(offered);
      settle(world);
      return;
    }
    expect(parent == moved || rowOf(viewOf(world)->pages(), parent)->value(S("depth")).toInt() > rowOf(viewOf(world)->pages(), moved)->value(S("depth")).toInt(),
           S("%1 is not offered as a place for %2").arg(c[1], c[0]));
    QMetaObject::invokeMethod(world.item(S("spaceScreen")), "closeSheet");
    settle(world);
    act(world, S("space.page.move"), {{S("pageId"), moved}, {S("parentPageId"), parent}});
  });
  step(S("the page %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("paragraph"), c[1]);
  });
  step(S("the MC restarts"), [](World& world, const Captures&, const Table&) {
    look(world, current(world));
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, S("the phone to see the MC go"));
  });
  step(S("the page %1 still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().client()->isReady(); }, S("the phone to reconnect"));
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world).contains(c[1]); }, S("%1 to read %2").arg(c[0], c[1]));
    world.item(S("spaceBlock:") + c[1]);
  });

  // Trash.
  step(S("the user moves the page %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    pageMenu(world, c[0], S("trash"));
    settle(world);
  });
  step(S("the page %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("page.trash"), {{S("pageId"), givenPage(world, c[0])}});
  });
  step(S("the trash of %1 holds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    const auto held = [&] { return column(viewOf(world)->trash(), S("title")) + column(viewOf(world)->deckTrash(), S("title")); };
    expectShown(world, [&] { return held() == listed(c[1]); }, S("the trash to hold %1").arg(c[1]));
    for (const QString& title : column(viewOf(world)->trash(), S("title"))) world.item(S("spaceTrashRow:") + title);
    for (const QString& title : column(viewOf(world)->deckTrash(), S("title"))) world.item(S("spaceDeckTrashRow:") + title);
  });
  step(S("the user restores the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    trashMenu(world, c[0], S("restore"));
    settle(world);
  });
  step(S("the user writes %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[1]);
    lookAtPage(world, page);
    if (viewOf(world)->trash()->indexOf(page) >= 0) {
      world.item(S("spaceTrashedNotice"));
      expect(world.find(S("spaceAddBlock")) == nullptr, S("a page in the trash offers to add a block"));
    }
    act(world, S("space.block.insert"), {{S("pageId"), page}, {S("kind"), S("paragraph")}, {S("text"), c[0]}});
  });
  step(S("the user deletes the page %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    look(world, current(world));
    if (viewOf(world)->trash()->indexOf(page) >= 0) {
      trashMenu(world, c[0], S("delete"));
      settle(world);
    } else {
      // Only the trash offers it.
      act(world, S("space.page.delete"), {{S("pageId"), page}});
    }
  });
  step(S("no blocks or comments of %1 or %1 remain").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    const QSet<QString> gone{spaces.named.value(S("page\n") + c[0]), spaces.named.value(S("page\n") + c[1])};
    look(world, current(world));
    const SpaceStream& copy = viewOf(world)->space();
    for (const QString& kind : {S("page"), S("block"), S("comment")}) {
      for (const QJsonObject& entity : copy.of(kind)) {
        const bool left = gone.contains(text(entity, kind == QLatin1String("page") ? QLatin1String("id") : QLatin1String("pageId")));
        expect(!left, S("the phone still holds the %1 %2").arg(kind, show(entity.toVariantMap())));
      }
    }
  });

  // Blocks.
  step(S("the user adds a (paragraph|heading|checklist|callout) block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[2]));
    world.tap(S("spaceAddBlock"));
    choose(world, c[0]);
    answer(world, c[1]);
  });
  step(S("%1 has a (paragraph|heading|checklist|callout) block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) { return block.value(S("kind")) == c[1] && block.value(S("text")) == c[2]; });
    }, S("a %1 block %2").arg(c[1], c[2]));
    world.item(S("spaceBlock:") + c[2]);
  });
  step(S("the user links %1 from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString linked = idOfPage(world, c[0]);
    lookAtPage(world, idOfPage(world, c[1]));
    world.tap(S("spaceAddBlock"));
    choose(world, S("subpage_link"));
    choose(world, linked);
    settle(world);
  });
  step(S("%1 links to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    const QString linked = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(S("kind")) == QLatin1String("subpage_link") && block.value(S("linkedPageId")) == linked && block.value(S("linkedTitle")) == c[1];
      });
    }, S("a link to %1").arg(c[1]));
    // And a tap follows it.
    world.tap(S("spaceLink:") + c[1]);
    world.waitFor([&] { return viewOf(world)->pageId() == linked && shown(world) == QLatin1String("page"); }, [&] { return S("the link to open %1; %2").arg(c[1], describe(world)); });
  });
  step(S("%1 has the blocks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& said : listed(c[1])) givenBlock(world, c[0], S("paragraph"), said);
  });
  step(S("%1 has the checklist item %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("checklist"), c[1]);
  });
  step(S("the user adds %1 after %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    blockMenu(world, c[1], S("below"));
    choose(world, S("paragraph"));
    answer(world, c[0]);
  });
  step(S("the blocks of %1 read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world) == listed(c[1]); }, S("the blocks to read %1").arg(c[1]));
  });
  step(S("the user changes the block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, text(blockSaying(world, c[0]), QLatin1String("pageId")));
    // A tap on the drawn text shows its source to edit.
    world.tap(world.item(S("spaceBlockText:") + c[0]));
    QQuickItem* editor = world.item(S("spaceBlockEditor:") + c[0]);
    world.waitFor([&] { return editor->hasActiveFocus(); }, S("the block's text to take the keyboard"));
    QMetaObject::invokeMethod(editor, "selectAll");
    world.type(c[1]);
    world.tap(S("spaceEditDone"));
    world.sync();
  });
  for (const bool tick : {true, false}) {
    step((tick ? S("the user ticks %1") : S("the user unticks %1")).arg(q), [tick](World& world, const Captures& c, const Table&) {
      const QJsonObject block = blockSaying(world, c[0]);
      lookAtPage(world, text(block, QLatin1String("pageId")));
      if (text(block, QLatin1String("kind")) == QLatin1String("checklist")) {
        world.tap(S("spaceTick:") + c[0]);
        world.sync();
      } else {
        // Only a checklist item has a box.
        expect(world.find(S("spaceTick:") + c[0]) == nullptr, S("a %1 block has a box").arg(text(block, QLatin1String("kind"))));
        act(world, S("space.block.setChecked"), {{S("blockId"), text(block, QLatin1String("id"))}, {S("checked"), tick}});
      }
    });
  }
  step(S("%1 is (not )?ticked").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const bool wanted = c.value(1).isEmpty();
    lookAtPage(world, text(blockSaying(world, c[0]), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->blocks(), id);
      // What the MC wrote, not only what the user asked for.
      return row && row->value(S("checked")).toBool() == wanted && !viewOf(world)->pending(id, S("checked")) &&
             viewOf(world)->space().entity(S("block"), id).value(QLatin1String("checked")).toBool() == wanted;
    }, S("%1 to be %2").arg(c[0], wanted ? S("ticked") : S("unticked")));
    expect(world.item(S("spaceTick:") + c[0])->property("checked").toBool() == wanted, S("the box of %1 shows otherwise").arg(c[0]));
  });
  step(S("the user moves the block %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject before = blockSaying(world, c[1]);
    const QString moved = text(blockSaying(world, c[0]), QLatin1String("id"));
    lookAtPage(world, text(before, QLatin1String("pageId")));
    // What the move changes, on the MC and in the phone's rows.
    FakeSpaces& spaces = fake(world.mc);
    spaces.mark = spaces.log.value(streamOf(current(world))).size();
    spaces.seen.clear();
    SpaceRows* rows = viewOf(world)->blocks();
    const auto idAt = [rows](int row) { return rows->get(row).value(S("id")).toString(); };
    QObject::connect(rows, &QAbstractItemModel::rowsAboutToBeMoved, rows, [&spaces, idAt](const QModelIndex&, int first, int, const QModelIndex&, int) {
      spaces.seen.append(S("moved ") + idAt(first));
    });
    QObject::connect(rows, &QAbstractItemModel::dataChanged, rows, [&spaces, idAt](const QModelIndex& first, const QModelIndex& last) {
      for (int row = first.row(); row <= last.row(); ++row) spaces.seen.append(S("changed ") + idAt(row));
    });
    for (const auto signal : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
      QObject::connect(rows, signal, rows, [&spaces] { spaces.seen.append(S("rows came or went")); });
    }
    QObject::connect(rows, &QAbstractItemModel::modelReset, rows, [&spaces] { spaces.seen.append(S("reset")); });
    // A step up at a time, under a finger.
    const QString target = text(before, QLatin1String("id"));
    const auto above = [&] { return rows->indexOf(moved) < rows->indexOf(target); };
    for (int steps = rows->rowCount(); steps > 0 && !above(); --steps) {
      world.tap(S("spaceBlockMenu:") + c[0]);
      choose(world, S("up"));
      settle(world);
    }
    expect(above(), describe(world));
  });
  step(S("only the block %1 changed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const FakeSpaces& spaces = fake(world.mc);
    const QList<FakeSpaces::Change> log = spaces.log.value(streamOf(current(world)));
    expect(log.size() > spaces.mark, S("the MC wrote nothing"));
    for (qsizetype i = spaces.mark; i < log.size(); ++i) {
      expect(log.at(i).kind == QLatin1String("block") && log.at(i).id == id,
             S("the MC also wrote the %1 %2: %3").arg(log.at(i).kind, log.at(i).id, show(log.at(i).patch.toVariantMap())));
    }
    expect(spaces.seen == QStringList{S("moved ") + id}, S("the phone's blocks: %1").arg(show(spaces.seen)));
  });
  step(S("the user deletes the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    blockMenu(world, c[0], S("delete"));
    settle(world);
  });
  step(S("a second client watching the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    watch(world, idOfSpace(world, c[0]));
  });
  step(S("the second client sees the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList texts = column(second(world).blocks(), S("text"));
    expect(texts.contains(c[0]), S("the second client shows the blocks %1").arg(show(texts)));
  });

  // A page's agent.
  step(S("the user asks %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString words = c[0].trimmed().startsWith(QLatin1String("@agent")) ? c[0] : S("@agent ") + c[0];
    const QString page = idOfPage(world, c[1]);
    sendPrompt(world, typeInPrompt(world, c[1], words));
    world.waitFor([&] { return fake(world.mc).lastMethod == QLatin1String("space.page.askAgent") && text(fake(world.mc).lastAsk, QLatin1String("pageId")) == page; },
                  [] { return S("the ask to reach the MC"); });
    world.sync();
  });
  step(S("the MC refuses the next ask"), [](World& world, const Captures&, const Table&) { fake(world.mc).refuseAsk = true; });
  step(S("the words %1 are kept to ask again").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* composer = world.item(S("spaceComposer"));
    const QString kept = S("@agent ") + c[0];
    world.waitFor([&] { return promptEditor(composer)->property("text") == kept && prompt(world).value(S("text")) == kept; },
                  [&] { return S("the prompt to hold \"%1\"; it is %2").arg(kept, show(prompt(world))); });
  });
  step(S("the agent of %1 does not stop when asked").arg(q), [](World& world, const Captures&, const Table&) { fake(world.mc).ignoresStop = true; });
  step(S("%1 says its agent is stopping").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(S("status")) == S("stopping"); }, S("stopping"));
  });
  step(S("the user can stop the agent of %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    const int before = fake(world.mc).stops;
    world.tap(S("spaceAgentStop"));
    world.waitFor([&] { return fake(world.mc).stops == before + 1; }, [] { return S("a second stop to reach the MC"); });
  });
  step(S("the thread of the agent of %1 is deleted").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), S("pageAgent"), idOfPage(world, c[0]), {{S("status"), S("stopped")}, {S("error"), S("its thread was deleted")}, {S("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(S("the agent of %1 names a thread this client does not have").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), S("pageAgent"), idOfPage(world, c[0]), {{S("threadId"), S("gone")}});
    world.sync();
  });
  step(S("the user follows the agent of %1 to its thread").arg(q), [](World& world, const Captures&, const Table&) {
    world.tap(S("spaceAgentOpenThread"));
  });
  step(S("the user is told the agent's thread is not available"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toldOf(world, S("The agent's thread is not available.")); }, [&] { return S("the user to be told; toasts %1").arg(show(toasts(world))); });
  });
  step(S("%1 says its agent stopped because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(S("status")) == S("stopped") && agent.value(S("error")) == c[1]; }, S("stopped because %1").arg(c[1]));
  });
  step(S("%1 says its agent is working on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(S("status")) == S("running") && agent.value(S("request")) == c[1]; }, S("working on %1").arg(c[1]));
  });
  step(S("%1 links to its agent's thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString thread = text(askedOn(world, c[0]), QLatin1String("threadId"));
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(S("threadId")) == thread && agent.value(S("threadTitle")) == S("Page agent"); }, S("linked to its thread"));
    world.tap(S("spaceAgentOpenThread"));
    world.sync();
    const QString key = navigation(world)->threadKey();
    expect(key.endsWith(QLatin1Char(':') + thread), S("the link opened %1").arg(key));
  });
  step(S("the agent of %1 adds the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    const QJsonObject author = agent(text(askedOn(world, c[0]), QLatin1String("threadId")));
    insertBlock(world.mc, current(world), page, {{S("kind"), S("paragraph")}, {S("text"), c[1]}, {S("checked"), false}}, QJsonValue::Undefined, author);
    noteEdits(world.mc, current(world), author);
    set(world.mc, streamOf(current(world)), S("pageAgent"), page, {{S("edited"), true}});
    world.sync();
  });
  step(S("the block %1 was written by the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[0]);
    expect(block.value(QLatin1String("createdBy")).toObject() == agent(text(askedOn(world, c[1]), QLatin1String("threadId"))), S("the block says %1").arg(show(block)));
  });
  step(S("the agent of %1 finishes").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), S("pageAgent"), idOfPage(world, c[0]), {{S("status"), S("completed")}, {S("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(S("the agent of %1 fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world.mc, streamOf(current(world)), S("pageAgent"), idOfPage(world, c[0]), {{S("status"), S("failed")}, {S("error"), c[1]}, {S("endedAt"), stamp(world.mc)}});
    world.sync();
  });
  step(S("the user stops the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    world.tap(S("spaceAgentStop"));
    world.sync();
  });
  step(S("the user dismisses the agent of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    world.tap(S("spaceAgentDismiss"));
    world.sync();
  });
  step(S("%1 says its agent finished and changed the page").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(S("status")) == S("completed") && agent.value(S("edited")).toBool(); }, S("finished with changes"));
  });
  step(S("%1 says its agent finished without changing the page").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(S("status")) == S("completed") && !agent.value(S("edited")).toBool(); }, S("finished without changes"));
  });
  step(S("%1 says its agent was stopped").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(S("status")) == S("stopped"); }, S("stopped"));
  });
  step(S("%1 says its agent failed with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [&](const QVariantMap& agent) { return agent.value(S("status")) == S("failed") && agent.value(S("error")) == c[1]; }, S("failed with %1").arg(c[1]));
  });
  step(S("%1 says nothing about an agent").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.isEmpty(); }, S("saying nothing"));
  });

  // A page's history.
  step(S("a while passes"), [](World& world, const Captures&, const Table&) { fake(world.mc).paused = true; });
  step(S("the agent in %1 adds the block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject author = agent(threadNamed(world, c[0]));
    insertBlock(world.mc, current(world), idOfPage(world, c[2]), {{S("kind"), S("paragraph")}, {S("text"), c[1]}, {S("checked"), false}}, QJsonValue::Undefined, author);
    noteEdits(world.mc, current(world), author);
    world.sync();
  });
  step(S("the user opens the history of %1").arg(q), [](World& world, const Captures& c, const Table&) { showHistory(world, idOfPage(world, c[0])); });
  step(S("the history has (\\d+) versions?"), [](World& world, const Captures& c, const Table&) {
    showHistory(world, viewOf(world)->pageId());
    expectShown(world, [&] { return viewOf(world)->history()->versions()->rowCount() == c[0].toInt(); }, S("the history to have %1 versions").arg(c[0]));
  });
  step(S("each version says when it was written and by the user"), [](World& world, const Captures&, const Table&) {
    for (const QVariantMap& row : viewOf(world)->history()->versions()->rows()) {
      expect(!row.value(S("at")).toString().isEmpty() && !row.value(S("byAgent")).toBool() && !row.value(S("byUpdate")).toBool(), S("a version says %1").arg(show(row)));
    }
  });
  step(S("the newest version is the page as it is now"), [](World& world, const Captures&, const Table&) {
    readVersion(world, S("0"));
    expect(column(viewOf(world)->history()->blocks(), S("text")) == column(viewOf(world)->blocks(), S("text")),
           S("the newest version reads %1").arg(show(listOf(viewOf(world)->history()->blocks()))));
    backTo(world, S("history"));
  });
  step(S("the newest version was written by the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(newest.value(S("byAgent")).toBool() && newest.value(S("threadTitle")).toString() == c[0], S("the newest version says %1").arg(show(newest)));
  });
  step(S("the newest version was written by the page's update"), [](World& world, const Captures&, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(newest.value(S("byUpdate")).toBool() && !newest.value(S("byAgent")).toBool(), S("the newest version says %1").arg(show(newest)));
  });
  step(S("the user reads the version (\\d+) back on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    readVersion(world, versionRow(world, c[1], c[0].toInt()));
  });
  step(S("the version shows the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QVariantMap block = versionImage(world, c[0]);
      return block.value(S("imageState")) == QLatin1String("shown") && block.value(S("imageUrl")).toString().contains(QLatin1String("/assets/space/"));
    }, S("the version to show the image %1").arg(c[0]));
  });
  step(S("the version says the image %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] { return versionImage(world, c[0]).value(S("imageState")) == QLatin1String("trashed"); }, S("the version to say the image %1 is in the trash").arg(c[0]));
  });
  step(S("the version reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectStep(world, S("version"));
    const QStringList texts = column(viewOf(world)->history()->blocks(), S("text"));
    expect(texts == listed(c[0]), S("the version reads %1").arg(show(texts)));
  });
  step(S("the version draws a chart of %1 (\\d+) and %1 (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    SpaceRows* blocks = viewOf(world)->history()->blocks();
    const QVariantList labels{c[0], c[2]};
    const QVariantList values{c[1].toDouble(), c[3].toDouble()};
    for (const QVariantMap& row : blocks->rows()) {
      if (row.value(S("kind")) != QLatin1String("chart")) continue;
      const QVariantMap chart = row.value(S("chart")).toMap();
      expect(chart.value(S("labels")).toList() == labels && chart.value(S("series")).toList().value(0).toMap().value(S("values")).toList() == values, S("the version's chart reads %1").arg(show(chart.value(S("labels")).toStringList())));
      return;
    }
    expect(false, S("no chart in the version"));
  });
  step(S("the user goes back to the list of versions"), [](World& world, const Captures&, const Table&) { backTo(world, S("history")); });
  step(S("no version is being read"), [](World& world, const Captures&, const Table&) {
    expect(!viewOf(world)->history()->reading() && viewOf(world)->history()->blocks()->rowCount() == 0, S("a version is still being read"));
  });
  step(S("the user restores the version (\\d+) back on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.tap(S("spaceHistoryRestore:") + versionRow(world, c[1], c[0].toInt()));
    world.sync();
    settleHistory(world);
  });
  step(S("the newest version says it restored an earlier one"), [](World& world, const Captures&, const Table&) {
    const QVariantMap newest = viewOf(world)->history()->versions()->get(0);
    expect(!newest.value(S("restoredFromAt")).toString().isEmpty(), S("the newest version says %1").arg(show(newest)));
  });
  step(S("the user cannot restore a version of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString row = versionRow(world, c[0], 1);
    expect(!world.find(S("spaceHistoryRestore:") + row), S("a page in the trash offers to restore a version"));
    readVersion(world, row);
    expect(!world.find(S("spaceVersionRestore")), S("a version of a page in the trash offers to be restored"));
    backTo(world, S("history"));
    // Another client trashed it just then: the MC's refusal reaches the user.
    act(world, S("space.history.restore"), {{S("version"), viewOf(world)->history()->versions()->get(1).value(S("version"))}});
    const FakeSpaces& spaces = fake(world.mc);
    expect(!spaces.last.error.isEmpty() && toldOf(world, spaces.last.error), S("the user is not told the restore was refused; toasts %1").arg(show(toasts(world))));
  });
  // Sites (features/space/sites.feature).
  step(S("the user publishes the page %1 as a site").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    lookAtPage(world, page);
    // A page in the trash offers no way to publish it.
    if (viewOf(world)->page().value(S("trashed")).toBool()) {
      act(world, S("space.page.publish"), {{S("pageId"), page}});
    } else {
      openPageMenu(world, page, S("publish"));
    }
  });
  step(S("the user publishes the page %1 over Tailscale").arg(q), [](World& world, const Captures& c, const Table&) {
    openPageMenu(world, idOfPage(world, c[0]), S("publishTailscale"));
  });
  step(S("the page %1 is published as a site").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("page.publish"), {{S("pageId"), givenPage(world, c[0])}});
    fake(world.mc).named.insert(S("link\n") + c[0], linkOf(world, c[0]));
  });
  step(S("the user unpublishes the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return !site.isEmpty(); }, S("show it is published"));
    world.tap(S("spaceSiteUnpublish"));
    world.sync();
  });
  step(S("the user copies the site link of the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return !site.isEmpty(); }, S("show it is published"));
    world.clipboard.clear();
    world.tap(S("spaceSiteCopy"));
  });
  step(S("the site link of the page %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = linkOf(world, c[0]);
    world.waitFor([&] { return world.clipboard == wanted; }, [&] { return S("the clipboard to hold the link; it holds \"%1\"").arg(world.clipboard); });
  });
  step(S("the page %1 shows it is published with a link").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString link = linkOf(world, c[0]);
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(S("url")).toString() == link; }, S("show its link"));
    world.item(S("spaceSiteLink"));
  });
  step(S("the page %1 shows it is not published").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.isEmpty(); }, S("show it is not published"));
  });
  // The fake serves no pages, so what stops a link here is its site being gone from the MC.
  step(S("the site link of the page %1 no longer opens").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(siteOfPage(world.mc, current(world), idOfPage(world, c[0])).isEmpty(), S("the MC still has the site of %1").arg(c[0]));
  });
  step(S("the second client sees the page %1 published").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!second(world).siteOf(idOfPage(world, c[0])).isEmpty(), S("the second client does not show %1 published").arg(c[0]));
  });
  step(S("the page %1 shows its site is behind").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.value(S("behind")).toBool(); }, S("show its site is behind"));
  });
  step(S("the page %1 shows its site is up to date").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return !site.isEmpty() && !site.value(S("behind")).toBool(); }, S("show its site is up to date"));
  });
  step(S("the page %1 has the same site link").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString earlier = fake(world.mc).named.value(S("link\n") + c[0]);
    expect(!earlier.isEmpty(), S("the page %1 had no link").arg(c[0]));
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(S("url")).toString() == earlier; }, S("keep the link %1").arg(earlier));
  });
  step(S("the MC listens only on this machine"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).address = world.mc.origin().toString();
    fake(world.mc).localOnly = true;
  });
  step(S("the page %1 says only this machine can open its site link").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [](const QVariantMap& site) { return site.value(S("localOnly")).toBool(); }, S("say only this machine can open its link"));
    world.item(S("spaceSiteLocalOnly"));
  });
  step(S("Tailscale names the MC's machine %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).tailnet = c[0];
  });
  step(S("the site link of the page %1 starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSite(world, c[0], [&](const QVariantMap& site) { return site.value(S("url")).toString().startsWith(c[1]); }, S("have a link starting with %1").arg(c[1]));
  });

  // Comments.
  step(S("the user comments %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c[0].isEmpty()) {
      // The dialog's action waits for words.
      blockMenu(world, c[1], S("comment"));
      world.awaitPopup(S("spaceTextDialog"));
      expect(!world.item(S("spaceTextSave"))->isEnabled(), S("a comment can be made with no body"));
      world.tap(S("spaceTextCancel"));
      settle(world);
      const QJsonObject block = blockSaying(world, c[1]);
      act(world, S("space.comment.add"), {{S("pageId"), text(block, QLatin1String("pageId"))}, {S("blockId"), text(block, QLatin1String("id"))}, {S("body"), c[0]}});
      return;
    }
    blockMenu(world, c[1], S("comment"));
    answer(world, c[0]);
  });
  step(S("the comment %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[1]);
    given(world, S("comment.add"), {{S("pageId"), text(block, QLatin1String("pageId"))}, {S("blockId"), text(block, QLatin1String("id"))}, {S("body"), c[0]}});
  });
  step(S("the comment %1 is resolved already").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("comment.resolve"), {{S("commentId"), idOfComment(world, c[0])}});
  });
  step(S("the user (resolves|reopens) the comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[1]);
    lookAtComments(world, text(one(world.mc, streamOf(current(world)), S("comment"), id), QLatin1String("pageId")));
    world.tap((c[0] == QLatin1String("resolves") ? S("spaceCommentResolve:") : S("spaceCommentReopen:")) + c[1]);
    world.sync();
  });
  step(S("the block %1 has the open comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[0]);
    lookAtPage(world, text(block, QLatin1String("pageId")));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->comments()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& comment) {
        return comment.value(S("body")) == c[1] && comment.value(S("blockId")) == text(block, QLatin1String("id")) && comment.value(S("blockText")) == c[0] &&
               !comment.value(S("resolved")).toBool();
      });
    }, S("the open comment %1 on %2").arg(c[1], c[0]));
    const auto row = rowOf(viewOf(world)->blocks(), text(block, QLatin1String("id")));
    expect(row && row->value(S("openComments")).toInt() == 1, S("the block does not count its open comment: %1").arg(describe(world)));
    // The block's badge leads to it, with the way to resolve it.
    world.tap(S("spaceComment:") + c[0]);
    expectStep(world, S("comments"));
    world.item(S("spaceCommentResolve:") + c[1]);
  });
  step(S("the comment %1 is resolved").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[0]);
    lookAtComments(world, text(one(world.mc, streamOf(current(world)), S("comment"), id), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->comments(), id);
      return row && row->value(S("resolved")).toBool();
    }, S("the comment %1 to be resolved").arg(c[0]));
    world.item(S("spaceCommentReopen:") + c[0]);
  });

  // Markdown.
  step(S("the page %1 with the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    for (const QStringList& row : table.mid(1)) givenBlock(world, c[0], row.value(0), row.value(1), row.value(2) == QLatin1String("yes"));
  });
  step(S("the user exports %1 as Markdown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    pageMenu(world, c[0], S("copy"));
    settle(world);
  });
  step(S("the Markdown is:"), [](World& world, const Captures&, const Table& doc) {
    const QString wanted = doc.value(0).value(0) + QLatin1Char('\n');
    world.waitFor([&] { return world.clipboard == wanted; }, [&] { return S("the clipboard to hold the page; it holds \"%1\"").arg(world.clipboard); });
    expect(toldOf(world, S("Page copied as Markdown")), S("the user is not told: %1").arg(show(toasts(world))));
  });
  step(S("the user imports this Markdown into %1:").arg(q), [](World& world, const Captures& c, const Table& doc) {
    look(world, idOfSpace(world, c[0]));
    world.tap(S("spaceImport"));
    world.awaitPopup(S("spaceTextDialog"));
    // Pasted, as a phone's Markdown comes.
    world.item(S("spaceTextField"))->setProperty("text", doc.value(0).value(0));
    world.tap(S("spaceTextSave"));
    settle(world);
  });
  step(S("the page %1 has the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QString page = idOfPage(world, c[0]);
    // The page imported is the one the user lands on.
    expectStep(world, S("page"));
    expectShown(world, [&] { return viewOf(world)->pageId() == page; }, S("%1 to open").arg(c[0]));
    const Table wanted = table.mid(1);
    expectShown(world, [&] { return blockTable(world) == wanted; }, S("the blocks %1").arg(show(tableOf(wanted))));
  });

  // Mermaid diagrams on a page: imported as the MC reads a "mermaid" fence (a
  // code block in "mermaid" holding the bare source), and drawn by the page
  // through the fake renderer (MermaidSteps.cpp).
  static const QMap<QString, QString> kDiagrams{
      {S("flowchart"), mermaid::kFlowchart},
      {S("graph"), S("graph TD\n  Cart --> Pay")},
      {S("sequenceDiagram"), S("sequenceDiagram\n  Cart->>Pay: order")},
      {S("stateDiagram-v2"), S("stateDiagram-v2\n  [*] --> Cart")},
      {S("gantt"), S("gantt\n  title Launch\n  section Build\n  MC :a1, 2026-11-01, 3d")},
      {S("block-beta"), S("block-beta\n  columns 2\n  Cart Pay")}};
  // Imports a page holding `source`, then `after` paragraphs, pasted as a
  // phone's Markdown comes, and lands on it.
  const auto importDiagram = [](World& world, const QString& source, int after) {
    QString markdown = S("# Ordering\n\nHow an order is paid:\n\n```mermaid\n%1\n```\n").arg(source);
    for (int step = 1; step <= after; ++step) markdown += S("\nStep %1 of paying.\n").arg(step);
    world.mc.part<Diagram>().source = source;
    look(world, current(world));
    world.tap(S("spaceImport"));
    world.awaitPopup(S("spaceTextDialog"));
    world.item(S("spaceTextField"))->setProperty("text", markdown);
    world.tap(S("spaceTextSave"));
    settle(world);
    expectStep(world, S("page"));
    expectShown(world, [&] { return column(viewOf(world)->blocks(), S("text")).contains(source); }, S("the imported page"));
  };
  const auto sourceEditor = [](World& world) {
    return world.item(S("spaceBlockEditor:") + world.mc.part<Diagram>().source);
  };
  step(S("the user imports a page holding a %1 Mermaid diagram").arg(q), [importDiagram](World& world, const Captures& c, const Table&) {
    expect(kDiagrams.contains(c[0]), S("no %1 diagram to import").arg(c[0]));
    importDiagram(world, kDiagrams.value(c[0]), 0);
  });
  step(S("the user imports a page holding a flowchart with an unclosed bracket"), [importDiagram](World& world, const Captures&, const Table&) {
    importDiagram(world, mermaid::kBrokenFlowchart, 0);
  });
  // Paragraphs after it, enough to scroll it off the screen.
  step(S("a page with a flowchart"), [importDiagram](World& world, const Captures&, const Table&) {
    importDiagram(world, mermaid::kFlowchart, 40);
  });
  step(S("the page has a diagram block of the type %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString source = world.mc.part<Diagram>().source;
    expect(source.section(QLatin1Char('\n'), 0, 0).section(QLatin1Char(' '), 0, 0) == c[0], S("the page holds a %1 diagram, not %2").arg(c[0], source));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(S("kind")) == QLatin1String("code") && block.value(S("language")) == QLatin1String("mermaid") && block.value(S("text")) == source;
      });
    }, S("a code block in \"mermaid\" holding the diagram"));
  });
  step(S("on the desktop and the phone the diagram is drawn"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, [&] { return S("the diagram to be drawn; %1").arg(describe(world)); });
    const QQuickItem* image = mermaid::drawn(world).first();
    expect(image->width() > 0 && image->x() + image->width() <= world.window().width(),
           S("the diagram is %1 wide at %2 on a %3 wide screen").arg(image->width()).arg(image->x()).arg(world.window().width()));
    expect(!world.find(S("spaceBlockEditor:") + world.mc.part<Diagram>().source), S("the diagram's source shows with its picture"));
  });
  step(S("the user adds a node to its source"), [sourceEditor](World& world, const Captures&, const Table&) {
    Diagram& diagram = world.mc.part<Diagram>();
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, S("the diagram to be drawn"));
    world.tap(S("spaceDiagramSource:") + diagram.source);
    QQuickItem* editor = sourceEditor(world);
    world.tap(editor);
    world.waitFor([&] { return editor->hasActiveFocus(); }, S("the source to take the keyboard"));
    editor->setProperty("cursorPosition", diagram.source.size());
    QTest::keyClick(&world.window(), Qt::Key_Return);
    world.type(S("  Pay --> Done"));
    world.tap(S("spaceEditDone"));
    world.sync();
    diagram.source += S("\n  Pay --> Done");
  });
  step(S("the diagram is drawn again with the new node"), [](World& world, const Captures&, const Table&) {
    const QString source = world.mc.part<Diagram>().source;
    world.waitFor([&] {
      return mermaid::drawn(world).size() == 1 && world.find(S("spaceDiagram:") + source) && !world.find(S("spaceBlockEditor:") + source);
    }, [&] { return S("the new source to be drawn; %1").arg(describe(world)); });
    expect(mermaid::asked(world) == 2, S("the MC was asked %1 times, not for the first and the new source").arg(mermaid::asked(world)));
  });
  step(S("the export writes the new source"), [](World& world, const Captures&, const Table&) {
    world.clipboard.clear();
    pageMenu(world, S("Ordering"), S("copy"));
    settle(world);
    const QString fence = S("```mermaid\n%1\n```").arg(world.mc.part<Diagram>().source);
    world.waitFor([&] { return world.clipboard.contains(fence); }, [&] { return S("the export to hold %1; it holds \"%2\"").arg(fence, world.clipboard); });
  });
  step(S("the user scrolls the page past it and back"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, S("the diagram to be drawn"));
    QQuickItem* list = world.item(S("spaceBlocks"));
    QMetaObject::invokeMethod(list, "positionViewAtEnd");
    world.waitFor([&] { return mermaid::drawn(world).isEmpty(); }, S("the page to scroll past the diagram"));
    QMetaObject::invokeMethod(list, "positionViewAtBeginning");
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, S("the diagram to be back"));
  });
  step(S("the diagram is not drawn again"), [](World& world, const Captures&, const Table&) {
    expect(mermaid::asked(world) == 1, S("the MC was asked to draw it %1 times").arg(mermaid::asked(world)));
  });

  // Markdown the page keeps as written, and headings by level.
  // A table wider than a phone, its cells padded to line up as people write them.
  static const QString table = S("| Step  | Owner | Before it ships to everyone            |\n"
                                 "| ----- | ----- | -------------------------------------- |\n"
                                 "|   MC  | Ada   | The release notes and a signed build   |");
  step(S("the page %1 holds a table the page does not model yet").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("raw"), table);
  });
  // A page's name, never a path: FilesSteps opens those.
  step(S("the user opens \"([^\"./]*)\""), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
  });
  step(S("the table is shown as its Markdown, exactly as written, in a fixed-width face"), [](World& world, const Captures&, const Table&) {
    QQuickItem* editor = world.item(S("spaceBlockEditor:") + table);
    expect(editor->property("text").toString() == table, S("the table shows as \"%1\"").arg(editor->property("text").toString()));
    // One line on screen for each it was written in, however narrow the phone.
    expect(editor->property("lineCount").toInt() == 3, S("the table is shown in %1 lines").arg(editor->property("lineCount").toInt()));
    const QFont font = editor->property("font").value<QFont>();
    expect(QFontInfo(font).fixedPitch(), S("the table is shown in %1, not a fixed-width face").arg(QFontInfo(font).family()));
  });
  step(S("the user can edit it as text"), [](World& world, const Captures&, const Table&) {
    QQuickItem* editor = world.item(S("spaceBlockEditor:") + table);
    world.tap(editor);
    world.waitFor([&] { return editor->hasActiveFocus(); }, S("the table to take the keyboard"));
    editor->setProperty("cursorPosition", table.size());
    QTest::keyClick(&world.window(), Qt::Key_Return);
    world.type(S("|   QA  | Grace | A pass on the phone |"));
    world.tap(S("spaceEditDone"));
    world.sync();
    const QString edited = table + S("\n|   QA  | Grace | A pass on the phone |");
    world.waitFor([&] { return !findBlock(world, edited).isEmpty(); }, [&] { return S("the MC to hold the edited table; %1").arg(describe(world)); });
    expect(text(findBlock(world, edited), QLatin1String("kind")) == QLatin1String("raw"), S("the table is no longer kept as written"));
  });
  // A table and a code block, which the page shows as their source until #854 draws them.
  static const QString modelledTable = S("| Step | Owner |\n| ---- | ----- |\n| MC   | Ada   |");
  static const QString code = S("run()\n    done()");
  step(S("the page %1 holds a table and a code block").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("table"), modelledTable);
    givenBlock(world, c[0], S("code"), code);
  });
  step(S("the table and the code are each shown line for line in a fixed-width face"), [](World& world, const Captures&, const Table&) {
    for (const QString& said : {modelledTable, code}) {
      QQuickItem* editor = world.item(S("spaceBlockEditor:") + said);
      expect(editor->property("text").toString() == said, S("the block shows as \"%1\"").arg(editor->property("text").toString()));
      expect(editor->property("lineCount").toInt() == said.count(QLatin1Char('\n')) + 1,
             S("%1 is shown in %2 lines").arg(said).arg(editor->property("lineCount").toInt()));
      expect(QFontInfo(editor->property("font").value<QFont>()).fixedPitch(), S("%1 is not in a fixed-width face").arg(said));
    }
  });
  // Blocks as the MC keeps them, a field per column; `-` is a field the block does not have.
  step(S("the page %1 holds the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QStringList header = table.value(0);
    for (const QStringList& row : table.mid(1)) {
      QJsonObject block{{S("pageId"), givenPage(world, c[0])}};
      for (qsizetype i = 0; i < header.size(); ++i) {
        const QString& field = header.at(i);
        const QString cell = row.value(i, S("-"));
        if (cell == QLatin1String("-")) {
          if (field == QLatin1String("text")) block.insert(field, QString());
        } else if (field == QLatin1String("checked")) {
          block.insert(field, cell == QLatin1String("true"));
        } else if (field == QLatin1String("depth") || field == QLatin1String("start")) {
          block.insert(field, cell.toInt());
        } else {
          block.insert(field, cell);
        }
      }
      given(world, S("block.insert"), block);
    }
  });
  // The page's lines as Markdown, from what each block shows: what the MC writes around its
  // text, then a tick standing for `- [ ]` and a callout's tint for `> `. A tall phone shows
  // every block at once.
  step(S("each block is shown as this Markdown, line for line:"), [](World& world, const Captures&, const Table& table) {
    QStringList wanted;
    for (const QString& line : table.value(0).value(0).split(QLatin1Char('\n'))) {
      if (!line.trimmed().isEmpty()) wanted.append(line);
    }
    world.resize(430, 2400);
    QStringList shown;
    world.waitFor([&] {
      shown = shownMarkdown(world.window().contentItem());
      return shown == wanted;
    }, [&] { return S("the page to show\n%1\nbut it shows\n%2").arg(wanted.join(QLatin1Char('\n')), shown.join(QLatin1Char('\n'))); });
  });
  step(S("the page %1 with headings of every level from 1 to 6").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = givenPage(world, c[0]);
    for (int level = 1; level <= 6; ++level) {
      given(world, S("block.insert"), {{S("pageId"), page}, {S("kind"), S("heading")}, {S("text"), S("Level %1").arg(level)}, {S("level"), level}});
    }
  });
  step(S("each heading is smaller than the one of the level above it"), [](World& world, const Captures&, const Table&) {
    const auto size = [&](int level) { return world.item(S("spaceBlockText:Level %1").arg(level))->property("fontSize").toInt(); };
    for (int level = 2; level <= 6; ++level) {
      expect(size(level) < size(level - 1), S("a level %1 heading is %2px, a level %3 one %4px").arg(level).arg(size(level)).arg(level - 1).arg(size(level - 1)));
    }
  });
  // Inline formatting (markdown.feature): a paragraph is drawn by the chat's Markdown brick,
  // each kind of formatting as the brick writes it, with none of its markers left.
  static const QMap<QString, std::pair<QString, QStringList>> inlined{
      {S("bold and italic text"), {S("**Bold** and _italic_"), {S("<b>Bold</b>"), S("<i>italic</i>")}}},
      {S("struck-through text"), {S("~~struck~~"), {S("<s>struck</s>")}}},
      {S("inline code"), {S("`mix test`"), {S("class=\"c\""), S("mix test")}}},
      {S("a link with a title"), {S("a [link](https://example.com \"Title\")"), {S("href=\"https://example.com\">link</a>")}}},
      {S("an autolinked address and a bare www link"),
       {S("<https://example.com> and www.example.com"),
        {S("href=\"https://example.com\">https://example.com</a>"), S("href=\"http://www.example.com\">www.example.com</a>")}}}};
  static const QString linking = S("[the docs](https://example.com/docs) hold ![Signups](https://example.com/signups.png)");
  const auto prose = [](World& world, const QString& said) {
    QQuickItem* drawn = world.item(S("spaceBlockText:") + said);
    expect(!world.find(S("spaceBlockEditor:") + said), S("the paragraph shows its source"));
    expect(!drawn->property("trusted").toBool(), S("the paragraph is drawn trusted"));
    QQuickItem* html = named(drawn, S("markdownProse"));
    expect(html != nullptr, S("the paragraph is not drawn as prose"));
    return html;
  };
  step(S("a page with a paragraph holding (.+)"), [](World& world, const Captures& c, const Table&) {
    expect(inlined.contains(c[0]), S("no paragraph holds %1").arg(c[0]));
    givenBlock(world, S("Notes"), S("paragraph"), inlined.value(c[0]).first);
  });
  step(S("a page with a paragraph linking to a web address"), [](World& world, const Captures&, const Table&) {
    givenBlock(world, S("Notes"), S("paragraph"), linking);
  });
  step(S("the user opens the page"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, idOfPage(world, S("Notes")));
  });
  step(S("the paragraph is shown with (.+)"), [prose](World& world, const Captures& c, const Table&) {
    const auto& [said, wanted] = inlined.value(c[0]);
    const QString html = prose(world, said)->property("text").toString();
    for (const QString& part : wanted) expect(html.contains(part), S("%1 is not drawn in %2").arg(part, html));
    for (const QString& marker : {S("**"), S("~~"), S("`"), S("]("), S("Title")}) expect(!html.contains(marker), S("%1 shows in %2").arg(marker, html));
  });
  step(S("nothing is fetched until the user opens the link"), [prose](World& world, const Captures&, const Table&) {
    QQuickItem* drawn = prose(world, linking);
    const QString html = drawn->property("text").toString();
    expect(!html.contains(S("<img")), S("the picture is loaded: %1").arg(html));
    expect(html.contains(S("href=\"https://example.com/signups.png\">")), S("the picture is no link: %1").arg(html));
    expect(world.openedUrls.isEmpty(), S("the phone opened %1").arg(world.openedUrls.size()));
    // The link starts the paragraph: a click on its first letters follows it.
    QTest::mouseClick(&world.window(), Qt::LeftButton, {}, drawn->mapToScene(QPointF(4, drawn->height() / 2)).toPoint());
    world.waitFor([&] { return !world.openedUrls.isEmpty(); }, S("the link to open"));
    expect(world.openedUrls == QList<QUrl>{QUrl(S("https://example.com/docs"))}, S("the phone opened %1").arg(world.openedUrls.value(0).toString()));
  });

  // Lists (markdown.feature): each item is a block the brick draws as a list of one, its
  // marker the one its depth takes, nested by the indent before it.
  struct Nested {
    QString kind, text;
    int depth;
    QString list;  // what the brick draws it in
  };
  static const QList<Nested> nested{
      {S("bullet"), S("Plan the release"), 0, S("<ul style=\"-qt-list-indent:0;list-style-type:disc;")},
      {S("numbered"), S("Tag"), 1, S("<ol style=\"-qt-list-indent:0;list-style-type:decimal;")},
      {S("numbered"), S("Ship"), 1, S("<ol start=\"2\" style=\"-qt-list-indent:0;list-style-type:decimal;")},
      {S("bullet"), S("Notes"), 2, S("<ul style=\"-qt-list-indent:0;list-style-type:circle;")},
      {S("bullet"), S("Announce"), 0, S("<ul style=\"-qt-list-indent:0;list-style-type:disc;")}};
  step(S("the page %1 with a bulleted list holding a numbered list").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const Nested& item : nested)
      given(world, S("block.insert"), {{S("pageId"), givenPage(world, c[0])}, {S("kind"), item.kind}, {S("text"), item.text}, {S("depth"), item.depth}});
  });
  step(S("each item is shown with its bullet or its number, indented under its parent"), [](World& world, const Captures&, const Table&) {
    QMap<QString, qreal> left;
    for (const Nested& item : nested) {
      QQuickItem* drawn = world.item(S("spaceBlockText:") + item.text);
      QQuickItem* prose = named(drawn, S("markdownProse"));
      expect(prose != nullptr, S("%1 is not drawn as prose").arg(item.text));
      const QString html = prose->property("text").toString();
      expect(html.contains(item.list) && html.contains(S(">%1</").arg(item.text)), S("%1 is drawn as %2").arg(item.text, html));
      QQuickItem* lead = world.find(S("spaceMarkdownLead:") + item.text);
      expect(!lead || !lead->isVisible() || lead->property("text").toString().trimmed().isEmpty(),
             S("%1 shows its marker as text: %2").arg(item.text, lead ? lead->property("text").toString() : QString()));
      left.insert(item.text, drawn->mapToScene({}).x());
    }
    const auto under = [&](const QString& child, const QString& parent) {
      expect(left.value(child) > left.value(parent), S("%1 (at %2) is not indented under %3 (at %4)").arg(child).arg(left.value(child)).arg(parent).arg(left.value(parent)));
    };
    under(S("Tag"), S("Plan the release"));
    under(S("Notes"), S("Ship"));
    expect(qFuzzyCompare(left.value(S("Tag")), left.value(S("Ship"))), S("Tag and Ship are not at one depth"));
    expect(qFuzzyCompare(left.value(S("Announce")), left.value(S("Plan the release"))), S("Announce is not back at the top"));
  });

  // A page from a thread.
  step(S("a connected environment with the thread %1 in the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[1]), S("the MC has no project %1").arg(c[1]));
    pairWithEnvironment(world);
    haveThread(world, c[0]);
    threadRow(world, c[0]);
  });
  step(S("the thread %1 talked about a release plan").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).talked.insert(threadNamed(world, c[0]));
  });
  step(S("text generation is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = S("available");
  });
  step(S("no text generation provider is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = S("unavailable");
  });
  // A page that updates itself.
  step(S("the user has %1 update itself with %1 every (\\d+) hours").arg(q), [](World& world, const Captures& c, const Table&) {
    askUpdate(world, c[0], c[1], [&] {
      choose(world, S("every:") + c[2]);
      settle(world);
    });
  });
  step(S("the user has %1 update itself with %1 every day at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    askUpdate(world, c[0], c[1], [&] {
      choose(world, S("time"));
      answer(world, c[2]);
    });
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
  step(S("the user pauses the updates of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateMenu(world, c[0], [](const QVariantMap& update) { return update.value(S("enabled")) == true; }, S("updatePause"));
  });
  step(S("the user resumes the updates of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateMenu(world, c[0], [](const QVariantMap& update) { return update.value(S("enabled")) == false; }, S("updatePause"));
  });
  step(S("the user runs the update of %1 now").arg(q), [](World& world, const Captures& c, const Table&) {
    updateMenu(world, c[0], [](const QVariantMap& update) { return !update.isEmpty(); }, S("updateRun"));
  });
  step(S("the user removes the update of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateMenu(world, c[0], [](const QVariantMap& update) { return !update.isEmpty(); }, S("updateRemove"));
  });
  // The screens have no way to, so this is what a client that tried would hear.
  step(S("the user tries to edit the generated part of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = generatedOf(world.mc, current(world), idOfPage(world, c[0]));
    expect(!block.isEmpty(), S("%1 has no generated part").arg(c[0]));
    lookAtPage(world, idOfPage(world, c[0]));
    act(world, S("space.block.update"), {{S("blockId"), text(block, QLatin1String("id"))}, {S("text"), S("Edited by hand")}});
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

  step(S("text generation fails"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = S("failed");
  });
  step(S("writing a page from a thread takes a while"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(S("pageFromThread"));
  });
  step(S("the page from the thread is written"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    world.sync();
  });
  step(S("the user opens the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
  });
  step(S("the user opens the page %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[1]));
    world.tap(S("spacePage:") + c[0]);
    expectStep(world, S("page"));
  });
  step(S("the Space screen shows the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expectStep(world, S("page"));
    const QString title = viewOf(world)->page().value(S("title")).toString();
    expect(title == c[0], S("another page shows: %1").arg(title));
  });
  step(S("the user goes to Settings from there"), [](World& world, const Captures&, const Table&) {
    // As the palette does: not by Back, which would take the screen's steps first.
    world.bridge().dispatch(NavigationController::kOpenSettings, QVariantMap{});
    world.waitFor([&] { return navigation(world)->route().kind == QLatin1String("settings"); }, S("the settings"));
  });
  step(S("the user opens the Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
  });
  step(S("the Space screen shows the list of Spaces"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expectStep(world, S("spaces"));
  });
  step(S("the user unfolds the phone"), [](World& world, const Captures&, const Table&) {
    world.resize(1024, 800);
  });
  step(S("the Space screen shows the pages of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expectStep(world, S("pages"));
    expect(viewOf(world)->spaceId() == idOfSpace(world, c[0]), S("another Space shows: %1").arg(describe(world)));
  });
  step(S("the user makes a page in %1 from the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The Space the page goes in is the one the user last had open.
    look(world, idOfSpace(world, c[0]));
    while (navigation(world)->route().kind == QLatin1String("space")) world.back();
    openThread(world, c[1]);
    // From the thread's menu.
    world.tap(S("threadMenu"));
    world.awaitPopup(S("mobileMenu"));
    // The menu is longer than the screen: its list scrolls to the item.
    QQuickItem* item = world.item(S("mobileMenuItem:page-from-thread"));
    QMetaObject::invokeMethod(item->parentItem()->parentItem(), "positionViewAtEnd");
    world.tap(item);
    world.awaitPopup(S("mobileMenu"), false);
    world.sync();
  });
  step(S("the new page holds the generated summary"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] {
      return shown(world) == QLatin1String("page") && viewOf(world)->spaceId() == current(world) && viewOf(world)->page().value(S("title")) == kSummaryTitle &&
             blockTexts(world) == QStringList{kSummary};
    }, S("the summary to open as a page"));
    const QVariantMap block = viewOf(world)->blocks()->get(0);
    expect(block.value(S("byAgent")).toBool(), S("the summary is not shown as the agent's: %1").arg(show(block)));
  });
  step(S("the new page remembers it came from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap page = viewOf(world)->page();
    expect(page.value(S("sourceThreadId")) == threadNamed(world, c[0]) && page.value(S("sourceThreadTitle")) == c[0], S("the page shows %1").arg(show(page)));
    world.item(S("spacePageSource"));
    expect(world.shows(c[0], false), S("the page does not say so: %1").arg(show(world.texts())));
  });
  step(S("the summary was written in the project's folder"), [](World& world, const Captures&, const Table&) {
    // The client names the thread; the MC finds its folder.
    const FakeSpaces& spaces = fake(world.mc);
    const QJsonObject thread = world.mc.threads.value(spaces.summarised);
    const QString folder = world.mc.projects.value(thread.value(QLatin1String("projectId")).toString()).value(QLatin1String("workspaceRoot")).toString();
    expect(!spaces.summarised.isEmpty() && !folder.isEmpty() && spaces.cwd == folder, S("the summary of %1 was written in \"%2\", not \"%3\"").arg(spaces.summarised, spaces.cwd, folder));
  });
  // Charts on a page (space/visualize.feature).
  step(S("this MC's threads took turns this week"), [](World&, const Captures&, const Table&) {});
  step(S("text generation charts the request from the MC's threads"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).chart = chartOf(S("bar"), S("Weekly turns"), S("Counted by this MC from its 2 threads, 12 weeks to 2026-11-01"), {{S("10-26"), 4}, {S("11-02"), 7}});
  });
  step(S("text generation answers with a (bar|line) chart of %1 (\\d+)(?: and %1 (\\d+))?").arg(q), [](World& world, const Captures& c, const Table&) {
    QList<std::pair<QString, int>> points{{c[1], c[2].toInt()}};
    if (!c.value(3).isEmpty()) points.append({c[3], c[4].toInt()});
    fake(world.mc).chart = chartOf(c[0], S("Signups"), kFromThisPage, points);
  });
  step(S("text generation says the request cannot be answered"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).chart = {};
  });
  step(S("the page %1 has a chart of %1 (\\d+) and %1 (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    givenChart(world, c[0], c[1], c[2].toInt(), c[3], c[4].toInt());
  });
  step(S("the page %1 has a chart with 2 labels and 1 number").arg(q), [](World& world, const Captures& c, const Table&) {
    givenUnmatchedChart(world, c[0]);
  });
  step(S("the page %1 has the blocks %1 and a chart of %1 (\\d+) and %1 (\\d+) and the blocks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("paragraph"), c[1]);
    givenChart(world, c[0], c[2], c[3].toInt(), c[4], c[5].toInt());
    givenBlock(world, c[0], S("paragraph"), c[6]);
  });
  step(S("%1 also says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], S("paragraph"), c[1]);
  });
  step(S("the user asks for %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).asked = idOfPage(world, c[1]);
    lookAtPage(world, fake(world.mc).asked);
    world.tap(S("spaceAddBlock"));
    choose(world, S("chart"));
    answer(world, wordsOf(c[0]));
  });
  step(S("the user asks again for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return !shownChart(world).isEmpty(); }, S("a chart on the page"));
    blockMenu(world, shownChart(world).value(S("text")).toString(), S("again"));
    // Typing replaces the words it offers, which are selected.
    answer(world, wordsOf(c[0]));
  });
  step(S("the page shows a (bar|line) chart titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    const QString drawn = c[0] == QLatin1String("bar") ? S("spaceChartBar") : S("spaceChartLine");
    expectShown(world, [&] {
      const QQuickItem* title = world.find(S("spaceChartTitle"));
      return title && title->property("text").toString() == c[1] && world.find(drawn);
    }, S("a %1 chart titled %2").arg(c[0], c[1]));
    expect(!drawing(world), S("the page still says a chart is being drawn"));
  });
  step(S("the chart says its numbers came from (this MC's threads|this page)"), [](World& world, const Captures& c, const Table&) {
    const QString source = world.item(S("spaceChartSource"))->property("text").toString();
    const QString start = c[0] == QLatin1String("this page") ? kFromThisPage : S("Counted by this MC");
    expect(source.startsWith(start), S("the chart says its numbers came from \"%1\"").arg(source));
  });
  step(S("the second client sees a chart titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    second(world).selectPage(fake(world.mc).asked);
    QStringList titles;
    for (const QVariantMap& row : second(world).blocks()->rows()) titles.append(row.value(S("chart")).toMap().value(S("title")).toString());
    expect(titles.contains(c[0]), S("the second client shows the charts %1").arg(show(titles)));
  });
  step(S("the user asks to see the numbers behind the chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return world.find(S("spaceChartNumbers")) != nullptr; }, S("a chart on the page"));
    world.tap(S("spaceChartNumbers"));
  });
  step(S("the chart's numbers are not shown"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    world.item(S("spaceChartUnmatched"));
    expect(world.find(S("spaceChartNumbers")) == nullptr, S("the chart offers its numbers"));
    expect(world.find(S("spaceChartBar")) == nullptr, S("the chart draws its bars"));
  });
  step(S("the numbers read %1 (\\d+)(?: and %1 (\\d+))?").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    QVariantList labels{c[0]};
    QVariantList values{c[1].toDouble()};
    if (!c.value(2).isEmpty()) {
      labels.append(c[2]);
      values.append(c[3].toDouble());
    }
    expectShown(world, [&] {
      const QVariantMap chart = shownChart(world).value(S("chart")).toMap();
      const QVariantList series = chart.value(S("series")).toList();
      return chart.value(S("labels")).toList() == labels && series.size() == 1 && series.first().toMap().value(S("values")).toList() == values;
    }, S("the numbers to read %1").arg(c.join(QLatin1Char(' '))));
    // And the table says so, once it is open.
    expectShown(world, [&] { return world.find(S("spaceChartNumbers")) != nullptr; }, S("a chart on the page"));
    const QQuickItem* table = world.find(S("spaceChartTable"));
    if (!table || !table->isVisible()) world.tap(S("spaceChartNumbers"));
    expectShown(world, [&] { return world.find(S("spaceChartCell:") + c[0]) != nullptr && world.find(S("spaceChartCell:") + c[1]) != nullptr; }, S("the table to read %1").arg(c.join(QLatin1Char(' '))));
  });
  step(S("the page shows one chart, between %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QStringList kinds = column(viewOf(world)->blocks(), S("kind"));
      const QStringList texts = column(viewOf(world)->blocks(), S("text"));
      const qsizetype at = kinds.indexOf(S("chart"));
      return kinds.count(S("chart")) == 1 && at > 0 && at + 1 < texts.size() && texts.at(at - 1) == c[0] && texts.at(at + 1) == c[1];
    }, S("one chart between %1 and %2").arg(c[0], c[1]));
  });
  step(S("the user deletes the chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return !shownChart(world).isEmpty(); }, S("a chart on the page"));
    blockMenu(world, shownChart(world).value(S("text")).toString(), S("delete"));
    settle(world);
  });
  step(S("the page shows no chart"), [](World& world, const Captures&, const Table&) {
    lookAtPage(world, fake(world.mc).asked);
    expectShown(world, [&] { return shownChart(world).isEmpty() && !world.find(S("spaceChart")); }, S("no chart on the page"));
  });
  step(S("the user is told no chart was drawn"), [](World& world, const Captures&, const Table&) {
    const QString start = S("No chart was drawn");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return S("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    expect(!drawing(world), S("the page still says a chart is being drawn"));
  });
  step(S("the user is told text generation (is unavailable|failed)"), [](World& world, const Captures& c, const Table&) {
    const QString start = c[0] == QLatin1String("failed") ? S("Text generation failed, so no page was written: The provider stopped answering.")
                                                          : S("Text generation is unavailable, so no page was written.");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return S("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    world.waitFor([&] { return world.shows(start, false); }, [&] { return S("the phone to show \"%1\"; it shows %2").arg(start, show(world.texts())); });
    expect(!world.state(S("space")).toMap().value(S("busy")).toBool(), S("the Space view still says it is writing"));
    expect(navigation(world)->route().kind == QLatin1String("thread"), S("the user was taken from the thread"));
  });

  // Decks and their slides (features/space/slides.feature).
  step(S("the user makes the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    world.tap(S("spaceNewDeck"));
    if (c[0].trimmed().isEmpty()) {
      // The dialog's action waits for a title.
      world.awaitPopup(S("spaceTextDialog"));
      expect(!world.item(S("spaceTextSave"))->isEnabled(), S("a deck can be made with no title"));
      world.tap(S("spaceTextCancel"));
      settle(world);
      act(world, S("space.deck.create"), {{S("title"), c[0]}});
      return;
    }
    answer(world, c[0]);
    // The deck made is the one the user lands on.
    expectStep(world, S("deck"));
    expect(viewOf(world)->deck().value(S("title")) == c[0], S("another deck opened: %1").arg(describe(world)));
  });
  step(S("the user makes a deck from the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString page = idOfPage(world, c[0]);
    look(world, current(world));
    expectShown(world, [&] { return viewOf(world)->pages()->indexOf(page) >= 0 || viewOf(world)->trash()->indexOf(page) >= 0; }, S("the Space to list %1").arg(c[0]));
    if (viewOf(world)->pages()->indexOf(page) < 0) {
      // Only a page out of the trash offers it.
      act(world, S("space.deck.createFromPage"), {{S("pageId"), page}});
      return;
    }
    pageMenu(world, c[0], S("deck"));
    settle(world);
    expectStep(world, S("deck"));
  });
  step(S("the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenDeck(world, c[0]);
  });
  step(S("the deck %1 with the slides %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = givenDeck(world, c[0]);
    for (const QJsonObject& slide : slidesOf(world.mc, streamOf(current(world)), deck)) {
      given(world, S("slide.delete"), {{S("slideId"), text(slide, QLatin1String("id"))}});
    }
    for (const QString& title : listed(c[1])) given(world, S("slide.insert"), {{S("deckId"), deck}, {S("title"), title}});
  });
  step(S("the deck %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("deck.trash"), {{S("deckId"), givenDeck(world, c[0])}});
  });
  step(S("the decks of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->decks(), S("title")) == listed(c[1]); }, S("the decks to be %1").arg(c[1]));
    for (const QString& title : listed(c[1])) world.item(S("spaceDeck:") + title);
  });
  step(S("the deck %1 has the slides:").arg(q), [](World& world, const Captures& c, const Table& table) {
    lookAtDeck(world, idOfDeck(world, c[0]));
    Table wanted;
    for (const QStringList& row : table.mid(1)) wanted.append({row.value(0), row.value(1)});
    // What the rows on screen hold, as the table writes it.
    const auto onScreen = [&] {
      Table rows;
      for (int row = 0; row < viewOf(world)->slides()->rowCount(); ++row) {
        QQuickItem* title = world.find(S("spaceSlideTitle:%1").arg(row));
        QQuickItem* body = world.find(S("spaceSlideBody:%1").arg(row));
        if (!title || !body) return Table{};
        rows.append({title->property("text").toString(), body->property("text").toString().replace(QLatin1Char('\n'), S(" / "))});
      }
      return rows;
    };
    world.waitFor([&] { return onScreen() == wanted; }, [&] { return S("the slides %1, shown %2").arg(show(tableOf(wanted)), show(tableOf(onScreen()))); });
  });
  step(S("the slides of %1 are( still)? %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().client()->isReady(); }, S("the phone to reconnect"));
    lookAtDeck(world, idOfDeck(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->slides(), S("title")) == listed(c[2]); },
                S("the slides to be %1, shown %2").arg(c[2], show(column(viewOf(world)->slides(), S("title")))));
  });
  step(S("the user renames the deck %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    deckMenu(world, c[0], S("rename"));
    answer(world, c[1]);
  });
  step(S("the user moves the deck %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    deckMenu(world, c[0], S("trash"));
    settle(world);
  });
  step(S("the user restores the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    world.tap(S("spaceDeckTrashMenu:") + c[0]);
    choose(world, S("restore"));
    settle(world);
  });
  step(S("the user deletes the deck %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = idOfDeck(world, c[0]);
    look(world, current(world));
    if (viewOf(world)->deckTrash()->indexOf(deck) >= 0) {
      world.tap(S("spaceDeckTrashMenu:") + c[0]);
      choose(world, S("delete"));
      settle(world);
    } else {
      // Only the trash offers it.
      act(world, S("space.deck.delete"), {{S("deckId"), deck}});
    }
  });
  step(S("no slides remain in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return viewOf(world)->space().of(S("slide")).isEmpty(); }, S("no slides to remain"));
  });
  step(S("the user adds the slide %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString deck = idOfDeck(world, c[1]);
    lookAtDeck(world, deck);
    if (trashed(one(world.mc, streamOf(current(world)), S("deck"), deck))) {
      // A deck in the trash offers no way to add one, and says why.
      world.item(S("spaceDeckTrashedNotice"));
      expect(world.find(S("spaceAddSlide")) == nullptr, S("a deck in the trash offers to add a slide"));
      act(world, S("space.slide.insert"), {{S("deckId"), deck}, {S("title"), c[0]}, {S("body"), QString()}});
      return;
    }
    world.tap(S("spaceAddSlide"));
    answer(world, c[0]);
  });
  step(S("the user adds the slide %1 after %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    slideMenu(world, c[1], S("below"));
    answer(world, c[0]);
  });
  step(S("the user changes the slide %1 to %1 reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString row = openSlide(world, c[0]);
    const auto write = [&](const QString& name, const QString& said) {
      QQuickItem* editor = world.item(name + row);
      world.tap(editor);
      world.waitFor([&] { return editor->hasActiveFocus(); }, S("the slide's text to take the keyboard"));
      QMetaObject::invokeMethod(editor, "selectAll");
      world.type(said);
    };
    write(S("spaceSlideTitle:"), c[1]);
    write(S("spaceSlideBody:"), c[2]);
    world.tap(S("spaceDeckDone"));
    world.sync();
  });
  step(S("the user moves the slide %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString moved = idOfSlide(world, c[0]);
    const QString target = idOfSlide(world, c[1]);
    openSlide(world, c[0]);
    // A step up at a time, under a finger.
    SpaceRows* rows = viewOf(world)->slides();
    const auto above = [&] { return rows->indexOf(moved) < rows->indexOf(target); };
    for (int steps = rows->rowCount(); steps > 0 && !above(); --steps) {
      slideMenu(world, c[0], S("up"));
      settle(world);
    }
    expect(above(), describe(world));
  });
  step(S("the user deletes the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    slideMenu(world, c[0], S("delete"));
    settle(world);
  });
  step(S("the second client sees the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList titles = column(second(world).decks(), S("title"));
    expect(titles.contains(c[0]), S("the second client shows the decks %1").arg(show(titles)));
  });
  step(S("the second client sees the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    second(world).selectDeck(text(slideTitled(world, c[0]), QLatin1String("deckId")));
    const QStringList titles = column(second(world).slides(), S("title"));
    expect(titles.contains(c[0]), S("the second client shows the slides %1").arg(show(titles)));
  });

  // Presenting.
  step(S("the user presents the deck %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtDeck(world, idOfDeck(world, c[0]));
    world.tap(S("spaceDeckPresent"));
    world.sync();
  });
  step(S("the presenter shows %1, slide (\\d+) of (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    SpaceController* view = viewOf(world);
    const QString count = S("%1 / %2").arg(c[1], c[2]);
    const auto said = [&](const QString& name) {
      QQuickItem* label = world.find(name);
      return label ? label->property("text").toString() : QString();
    };
    world.waitFor([&] { return view->presenting() && said(S("spacePresenterTitle")) == c[0] && said(S("spacePresenterCount")) == count; },
                  [&] { return S("the presenter to show %1, %2; it shows %3, %4").arg(c[0], count, said(S("spacePresenterTitle")), said(S("spacePresenterCount"))); });
  });
  step(S("the user steps (forward|back)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("forward")) {
      // A tap anywhere but the left third.
      world.tap(S("spacePresenterTap"));
    } else if (QQuickItem* button = world.item(S("spacePresenterBack")); button->isEnabled()) {
      world.tap(button);
    } else {
      // At the first slide its button offers nothing; the keyboard still asks.
      act(world, S("space.deck.step"), {{S("by"), -1}});
    }
    world.sync();
  });
  step(S("the user leaves the presenter"), [](World& world, const Captures&, const Table&) {
    world.back();
    world.sync();
  });
  step(S("nothing is being presented"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return !viewOf(world)->presenting(); }, S("the presenter to be closed"));
    world.awaitPopup(S("spacePresenterStage"), false);
  });
  step(S("the user is told the deck has no slides"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toldOf(world, S("This deck has no slides")); }, [&] { return S("the user to be told; toasts %1").arg(show(toasts(world))); });
  });
  step(S("another client changes the slide %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("slide.update"), {{S("slideId"), idOfSlide(world, c[0])}, {S("title"), c[1]}});
  });
  step(S("another client moves the slide %1 after %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("slide.move"), {{S("slideId"), idOfSlide(world, c[0])}, {S("afterSlideId"), idOfSlide(world, c[1])}});
  });
  step(S("another client deletes the slide %1").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("slide.delete"), {{S("slideId"), idOfSlide(world, c[0])}});
  });
  step(S("another client moves the deck %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, S("deck.trash"), {{S("deckId"), idOfDeck(world, c[0])}});
  });
  // Images.
  step(QStringLiteral("the user adds the image %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    signImages(world);
    takeUploads(world);
    look(world, idOfSpace(world, c[1]));
    // The system's file picker is not this app's; what it answers with goes here.
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
    // The dialog holds back a blank prompt or no provider; the MC's answer is what this is about.
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
    const QString image = idOfImage(world, c[0]);
    lookAtPage(world, idOfPage(world, c[1]));
    world.waitFor([&] { return viewOf(world)->images()->indexOf(image) >= 0 || imageTrashed(world, image); }, S("the Space to know the image"));
    // The sheet does not offer an image in the trash; the MC's refusal is what this is about.
    if (imageTrashed(world, image)) {
      act(world, S("space.block.insert"), {{S("pageId"), viewOf(world)->pageId()}, {S("kind"), S("image")}, {S("text"), c[0]}, {S("imageId"), image}});
      return;
    }
    world.tap(S("spaceAddBlock"));
    choose(world, S("image"));
    world.waitFor([&] { return world.find(S("spaceSheetItem:") + image) != nullptr; }, S("the sheet to offer the image"));
    world.tap(S("spaceSheetItem:") + image);
    settle(world);
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
    imageMenu(world, c[0], false, S("trash"));
  });
  step(QStringLiteral("the user restores the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    imageMenu(world, c[0], true, S("restore"));
  });
  step(QStringLiteral("the user deletes the image %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString image = idOfImage(world, c[0]);
    look(world, current(world));
    world.waitFor([&] { return viewOf(world)->images()->indexOf(image) >= 0 || imageTrashed(world, image); }, S("the Space to know the image"));
    // A live image's menu has no such choice; the MC's refusal is what this is about.
    if (imageTrashed(world, image)) {
      imageMenu(world, c[0], true, S("delete"));
    } else {
      act(world, S("space.image.delete"), {{S("imageId"), image}});
    }
  });
  step(QStringLiteral("the user opens the images of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (world.find(S("desktopLayout"))) {
      world.tap(S("spaceImages"));
    } else {
      lookAtImages(world, idOfSpace(world, c[0]), false);
    }
  });
  step(QStringLiteral("the user sees the image %1 with its name").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->images(), idOfImage(world, c[0]));
      return row && row->value(S("name")) == c[0] && !row->value(S("url")).toString().isEmpty() && world.find(S("spaceImage:") + c[0]) != nullptr;
    }, S("the image %1 with a name and an address").arg(c[0]));
  });
  step(QStringLiteral("no address has been signed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!fake(world.mc).signedImages.contains(idOfImage(world, c[0])), QStringLiteral("the client signed an address for %1 before it was shown").arg(c[0]));
  });
  step(QStringLiteral("an address has been signed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fake(world.mc).signedImages.contains(idOfImage(world, c[0])); }, [&] { return QStringLiteral("an address to be signed for %1").arg(c[0]); });
  });

  // Project files in the Space sidebar (features/space/project-files.feature).
  step(S("%1 has the file %1 reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kProject, S("the phone's threads are all in shop"));
    filesOf(world.mc, c[0]).insert(c[1], QString(c[2]).replace(S("\\n"), S("\n")));
    // A thread to show the project's files in.
    haveThread(world, kFilesThread);
    world.sync();
  });
  step(S("the project %1 has the file %1 reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveProject(world, c[0]);
    filesOf(world.mc, c[0]).insert(c[1], QString(c[2]).replace(S("\\n"), S("\n")));
  });
  step(S("the project %1 has no Space files").arg(q), [](World& world, const Captures& c, const Table&) {
    haveProject(world, c[0]);
  });
  step(S("the user is in the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, spaceNamed(world, c[0]));
  });
  step(S("the sidebar's project sections are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtSidebar(world);
    const QStringList wanted = c[0].split(S(", "));
    world.waitFor([&] {
      QStringList projects;
      for (const QVariantMap& row : sectionRows(world)) {
        if (row.value(S("kind")) == QLatin1String("project")) projects.append(row.value(S("projectId")).toString());
      }
      return projects == wanted;
    }, [&] { return S("the project sections to be %1; %2").arg(c[0], describeSections(world)); });
    for (const QString& project : wanted) sectionItem(world, S("project"), project);
  });
  step(S("the section of %1 is collapsed").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtSection(world, c[0]);
    world.waitFor([&] {
      const QList<QVariantMap> rows = sectionRows(world);
      return std::none_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& row) {
        return row.value(S("projectId")) == c[0] && (row.value(S("kind")) != QLatin1String("project") || row.value(S("expanded")).toBool());
      });
    }, [&] { return S("the section of %1 to be collapsed; %2").arg(c[0], describeSections(world)); });
    // The list lets go of a removed row on its next pass.
    world.waitFor([&] { return world.find(S("spaceProjectFolder:%1:docs").arg(c[0])) == nullptr; }, S("the collapsed section to hide its folders"));
  });
  step(S("the section of %1 is expanded").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtSection(world, c[0]);
    world.waitFor([&] { return expanded(world, c[0]); }, [&] { return S("the section of %1 to be expanded; %2").arg(c[0], describeSections(world)); });
  });
  step(S("the user (?:expands|expanded) the section of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setSection(world, c[0], true);
  });
  step(S("the user collapses the section of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setSection(world, c[0], false);
  });
  step(S("the folder %1 of %1 is collapsed").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtFolder(world, c[1], c[0]);
    waitForFolder(world, c[1], c[0], false);
    world.waitFor([&] {
      const QList<QVariantMap> rows = sectionRows(world);
      return std::none_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& row) {
        return row.value(S("projectId")) == c[1] && row.value(S("path")).toString().startsWith(c[0] + QLatin1Char('/'));
      });
    }, [&] { return S("nothing in the folder %1 of %2 to show; %3").arg(c[0], c[1], describeSections(world)); });
  });
  step(S("the user (?:expands|expanded) the folder %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setFolder(world, c[1], c[0], true);
  });
  step(S("the user collapses the folder %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setFolder(world, c[1], c[0], false);
  });
  step(S("the user expands the folder %1 of %1 from the keyboard").arg(q), [](World& world, const Captures& c, const Table&) {
    setFolder(world, c[1], c[0], true, true);
  });
  step(S("the user collapses the folder %1 of %1 from the keyboard").arg(q), [](World& world, const Captures& c, const Table&) {
    setFolder(world, c[1], c[0], false, true);
  });
  step(S("the section of %1 shows %1 in the folder %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtSection(world, c[0]);
    world.waitFor([&] {
      const QList<QVariantMap> rows = sectionRows(world);
      for (qsizetype i = 0; i + 1 < rows.size(); ++i) {
        const QVariantMap& folder = rows.at(i);
        const QVariantMap& file = rows.at(i + 1);
        if (folder.value(S("kind")) != QLatin1String("folder") || folder.value(S("projectId")) != c[0] || folder.value(S("path")) != c[2]) continue;
        return file.value(S("kind")) == QLatin1String("file") && file.value(S("path")) == c[2] + QLatin1Char('/') + c[1] && file.value(S("name")) == c[1] &&
               file.value(S("depth")).toInt() == folder.value(S("depth")).toInt() + 1;
      }
      return false;
    }, [&] { return S("the section of %1 to show %2 in %3; %4").arg(c[0], c[1], c[2], describeSections(world)); });
    sectionItem(world, S("folder"), c[0], c[2]);
    sectionItem(world, S("file"), c[0], c[2] + QLatin1Char('/') + c[1]);
  });
  step(S("the client starts again"), [](World& world, const Captures&, const Table&) {
    world.close();
    world.open();
    world.waitFor([&] { return world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected"); },
                  [&] { return S("the reopened app to connect; it is %1").arg(show(world.state(S("connection")))); });
  });
  step(S("the user picks %1 in the section of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pickInSection(world, c[1], c[0]);
  });
  step(S("the page editor shows the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectOpened(world, c[0]);
  });
  step(S("the page editor shows the page %1 in the section of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectFilePage(world, c[0], c[1]);
  });
  step(S("the page %1 is not among the pages of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString space = spaceNamed(world, c[1]);
    expect(viewOf(world)->spaceId() == space, S("the Space screen shows %1, not %2").arg(viewOf(world)->spaceName(), c[1]));
    expect(!column(viewOf(world)->pages(), S("title")).contains(c[0]), S("the Space screen lists %1 among the pages of %2").arg(c[0], c[1]));
    const QList<QJsonObject> pages = all(world.mc, streamOf(space), S("page"));
    expect(std::none_of(pages.cbegin(), pages.cend(), [&](const QJsonObject& page) { return text(page, QLatin1String("title")) == c[0]; }),
           S("the MC put %1 in %2").arg(c[0], c[1]));
  });
  step(S("the user is editing %1 of %1 from its section").arg(q), [](World& world, const Captures& c, const Table&) {
    pickInSection(world, c[1], c[0]);
    expectStep(world, S("page"));
    world.waitFor([&] {
      const QString space = projectSpace(world.mc, c[1]);
      return !space.isEmpty() && viewOf(world)->fileSpaceId() == space && shownFile(world).value(S("path")) == c[0];
    }, [&] { return S("%1 to be shown from its section; %2").arg(c[0], describe(world)); });
  });
  // Back to the Space's pages, where the page is a tap away.
  step(S("the user picks the page %1 in the sidebar").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfPage(world, c[0]);
    backTo(world, S("pages"));
    world.tap(S("spacePage:") + c[0]);
    expectStep(world, S("page"));
    world.waitFor([&] { return viewOf(world)->pageId() == id; }, [&] { return S("the page %1 to open; %2").arg(c[0], describe(world)); });
  });
  step(S("the user is browsing the files of %1").arg(q), [](World& world, const Captures&, const Table&) {
    browseFiles(world);
  });
  step(S("the user picks \"Edit as a page\" on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    holdEntry(world, c[0]);
    world.tap(S("fileEntryEditAsPage"));
  });
  step(S("the user is reading %1 in the file viewer").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world);
    world.bridge().dispatch(S("files.open"), QVariantMap{{S("path"), c[0]}});
    world.waitFor([&] { return viewerOf(world).openPath() == c[0] && viewerOf(world).fileStatus() != QLatin1String("loading"); },
                  [&] { return S("the viewer to open %1; it has \"%2\"").arg(c[0], viewerOf(world).openPath()); });
  });
  step(S("the user picks \"Edit as a page\" in the file viewer"), [](World& world, const Captures&, const Table&) {
    world.tap(world.item(S("fileEditAsPage")));
  });
  step(S("the agent's message in a thread of %1 links %1").arg(q), [](World& world, const Captures& c, const Table&) {
    inFilesThread(world);
    waitForFiles(world, c[0]);
    const QString run = S("run-1");
    setEntity(world.mc, world.thread, S("run"), run, {{S("id"), run}, {S("ordinal"), 1}, {S("status"), S("completed")}});
    setEntity(world.mc, world.thread, S("turn-item"), S("message:") + run,
              {{S("id"), S("message:") + run},
               {S("type"), S("assistant_message")},
               {S("runId"), run},
               {S("ordinal"), 2},
               {S("status"), S("completed")},
               {S("text"), S("See [the guide](%1).").arg(c[1])},
               {S("updatedAt"), S("2026-09-23T09:00:00Z")}});
    world.sync();
    fake(world.mc).link = c[1];
  });
  // A finger held on the link asks for its menu (tst_Markdown.qml holds one).
  step(S("the user picks \"Edit as a page\" on that link"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(S("link.menu"), QVariantMap{{S("url"), fake(world.mc).link}, {S("x"), 10}, {S("y"), 10}});
    world.awaitPopup(S("mobileMenu"));
    world.tap(S("mobileMenuItem:edit-as-page"));
  });
  step(S("the user asks the command palette to edit %1 of %1 as a page").arg(q), [](World& world, const Captures& c, const Table&) {
    runCommand(world, S("Edit a project file as a page"));
    pickFile(world, c[0]);
    expect(at(world.state(S("space")), S("picking")).toString() == c[1], S("the picker offers another project than %1").arg(c[1]));
  });
  step(S("the user asks the command palette to scan %1 for Space files").arg(q), [](World& world, const Captures&, const Table&) {
    runCommand(world, S("Scan project for Space files"));
  });
  step(S("the user is told the scan wrote the spaces section"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return toldOf(world, S("Wrote the spaces section")); }, S("a toast that the scan wrote the spaces section"));
  });
  step(S("%1 offers no \"Edit as a page\"").arg(q), [](World& world, const Captures& c, const Table&) {
    holdEntry(world, c[0]);
    world.sync();
    expect(world.find(S("fileEntryEditAsPage")) == nullptr, S("the menu of %1 offers editing it as a page").arg(c[0]));
    closeEntryMenu(world);
    // The Markdown beside it is offered, so the menu is not merely waiting.
    holdEntry(world, S("docs/guide.md"));
    world.item(S("fileEntryEditAsPage"));
    closeEntryMenu(world);
  });
  step(S("the user has opened %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveProject(world, c[1]);
    const Answer answer = call(world.mc, S("page.openFile"), {{S("projectId"), c[1]}, {S("relativePath"), c[0]}});
    expect(answer.error.isEmpty(), S("the MC refused space.page.openFile: %1").arg(answer.error));
    world.sync();
  });
  step(S("the user shows the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtFilePage(world, c[0]);
  });
  step(S("the page says it is the file %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, [&] {
      const QVariantMap file = shownFile(world);
      return file.value(S("path")) == c[0] && file.value(S("projectTitle")) == c[1] && !file.value(S("missing")).toBool() &&
             file.value(S("conflictAt")).toString().isEmpty();
    }, S("the page to say it is %1 of %2").arg(c[0], c[1]));
    const QString said = world.item(S("spacePageFilePath"))->property("text").toString();
    expect(said.contains(c[0]) && said.contains(c[1]), S("the page says \"%1\"").arg(said));
    world.waitFor([&] { return fake(world.mc).syncs >= 1; }, S("showing the page to read its file again"));
  });
  step(S("the user shows the file of the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtFilePage(world, c[0]);
    world.tap(world.item(S("spacePageFileShow")));
  });
  step(S("the file viewer shows %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return navigation(world)->route().kind == QLatin1String("thread") && world.native().controller<RightPanelController>()->projectId() == c[1] &&
             viewerOf(world).openPath() == c[0] && world.find(S("filesPanel")) != nullptr;
    }, [&] { return S("the Files screen of %1 to show %2; it shows \"%3\"; the screen says: %4").arg(c[1], c[0], viewerOf(world).openPath(), world.texts().join(S(" | "))); });
  });
  step(S("the thread's row changes (\\d+) times"), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).listings = 0;
    for (int i = 0; i < c[0].toInt(); ++i) updateRow(world.mc, world.thread, {{S("updatedAt"), S("2026-09-23T09:%1:00Z").arg(i + 1, 2, 10, QLatin1Char('0'))}});
    world.sync();
  });
  step(S("the MC is not asked for the files of %1 again").arg(q), [](World& world, const Captures&, const Table&) {
    world.sync();
    if (fake(world.mc).listings != 0) fail(S("the MC was asked for them %1 more times").arg(fake(world.mc).listings));
  });
  step(S("a newer thread of %1 works in a worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = S("thread-worktree");
    world.mc.threads.insert(id, {{S("id"), id}, {S("title"), S("Draft")}, {S("projectId"), c[0]}, {S("worktreePath"), S("/work/%1-worktree").arg(c[0])},
                                 {S("createdAt"), S("2026-09-23T10:00:00Z")}, {S("updatedAt"), S("2026-09-23T10:00:00Z")}});
    world.mc.sendRow(id, world.mc.threads.value(id));
    world.sync();
  });
  step(S("the file viewer shows the project's own %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.mc.environmentId + QLatin1Char(':') + haveThread(world, kFilesThread);
    world.waitFor([&] {
      const auto route = navigation(world)->route();
      return route.kind == QLatin1String("thread") && route.threadKey == key && viewerOf(world).openPath() == c[0] && world.find(S("filesPanel")) != nullptr;
    }, [&] {
      return S("the Files screen of %1's thread on its folder (%2) to show %3; the route is %4, showing \"%5\"")
          .arg(c[1], key, c[0], navigation(world)->route().threadKey, viewerOf(world).openPath());
    });
  });
  step(S("an agent in %1 deleted %1").arg(q), [](World& world, const Captures& c, const Table&) {
    filesOf(world.mc, c[0]).remove(c[1]);
    // As the MC's watcher sees it go.
    const auto [space, page] = pageOfFile(world.mc, c[0], c[1]);
    if (!page.isEmpty()) loseFile(world.mc, space, page);
    world.sync();
  });
  step(S("the page says its file is gone"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return shownFile(world).value(S("missing")).toBool(); }, S("the page to say its file is gone"));
    world.item(S("spacePageFileGone"));
    expect(world.find(S("spacePageFileShow")) == nullptr, S("the page offers to show a file that is gone"));
  });
  step(S("the file won over the user's edit of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto [space, found] = filePage(world, c[0]);
    const QString page = text(found, QLatin1String("id"));
    given(world, S("block.insert"), {{S("spaceId"), space}, {S("pageId"), page}, {S("kind"), S("paragraph")}, {S("text"), S("An edit of mine.")}, {S("checked"), false}});
    const QJsonObject file = found.value(QLatin1String("file")).toObject();
    QString& contents = filesOf(world.mc, text(file, QLatin1String("projectId")))[text(file, QLatin1String("path"))];
    contents += S("\n\nAn agent's line.");
    takeFile(world.mc, space, page, {{S("conflictAt"), stamp(world.mc)}});
    noteEdits(world.mc, space, kFile);
    world.sync();
  });
  step(S("the page says the file changed under the user's edit and the edit is in its history"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] { return !shownFile(world).value(S("conflictAt")).toString().isEmpty(); }, S("the page to say the file won"));
    world.tap(world.item(S("spacePageFileHistory")));
    expectStep(world, S("history"));
    settleHistory(world);
    expectShown(world, [&] {
      const QList<QVariantMap> versions = viewOf(world)->history()->versions()->rows();
      return versions.size() >= 2 && versions.first().value(S("byFile")).toBool() && !versions.at(1).value(S("byFile")).toBool();
    }, S("the history to hold the file's version over the user's edit"));
  });
  step(S("%1 of %1 was rewritten outside HAL-C2 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    filesOf(world.mc, c[1]).insert(c[0], QString(c[2]).replace(S("\\n"), S("\n")));
  });
  // The worktree's copy is the thread's alone; the MC lists and opens the project folder's files.
  step(S("a thread of %1 works in a worktree where %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).onWorktree = true;
    updateRow(world.mc, haveThread(world, kFilesThread), {{S("worktreePath"), S("/work/%1-worktree").arg(c[0])}});
    if (!fakeFiles(world.mc).files.contains(c[1])) {
      fakeFiles(world.mc).files.insert(c[1], QString(c[2]).replace(S("\\n"), S("\n")));
      fake(world.mc).worktreeOnly.insert(c[1]);
    }
    world.sync();
  });
  step(S("the user picks \"Edit the project's copy as a page\" on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    browseFiles(world);
    holdEntry(world, c[0]);
    QQuickItem* item = world.item(S("fileEntryEditAsPage"));
    expect(item->property("text").toString() == QLatin1String("Edit the project's copy as a page"),
           S("the entry did not say it edits the project's copy: %1").arg(item->property("text").toString()));
    world.tap(item);
  });
  step(S("the page %1 shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Already open where the file opened it, its project's Space rather than the scenario's.
    if (viewOf(world)->page().value(S("title")).toString() != c[0]) lookAtFilePage(world, c[0]);
    expectShown(world, [&] { return blockTexts(world).contains(c[1]); }, S("the page %1 to say %2").arg(c[0], c[1]));
  });
});


// --- The page's prompt: the timeline's Composer, aimed at the page (SpacePageView) ---

// What the scenario chose in a page's prompt, to find in the ask.
struct PromptChoice {
  bool offered = false;
  QString model;
};

// A provider with models that have an effort, and the skill "review".
QJsonObject promptProvider(const QString& id, const QString& name, const QStringList& models) {
  QJsonArray choices;
  for (const char* level : {"low", "medium", "high"}) choices.append(QJsonObject{{S("id"), S(level)}, {S("label"), S(level)}});
  const QJsonObject effort{{S("id"), S("reasoningEffort")}, {S("label"), S("Reasoning")}, {S("type"), S("select")}, {S("options"), choices}, {S("currentValue"), S("medium")}};
  QJsonArray list;
  for (const QString& slug : models) list.append(QJsonObject{{S("slug"), slug}, {S("name"), slug}, {S("capabilities"), QJsonObject{{S("optionDescriptors"), QJsonArray{effort}}}}});
  return {{S("instanceId"), id}, {S("driver"), id}, {S("displayName"), name}, {S("enabled"), true}, {S("installed"), true}, {S("status"), S("ready")}, {S("models"), list},
          {S("skills"), QJsonArray{QJsonObject{{S("name"), S("review")}, {S("description"), S("Review the changes")}, {S("enabled"), true}}}}};
}

QVariantMap prompt(World& world) {
  return world.state(S("composer")).toMap();
}

// The MC's Codex and Claude, and its threads each on a model: Claude's second.
void offerModels(World& world) {
  if (std::exchange(world.mc.part<PromptChoice>().offered, true)) return;
  for (auto it = world.mc.threads.begin(); it != world.mc.threads.end(); ++it) {
    if (it->contains(QLatin1String("modelSelection"))) continue;
    it->insert(S("modelSelection"), QJsonObject{{S("instanceId"), S("claudeAgent")}, {S("model"), S("claude-sonnet")}});
    world.mc.sendRow(it.key(), *it);
  }
  offerProviders(world.mc, {promptProvider(S("codex"), S("Codex"), {S("gpt-5"), S("gpt-5-codex")}),
                            promptProvider(S("claudeAgent"), S("Claude"), {S("claude-opus"), S("claude-sonnet")})});
  world.waitFor([&] { return world.state(S("modelPicker")).toMap().value(S("instances")).toList().size() == 2; }, S("the picker to list Codex and Claude"));
}

QQuickItem* promptEditor(QQuickItem* composer) {
  return composer->property("editor").value<QQuickItem*>();
}

// The page `title` open with its prompt on screen, aimed at it and knowing where an ask runs.
QQuickItem* promptOn(World& world, const QString& title) {
  const QString id = idOfPage(world, title);
  offerModels(world);
  lookAtPage(world, id);
  world.waitFor([&] {
    const QVariantMap state = prompt(world);
    return state.value(S("target")) == S("page#") + id && !state.value(S("project")).isNull() && !state.value(S("selectedModel")).isNull();
  }, [&] { return S("the prompt to be the page's; it is %1").arg(show(prompt(world))); });
  QQuickItem* composer = world.item(S("spaceComposer"));
  QQuickItem* editor = promptEditor(composer);
  world.waitFor([&] { return editor->property("text") == prompt(world).value(S("text")); },
                [&] { return S("the page to show its prompt; the editor reads \"%1\"").arg(editor->property("text").toString()); });
  return composer;
}

// The editor and the shell agree on what the prompt holds.
void settlePrompt(World& world, QQuickItem* composer) {
  QMetaObject::invokeMethod(composer, "flushText");
  world.sync();
  world.waitFor([&] { return promptEditor(composer)->property("text") == prompt(world).value(S("text")); },
                [&] { return S("the editor to read what the shell has: %1").arg(show(prompt(world))); });
}

// The user taps into the prompt of `title` and types `text` at the end of it.
QQuickItem* typeInPrompt(World& world, const QString& title, const QString& text) {
  QQuickItem* composer = promptOn(world, title);
  QQuickItem* editor = promptEditor(composer);
  world.tap(editor);
  expect(editor->hasActiveFocus(), S("the prompt did not take the keyboard"));
  editor->setProperty("cursorPosition", editor->property("text").toString().size());
  world.type(text);
  settlePrompt(world, composer);
  return composer;
}

// The user taps the prompt's send.
void sendPrompt(World& world, QQuickItem* composer) {
  world.tap(S("primaryAction"));
  settlePrompt(world, composer);
  world.sync();
}

// The ask the MC was sent last, once one came.
QJsonObject lastAsk(World& world) {
  world.waitFor([&] { return !fake(world.mc).lastAsk.isEmpty(); }, S("an ask to reach the MC"));
  return fake(world.mc).lastAsk;
}

QStringList attachmentNames(const QVariantMap& state) {
  QStringList names;
  for (const QVariant& attachment : state.value(S("attachments")).toList()) names.append(attachment.toMap().value(S("name")).toString());
  return names;
}

// Attaches `name` to the prompt of `title`: a picture, or a PDF that uploads.
// The system's picker is not this app's; what it answers with goes here.
void attachToPrompt(World& world, const QString& title, const QString& name) {
  promptOn(world, title);
  takeUploads(world);
  const bool image = name.endsWith(QLatin1String(".png"));
  const QByteArray bytes = image ? pngBytes() : QByteArrayLiteral("%PDF-1.4\n");
  world.bridge().dispatch(S("composer.attach"), QVariantMap{{S("files"), QVariantList{QVariantMap{{S("name"), name},
                                                                                                   {S("mimeType"), image ? S("image/png") : S("application/pdf")},
                                                                                                   {S("base64"), QString::fromLatin1(bytes.toBase64())}}}}});
  // A file is the MC's once its upload is done.
  world.waitFor([&] {
    for (const QVariant& attachment : prompt(world).value(S("attachments")).toList()) {
      if (attachment.toMap().value(S("name")) == name) return attachment.toMap().value(S("status")).toString().isEmpty();
    }
    return false;
  }, [&] { return S("the prompt to hold %1; it holds %2").arg(name, show(prompt(world).value(S("attachments")))); });
}

// Types `typed` into the prompt of `title` and picks the suggestion `id` it offers.
void suggestInPrompt(World& world, const QString& title, const QString& typed, const QString& id) {
  typeInPrompt(world, title, typed);
  world.waitFor([&] {
    for (const QVariant& item : prompt(world).value(S("suggestions")).toList()) {
      if (item.toMap().value(S("id")).toString().contains(id)) {
        world.bridge().dispatch(S("composer.suggest.select"), QVariantMap{{S("id"), item.toMap().value(S("id"))}});
        return true;
      }
    }
    return false;
  }, [&] { return S("the prompt to offer %1; it offers %2").arg(id, show(prompt(world).value(S("suggestions")))); });
  world.sync();
}

bool hasEffort(const QJsonObject& selection, const QString& level) {
  const QJsonArray options = selection.value(QLatin1String("options")).toArray();
  return std::any_of(options.begin(), options.end(), [&](const QJsonValue& option) {
    return option.toObject().value(QLatin1String("id")) == QLatin1String("reasoningEffort") && option.toObject().value(QLatin1String("value")) == level;
  });
}

// `key` runs `command`, as the MC pushes the user's keybindings.
void bindKey(World& world, const QString& key, const QString& command) {
  const QJsonArray rules{QJsonObject{{S("key"), key}, {S("command"), command}}};
  for (const int id : world.mc.subscribers(S("config"))) world.mc.send({{S("t"), S("config.keybindings")}, {S("id"), id}, {S("rules"), rules}});
  world.sync();
}

const Steps promptSteps([] {
  const QString q = kQuoted;

  step(S("the page %1 in the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(idOfSpace(world, c[1]) == current(world), S("the scenario's Space is not %1").arg(c[1]));
    givenPage(world, c[0]);
  });
  step(S("the user (?:typed|types) %1 in the prompt of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInPrompt(world, c[1], c[0]);
  });
  step(S("the user sends %1 from the prompt of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    sendPrompt(world, typeInPrompt(world, c[1], c[0]));
  });
  step(S("the user is offered the kinds of block, and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.awaitPopup(S("spaceSlashMenu"));
    QObject* slash = world.popup(S("spaceSlashMenu"));
    QStringList labels;
    world.waitFor([&] {
      labels.clear();
      for (const QVariant& entry : slash->property("shown").toList()) labels.append(entry.toMap().value(S("label")).toString());
      return labels.contains(c[0]) && labels.contains(S("Heading")) && labels.contains(S("Checklist"));
    }, [&] { return S("the slash menu to offer the kinds and %1; it offers %2").arg(c[0], labels.join(u", ")); });
    // The page's own menu, not the thread's slash commands.
    expect(prompt(world).value(S("suggestions")).toList().isEmpty(), S("the prompt also offers %1").arg(show(prompt(world).value(S("suggestions")))));
  });
  // Older than the Background's thread, so an ask still runs in its project by default.
  step(S("the thread %1 of the project %1 runs on another model").arg(q), [](World& world, const Captures& c, const Table&) {
    haveProject(world, c[1]);
    const QString id = S("t-") + c[0].toLower();
    world.mc.threads.insert(id, {{S("id"), id}, {S("title"), c[0]}, {S("projectId"), c[1]},
                                 {S("createdAt"), S("2026-09-22T09:00:00Z")}, {S("updatedAt"), S("2026-09-22T09:00:00Z")},
                                 {S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), S("gpt-5")}}}});
    world.mc.sendRow(id, world.mc.threads.value(id));
    world.sync();
  });
  step(S("the user starts an ask on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* composer = promptOn(world, c[0]);
    world.bridge().dispatch(S("composer.ask"), QVariantMap());
    world.waitFor([&] { return prompt(world).value(S("text")).toString().startsWith(QLatin1String("@agent ")); },
                  [&] { return S("the prompt to start an ask; it reads %1").arg(show(prompt(world).value(S("text")))); });
    settlePrompt(world, composer);
  });
  step(S("the prompt of %1 says the ask runs in the project %1 on the model of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    promptOn(world, c[0]);
    QQuickItem* project = world.item(S("spaceAskProject"));
    world.waitFor([&] { return project->isVisible() && project->property("text") == c[1]; },
                  [&] { return S("the prompt to say the project %1; it says \"%2\"").arg(c[1], project->property("text").toString()); });
    const QJsonObject model = world.mc.threads.value(threadNamed(world, c[2])).value(QLatin1String("modelSelection")).toObject();
    const QVariantMap state = prompt(world);
    expect(state.value(S("selectedModel")) == model.value(QLatin1String("model")).toString() &&
               state.value(S("selectedInstanceId")) == model.value(QLatin1String("instanceId")).toString(),
           S("the prompt is on %1 of %2, %3 on %4").arg(state.value(S("selectedModel")).toString(), state.value(S("selectedInstanceId")).toString(), c[2], show(model)));
  });

  // What an ask chose.
  step(S("the user chooses (another model|high effort|planning|approval for each action|the project %1|the image %1|the file %1|a mention of %1|the skill %1) in the prompt of %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         // Each choice that names something has its own group: one of them matched.
         const QString title = c.last();
         promptOn(world, title);
         const QString what = c[0];
         const QString named = c.mid(1, c.size() - 2).join(QString());
         if (what == QLatin1String("another model")) {
           const QString now = prompt(world).value(S("selectedModel")).toString();
           const QString other = now == QLatin1String("gpt-5-codex") ? S("gpt-5") : S("gpt-5-codex");
           world.mc.part<PromptChoice>().model = other;
           world.bridge().dispatch(S("composer.model.select"), QVariantMap{{S("instanceId"), S("codex")}, {S("model"), other}});
           world.waitFor([&] { return prompt(world).value(S("selectedModel")) == other; }, S("the prompt to be on %1").arg(other));
         } else if (what == QLatin1String("high effort")) {
           world.bridge().dispatch(S("composer.option.set"), QVariantMap{{S("id"), S("reasoningEffort")}, {S("value"), S("high")}});
           world.sync();
         } else if (what == QLatin1String("planning")) {
           auto* settings = world.native().controller<SettingsController>();
           expect(settings->writeDevice(S("planModeEnabled"), true), settings->deviceError());
           world.waitFor([&] { return prompt(world).value(S("showInteractionModeToggle")).toBool(); }, S("the prompt to offer planning"));
           world.bridge().dispatch(S("composer.interactionMode.set"), QVariantMap{{S("mode"), S("plan")}});
           world.waitFor([&] { return prompt(world).value(S("interactionMode")) == QLatin1String("plan"); }, S("the prompt to plan"));
         } else if (what == QLatin1String("approval for each action")) {
           world.bridge().dispatch(S("composer.runtimeMode.set"), QVariantMap{{S("mode"), S("approval-required")}});
           world.waitFor([&] { return prompt(world).value(S("runtimeMode")) == QLatin1String("approval-required"); }, S("the prompt to ask before each action"));
         } else if (what.startsWith(QLatin1String("the project"))) {
           haveProject(world, named);
           // The project button's sheet, as the user picks from it.
           world.tap(S("spaceAskProject"));
           choose(world, named);
           settle(world);
           world.waitFor([&] { return prompt(world).value(S("project")).toMap().value(S("id")) == named; },
                         [&] { return S("the ask to run in %1; it runs in %2").arg(named, show(prompt(world).value(S("project")))); });
         } else if (what.startsWith(QLatin1String("the image")) || what.startsWith(QLatin1String("the file"))) {
           attachToPrompt(world, title, named);
         } else if (what.startsWith(QLatin1String("a mention"))) {
           fakeFiles(world.mc).files.insert(named, S("# shop\n"));
           suggestInPrompt(world, title, S("@") + named.left(4), named);
         } else {
           suggestInPrompt(world, title, S("$") + named.left(3), S(":") + named);
         }
         settlePrompt(world, promptOn(world, title));
       });
  step(S("the agent's thread of %1 has (another model|high effort|planning|approval for each action|the project %1|the image %1|the file %1|a mention of %1|the skill %1)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QJsonObject ask = lastAsk(world);
         const QString what = c[1];
         const QString named = c.mid(2).join(QString());
         const QJsonObject model = ask.value(QLatin1String("modelSelection")).toObject();
         QStringList attached;
         for (const QJsonValue& attachment : ask.value(QLatin1String("attachments")).toArray()) attached.append(attachment.toObject().value(QLatin1String("name")).toString());
         bool has = false;
         if (what == QLatin1String("another model")) has = model.value(QLatin1String("model")) == world.mc.part<PromptChoice>().model;
         else if (what == QLatin1String("high effort")) has = hasEffort(model, S("high"));
         else if (what == QLatin1String("planning")) has = ask.value(QLatin1String("interactionMode")) == QLatin1String("plan");
         else if (what == QLatin1String("approval for each action")) has = ask.value(QLatin1String("runtimeMode")) == QLatin1String("approval-required");
         else if (what.startsWith(QLatin1String("the project"))) has = ask.value(QLatin1String("projectId")) == named;
         else if (what.startsWith(QLatin1String("the image")) || what.startsWith(QLatin1String("the file"))) has = attached.contains(named);
         else if (what.startsWith(QLatin1String("a mention"))) has = text(ask, QLatin1String("request")).contains(named);
         else has = text(ask, QLatin1String("request")).contains(S("$") + named);
         // And it is the ask the user sent, the page's agent working on it.
         expect(has && text(ask, QLatin1String("request")).endsWith(QLatin1String("tidy this")), S("the ask was %1").arg(show(ask)));
         expectAgent(world, c[0], [](const QVariantMap& agent) { return agent.value(S("status")) == QLatin1String("running"); }, S("working"));
       });

  // The ways to an ask.
  step(S("the user asks an agent about %1 from (the page's menu|the command palette|its keybinding)").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* composer = promptOn(world, c[0]);
    if (c[1] == QLatin1String("the page's menu")) {
      // From the list of pages, where the prompt is no longer the page's: the ask has
      // to open the page and aim the prompt at it before it starts.
      const QString target = S("page#") + idOfPage(world, c[0]);
      look(world, current(world));
      world.waitFor([&] { return prompt(world).value(S("target")) != target; },
                    [&] { return S("the prompt to leave the page on the list; it is %1").arg(show(prompt(world))); });
      pageMenu(world, c[0], S("agent"));
      expectStep(world, S("page"));
    } else if (c[1] == QLatin1String("the command palette")) {
      expect(world.native().controller<KeybindingController>()->commands()->run(SpaceController::kAskAgent), S("the palette has no way to ask an agent"));
    } else {
      bindKey(world, S("mod+alt+y"), SpaceController::kAskAgent);
      world.press(S("Ctrl+Alt+Y"));
    }
    world.sync();
    settlePrompt(world, composer);
  });
  step(S("the prompt of %1 is ready to ask an agent").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* editor = promptEditor(promptOn(world, c[0]));
    world.waitFor([&] { return editor->property("text").toString().startsWith(QLatin1String("@agent ")) && editor->hasActiveFocus(); },
                  [&] { return S("the prompt to start an ask with the keyboard in it; it reads \"%1\"").arg(editor->property("text").toString()); });
    expect(world.item(S("spaceAskProject"))->isVisible(), S("the prompt does not say where the ask runs"));
  });
  step(S("the user takes \"@agent\" out of the prompt of %1 and sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* composer = promptOn(world, c[0]);
    QQuickItem* editor = promptEditor(composer);
    world.tap(editor);
    editor->setProperty("cursorPosition", editor->property("text").toString().size());
    while (!editor->property("text").toString().isEmpty()) QTest::keyClick(&world.window(), Qt::Key_Backspace);
    settlePrompt(world, composer);
    sendPrompt(world, typeInPrompt(world, c[0], c[1]));
  });
  step(S("the user stops from the prompt of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    promptOn(world, c[0]);
    QQuickItem* button = world.item(S("primaryAction"));
    world.waitFor([&] { return button->property("stopMode").toBool() && button->isEnabled(); },
                  [&] { return S("the prompt to offer a stop; it is %1").arg(show(prompt(world))); });
    world.tap(button);
    world.sync();
  });

  // Drafts.
  step(S("the user opens %1 and comes back to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    promptOn(world, c[0]);
    promptOn(world, c[1]);
  });
  step(S("the user opens the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.mc.environmentId + QLatin1Char(':') + threadNamed(world, c[0]);
    world.bridge().dispatch(S("thread.open"), QVariantMap{{S("key"), key}});
    world.waitFor([&] { return prompt(world).value(S("target")) == key; }, S("the prompt to be the thread's"));
  });
  step(S("the prompt of %1 (reads|does not read) %1(?: with the image %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    if (findPage(world, c[0]).isEmpty()) {
      // A thread's prompt.
      const QString key = world.mc.environmentId + QLatin1Char(':') + threadNamed(world, c[0]);
      world.sync();
      const QVariantMap state = prompt(world);
      expect(state.value(S("target")) == key && (state.value(S("text")) == c[2]) == (c[1] == QLatin1String("reads")), S("the prompt of %1 is %2").arg(c[0], show(state)));
      return;
    }
    QQuickItem* editor = promptEditor(promptOn(world, c[0]));
    const bool reads = c[1] == QLatin1String("reads");
    world.waitFor([&] {
      const QVariantMap state = prompt(world);
      const bool same = state.value(S("text")) == c[2] && editor->property("text") == c[2] && (c.value(3).isEmpty() || attachmentNames(state) == QStringList{c[3]});
      return same == reads;
    }, [&] { return S("the prompt to %1 \"%2\"; it is %3").arg(c[1], c[2], show(prompt(world))); });
  });
  step(S("the prompt of %1 is empty").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* editor = promptEditor(promptOn(world, c[0]));
    expect(prompt(world).value(S("text")).toString().isEmpty() && editor->property("text").toString().isEmpty() && prompt(world).value(S("attachments")).toList().isEmpty(),
           S("the prompt is %1").arg(show(prompt(world))));
  });
  step(S("the user stashes the prompt of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settlePrompt(world, promptOn(world, c[0]));
    world.bridge().dispatch(S("composer.stash"), QVariantMap());
    world.sync();
    expect(prompt(world).value(S("text")).toString().isEmpty(), S("the prompt kept %1").arg(show(prompt(world))));
  });
  step(S("the user brings %1 back from the stash").arg(q), [](World& world, const Captures& c, const Table&) {
    QString id;
    for (const QVariant& entry : world.state(S("composerStash")).toMap().value(S("entries")).toList()) {
      if (entry.toMap().value(S("snippet")) == c[0]) id = entry.toMap().value(S("id")).toString();
    }
    expect(!id.isEmpty(), S("the stash holds %1").arg(show(world.state(S("composerStash")))));
    world.bridge().dispatch(S("composer.stash.restore"), QVariantMap{{S("id"), id}});
    world.sync();
  });
  step(S("the user turned on (vim keys|rich text)"), [](World& world, const Captures& c, const Table&) {
    const QString key = c[0] == QLatin1String("vim keys") ? S("composerVimKeys") : S("composerRichTextEnabled");
    // What the General page's switch does (SettingsRow), from off.
    world.native().controller<SettingsController>()->set(key, false);
    world.native().controller<SettingsController>()->set(key, true);
  });
  step(S("the prompt of %1 edits with (vim keys|rich text)").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* composer = promptOn(world, c[0]);
    if (c[1] == QLatin1String("vim keys")) {
      QObject* vim = composer->property("vim").value<QObject*>();
      expect(vim && vim->property("vimEnabled").toBool(), S("the page's prompt has Vim keys off"));
      // Escape leaves insert mode, as in a thread's prompt.
      world.tap(promptEditor(composer));
      QTest::keyClick(&world.window(), Qt::Key_Escape);
      world.waitFor([&] { return !vim->property("insertMode").toBool(); }, S("Escape to leave insert mode"));
    } else {
      expect(composer->property("richText").toBool(), S("the page's prompt has rich text off"));
    }
  });
  step(S("the user attached the image %1 in the prompt of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    attachToPrompt(world, c[1], c[0]);
  });
});

}  // namespace

namespace mermaid {

bool onPage(World& world) {
  return !world.mc.part<Diagram>().source.isEmpty();
}

void expectPageSource(World& world) {
  const QString source = world.mc.part<Diagram>().source;
  world.waitFor([&] {
    QQuickItem* editor = world.find(QStringLiteral("spaceBlockEditor:") + source);
    return editor && editor->property("text") == source && asked(world) == 1;
  }, [&] { return QStringLiteral("the diagram's source; %1").arg(describe(world)); });
  expect(drawn(world).isEmpty(), QStringLiteral("a picture is drawn"));
}

}  // namespace mermaid
