#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The usage page, which the shell owns (the route `usage`): token use and
// estimated cost from each environment's session history, and how much of each
// provider's rate limits is left (the web's UsagePage).
//
// Usage: every chosen environment is asked for `server.getUsageSummary` over
// the window, and the answers merge as packages/shared usageMerge.ts merges
// them: the newest read owns a transcript directory several environments share,
// an environment keeps only the providers whose directories it owns, and one on
// an older contract is left out and named. An environment still scanning does
// not hold back the others.
//
// Limits: no call of their own. While limits show, each chosen environment's
// `config` shape brings its providers' `usageLimits`, and `server.refreshProviders`
// asks for them afresh: on showing, at most every five minutes per environment,
// or whenever the user refreshes. Accounts of one driver pool per window.
//
// Publishes `usage`: {open, metric: cost | tokens | limits, windowDays: 1 | 7 |
// 30 | 90, windowLabel, environmentId ("" for all), environments [{id, label,
// status: scanning | ready | failed | outdated | offline}], scanning,
// refreshing, notices [text], message (why there is nothing to show, or ""),
// summary {costUsd, totalTokens, sessions, unpricedShare, cacheSavingsUsd,
// cachedInputTokens, uncachedInputTokens, cacheCreationTokens, outputTokens,
// providers [{id, label, costUsd, totalTokens, sessions}], models [{provider,
// model, costUsd, totalTokens, unpriced}], periods [{key, label, costUsd,
// totalTokens}] newest first} | null, limits {pools [{driver, label, windows
// [{key, label, remainingPercent, resetsAt, accounts [{name, usedPercent,
// resetsAt}]}], credits [{key, name, available, nextExpiresAt, busy,
// status}]}], notices [text]}}.
//
// Actions: `usage.metric {metric}` and `usage.window {days}` (kept on this
// device), `usage.environment {id}`, `usage.refresh`, and `usage.resetCredit
// {key}`, which spends one of the account's banked reset credits.
class UsageController : public QObject, public NativeController {
  Q_OBJECT

public:
  UsageController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

private:
  struct Answer {
    QString status;  // scanning, ready, failed, offline
    QJsonObject summary;
  };
  // Where an account's reset credit is spent: `provider.consumeResetCredit`'s input.
  struct Redeem {
    QString environmentId;
    QJsonObject input;
  };

  void setOpen(bool open);
  void update();
  void read(bool rescan);
  void refreshLimits(bool manual);
  void follow();
  void unfollow();
  QStringList targets() const;
  QString label(const QString& environmentId) const;
  QJsonObject window() const;
  void keep();
  void publish();
  QVariantMap summary(QStringList& notices) const;
  QVariantMap limits();
  void redeem(const QString& key);

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  bool m_open = false;
  QString m_metric = QStringLiteral("limits");
  int m_windowDays = 30;
  QString m_environment;
  QHash<QString, Answer> m_answers;
  // Bumped by every read; an answer lands only if nothing was asked since.
  quint64 m_generation = 0;
  int m_refreshing = 0;
  // Each followed environment's `config` shape, and its providers.
  QHash<QString, int> m_configs;
  QHash<QString, QJsonArray> m_providers;
  // When each environment's limits were last asked for, and those in flight.
  QHash<QString, QDateTime> m_limitsAsked;
  QSet<QString> m_limitsInFlight;
  // Reset credits: each shown account's redemption target, those being
  // spent, and what the last spend said. Bumped on every opening.
  QHash<QString, Redeem> m_redeems;
  QSet<QString> m_redeeming;
  QHash<QString, QString> m_redeemStatus;
  quint64 m_openings = 0;
};
