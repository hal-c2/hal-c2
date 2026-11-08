#pragma once

#include <QHash>
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
// functions, which ComposerController publishes.
namespace composer {

// One provider instance of the config's `providers`, as the picker lists it.
struct Instance {
  QString instanceId;
  QString driver;
  QString displayName;
  QString accentColor;  // "#rrggbb" or empty
  QString iconUrl;  // an ACP registry icon, or empty
  QString status;
  QString message;
  bool enabled = false;
  bool isDefault = false;
  bool available = false;
  bool requiresNewThreadForModelChange = false;
  bool showInteractionModeToggle = true;
  bool canSetUp = false;  // setup.canInstall or setup.canAuthenticate
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
// The slug on this instance that `model` (a slug, name or alias from another
// account of the same driver) names, for falling back to this account: an
// exact slug wins, then an alias or name of a built-in model. A custom model
// is only ever itself, never the built-in it is named like. Empty when none.
QString fallbackModelSlug(const Instance& instance, const QString& model);

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

// `modelPicker.instances`: the rail with each instance's offered models.
// `started` says whether the thread's session started (models it cannot
// switch to say why); `current*` is the thread's own selection.
QVariantList pickerInstances(const QList<Instance>& list, const ModelPrefs& prefs, const QString& selectedInstance,
                             const QString& selectedModel, bool started,
                             const QString& currentInstance, const QString& currentModel);

// Whether `space.image.providers`' answer offers `model` from a ready `instanceId`.
bool offersImageModel(const QVariantMap& offer, const QString& instanceId, const QString& model);
// `modelPicker.instances` for a Space's images: each provider of the answer,
// drawn as the catalogue draws it, with its image models.
QVariantList imagePickerInstances(const QVariantMap& offer, const QList<Instance>& catalogue);

// The selected model's option descriptors with their current values.
QJsonArray descriptors(const QJsonObject& model, const QJsonArray& selections, bool planModeEnabled);
// `composer.options`.
QVariantList shellOptions(const QJsonArray& descriptors);
// The selections to keep after the user sets option `id`; nothing when the
// value does not fit the option.
std::optional<QJsonArray> applyOption(const QJsonArray& descriptors, const QString& id, const QVariant& value);
// The choice one level up (`direction` > 0) or down from select `descriptor`'s
// current value, wrapping; the values the prompt carries (Ultrathink) are
// never stepped to. A value outside the list steps from the default, or
// from the ends when none is marked. Nothing with fewer than two to step through.
std::optional<QString> steppedChoice(const QJsonObject& descriptor, int direction);
// Whether `text` asks for ultrathink in its own words, past the prefix the
// effort control puts there; the effort is then the prompt's (upstream's
// isClaudeUltrathinkPrompt).
bool ultrathinkInWords(const QString& text);

// `composer.runtimeModes`: [{value, label, description}].
QVariantList runtimeModes(const Instance* instance);
// What the composer shows as the permissions: `saved` when this instance
// offers it, else Supervised (or the first mode it offers). The saved value
// itself stays until the user chooses.
QString shownRuntimeMode(const Instance* instance, const QString& saved);
// What stands where the model would be when no provider can run a turn, as
// a key the QML words and translates: "open-provider-settings" when the MC
// says one can be set up, else "no-provider-available". Empty when some
// provider is ready, or none has been reported yet.
QString noProviderStandIn(const QList<Instance>& list);

// `composer.enterIntents`: {singleLine, multiline}, each held-modifier set
// ("ctrl+meta+alt+shift" order, "" for none) to what Enter sends.
QVariantMap enterIntents(const QList<keybindings::Binding>& bindings, bool mac, const QString& sendShortcut, bool draft,
                         bool running);
// One `modelPicker` key: {key, ctrlKey, metaKey, shiftKey, altKey, label}, or
// null when the command has no key.
QVariant pickerKey(const QList<keybindings::Binding>& bindings, bool mac, const QString& command);

// What the text before the caret asks for: "path" (@), "skill" ($),
// "slash-command" (/) or "pull-request" (#). A slash after other text on its
// line is `midLine`: it offers only what its word is the start of a name of.
struct Trigger {
  QString kind;
  QString query;
  int start = 0;
  int end = 0;
  bool midLine = false;
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
// What the @ menu says when its search could not run, which is not "no match".
QString pathSearchUnavailableText();
// What the @ menu says while its search has not answered.
QString pathSearchingText();
// Whether a currency sign followed by `query` is a skill rather than a price:
// a query led by a digit only when one of the instance's skills starts so.
bool opensSkillMenu(const Instance* instance, const QString& query);

// How well a value matches a query: lower is better, nothing is no match.
std::optional<int> scoreQueryMatch(const QString& value, const QString& query, int exactBase, int prefixBase,
                                   std::optional<int> boundaryBase, std::optional<int> includesBase,
                                   std::optional<int> fuzzyBase, const QString& boundaryMarkers = QStringLiteral(" -_/"));

// What waits behind the running turn, from the thread's runs and the messages
// the timeline holds, each in the order it runs: the user's queued follow-ups
// (`runId`, `messageId`, `text`, `attachments`: [{id, name, mimeType, kind
// ("image" | "file")}]), and what the MC queued for the agent itself, a delegated
// task's result or the provider's wake-up (`runId`, `summary`, `outcome`), which
// is not the user's to edit, steer with or remove. A run whose message has not
// arrived yet is in neither: which it is, and what it says, comes with the
// message. `held` is the MC keeping the queue for the user (after a restart or a
// usage limit) until it is resumed, whether or not every run is listed yet.
struct Queued {
  QVariantList queue;
  QVariantList waiting;
  bool held = false;
  // Held with something listed: the card shows and the resume is offered.
  // Held with nothing listed shows no card, so it offers no resume either.
  bool shownHeld() const { return held && (!queue.isEmpty() || !waiting.isEmpty()); }
};
Queued queued(const QList<QJsonObject>& runs, const QHash<QString, QJsonObject>& messages);

// What "/usage-limits" answers with for `instanceId`: every account of its
// driver, from the environment's providers and its hubs (`sources`), the same
// account reported both ways once. Each account has the hub it came through as
// `source` (empty for the environment's own), a `label` ("Codex · Work", or the
// hub's account id; `sensitive` when it holds an email, hidden until asked for),
// a `plan`, and its `windows` ({label, usedPercent, remainingPercent, resetsAt})
// or a `notice` instead. `summary` is the one account, {label: "3 accounts"}, or
// an empty label when there are none; a hub that cannot be read is in `notices`.
QVariantMap usageLimitsReport(const QString& instanceId, const QJsonArray& providers, const QJsonArray& sources);

}  // namespace composer
