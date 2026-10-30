#include "PushInbox.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QUrl>

#include <algorithm>
#include <atomic>
#include <mutex>

namespace push {

namespace {

constexpr qint64 kMinute = 60 * 1000;
// Older or newer than this against the phone's clock, a message is not news.
constexpr qint64 kFreshness = 10 * kMinute;
// A running card with no word of its end goes after this.
constexpr qint64 kActiveLifetime = 120 * kMinute;
// How long a finished thread stays on the card.
constexpr qint64 kFinishedLifetime = 15 * kMinute;
// The longest a card stays up, whatever it is told.
constexpr qint64 kLongestCard = 24 * 60 * kMinute;
// The alerts shown, by id, so a redelivery shows nothing.
constexpr int kSeen = 64;

std::atomic_bool g_foreground{false};
// The app's thread and Android's receiver read and write the one file.
std::mutex g_lock;

QString text(const QJsonObject& object, const char* key, int limit) {
  QString value = object.value(QLatin1String(key)).toString().simplified();
  if (value.size() > limit) value = value.left(limit - 1) + QChar(0x2026);
  return value;
}

QByteArray fromBase64Url(const QJsonValue& value) {
  return QByteArray::fromBase64(value.toString().toLatin1(), QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
}

QString base64Url(const QByteArray& bytes) {
  return QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

QJsonObject load(const QString& path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {};
  return QJsonDocument::fromJson(file.readAll()).object();
}

void save(const QString& path, const QJsonObject& state) {
  QDir().mkpath(QFileInfo(path).absolutePath());
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
  file.write(QJsonDocument(state).toJson(QJsonDocument::Compact));
  file.commit();
}

Keys keysOf(const QJsonObject& state) {
  const QJsonObject keys = state.value(QLatin1String("keys")).toObject();
  return {fromBase64Url(keys.value(QLatin1String("private"))), fromBase64Url(keys.value(QLatin1String("p256dh"))),
          fromBase64Url(keys.value(QLatin1String("auth")))};
}

// A phase of the contract: a row's status label, the live update's chip and
// the card's action.
struct Phase {
  const char* name;
  const char* status;
  const char* chip;
  const char* action;
};

constexpr Phase kPhases[] = {
    {"starting", "Connecting", "Working", "Open"},
    {"running", "Working", "Working", "Open"},
    {"waiting_for_approval", "Approval", "Approve", "Approve"},
    {"waiting_for_input", "Input", "Answer", "Answer"},
    {"stale", "Waiting", "Waiting", "Open"},
    {"completed", "Done", "Done", "Open"},
    {"failed", "Failed", "Failed", "Open"},
};

const Phase* phaseByName(const QString& name) {
  for (const Phase& phase : kPhases) {
    if (name == QLatin1String(phase.name)) return &phase;
  }
  return nullptr;
}

const Phase* phaseOf(const QJsonObject& activity) { return phaseByName(activity.value(QLatin1String("phase")).toString()); }

struct Row {
  QString status;
  QString title;
  QString project;
};

QList<Row> rowsOf(const QJsonObject& activity) {
  QList<Row> rows;
  for (const QJsonValue& value : activity.value(QLatin1String("rows")).toArray()) {
    const QJsonObject row = value.toObject();
    rows.append({text(row, "status", 40), text(row, "title", 120), text(row, "project", 120)});
  }
  return rows;
}

QString summary(const QJsonObject& activity, const QList<Row>& rows) {
  if (rows.isEmpty()) return QStringLiteral("Agent activity");
  if (rows.size() == 1) return rows.first().title;
  const int attention = activity.value(QLatin1String("attentionCount")).toInt();
  if (attention == 1) return QStringLiteral("1 needs you");
  if (attention > 1) return QStringLiteral("%1 need you").arg(attention);
  const auto failed = std::count_if(rows.begin(), rows.end(), [](const Row& row) { return row.status == QLatin1String("Failed"); });
  if (activity.value(QLatin1String("active")).toBool()) {
    if (failed > 0) return QStringLiteral("%1 failed").arg(failed);
    return QStringLiteral("%1 working").arg(activity.value(QLatin1String("activeCount")).toInt());
  }
  return failed > 0 ? QStringLiteral("Finished, %1 failed").arg(failed) : QStringLiteral("All finished");
}

QJsonValue chip(const QJsonObject& activity, const Phase* phase) {
  if (!activity.value(QLatin1String("active")).toBool()) return QJsonValue::Null;
  if (!phase) return QStringLiteral("Active");
  const int active = activity.value(QLatin1String("activeCount")).toInt();
  if (QLatin1String(phase->name) == QLatin1String("running") && active > 1) {
    return active > 9 ? QStringLiteral("9+ live") : QStringLiteral("%1 live").arg(active);
  }
  return QString::fromLatin1(phase->chip);
}

QJsonObject alertEffect(const QJsonObject& alert) {
  const QString id = alert.value(QLatin1String("id")).toString();
  const QByteArray digest = QCryptographicHash::hash(id.toUtf8(), QCryptographicHash::Sha256);
  const int number = int((quint32(quint8(digest[0])) << 24 | quint32(quint8(digest[1])) << 16 | quint32(quint8(digest[2])) << 8 |
                          quint32(quint8(digest[3]))) &
                         0x7fffffff);
  return {
      {QStringLiteral("tag"), QStringLiteral("hal-c2-agent-alert")},
      {QStringLiteral("id"), number},
      {QStringLiteral("key"), id},
      {QStringLiteral("channel"), QLatin1String(kAlertChannel)},
      {QStringLiteral("title"), text(alert, "title", 120)},
      {QStringLiteral("body"), alert.value(QLatin1String("body")).toString().left(4000)},
      {QStringLiteral("link"), threadLink(alert)},
      {QStringLiteral("visibility"), QStringLiteral("private")},
      {QStringLiteral("publicTitle"), QStringLiteral("HAL-C2")},
      {QStringLiteral("publicText"), QStringLiteral("Agent update")},
  };
}

QJsonObject cancelCard(QJsonObject effects) {
  effects.insert(QStringLiteral("cancelCard"), true);
  return effects;
}

}  // namespace

void setForeground(bool on) { g_foreground = on; }
bool foreground() { return g_foreground; }

Inbox::Inbox(const QString& dataDir) : m_path(QDir(dataDir).filePath(QStringLiteral("push.json"))) {}

Keys Inbox::keys() {
  const std::lock_guard lock(g_lock);
  QJsonObject state = load(m_path);
  Keys keys = keysOf(state);
  if (keys.valid()) return keys;
  keys = generateKeys();
  if (!keys.valid()) return {};
  state.insert(QStringLiteral("keys"), QJsonObject{{QStringLiteral("private"), base64Url(keys.privateKey)},
                                                   {QStringLiteral("p256dh"), base64Url(keys.publicKey)},
                                                   {QStringLiteral("auth"), base64Url(keys.auth)}});
  save(m_path, state);
  return keys;
}

bool Inbox::liveActivity() {
  const std::lock_guard lock(g_lock);
  return load(m_path).value(QLatin1String("liveActivity")).toBool(true);
}

QJsonObject Inbox::setLiveActivity(bool on) {
  const std::lock_guard lock(g_lock);
  QJsonObject state = load(m_path);
  state.insert(QStringLiteral("liveActivity"), on);
  state.insert(QStringLiteral("dismissed"), false);
  save(m_path, state);
  return on ? channels() : cancelCard(channels());
}

QJsonObject Inbox::receive(const QByteArray& body, const Device& device) {
  Keys keys;
  {
    const std::lock_guard lock(g_lock);
    keys = keysOf(load(m_path));
  }
  const std::optional<QByteArray> plain = decrypt(body, keys);
  if (!plain) return channels();
  return deliver(QJsonDocument::fromJson(*plain).object(), device);
}

QJsonObject Inbox::deliver(const QJsonObject& message, const Device& device) {
  QJsonObject effects = channels();
  const qint64 sentAt = qint64(message.value(QLatin1String("sentAt")).toDouble());
  // Nothing is recorded of a message that is not shown for these reasons, so
  // the same one delivered again once they pass is shown then.
  if (sentAt <= 0 || qAbs(device.now - sentAt) > kFreshness || !device.permitted) return effects;

  const std::lock_guard lock(g_lock);
  QJsonObject state = load(m_path);

  const QJsonObject alert = message.value(QLatin1String("alert")).toObject();
  const QString id = alert.value(QLatin1String("id")).toString();
  if (!id.isEmpty()) {
    QJsonArray seen = state.value(QLatin1String("seen")).toArray();
    if (!seen.contains(id)) {
      // An open app shows the thread itself; the alert counts as seen.
      if (!device.foreground) effects.insert(QStringLiteral("alert"), alertEffect(alert));
      seen.append(id);
      while (seen.size() > kSeen) seen.removeFirst();
      state.insert(QStringLiteral("seen"), seen);
    }
  }

  const QJsonValue activityValue = message.value(QLatin1String("activity"));
  if (activityValue.isObject() && sentAt >= qint64(state.value(QLatin1String("lastUpdate")).toDouble())) {
    const QJsonObject activity = activityValue.toObject();
    state.insert(QStringLiteral("lastUpdate"), double(sentAt));
    const bool active = activity.value(QLatin1String("active")).toBool();
    const bool wasActive = state.value(QLatin1String("lastActive")).toBool();
    state.insert(QStringLiteral("lastActive"), active);
    const qint64 expiresAt = activity.contains(QLatin1String("expiresAt")) ? qint64(activity.value(QLatin1String("expiresAt")).toDouble())
                             : active                                      ? sentAt + kActiveLifetime
                                                                           : sentAt;
    const qint64 remaining = qMin(expiresAt - device.now, kLongestCard);
    if (remaining <= 0 || !state.value(QLatin1String("liveActivity")).toBool(true)) {
      effects = cancelCard(effects);
      state.insert(QStringLiteral("dismissed"), false);
    } else {
      // A run that starts again brings back a card the user put away.
      if (active && !wasActive) state.insert(QStringLiteral("dismissed"), false);
      if (!state.value(QLatin1String("dismissed")).toBool()) effects.insert(QStringLiteral("card"), card(activity, remaining, device.sdk));
    }
  }
  save(m_path, state);
  return effects;
}

QJsonObject Inbox::dismiss() {
  const std::lock_guard lock(g_lock);
  QJsonObject state = load(m_path);
  state.insert(QStringLiteral("dismissed"), true);
  save(m_path, state);
  return cancelCard(channels());
}

bool Inbox::dismissed() {
  const std::lock_guard lock(g_lock);
  return load(m_path).value(QLatin1String("dismissed")).toBool();
}

QJsonValue Inbox::value(const QString& key) {
  const std::lock_guard lock(g_lock);
  return load(m_path).value(key);
}

void Inbox::setValue(const QString& key, const QJsonValue& value) {
  const std::lock_guard lock(g_lock);
  QJsonObject state = load(m_path);
  if (state.value(key) == value) return;
  state.insert(key, value);
  save(m_path, state);
}

QJsonObject activity(QList<ActivityRow> rows, qint64 now) {
  const auto group = [](const QString& phase) {
    if (phase == QLatin1String("waiting_for_approval") || phase == QLatin1String("waiting_for_input")) return 0;
    if (phase == QLatin1String("failed")) return 1;
    if (phase == QLatin1String("completed")) return 3;
    return 2;
  };
  const auto finished = [&](const ActivityRow& row) { return group(row.phase) == 3 || row.phase == QLatin1String("failed"); };
  rows.removeIf([&](const ActivityRow& row) { return !phaseByName(row.phase) || (finished(row) && row.at < now - kFinishedLifetime); });
  std::stable_sort(rows.begin(), rows.end(), [&](const ActivityRow& a, const ActivityRow& b) {
    return group(a.phase) != group(b.phase) ? group(a.phase) < group(b.phase) : a.at > b.at;
  });
  int active = 0;
  int attention = 0;
  qint64 lastFinish = 0;
  QJsonArray listed;
  for (const ActivityRow& row : rows) {
    if (finished(row)) {
      lastFinish = qMax(lastFinish, row.at);
    } else {
      ++active;
    }
    if (group(row.phase) == 0) ++attention;
    if (listed.size() < 5) {
      listed.append(QJsonObject{{QStringLiteral("status"), QString::fromLatin1(phaseByName(row.phase)->status)},
                                {QStringLiteral("title"), row.title},
                                {QStringLiteral("project"), row.project},
                                {QStringLiteral("environmentId"), row.environmentId},
                                {QStringLiteral("threadId"), row.threadId}});
    }
  }
  QJsonObject result{
      {QStringLiteral("active"), active > 0},
      {QStringLiteral("activeCount"), active},
      {QStringLiteral("attentionCount"), attention},
      {QStringLiteral("rows"), listed},
      {QStringLiteral("expiresAt"), double(active > 0 ? now + kActiveLifetime : rows.isEmpty() ? now : lastFinish + kFinishedLifetime)},
  };
  if (!rows.isEmpty()) {
    const ActivityRow& first = rows.first();
    result.insert(QStringLiteral("phase"), first.phase);
    result.insert(QStringLiteral("environmentId"), first.environmentId);
    result.insert(QStringLiteral("threadId"), first.threadId);
    result.insert(QStringLiteral("link"), threadLink(result));
  }
  return result;
}

QJsonObject channels() {
  return {{QStringLiteral("channels"),
           QJsonArray{
               QJsonObject{{QStringLiteral("id"), QLatin1String(kAlertChannel)},
                           {QStringLiteral("name"), QStringLiteral("Agent alerts")},
                           {QStringLiteral("importance"), QStringLiteral("high")}},
               QJsonObject{{QStringLiteral("id"), QLatin1String(kActivityChannel)},
                           {QStringLiteral("name"), QStringLiteral("Ongoing agent activity")},
                           {QStringLiteral("importance"), QStringLiteral("low")}},
           }}};
}

QJsonObject card(const QJsonObject& activity, qint64 remainingMs, int sdk) {
  const bool active = activity.value(QLatin1String("active")).toBool();
  const Phase* phase = phaseOf(activity);
  const QList<Row> rows = rowsOf(activity);
  QStringList lines;
  QString subtext;
  if (rows.size() == 1) {
    const Row& row = rows.first();
    lines.append(row.project.isEmpty() ? row.status : row.status + QStringLiteral(" · ") + row.project);
  } else if (!rows.isEmpty()) {
    const bool oneProject = std::all_of(rows.begin(), rows.end(), [&](const Row& row) { return row.project == rows.first().project; });
    for (const Row& row : rows) {
      lines.append(row.status + QLatin1Char(' ') + row.title + (oneProject || row.project.isEmpty() ? QString() : QStringLiteral(" · ") + row.project));
    }
    QStringList parts;
    if (oneProject && !rows.first().project.isEmpty()) parts.append(rows.first().project);
    parts.append(active ? QStringLiteral("%1 active").arg(activity.value(QLatin1String("activeCount")).toInt())
                        : QStringLiteral("%1 threads").arg(rows.size()));
    subtext = parts.join(QStringLiteral(" · "));
  }
  QJsonObject card{
      {QStringLiteral("id"), kCardId},
      {QStringLiteral("channel"), QLatin1String(kActivityChannel)},
      {QStringLiteral("title"), summary(activity, rows)},
      {QStringLiteral("text"), lines.value(0)},
      {QStringLiteral("lines"), QJsonArray::fromStringList(lines)},
      {QStringLiteral("subtext"), subtext},
      {QStringLiteral("chip"), chip(activity, phase)},
      {QStringLiteral("action"), active ? QJsonValue(QString::fromLatin1(phase ? phase->action : "Open")) : QJsonValue::Null},
      {QStringLiteral("dismissAction"), active ? QJsonValue(QStringLiteral("Dismiss")) : QJsonValue::Null},
      {QStringLiteral("ongoing"), active},
      // Android 16 lifts an ongoing card to a live update in the status bar.
      {QStringLiteral("promoted"), active && sdk >= 36},
      {QStringLiteral("link"), threadLink(activity)},
      {QStringLiteral("timeoutMs"), double(remainingMs)},
      {QStringLiteral("silent"), true},
      {QStringLiteral("showWhen"), false},
      {QStringLiteral("visibility"), QStringLiteral("private")},
      {QStringLiteral("publicTitle"), QStringLiteral("HAL-C2")},
      {QStringLiteral("publicText"), QStringLiteral("Agent activity")},
  };
  return card;
}

std::pair<QString, QString> parseThreadLink(const QString& link) {
  const QUrl url(link, QUrl::StrictMode);
  if (!url.isValid() || url.scheme() != QLatin1String("hal-c2") || url.host() != QLatin1String("threads") || url.hasQuery() ||
      url.hasFragment()) {
    return {};
  }
  const QStringList parts = url.path(QUrl::FullyDecoded).split(QLatin1Char('/'), Qt::SkipEmptyParts);
  if (parts.size() != 2) return {};
  return {parts.at(0), parts.at(1)};
}

QString threadLink(const QJsonObject& item) {
  const QString link = item.value(QLatin1String("link")).toString();
  if (!parseThreadLink(link).first.isEmpty()) return link;
  const QString environment = item.value(QLatin1String("environmentId")).toString();
  const QString thread = item.value(QLatin1String("threadId")).toString();
  if (environment.isEmpty() || thread.isEmpty()) return {};
  return QStringLiteral("hal-c2://threads/%1/%2")
      .arg(QString::fromLatin1(QUrl::toPercentEncoding(environment)), QString::fromLatin1(QUrl::toPercentEncoding(thread)));
}

}  // namespace push
