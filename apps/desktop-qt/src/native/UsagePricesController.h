#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariantMap>

#include "NativeController.h"

class EnvironmentSettings;
class McClient;
class ShellBridge;
class ShellStore;

// Custom model prices for Usage (the web's UsagePriceOverrides): what a
// million tokens of a model cost, kept by each environment in its settings
// (`usagePriceOverrides`, apps/server-ex HalC2.Usage.Pricing), edited here
// for the environments the usage page has chosen, all at once.
//
// Publishes `usagePrices`:
//   {open, saving, error,
//    targets [{id, label, status: "" | "Saved" | "Not saved", error}],
//    rows [{model, isNew, removed, cells {<field>: {value, placeholder}}}],
//    canRetry}
// A cell's value is what was typed, else the price every chosen environment
// agrees on; where they differ it is empty with the placeholder "Mixed"
// ("Unavailable" while one cannot be read, "Automatic" where none sets one).
// Fields: inputCostPerMillionTokens, outputCostPerMillionTokens,
// cacheReadCostPerMillionTokens, cacheWriteCostPerMillionTokens.
//
// Actions: `usagePrices.open` and `.close`; `.add {model}`; `.edit {model,
// field, value}`; `.remove {model}` marks a price to go back to automatic and
// `.restore {model}` takes that back, both before saving; `.save` writes only
// the edited cells to every chosen environment, each on its own, and `.retry`
// ("Retry failed saves") writes again only where it failed.
class UsagePricesController : public QObject, public NativeController {
  Q_OBJECT

public:
  UsagePricesController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  struct Draft {
    QString model;
    bool isNew = false;
    bool removed = false;
    QHash<QString, QString> values;  // by field, as typed
  };

  void setOpen(bool open);
  void follow();
  // The environments the usage page has chosen: the one it is filtered to, else all.
  QStringList chosen() const;
  Draft& draft(const QString& model);
  QJsonObject prices(const QString& environmentId, bool* known = nullptr) const;
  // The target's `usagePriceOverrides` with the drafts applied; `error` says
  // why a draft cannot be saved there.
  QJsonObject edited(const QJsonObject& current, const QString& label, QString* error) const;
  void save(const QStringList& targets);
  void write(const QString& environmentId, int retries);
  void settled(const QString& environmentId, const QString& error);
  QString label(const QString& environmentId) const;
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  EnvironmentSettings* m_settings;
  bool m_active = false;
  bool m_open = false;
  QStringList m_targets;
  QList<Draft> m_drafts;
  // Each target's last save: empty when saved, else why not.
  QHash<QString, QString> m_results;
  QSet<QString> m_writing;
  QString m_error;
  // Which targets were online when last followed: one that comes back is read again.
  QSet<QString> m_online;
};
