#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QVariantList>

// An instance's custom models (`config.customModels`: bare slugs or {slug,
// name, capabilities {optionDescriptors}}). The editor edits options as
// [{id, label, type: select | boolean, choices [{id, label, isDefault}]}].
namespace ProviderCustomModels {

// The saved models, first of each slug: [{slug, name ("" when it is the
// slug), options}].
QVariantList read(const QJsonValue& setting);
// Why `slug` cannot be added next to the provider's `models` and the saved
// `setting`, or empty.
QString refusal(const QString& slug, const QJsonArray& models, const QJsonValue& setting);
// The first problem with `options` in reading order ("Option 1 needs an
// id."), or empty.
QString problem(const QVariantList& options);
// The stored setting for a model: its bare slug without a name or options.
QJsonValue setting(const QString& slug, const QString& name, const QVariantList& options);
// The options a driver's adapter reads, with their usual choices.
QVariantList presets(const QString& driver);
// The provider's own models with options, as editor options to copy from:
// [{slug, name, options}]. Claude's context window is left out, and choices
// delivered as prompt text.
QVariantList copyable(const QJsonArray& models, const QString& driver);

}  // namespace ProviderCustomModels
