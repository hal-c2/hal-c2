#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QString>

// Provider instances in an environment's settings document, as the MC reads
// them (HalC2.Acp instance/setting, HalC2.ProviderSecrets): each instance's
// `providerInstances.<id>` entry {driver, enabled, displayName, accentColor,
// config, environment [{name, value, sensitive, valueRedacted}]}, and for a
// built-in's own slot (the id is the driver) the `providers.<driver>` entry it
// falls back to.
namespace ProviderInstances {

// The instance as the MC reads it: its own entry, or for a built-in's own
// slot one made from `providers.<driver>`.
QJsonObject of(const QJsonObject& settings, const QString& id, const QString& driver);
// `settings` with the instance's entry replaced; an empty one removes it.
QJsonObject with(QJsonObject settings, const QString& id, const QJsonObject& instance);
// `instance` with `config.<key>` set; an empty string or null removes it.
QJsonObject withConfig(QJsonObject instance, const QString& key, const QJsonValue& value);
// Ids a new instance may not take (existing ids): Codex's and
// Claude's own slots, configured instances and providers, and the instances
// the environment lists.
QSet<QString> taken(const QJsonObject& settings, const QJsonArray& providers);
// `#rrggbb` in lower case, or empty for anything else.
QString accent(const QString& color);
// An environment variable name (ENVIRONMENT_VARIABLE_NAME_PATTERN).
bool validVariableName(const QString& name);

}  // namespace ProviderInstances
