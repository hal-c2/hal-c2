#include "UsageController.h"

#include <QLocale>
#include <QTimeZone>

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>

#include "CommandRegistry.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<UsageController> registrar(QStringLiteral("usage"), {QStringLiteral("usage")});

const QString kKey = QStringLiteral("usage");
// Where the metric and window are kept on this device.
const QString kPreferences = QStringLiteral("usage");
const QStringList kMetrics{QStringLiteral("cost"), QStringLiteral("tokens"), QStringLiteral("limits")};
const QList<int> kWindows{1, 7, 30, 90};
// Limits are asked for afresh at most this often, unless the user asks.
constexpr qint64 kLimitsThrottleSecs = 5 * 60;
// The contract versions whose summaries merge (usageMerge.ts).
constexpr int kContractSince = 4;
constexpr int kContract = 5;

// The providers usage reports, in the order the page lists them.
const QList<QPair<QString, QString>> kUsageProviders{
    {QStringLiteral("codex"), QStringLiteral("Codex")},
    {QStringLiteral("claude"), QStringLiteral("Claude Code")},
    {QStringLiteral("grok"), QStringLiteral("Grok Build")},
};
const QHash<QString, QString> kDriverLabels{
    {QStringLiteral("codex"), QStringLiteral("Codex")},       {QStringLiteral("claudeAgent"), QStringLiteral("Claude Code")},
    {QStringLiteral("grok"), QStringLiteral("Grok Build")},   {QStringLiteral("cursor"), QStringLiteral("Cursor")},
    {QStringLiteral("opencode"), QStringLiteral("OpenCode")},
};
const QStringList kWindowKinds{QStringLiteral("session"), QStringLiteral("weekly"), QStringLiteral("monthly")};

QLocale english() {
  return QLocale(QLocale::English, QLocale::UnitedStates);
}

QString text(const QJsonObject& object, const char* field) {
  return object.value(QLatin1String(field)).toString();
}

double number(const QJsonObject& object, const char* field) {
  return object.value(QLatin1String(field)).toDouble();
}

bool compatible(const QJsonObject& summary) {
  const int version = summary.value(QLatin1String("contractVersion")).toInt();
  return version >= kContractSince && version <= kContract;
}

QString fingerprint(const QJsonObject& source) {
  const QJsonObject print = source.value(QLatin1String("fingerprint")).toObject();
  return QStringList{text(print, "hostId"), text(print, "provider"), text(print, "resolvedHomePath"), text(print, "volumeId")}
      .join(QLatin1Char(' '));
}

double tokens(const QJsonObject& totals) {
  // reasoningTokens are a part of outputTokens.
  return number(totals, "uncachedInputTokens") + number(totals, "cachedInputTokens") +
         number(totals, "cacheCreationTokens") + number(totals, "outputTokens");
}

int kindRank(const QString& kind) {
  const int rank = kWindowKinds.indexOf(kind);
  return rank < 0 ? kWindowKinds.size() : rank;
}

}  // namespace

UsageController::UsageController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

void UsageController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  if (auto* settings = shell->controller<SettingsController>()) {
    const QVariantMap kept = settings->deviceValue(kPreferences).toMap();
    if (kMetrics.contains(kept.value(QStringLiteral("metric")).toString())) {
      m_metric = kept.value(QStringLiteral("metric")).toString();
    }
    if (kWindows.contains(kept.value(QStringLiteral("windowDays")).toInt())) {
      m_windowDays = kept.value(QStringLiteral("windowDays")).toInt();
    }
  }
  auto* navigation = shell->controller<NavigationController>();
  if (auto* keys = shell->controller<KeybindingController>()) {
    // usage.open is NavigationController's, with the other pages the palette offers.
    keys->commands()->add(QStringLiteral("usage.refresh"), keybindings::commandLabel(QStringLiteral("usage.refresh")),
                          [this, navigation] {
                            if (navigation->route().kind != QLatin1String("usage")) {
                              navigation->open(NavigationController::Route::of(QStringLiteral("usage")));
                            }
                            handle(QStringLiteral("usage.refresh"), {});
                          });
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation] { setOpen(navigation->route().kind == QLatin1String("usage")); });
  // An environment that comes, goes, or drops changes who is asked.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (m_open) update();
  });
  setOpen(navigation->route().kind == QLatin1String("usage"));
  publish();
}

bool UsageController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("usage.")) || action == QLatin1String("usage.open")) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("usage.metric")) {
    const QString metric = input.value(QStringLiteral("metric")).toString();
    if (!kMetrics.contains(metric) || metric == m_metric) return true;
    const bool fromLimits = m_metric == QLatin1String("limits");
    m_metric = metric;
    keep();
    // Usage is not read while limits show; what was read before may be old.
    if (m_open && fromLimits) read(false);
    if (m_open) update();
    publish();
  } else if (action == QLatin1String("usage.window")) {
    const int days = input.value(QStringLiteral("days")).toInt();
    if (!kWindows.contains(days) || days == m_windowDays) return true;
    m_windowDays = days;
    // The last window's numbers are not this one's.
    m_answers.clear();
    keep();
    if (m_open) update();
    publish();
  } else if (action == QLatin1String("usage.environment")) {
    const QString environmentId = input.value(QStringLiteral("id")).toString();
    if (!environmentId.isEmpty() && !m_store->environments().contains(environmentId)) return true;
    m_environment = environmentId;
    if (m_open) update();
    publish();
  } else if (action == QLatin1String("usage.refresh")) {
    if (!m_open || m_refreshing > 0) return true;
    if (m_metric == QLatin1String("limits")) {
      refreshLimits(true);
    } else {
      read(true);
    }
  } else if (action == QLatin1String("usage.resetCredit")) {
    if (m_open) redeem(input.value(QStringLiteral("key")).toString());
  } else {
    return false;
  }
  return true;
}

void UsageController::keep() {
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kPreferences, QVariantMap{{QStringLiteral("metric"), m_metric},
                                                    {QStringLiteral("windowDays"), m_windowDays}});
  }
}

void UsageController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  if (!open) {
    // Nothing is read or followed for a page nobody sees.
    ++m_generation;
    ++m_openings;
    m_redeemStatus.clear();
    unfollow();
    publish();
    return;
  }
  if (m_metric != QLatin1String("limits")) read(false);
  update();
}

// Asks whoever is not yet asked: limits are followed while they show; usage
// is read again for environments that came, went, or came back.
void UsageController::update() {
  if (!m_open) return;
  if (!m_environment.isEmpty() && !m_store->environments().contains(m_environment)) m_environment.clear();
  if (m_metric == QLatin1String("limits")) {
    follow();
    refreshLimits(false);
  } else {
    unfollow();
    QStringList asked = m_answers.keys();
    QStringList wanted = targets();
    std::sort(asked.begin(), asked.end());
    std::sort(wanted.begin(), wanted.end());
    bool changed = asked != wanted;
    for (const QString& environmentId : wanted) {
      const bool offline = m_answers.value(environmentId).status == QLatin1String("offline");
      if (offline == m_store->environmentOnline(environmentId)) changed = true;
    }
    if (changed) read(false);
  }
  publish();
}

QStringList UsageController::targets() const {
  QStringList environments;
  for (const QString& environmentId : m_store->environments()) {
    if (!m_environment.isEmpty() && environmentId != m_environment) continue;
    if (m_store->reaches(environmentId)) environments.append(environmentId);
  }
  return environments;
}

QString UsageController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  return label.isEmpty() ? environmentId : label;
}

// The window as the web's makeWindow draws it: whole local days ending today,
// or the past 24 hours to the minute, bucketed by hour.
QJsonObject UsageController::window() const {
  const QDateTime now = m_now().toUTC();
  QJsonObject window{{QStringLiteral("timeZone"), QString::fromUtf8(QTimeZone::systemTimeZoneId())}};
  if (m_windowDays == 1) {
    QDateTime until = now;
    until.setTime(QTime(now.time().hour(), now.time().minute()));
    const QDateTime since = until.addSecs(-24 * 60 * 60);
    window.insert(QStringLiteral("resolution"), QStringLiteral("hour"));
    window.insert(QStringLiteral("sinceTime"), since.toString(Qt::ISODateWithMs));
    window.insert(QStringLiteral("untilTime"), until.toString(Qt::ISODateWithMs));
    window.insert(QStringLiteral("sinceDay"), since.toLocalTime().date().toString(Qt::ISODate));
    window.insert(QStringLiteral("untilDay"), until.toLocalTime().date().toString(Qt::ISODate));
    return window;
  }
  const QDate today = now.toLocalTime().date();
  window.insert(QStringLiteral("resolution"), QStringLiteral("day"));
  window.insert(QStringLiteral("sinceDay"), today.addDays(-(m_windowDays - 1)).toString(Qt::ISODate));
  window.insert(QStringLiteral("untilDay"), today.toString(Qt::ISODate));
  return window;
}

// Every chosen environment is asked for its summary; `rescan` fetches prices
// first, as the user's refresh does. The last numbers stay until new ones land.
void UsageController::read(bool rescan) {
  if (!m_open) return;
  const quint64 generation = ++m_generation;
  QHash<QString, Answer> answers;
  for (const QString& environmentId : targets()) {
    Answer answer = m_answers.value(environmentId);
    if (!m_store->environmentOnline(environmentId)) {
      answer = {QStringLiteral("offline"), {}};
    } else {
      answer.status = QStringLiteral("scanning");
    }
    answers.insert(environmentId, answer);
  }
  m_answers = answers;
  const QJsonObject input = window();
  for (const QString& environmentId : answers.keys()) {
    if (answers.value(environmentId).status != QLatin1String("scanning")) continue;
    auto summarize = [this, generation, environmentId, input, rescan] {
      if (generation != m_generation) {
        if (rescan) --m_refreshing;
        publish();
        return;
      }
      m_client->call(this, environmentId, QStringLiteral("server.getUsageSummary"), input,
                     [this, generation, environmentId, rescan](const QJsonValue& result, const std::optional<QString>& error) {
                       if (rescan) --m_refreshing;
                       if (generation != m_generation || !m_answers.contains(environmentId)) {
                         publish();
                         return;
                       }
                       m_answers[environmentId] = error ? Answer{QStringLiteral("failed"), {}}
                                                        : Answer{QStringLiteral("ready"), result.toObject()};
                       publish();
                     });
    };
    if (!rescan) {
      summarize();
      continue;
    }
    ++m_refreshing;
    // New prices or not, the history is read again.
    m_client->call(this, environmentId, QStringLiteral("server.refreshUsageRates"), QJsonObject(),
                   [summarize](const QJsonValue&, const std::optional<QString>&) { summarize(); });
  }
  publish();
}

// Each chosen environment re-reads its providers' limits; the answers come as
// `config.providers`. Unless the user asked, not within five minutes of the last.
void UsageController::refreshLimits(bool manual) {
  const QDateTime now = m_now();
  for (const QString& environmentId : targets()) {
    if (!m_store->environmentOnline(environmentId) || m_limitsInFlight.contains(environmentId)) continue;
    const QDateTime asked = m_limitsAsked.value(environmentId);
    if (!manual && asked.isValid() && asked.secsTo(now) < kLimitsThrottleSecs) continue;
    m_limitsAsked.insert(environmentId, now);
    m_limitsInFlight.insert(environmentId);
    ++m_refreshing;
    m_client->call(this, environmentId, QStringLiteral("server.refreshProviders"), QJsonObject(),
                   [this, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                     m_limitsInFlight.remove(environmentId);
                     --m_refreshing;
                     const QJsonValue providers = result.toObject().value(QLatin1String("providers"));
                     if (!error && providers.isArray() && m_configs.contains(environmentId)) {
                       m_providers.insert(environmentId, providers.toArray());
                     }
                     publish();
                   });
  }
  publish();
}

// While limits show, each chosen environment's config says what its providers have left.
void UsageController::follow() {
  QStringList environments;
  for (const QString& environmentId : targets()) {
    if (m_store->environmentOnline(environmentId)) environments.append(environmentId);
  }
  for (auto it = m_configs.begin(); it != m_configs.end();) {
    if (environments.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    m_providers.remove(it.key());
    m_sources.remove(it.key());
    it = m_configs.erase(it);
  }
  for (const QString& environmentId : environments) {
    if (m_configs.contains(environmentId)) continue;
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("config")}, {QStringLiteral("environment"), environmentId}};
    m_configs.insert(environmentId, m_client->subscribe(this, shape, [this, environmentId](const QJsonObject& frame) {
      const QString type = frame.value(QLatin1String("t")).toString();
      if (type == QLatin1String("config")) {
        m_providers.insert(environmentId, frame.value(QLatin1String("config")).toObject().value(QLatin1String("providers")).toArray());
      } else if (type == QLatin1String("config.providers")) {
        m_providers.insert(environmentId, frame.value(QLatin1String("providers")).toArray());
      } else if (type == QLatin1String("config.usageLimitSources")) {
        m_sources.insert(environmentId, frame.value(QLatin1String("sources")).toArray());
      } else {
        return;
      }
      publish();
    }));
  }
}

void UsageController::unfollow() {
  for (const int id : std::as_const(m_configs)) m_client->unsubscribe(id);
  m_configs.clear();
  m_providers.clear();
  m_sources.clear();
}

// The chosen environments' summaries merged (usageMerge.ts), or an empty map
// while none has answered. What was left out is said in `notices`.
QVariantMap UsageController::summary(QStringList& notices) const {
  struct Contribution {
    QString id;
    QJsonObject summary;
  };
  QList<Contribution> current;
  QStringList ids = m_answers.keys();
  std::sort(ids.begin(), ids.end());
  const bool several = ids.size() > 1;
  for (const QString& environmentId : ids) {
    const Answer& answer = m_answers.value(environmentId);
    if (answer.status == QLatin1String("failed") || answer.status == QLatin1String("offline")) {
      notices.append(several ? QStringLiteral("%1 could not report usage.").arg(label(environmentId))
                             : QStringLiteral("This environment could not report usage."));
      continue;
    }
    if (answer.summary.isEmpty()) continue;
    if (!compatible(answer.summary)) {
      notices.append(QStringLiteral("%1 runs an older server version and is excluded from totals.").arg(label(environmentId)));
      continue;
    }
    current.append({environmentId, answer.summary});
  }
  if (current.isEmpty()) return {};

  // The newest read owns each transcript directory; ties go to the lower id.
  std::sort(current.begin(), current.end(), [](const Contribution& a, const Contribution& b) {
    const QDateTime left = QDateTime::fromString(text(a.summary, "readAt"), Qt::ISODateWithMs);
    const QDateTime right = QDateTime::fromString(text(b.summary, "readAt"), Qt::ISODateWithMs);
    if (left != right) return left > right;
    return a.id < b.id;
  });
  QHash<QString, QString> owners;
  QStringList duplicates;
  for (const Contribution& contribution : current) {
    for (const QJsonValue& value : contribution.summary.value(QLatin1String("sources")).toArray()) {
      const QJsonObject source = value.toObject();
      if (text(source, "status") == QLatin1String("missing")) continue;
      const QString key = fingerprint(source);
      if (owners.contains(key)) {
        duplicates.append(QStringLiteral("%1: %2").arg(
            label(contribution.id),
            text(source.value(QLatin1String("fingerprint")).toObject(), "resolvedHomePath")));
        continue;
      }
      owners.insert(key, contribution.id);
    }
  }
  if (!duplicates.isEmpty()) {
    notices.append(QStringLiteral("Counted once across environments sharing a transcript directory: %1")
                       .arg(duplicates.join(QStringLiteral(", "))));
  }

  struct Sum {
    double cost = 0;
    double tokens = 0;
    double sessions = 0;
    double records = 0;
    double unpriced = 0;
  };
  Sum total;
  double cacheSavings = 0;
  double cached = 0, uncached = 0, creation = 0, output = 0;
  QHash<QString, Sum> providers;
  std::map<QPair<QString, QString>, Sum> models;
  std::map<QString, Sum> periods;
  const bool hourly = m_windowDays == 1;
  for (const Contribution& contribution : current) {
    QSet<QString> owned;
    for (const QJsonValue& value : contribution.summary.value(QLatin1String("sources")).toArray()) {
      const QJsonObject source = value.toObject();
      if (text(source, "status") == QLatin1String("missing") || owners.value(fingerprint(source)) != contribution.id) continue;
      const QString provider = text(source.value(QLatin1String("fingerprint")).toObject(), "provider");
      owned.insert(provider);
      // Distinct within a directory; buckets would count a session once a day.
      const double sessions = number(source, "distinctSessions");
      providers[provider].sessions += sessions;
      total.sessions += sessions;
    }
    for (const QJsonValue& value : contribution.summary.value(QLatin1String("buckets")).toArray()) {
      const QJsonObject bucket = value.toObject();
      const QString provider = text(bucket, "provider");
      if (!owned.contains(provider)) continue;
      const QJsonObject totals = bucket.value(QLatin1String("totals")).toObject();
      const double cost = number(bucket, "costUsd");
      const double used = tokens(totals);
      const double records = number(bucket, "records");
      const double unpriced = number(bucket, "unpricedRecords");
      for (Sum* sum : {&total, &providers[provider], &models[{provider, text(bucket, "model")}],
                       &periods[hourly ? text(bucket, "hourStart") : text(bucket, "day")]}) {
        sum->cost += cost;
        sum->tokens += used;
        sum->records += records;
        sum->unpriced += unpriced;
      }
      cacheSavings += number(bucket, "cacheSavingsUsd");
      cached += number(totals, "cachedInputTokens");
      uncached += number(totals, "uncachedInputTokens");
      creation += number(totals, "cacheCreationTokens");
      output += number(totals, "outputTokens");
    }
  }

  QVariantList providerRows;
  for (const auto& [id, name] : kUsageProviders) {
    const Sum sum = providers.value(id);
    if (sum.tokens <= 0 && sum.cost <= 0) continue;
    providerRows.append(QVariantMap{{QStringLiteral("id"), id},
                                    {QStringLiteral("label"), name},
                                    {QStringLiteral("costUsd"), sum.cost},
                                    {QStringLiteral("totalTokens"), sum.tokens},
                                    {QStringLiteral("sessions"), sum.sessions}});
  }
  QList<QPair<QPair<QString, QString>, Sum>> modelList(models.begin(), models.end());
  const bool byTokens = m_metric == QLatin1String("tokens");
  std::stable_sort(modelList.begin(), modelList.end(), [byTokens](const auto& a, const auto& b) {
    if (byTokens) return a.second.tokens > b.second.tokens;
    if (a.second.cost != b.second.cost) return a.second.cost > b.second.cost;
    return a.second.tokens > b.second.tokens;
  });
  QVariantList modelRows;
  for (const auto& [key, sum] : modelList) {
    modelRows.append(QVariantMap{{QStringLiteral("provider"), key.first},
                                 {QStringLiteral("model"), key.second},
                                 {QStringLiteral("costUsd"), sum.cost},
                                 {QStringLiteral("totalTokens"), sum.tokens},
                                 {QStringLiteral("unpriced"), sum.records > 0 && sum.unpriced >= sum.records}});
  }
  QVariantList periodRows;
  for (auto it = periods.crbegin(); it != periods.crend(); ++it) {
    QString name;
    if (hourly) {
      name = english().toString(QDateTime::fromString(it->first, Qt::ISODateWithMs).toLocalTime().time(), QStringLiteral("h AP"));
    } else {
      name = english().toString(QDate::fromString(it->first, Qt::ISODate), QStringLiteral("MMM d"));
    }
    periodRows.append(QVariantMap{{QStringLiteral("key"), it->first},
                                  {QStringLiteral("label"), name},
                                  {QStringLiteral("costUsd"), it->second.cost},
                                  {QStringLiteral("totalTokens"), it->second.tokens}});
  }
  return {
      {QStringLiteral("costUsd"), total.cost},
      {QStringLiteral("totalTokens"), total.tokens},
      {QStringLiteral("sessions"), total.sessions},
      {QStringLiteral("unpricedShare"), total.records > 0 ? total.unpriced / total.records : 0.0},
      {QStringLiteral("cacheSavingsUsd"), cacheSavings},
      {QStringLiteral("cachedInputTokens"), cached},
      {QStringLiteral("uncachedInputTokens"), uncached},
      {QStringLiteral("cacheCreationTokens"), creation},
      {QStringLiteral("outputTokens"), output},
      {QStringLiteral("providers"), providerRows},
      {QStringLiteral("models"), modelRows},
      {QStringLiteral("periods"), periodRows},
  };
}

// The followed environments' accounts, one per driver and email with the
// freshest read winning, pooled per driver and window (usageLimits.ts).
// Remembers where each account's banked reset credit is redeemed.
QVariantMap UsageController::limits() {
  struct Account {
    QString driver;
    QString name;
    QString checkedAt;
    QJsonArray windows;
    // The freshest read that knew the reset credits, and where to redeem them.
    QString creditsAt;
    QJsonObject credits;
    Redeem redeem;
    // Redeeming through a hub also clears the cooldown it holds for the
    // account, so the freshest hub target wins the redemption outright.
    QString hubAt;
    Redeem hubRedeem;
  };
  QList<QString> order;
  QHash<QString, Account> accounts;
  QStringList notices;
  QStringList ids = m_providers.keys();
  for (const QString& environmentId : m_sources.keys()) {
    if (!ids.contains(environmentId)) ids.append(environmentId);
  }
  std::sort(ids.begin(), ids.end());
  const bool several = m_store->environments().size() > 1;
  auto later = [](const QString& a, const QString& b) {
    return QDateTime::fromString(a, Qt::ISODateWithMs) > QDateTime::fromString(b, Qt::ISODateWithMs);
  };
  auto merge = [&](const QString& key, const Account& next) {
    if (!accounts.contains(key)) {
      order.append(key);
      accounts.insert(key, next);
      return;
    }
    Account& known = accounts[key];
    if (later(next.checkedAt, known.checkedAt)) {
      known.checkedAt = next.checkedAt;
      known.windows = next.windows;
    }
    // Credits and their redemption target travel together.
    if (!next.credits.isEmpty() && (known.credits.isEmpty() || later(next.creditsAt, known.creditsAt))) {
      known.credits = next.credits;
      known.creditsAt = next.creditsAt;
      known.redeem = next.redeem;
    }
    if (!next.hubRedeem.environmentId.isEmpty() && (known.hubAt.isEmpty() || later(next.hubAt, known.hubAt))) {
      known.hubAt = next.hubAt;
      known.hubRedeem = next.hubRedeem;
    }
  };
  for (const QString& environmentId : ids) {
    for (const QJsonValue& value : m_providers.value(environmentId)) {
      const QJsonObject provider = value.toObject();
      if (!provider.value(QLatin1String("enabled")).toBool(true) || !provider.value(QLatin1String("installed")).toBool(true) ||
          text(provider, "availability") == QLatin1String("unavailable") || !provider.contains(QLatin1String("usageLimits"))) {
        continue;
      }
      const QJsonObject limits = provider.value(QLatin1String("usageLimits")).toObject();
      const QString driver = text(provider, "driver");
      QString name = text(provider, "displayName");
      if (name.isEmpty()) name = kDriverLabels.value(driver, text(provider, "instanceId"));
      const QString prefix = several ? label(environmentId) + QStringLiteral(" · ") : QString();
      const QJsonObject unavailable = limits.value(QLatin1String("unavailable")).toObject();
      if (!unavailable.isEmpty()) {
        if (text(unavailable, "reason") == QLatin1String("unsupported")) continue;
        const QString message = text(unavailable, "message");
        notices.append(QStringLiteral("%1%2: %3").arg(prefix, name, message.isEmpty() ? QStringLiteral("Could not read limits.") : message));
        continue;
      }
      const QJsonArray windows = limits.value(QLatin1String("windows")).toArray();
      if (windows.isEmpty()) {
        notices.append(QStringLiteral("%1%2: No limits reported.").arg(prefix, name));
        continue;
      }
      const QString email = text(provider.value(QLatin1String("auth")).toObject(), "email").toLower();
      const QString key = driver + QLatin1Char(':') +
                          (email.isEmpty() ? environmentId + QLatin1Char(':') + text(provider, "instanceId") : email);
      const QString checkedAt = text(limits, "checkedAt");
      merge(key, {driver, name, checkedAt, windows, checkedAt, limits.value(QLatin1String("resetCredits")).toObject(),
                  {environmentId, QJsonObject{{QStringLiteral("instanceId"), text(provider, "instanceId")}}}, {}, {}});
    }
  }
  // Every hub account, those an environment also signs in to included: the
  // hub may hold the fresher read of the same subscription.
  for (const QString& environmentId : ids) {
    const QString prefix = several ? label(environmentId) + QStringLiteral(" · ") : QString();
    for (const QJsonValue& value : m_sources.value(environmentId)) {
      const QJsonObject source = value.toObject();
      const QString sourceLabel = prefix + text(source, "label");
      const QJsonArray sourceAccounts = source.value(QLatin1String("accounts")).toArray();
      if (!text(source, "error").isEmpty()) {
        notices.append(QStringLiteral("%1: %2").arg(sourceLabel, text(source, "error")));
      } else if (sourceAccounts.isEmpty()) {
        notices.append(QStringLiteral("%1: No accounts reported.").arg(sourceLabel));
      }
      for (const QJsonValue& entry : sourceAccounts) {
        const QJsonObject account = entry.toObject();
        const QJsonObject limits = account.value(QLatin1String("usageLimits")).toObject();
        const QJsonArray windows = limits.value(QLatin1String("windows")).toArray();
        if (limits.contains(QLatin1String("unavailable")) || windows.isEmpty()) continue;
        const QString driver = text(account, "driver");
        const QString email = text(account, "email").trimmed().toLower();
        const QString id = text(account, "id");
        const QString key = driver + QLatin1Char(':') + (email.isEmpty() ? text(source, "id") + QLatin1Char(':') + id : email);
        // A hub only names the account by its file when it has no address.
        QString name = id;
        if (name.endsWith(QLatin1String(".json"), Qt::CaseInsensitive)) name.chop(5);
        if (!email.isEmpty()) name = sourceLabel;
        const QString checkedAt = text(limits, "checkedAt");
        const QJsonObject credits = limits.value(QLatin1String("resetCredits")).toObject();
        const QString creditId = text(credits, "nextCreditId");
        const Redeem redeem = creditId.isEmpty() ? Redeem{}
                                                 : Redeem{environmentId, QJsonObject{{QStringLiteral("sourceId"), text(source, "id")},
                                                                                     {QStringLiteral("accountId"), id},
                                                                                     {QStringLiteral("creditId"), creditId}}};
        merge(key, {driver, name, checkedAt, windows, checkedAt, credits, redeem, checkedAt, redeem});
      }
    }
  }

  // Each account's session reset orders it within its pool, soonest first.
  auto sessionReset = [](const Account& account) {
    QDateTime soonest;
    for (const QJsonValue& value : account.windows) {
      const QJsonObject window = value.toObject();
      if (text(window, "kind") != QLatin1String("session")) continue;
      const QDateTime at = QDateTime::fromString(text(window, "resetsAt"), Qt::ISODateWithMs);
      if (at.isValid() && (!soonest.isValid() || at < soonest)) soonest = at;
    }
    return soonest;
  };
  std::stable_sort(order.begin(), order.end(), [&](const QString& a, const QString& b) {
    const QDateTime left = sessionReset(accounts.value(a));
    const QDateTime right = sessionReset(accounts.value(b));
    if (left.isValid() != right.isValid()) return left.isValid();
    return left.isValid() && left < right;
  });

  QStringList drivers;
  for (const QString& key : order) {
    if (!drivers.contains(accounts.value(key).driver)) drivers.append(accounts.value(key).driver);
  }
  // The drivers the page knows come first.
  std::stable_sort(drivers.begin(), drivers.end(), [](const QString& a, const QString& b) {
    return (kDriverLabels.contains(a) ? 0 : 1) < (kDriverLabels.contains(b) ? 0 : 1);
  });
  m_redeems.clear();
  QVariantList pools;
  for (const QString& driver : drivers) {
    QStringList windowKeys;
    QHash<QString, QVariantList> members;
    QHash<QString, QJsonObject> firsts;
    QVariantList credits;
    for (const QString& key : order) {
      const Account& account = accounts[key];
      if (account.driver != driver) continue;
      for (const QJsonValue& value : account.windows) {
        const QJsonObject window = value.toObject();
        const QString windowKey = text(window, "kind") + QLatin1Char(':') + text(window, "id");
        if (!windowKeys.contains(windowKey)) {
          windowKeys.append(windowKey);
          firsts.insert(windowKey, window);
        }
        members[windowKey].append(QVariantMap{{QStringLiteral("name"), account.name},
                                              {QStringLiteral("usedPercent"), number(window, "usedPercent")},
                                              {QStringLiteral("resetsAt"), text(window, "resetsAt")}});
      }
      // Banked reset credits, and what came of the last redemption.
      const int available = account.credits.value(QLatin1String("availableCount")).toInt();
      const QString status = m_redeemStatus.value(key);
      if (available == 0 && status.isEmpty() && !m_redeeming.contains(key)) continue;
      const Redeem& target = account.hubRedeem.environmentId.isEmpty() ? account.redeem : account.hubRedeem;
      if (!target.environmentId.isEmpty()) m_redeems.insert(key, target);
      credits.append(QVariantMap{{QStringLiteral("key"), key},
                                 {QStringLiteral("name"), account.name},
                                 {QStringLiteral("available"), available},
                                 {QStringLiteral("nextExpiresAt"), text(account.credits, "nextExpiresAt")},
                                 {QStringLiteral("busy"), m_redeeming.contains(key)},
                                 {QStringLiteral("status"), status}});
    }
    std::stable_sort(windowKeys.begin(), windowKeys.end(), [&](const QString& a, const QString& b) {
      const int left = kindRank(text(firsts.value(a), "kind"));
      const int right = kindRank(text(firsts.value(b), "kind"));
      if (left != right) return left < right;
      return text(firsts.value(a), "id") < text(firsts.value(b), "id");
    });
    QVariantList windows;
    for (const QString& windowKey : windowKeys) {
      const QVariantList& list = members.value(windowKey);
      double used = 0;
      QString soonest;
      for (const QVariant& member : list) {
        used += member.toMap().value(QStringLiteral("usedPercent")).toDouble();
        const QString at = member.toMap().value(QStringLiteral("resetsAt")).toString();
        if (!at.isEmpty() && (soonest.isEmpty() || QDateTime::fromString(at, Qt::ISODateWithMs) <
                                                       QDateTime::fromString(soonest, Qt::ISODateWithMs))) {
          soonest = at;
        }
      }
      windows.append(QVariantMap{{QStringLiteral("key"), windowKey},
                                 {QStringLiteral("label"), text(firsts.value(windowKey), "label")},
                                 {QStringLiteral("remainingPercent"), static_cast<int>(std::lround(100 - used / list.size()))},
                                 {QStringLiteral("resetsAt"), soonest},
                                 {QStringLiteral("accounts"), list}});
    }
    pools.append(QVariantMap{{QStringLiteral("driver"), driver},
                             {QStringLiteral("label"), kDriverLabels.value(driver, accounts.value(order.first()).name)},
                             {QStringLiteral("windows"), windows},
                             {QStringLiteral("credits"), credits}});
  }
  return {{QStringLiteral("pools"), pools}, {QStringLiteral("notices"), notices}};
}

// Spends one banked reset credit of the account `key`, where its credits were
// read. What came of it stays beside the credits until the page closes.
void UsageController::redeem(const QString& key) {
  if (!m_redeems.contains(key) || m_redeeming.contains(key)) return;
  const Redeem target = m_redeems.value(key);
  m_redeeming.insert(key);
  m_redeemStatus.remove(key);
  const quint64 session = m_openings;
  m_client->call(this, target.environmentId, QStringLiteral("provider.consumeResetCredit"), target.input,
                 [this, key, session](const QJsonValue& result, const std::optional<QString>& error) {
                   m_redeeming.remove(key);
                   if (session != m_openings) return;
                   static const QHash<QString, QString> outcomes{
                       {QStringLiteral("reset"), QStringLiteral("Reset applied. Your windows have cleared.")},
                       {QStringLiteral("nothingToReset"), QStringLiteral("Nothing to reset right now.")},
                       {QStringLiteral("noCredit"), QStringLiteral("No reset credit left.")},
                       {QStringLiteral("alreadyRedeemed"), QStringLiteral("That credit was already redeemed.")},
                   };
                   const QJsonObject answer = result.toObject();
                   QString status = error ? *error : text(answer, "warning");
                   if (!error && status.isEmpty()) status = outcomes.value(text(answer, "outcome"));
                   if (status.isEmpty()) status = QStringLiteral("Could not use the reset credit.");
                   m_redeemStatus.insert(key, status);
                   // The windows and the balance are read again.
                   if (!error) refreshLimits(true);
                   publish();
                 });
  publish();
}

void UsageController::publish() {
  if (!m_active) return;
  const bool limitsShown = m_metric == QLatin1String("limits");
  const QStringList chosen = targets();
  QVariantList environments;
  bool scanning = false;
  for (const QString& environmentId : m_store->environments()) {
    if (!m_store->reaches(environmentId)) continue;
    const Answer answer = m_answers.value(environmentId);
    QString status = m_store->environmentOnline(environmentId) ? answer.status : QStringLiteral("offline");
    if (status.isEmpty()) status = QStringLiteral("scanning");
    if (status == QLatin1String("ready") && !compatible(answer.summary)) status = QStringLiteral("outdated");
    if (chosen.contains(environmentId) && status == QLatin1String("scanning")) scanning = true;
    environments.append(QVariantMap{{QStringLiteral("id"), environmentId},
                                    {QStringLiteral("label"), label(environmentId)},
                                    {QStringLiteral("status"), status}});
  }
  QStringList notices;
  const QVariantMap merged = m_open && !limitsShown ? summary(notices) : QVariantMap();
  const QVariantMap limitsNow = m_open && limitsShown ? limits() : QVariantMap();
  // Why there is nothing to show.
  QString message;
  if (chosen.isEmpty()) {
    message = limitsShown ? QStringLiteral("Connect an environment to see limits.")
                          : QStringLiteral("Connect an environment to see usage.");
  } else if (limitsShown) {
    if (limitsNow.value(QStringLiteral("pools")).toList().isEmpty() && limitsNow.value(QStringLiteral("notices")).toList().isEmpty()) {
      message = QStringLiteral("No provider on the selected environments reports subscription limits.");
    }
  } else if (merged.isEmpty()) {
    if (scanning) message = QStringLiteral("Reading session history…");
  } else if (merged.value(QStringLiteral("periods")).toList().isEmpty()) {
    message = QStringLiteral("No activity in this window.");
  }
  const QDateTime now = m_now().toLocalTime();
  QString windowLabel;
  if (m_windowDays == 1) {
    windowLabel = QStringLiteral("%1 to %2").arg(english().toString(now.addSecs(-24 * 60 * 60), QStringLiteral("MMM d, h AP")),
                                                 english().toString(now, QStringLiteral("MMM d, h AP")));
  } else {
    windowLabel = QStringLiteral("%1 to %2").arg(english().toString(now.date().addDays(-(m_windowDays - 1)), QStringLiteral("MMM d")),
                                                 english().toString(now.date(), QStringLiteral("MMM d")));
  }
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("open"), m_open},
                              {QStringLiteral("metric"), m_metric},
                              {QStringLiteral("windowDays"), m_windowDays},
                              {QStringLiteral("windowLabel"), windowLabel},
                              {QStringLiteral("environmentId"), m_environment},
                              {QStringLiteral("environments"), environments},
                              {QStringLiteral("scanning"), !limitsShown && scanning},
                              {QStringLiteral("refreshing"), m_refreshing > 0},
                              {QStringLiteral("notices"), notices},
                              {QStringLiteral("message"), message},
                              {QStringLiteral("summary"), merged.isEmpty() ? QVariant() : QVariant(merged)},
                              {QStringLiteral("limits"), limitsNow},
                          });
}
