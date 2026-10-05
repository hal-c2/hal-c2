#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <optional>

#include "Keybindings.h"

// What the composer offers, worked out from the MC's own words: the
// provider instances and models of the environment's config (`providers`),
// this device's favourites and model order, the model's options, the
// permission modes, what Enter sends, and the @, $ and / suggestions. Pure
// functions, ported from the web (shellComposerState.ts, providerInstances.ts,
// modelOrdering.ts, packages/shared/src/model.ts, composer-logic.ts,
// composerSlashCommandSearch.ts, providerSkillSearch.ts, searchRanking.ts), so
// ComposerController publishes what the web app does.
namespace composer {

// One provider instance of the config's `providers`, as the picker lists it.
struct Instance {
  QString instanceId;
  QString driver;
  QString displayName;
  QString accentColor;  // "#rrggbb" or empty
  QString iconUrl;  // an ACP registry icon, or empty
  QString groupKey;  // continuation.groupKey
  QString status;
  QString message;
  bool enabled = false;
  bool isDefault = false;
  bool available = false;
  bool requiresNewThreadForModelChange = false;
  bool showInteractionModeToggle = true;
  QStringList runtimeModes;  // supportedRuntimeModes; empty: all
  QJsonArray models;
  QJsonArray slashCommands;
  QJsonObject usageLimits;  // ServerProviderUsageLimits, when the provider reports them
  QJsonArray skills;

  bool ready() const { return enabled && available && status == QLatin1String("ready"); }
};

// The instances, grouped by driver in first-seen order, defaults first.
QList<Instance> instances(const QJsonArray& providers);
const Instance* find(const QList<Instance>& list, const QString& instanceId);
// The instance's model named by slug, name or alias; empty when none.
QJsonObject findModel(const Instance& instance, const QString& model);
// The model a thread starts on with this instance: its default one.
QString defaultModel(const Instance& instance);

// This device's model settings: `favorites` and `providerModelPreferences`.
struct ModelPrefs {
  QSet<QString> favorites;  // instanceId + '\n' + slug
  QJsonObject preferences;  // by instanceId: {hiddenModels, modelOrder}
};
ModelPrefs modelPrefs(const QJsonValue& favorites, const QJsonValue& preferences);
// `favorites` with the model starred or unstarred.
QJsonArray toggleFavorite(const QJsonValue& favorites, const QString& instanceId, const QString& model);

// Why switching a started thread to `next` needs a new thread, or nothing.
struct Block {
  QString title;
  QString description;
};
std::optional<Block> blockReason(const QList<Instance>& list, const QString& currentInstance, const QString& currentModel,
                                 const QString& nextInstance, const QString& nextModel);

// The thread's lock: the driver (and continuation group) a started thread keeps.
struct Lock {
  QString driver;
  QString groupKey;
};

// `modelPicker.instances`: the rail with each instance's offered models.
// `started` says whether the thread's session started (models it cannot
// switch to say why); `current*` is the thread's own selection.
QVariantList pickerInstances(const QList<Instance>& list, const ModelPrefs& prefs, const QString& selectedInstance,
                             const QString& selectedModel, const std::optional<Lock>& lock, bool started,
                             const QString& currentInstance, const QString& currentModel);

// The selected model's option descriptors with their current values.
QJsonArray descriptors(const QJsonObject& model, const QJsonArray& selections, bool planModeEnabled);
// `composer.options`.
QVariantList shellOptions(const QJsonArray& descriptors);
// The selections to keep after the user sets option `id`; nothing when the
// value does not fit the option.
std::optional<QJsonArray> applyOption(const QJsonArray& descriptors, const QString& id, const QVariant& value);

// `composer.runtimeModes`: [{value, label, description}].
QVariantList runtimeModes(const Instance* instance);

// `composer.enterIntents`: {singleLine, multiline}, each held-modifier set
// ("ctrl+meta+alt+shift" order, "" for none) to what Enter sends.
QVariantMap enterIntents(const QList<keybindings::Binding>& bindings, bool mac, const QString& sendShortcut, bool draft,
                         bool running);
// One `modelPicker` key: {key, ctrlKey, metaKey, shiftKey, altKey, label}, or
// null when the command has no key.
QVariant pickerKey(const QList<keybindings::Binding>& bindings, bool mac, const QString& command);

// What the text before the caret asks for: "path" (@), "skill" ($),
// "slash-command" (/ at a line start) or "pull-request" (#).
struct Trigger {
  QString kind;
  QString query;
  int start = 0;
  int end = 0;
};
std::optional<Trigger> trigger(const QString& text, int cursor);

// A suggestion: `composer.suggestions` shows {id, kind, label, description};
// `replacement` is what selecting it puts in the trigger's place.
struct Suggestion {
  QString id;
  QString kind;
  QString label;
  QString description;
  QString replacement;
};
// The / menu for the instance: the composer's own commands, the provider's
// commands and (when shown there) its skills, ranked for the query.
QList<Suggestion> slashItems(const Instance* instance, const Trigger& trigger, bool planModeEnabled, bool showSkills,
                             bool promptEmpty);
// The $ menu: the instance's skills ranked for the query.
QList<Suggestion> skillItems(const Instance* instance, const Trigger& trigger);
// The @ menu: the entries of a workspace search, as file links.
QList<Suggestion> pathItems(const QList<std::pair<QString, bool>>& entries);
// A path as the prompt names it: the @ menu's file link, with its trailing space.
QString pathLink(const QString& path);
// The text the empty menu shows for the trigger.
QString emptyText(const QString& kind);

// searchRanking.ts scoreQueryMatch: lower is better, nothing is no match.
std::optional<int> scoreQueryMatch(const QString& value, const QString& query, int exactBase, int prefixBase,
                                   std::optional<int> boundaryBase, std::optional<int> includesBase,
                                   std::optional<int> fuzzyBase, const QString& boundaryMarkers = QStringLiteral(" -_/"));

}  // namespace composer
