#include "ProviderUpdates.h"

#include <QMap>

#include <algorithm>

namespace providerUpdates {

namespace {

// How long a success shows (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
constexpr int kSuccessMs = 3000;

QString driver(const QJsonObject& provider) { return provider.value(QLatin1String("driver")).toString(); }

bool updatable(const QJsonObject& provider) {
  const QJsonObject advisory = provider.value(QLatin1String("versionAdvisory")).toObject();
  return advisory.value(QLatin1String("canUpdate")).toBool() &&
         !advisory.value(QLatin1String("updateCommand")).toString().isEmpty();
}

QString finishedAt(const QJsonObject& provider) { return field(provider, QStringLiteral("updateState.finishedAt")); }

// "codex:<finishedAt>:<message>" of each, sorted.
QString terminalKey(const QString& prefix, const QList<QJsonObject>& providers) {
  QStringList parts;
  for (const QJsonObject& provider : providers) {
    const QString finished = finishedAt(provider);
    parts.append(driver(provider) + QLatin1Char(':') + (finished.isEmpty() ? QStringLiteral("pending") : finished) +
                 QLatin1Char(':') + field(provider, QStringLiteral("updateState.message")));
  }
  std::sort(parts.begin(), parts.end());
  return prefix + QLatin1Char(':') + parts.join(QLatin1Char('|'));
}

QString latestFinishedAt(const QList<QJsonObject>& providers) {
  QString latest;
  for (const QJsonObject& provider : providers) latest = std::max(latest, finishedAt(provider));
  return latest;
}

QString failedDescription(const QList<QJsonObject>& failed) {
  const QString message = failed.size() == 1 ? field(failed.first(), QStringLiteral("updateState.message")) : QString();
  return !message.isEmpty() ? message
                            : QStringLiteral("%1 failed to update. Check provider settings for details.").arg(list(failed));
}

QString updatedDescription(int count) {
  return count == 1 ? QStringLiteral("New sessions will use the updated provider.")
                    : QStringLiteral("New sessions will use the updated providers.");
}

int severity(const QJsonObject& provider) {
  static const QHash<QString, int> order{{QStringLiteral("succeeded"), 1}, {QStringLiteral("queued"), 2},
                                         {QStringLiteral("running"), 2},   {QStringLiteral("unchanged"), 3},
                                         {QStringLiteral("failed"), 4}};
  return order.value(status(provider), 0);
}

}  // namespace

QString driverName(const QString& driver) {
  static const QHash<QString, QString> names{
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity")},
      {QStringLiteral("codex"), QStringLiteral("Codex")},
      {QStringLiteral("claudeAgent"), QStringLiteral("Claude")},
      {QStringLiteral("cursor"), QStringLiteral("Cursor")},
      {QStringLiteral("grok"), QStringLiteral("Grok")},
      {QStringLiteral("acpRegistry"), QStringLiteral("ACP Registry")},
      {QStringLiteral("pi"), QStringLiteral("Pi")},
      {QStringLiteral("muse"), QStringLiteral("Muse Code")},
      {QStringLiteral("opencode"), QStringLiteral("OpenCode")},
  };
  return names.value(driver, driver);
}

QString version(const QString& value) {
  return value.startsWith(QLatin1Char('v')) ? value : QStringLiteral("v") + value;
}

QString field(const QJsonObject& object, const QString& path) {
  QJsonValue value = object;
  for (const QString& part : path.split(QLatin1Char('.'))) value = value.toObject().value(part);
  return value.toString();
}

QString status(const QJsonObject& provider) { return field(provider, QStringLiteral("updateState.status")); }

bool active(const QJsonObject& provider) {
  const QString state = status(provider);
  return state == QLatin1String("queued") || state == QLatin1String("running");
}

bool candidate(const QJsonObject& provider) {
  const QString compatibility = field(provider, QStringLiteral("compatibilityAdvisory.latestVersionStatus"));
  return provider.value(QLatin1String("enabled")).toBool() && compatibility != QLatin1String("broken") &&
         compatibility != QLatin1String("unsupported") &&
         field(provider, QStringLiteral("versionAdvisory.status")) == QLatin1String("behind_latest") &&
         !field(provider, QStringLiteral("versionAdvisory.latestVersion")).isEmpty();
}

QList<QJsonObject> byDriver(const QList<QJsonObject>& providers) {
  QMap<QString, QJsonObject> chosen;
  QStringList order;
  for (const QJsonObject& provider : providers) {
    const QString name = driver(provider);
    if (!chosen.contains(name)) {
      chosen.insert(name, provider);
      order.append(name);
      continue;
    }
    const QJsonObject current = chosen.value(name);
    if (provider.value(QLatin1String("instanceId")).toString() == name) {
      chosen.insert(name, provider);
    } else if (current.value(QLatin1String("instanceId")).toString() != name &&
               provider.value(QLatin1String("checkedAt")).toString() >= current.value(QLatin1String("checkedAt")).toString()) {
      chosen.insert(name, provider);
    }
  }
  QList<QJsonObject> result;
  for (const QString& name : order) result.append(chosen.value(name));
  return result;
}

QList<QJsonObject> candidates(const QJsonArray& providers) {
  QList<QJsonObject> found;
  for (const QJsonValue& value : providers) {
    if (candidate(value.toObject())) found.append(value.toObject());
  }
  return byDriver(found);
}

bool oneClick(const QJsonObject& provider, const QJsonArray& providers) {
  if (active(provider) || !updatable(provider)) return false;
  QSet<QString> commands;
  for (const QJsonValue& value : providers) {
    const QJsonObject other = value.toObject();
    if (driver(other) != driver(provider) || !candidate(other)) continue;
    if (!updatable(other)) return false;
    commands.insert(field(other, QStringLiteral("versionAdvisory.updateCommand")));
  }
  return commands.size() == 1;
}

QString key(const QList<QJsonObject>& candidates) {
  QStringList parts;
  for (const QJsonObject& provider : byDriver(candidates)) {
    parts.append(driver(provider) + QLatin1Char(':') + field(provider, QStringLiteral("versionAdvisory.latestVersion")));
  }
  std::sort(parts.begin(), parts.end());
  return parts.join(QLatin1Char('|'));
}

QString list(const QList<QJsonObject>& providers) {
  QStringList names;
  for (const QJsonObject& provider : providers) names.append(driverName(driver(provider)));
  if (names.size() <= 2) return names.join(QStringLiteral(" and "));
  return names.mid(0, names.size() - 1).join(QStringLiteral(", ")) + QStringLiteral(", and ") + names.last();
}

QString latestCheckedAt(const QJsonArray& providers) {
  QString latest;
  for (const QJsonValue& value : providers) latest = std::max(latest, value.toObject().value(QLatin1String("checkedAt")).toString());
  return latest;
}

bool View::terminal() const {
  return phase == QLatin1String("succeeded") || phase == QLatin1String("failed") || phase == QLatin1String("unchanged");
}

View offer(const QList<QJsonObject>& candidates, bool oneClick) {
  const QString title =
      candidates.size() == 1
          ? QStringLiteral("Update Available: %1 %2")
                .arg(driverName(driver(candidates.first())),
                     version(field(candidates.first(), QStringLiteral("versionAdvisory.latestVersion"))))
          : QStringLiteral("Updates Available: %1 providers").arg(candidates.size());
  return {QStringLiteral("initial"), QStringLiteral("warning"), title,
          oneClick ? QStringLiteral("Install the update now or review provider settings.")
                   : QStringLiteral("%1 can be updated from provider settings.").arg(list(candidates))};
}

View running(int count) {
  return {QStringLiteral("running"), QStringLiteral("loading"),
          count == 1 ? QStringLiteral("Updating provider") : QStringLiteral("Updating providers"),
          QStringLiteral("Running provider update command.")};
}

View rejected(int count, const QString& message) {
  return {QStringLiteral("failed"), QStringLiteral("error"),
          count == 1 ? QStringLiteral("Provider update failed") : QStringLiteral("Provider updates failed"), message};
}

View progress(const QList<QJsonObject>& snapshots, int count) {
  const QList<QJsonObject> providers = byDriver(snapshots);
  QList<QJsonObject> failed, unchanged;
  for (const QJsonObject& provider : providers) {
    if (status(provider) == QLatin1String("failed")) failed.append(provider);
    if (status(provider) == QLatin1String("unchanged")) unchanged.append(provider);
  }
  if (!failed.isEmpty()) {
    return {QStringLiteral("failed"), QStringLiteral("error"),
            failed.size() == 1 ? QStringLiteral("Provider update failed") : QStringLiteral("Provider updates failed"),
            failedDescription(failed)};
  }
  if (!unchanged.isEmpty()) {
    return {QStringLiteral("unchanged"), QStringLiteral("warning"),
            unchanged.size() == 1 ? QStringLiteral("Provider still needs an update")
                                  : QStringLiteral("Providers still need updates"),
            QStringLiteral("%1 %2 outdated. Check provider settings for details.")
                .arg(list(unchanged), unchanged.size() == 1 ? QStringLiteral("still appears") : QStringLiteral("still appear"))};
  }
  if (std::any_of(providers.cbegin(), providers.cend(), active)) return running(count);
  const bool done = providers.size() >= count && std::all_of(providers.cbegin(), providers.cend(), [](const QJsonObject& provider) {
                      return status(provider) == QLatin1String("succeeded") || !candidate(provider);
                    });
  if (!done) return running(count);
  return {QStringLiteral("succeeded"), QStringLiteral("success"),
          count == 1 ? QStringLiteral("Provider updated") : QStringLiteral("Provider updates finished"),
          updatedDescription(count)};
}

QList<QJsonObject> worstByDriver(const QList<QJsonObject>& snapshots) {
  QMap<QString, QJsonObject> worst;
  QStringList order;
  for (const QJsonObject& snapshot : snapshots) {
    const QString name = driver(snapshot);
    if (!worst.contains(name)) order.append(name);
    if (!worst.contains(name) || severity(snapshot) > severity(worst.value(name))) worst.insert(name, snapshot);
  }
  QList<QJsonObject> result;
  for (const QString& name : order) result.append(worst.value(name));
  return result;
}

std::optional<Notice> notice(const QList<QJsonObject>& all, const QString& visibleAfter, const QSet<QString>& dismissed) {
  const QList<QJsonObject> providers = byDriver(all);
  QList<QJsonObject> running;
  std::copy_if(providers.cbegin(), providers.cend(), std::back_inserter(running), active);
  if (!running.isEmpty()) {
    QStringList parts;
    for (const QJsonObject& provider : running) parts.append(driver(provider) + QLatin1Char(':') + status(provider));
    std::sort(parts.begin(), parts.end());
    return Notice{QStringLiteral("loading:") + parts.join(QLatin1Char('|')), QStringLiteral("loading"),
                  running.size() == 1 ? QStringLiteral("Updating %1").arg(driverName(driver(running.first())))
                                      : QStringLiteral("Updating %1 providers").arg(running.size()),
                  running.size() == 1 ? QStringLiteral("%1 update in progress.").arg(list(running))
                                      : QStringLiteral("%1 updates are in progress.").arg(list(running))};
  }

  QList<QJsonObject> failed, unchanged, succeeded;
  for (const QJsonObject& provider : providers) {
    const QString state = status(provider);
    if (!visibleAfter.isEmpty() && (finishedAt(provider).isEmpty() || finishedAt(provider) < visibleAfter)) continue;
    if (state == QLatin1String("failed")) failed.append(provider);
    if (state == QLatin1String("unchanged")) unchanged.append(provider);
    if (state == QLatin1String("succeeded")) succeeded.append(provider);
  }
  struct Ranked {
    Notice notice;
    QString finished;
  };
  QList<Ranked> ranked;
  if (!failed.isEmpty()) {
    const QString latest = field(failed.first(), QStringLiteral("versionAdvisory.latestVersion"));
    const QString name = driverName(driver(failed.first()));
    ranked.append({{terminalKey(QStringLiteral("failed"), failed), QStringLiteral("error"),
                    failed.size() > 1      ? QStringLiteral("%1 provider updates failed").arg(failed.size())
                    : !latest.isEmpty() ? QStringLiteral("%1 %2 update failed").arg(name, version(latest))
                                        : QStringLiteral("%1 update failed").arg(name),
                    failedDescription(failed), true},
                   latestFinishedAt(failed)});
  }
  if (!unchanged.isEmpty()) {
    ranked.append({{terminalKey(QStringLiteral("unchanged"), unchanged), QStringLiteral("warning"),
                    unchanged.size() == 1
                        ? QStringLiteral("%1 still needs an update").arg(driverName(driver(unchanged.first())))
                        : QStringLiteral("%1 providers still need updates").arg(unchanged.size()),
                    QStringLiteral("%1 %2 outdated. Review provider settings for details.")
                        .arg(list(unchanged),
                             unchanged.size() == 1 ? QStringLiteral("still appears") : QStringLiteral("still appear")),
                    true},
                   latestFinishedAt(unchanged)});
  }
  if (!succeeded.isEmpty()) {
    const QJsonObject& first = succeeded.first();
    const QString name = driverName(driver(first));
    const QString current = first.value(QLatin1String("version")).toString();
    ranked.append({{terminalKey(QStringLiteral("succeeded"), succeeded), QStringLiteral("success"),
                    succeeded.size() > 1   ? QStringLiteral("%1 providers updated").arg(succeeded.size())
                    : !current.isEmpty() ? QStringLiteral("%1 updated: %2").arg(name, version(current))
                                         : QStringLiteral("%1 updated").arg(name),
                    updatedDescription(int(succeeded.size())), false, kSuccessMs},
                   latestFinishedAt(succeeded)});
  }
  std::stable_sort(ranked.begin(), ranked.end(), [](const Ranked& left, const Ranked& right) { return left.finished > right.finished; });
  for (const Ranked& candidate : ranked) {
    if (!dismissed.contains(candidate.notice.key)) return candidate.notice;
  }
  return std::nullopt;
}

std::optional<Notice> notice(const QJsonArray& providers, const QString& visibleAfter, const QSet<QString>& dismissed) {
  QList<QJsonObject> all;
  for (const QJsonValue& value : providers) all.append(value.toObject());
  return notice(all, visibleAfter, dismissed);
}

Group group(const QString& environmentId, const QString& label, const QJsonArray& providers, bool settling) {
  Group result{environmentId, label, settling, {}, providers};
  for (const QJsonObject& provider : candidates(providers)) {
    if (oneClick(provider, providers)) result.candidates.append(provider);
  }
  return result;
}

QString key(const QList<Group>& groups) {
  QStringList parts;
  for (const Group& group : groups) {
    if (group.candidates.isEmpty()) continue;
    QStringList providers;
    for (const QJsonObject& provider : group.candidates) {
      providers.append(driver(provider) + QLatin1Char(':') + field(provider, QStringLiteral("versionAdvisory.latestVersion")));
    }
    std::sort(providers.begin(), providers.end());
    parts.append(group.environmentId + QLatin1Char('=') + providers.join(QLatin1Char(',')));
  }
  std::sort(parts.begin(), parts.end());
  return parts.join(QLatin1Char('|'));
}

std::optional<int> Rows::start(const QString& environmentId, const QDateTime& now) {
  Row& row = m_rows[environmentId];
  if (row.running) return std::nullopt;
  ++row.version;
  row.running = true;
  row.deadline = now.addMSecs(kExpiryMs);
  row.error.clear();
  row.result.reset();
  return row.version;
}

void Rows::settle(const QString& environmentId, int version, const QString& error, const std::optional<View>& result) {
  auto found = m_rows.find(environmentId);
  if (found == m_rows.end() || found->version != version) return;
  found->running = false;
  found->deadline.reset();
  found->error = error;
  found->result.reset();
  if (error.isEmpty() && result && result->terminal()) found->result = result;
}

void Rows::refuse(const QString& environmentId, const QString& error) {
  Row& row = m_rows[environmentId];
  if (row.running) return;
  row.error = error;
  row.result.reset();
}

bool Rows::expire(const QDateTime& now) {
  bool any = false;
  for (Row& row : m_rows) {
    if (!row.deadline || *row.deadline > now) continue;
    row.deadline.reset();
    row.running = false;
    row.error = QStringLiteral("Update timed out — try again.");
    any = true;
  }
  return any;
}

std::optional<QDateTime> Rows::deadline() const {
  std::optional<QDateTime> next;
  for (const Row& row : m_rows) {
    if (row.deadline && (!next || *row.deadline < *next)) next = row.deadline;
  }
  return next;
}

bool Rows::running(const QString& environmentId) const { return m_rows.value(environmentId).running; }

RowStatus Rows::status(const Group& group, const QString& visibleAfter) const {
  const Row row = m_rows.value(group.environmentId);
  if (!row.error.isEmpty()) return {QStringLiteral("failed"), row.error};
  if (row.result) {
    if (row.result->phase == QLatin1String("succeeded")) return {QStringLiteral("success"), QStringLiteral("Updated")};
    return {row.result->phase, row.result->description};
  }
  // The live state of what the row offers, not of every provider there, so
  // another provider's success does not hide this one's Update.
  if (const std::optional<Notice> live = notice(group.candidates, visibleAfter)) {
    if (live->tone == QLatin1String("success")) return {QStringLiteral("success"), QStringLiteral("Updated")};
    if (live->tone == QLatin1String("error")) return {QStringLiteral("failed"), live->description};
    if (live->tone == QLatin1String("warning")) return {QStringLiteral("unchanged"), live->description};
    return {QStringLiteral("loading"), QStringLiteral("Updating…")};
  }
  if (row.running) return {QStringLiteral("loading"), QStringLiteral("Updating…")};
  QStringList names;
  for (const QJsonObject& provider : group.candidates) names.append(driverName(driver(provider)));
  return {QStringLiteral("idle"), names.join(QStringLiteral(", "))};
}

bool Sidebar::setProviders(const QJsonArray& providers, const QDateTime& now) {
  // Updates that finished before the providers were first seen happened
  // before this app was looking; they are not news.
  if (!m_visibleAfter && !providers.isEmpty()) m_visibleAfter = latestCheckedAt(providers);
  m_providers = providers;
  return refresh(now);
}

bool Sidebar::dismiss(const QDateTime& now) {
  if (!m_notice || !m_notice->dismissible) return false;
  m_dismissed.insert(m_notice->key);
  return refresh(now);
}

bool Sidebar::expire(const QDateTime& now) {
  if (!m_deadline || *m_deadline > now || !m_notice) return false;
  m_dismissed.insert(m_notice->key);
  return refresh(now);
}

bool Sidebar::refresh(const QDateTime& now) {
  const std::optional<Notice> next = notice(m_providers, m_visibleAfter.value_or(QString()), m_dismissed);
  const bool same = next.has_value() == m_notice.has_value() && (!next || next->key == m_notice->key);
  if (same) {
    // Same notice, maybe reworded; its timer keeps running.
    const bool reworded = next && (next->title != m_notice->title || next->description != m_notice->description);
    if (next) m_notice = next;
    return reworded;
  }
  m_notice = next;
  m_deadline.reset();
  if (next && next->dismissAfterMs > 0) m_deadline = now.addMSecs(next->dismissAfterMs);
  return true;
}

QString iso(const QDateTime& time) { return time.toUTC().toString(Qt::ISODateWithMs); }

}  // namespace providerUpdates
