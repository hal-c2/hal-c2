#include "ComposerModel.h"

#include <QHash>
#include <QRegularExpression>
#include <QUrl>

#include <algorithm>
#include <limits>

#include "TimelineSummary.h"

namespace composer {

namespace {

QString str(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// providerInstances.ts brand labels.
QString brandLabel(const QString& driver) {
  static const QHash<QString, QString> labels{
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity")},
      {QStringLiteral("codex"), QStringLiteral("Codex")},
      {QStringLiteral("claudeAgent"), QStringLiteral("Claude")},
      {QStringLiteral("claude"), QStringLiteral("Claude")},
      {QStringLiteral("cursor"), QStringLiteral("Cursor")},
      {QStringLiteral("grok"), QStringLiteral("Grok")},
      {QStringLiteral("acpRegistry"), QStringLiteral("ACP Registry")},
      {QStringLiteral("pi"), QStringLiteral("Pi")},
      {QStringLiteral("opencode"), QStringLiteral("OpenCode")},
  };
  return labels.value(driver);
}

// "codexWork" and "codex_work" are "Codex Work".
QString humanizeSlug(const QString& slug) {
  QString spaced;
  for (qsizetype i = 0; i < slug.size(); ++i) {
    const QChar c = slug.at(i);
    if (c == u'_' || c == u'-') {
      spaced.append(u' ');
      continue;
    }
    if (c.isUpper() && i > 0 && slug.at(i - 1).isLower()) spaced.append(u' ');
    spaced.append(c);
  }
  QStringList words = spaced.simplified().split(u' ', Qt::SkipEmptyParts);
  for (QString& word : words) word[0] = word.at(0).toUpper();
  return words.join(u' ');
}

QString displayNameOf(const QJsonObject& provider, const QString& instanceId, const QString& driver) {
  const QString brand = brandLabel(driver).isEmpty() ? humanizeSlug(driver) : brandLabel(driver);
  const QString named = str(provider, QLatin1String("displayName")).trimmed();
  if (!named.isEmpty() && named != brand) return named;
  if (instanceId != driver) return humanizeSlug(instanceId);
  return named.isEmpty() ? brand : named;
}

QString initialsOf(const QString& name) {
  const QStringList words = name.split(QRegularExpression(QStringLiteral("[\\s_-]+")), Qt::SkipEmptyParts);
  if (words.isEmpty()) return {};
  if (words.size() == 1) return words.first().left(2).toUpper();
  return (words.at(0).left(1) + words.at(1).left(1)).toUpper();
}

QString registryIcon(const QString& driver, const QString& url) {
  if (driver != QLatin1String("acpRegistry") || url.isEmpty()) return {};
  const QUrl parsed(url);
  if (parsed.scheme() != QLatin1String("https") || parsed.host() != QLatin1String("cdn.agentclientprotocol.com") ||
      parsed.port() != -1 || !parsed.userInfo().isEmpty()) {
    return {};
  }
  return url;
}

bool modelMatches(const QJsonObject& model, const QString& value) {
  if (str(model, QLatin1String("slug")) == value) return true;
  if (str(model, QLatin1String("name")).compare(value, Qt::CaseInsensitive) == 0) return true;
  for (const QJsonValue& alias : model.value(QLatin1String("aliases")).toArray()) {
    if (alias.toString() == value) return true;
  }
  return false;
}

const QString kAntigravityDefault = QStringLiteral("antigravity-default");

bool keepsUnlistedModel(const QString& driver) {
  return driver == QLatin1String("opencode") || driver == QLatin1String("antigravity");
}

// The instance's models as the picker offers them (modelOptionsByInstance):
// hidden ones out, the user's order, and the thread's model kept when the
// provider no longer lists it.
QList<QJsonObject> modelOptions(const Instance& instance, const ModelPrefs& prefs, const QString& selectedInstance,
                                const QString& selectedModel) {
  const QJsonObject preference = prefs.preferences.value(instance.instanceId).toObject();
  QSet<QString> hidden;
  for (const QJsonValue& slug : preference.value(QLatin1String("hiddenModels")).toArray()) hidden.insert(slug.toString());
  QHash<QString, int> order;
  const QJsonArray modelOrder = preference.value(QLatin1String("modelOrder")).toArray();
  for (qsizetype i = 0; i < modelOrder.size(); ++i) order.insert(modelOrder.at(i).toString(), int(i));

  QList<QJsonObject> models;
  for (const QJsonValue& value : instance.models) {
    const QJsonObject model = value.toObject();
    if (!model.value(QLatin1String("isCustom")).toBool() && hidden.contains(str(model, QLatin1String("slug")))) continue;
    models.append(model);
  }
  const auto rank = [&order](const QJsonObject& model) {
    return order.value(str(model, QLatin1String("slug")), std::numeric_limits<int>::max());
  };
  std::stable_sort(models.begin(), models.end(), [&](const QJsonObject& a, const QJsonObject& b) { return rank(a) < rank(b); });

  if (keepsUnlistedModel(instance.driver) && instance.instanceId == selectedInstance && !selectedModel.isEmpty() &&
      selectedModel != kAntigravityDefault && !hidden.contains(selectedModel)) {
    const bool listed = std::any_of(instance.models.begin(), instance.models.end(),
                                    [&](const QJsonValue& model) { return modelMatches(model.toObject(), selectedModel); });
    if (!listed) {
      models.append({{QStringLiteral("slug"), selectedModel},
                     {QStringLiteral("name"), selectedModel},
                     {QStringLiteral("isUnavailable"), true}});
    }
  }
  return models;
}

// ModelPickerContent.tsx shouldIncludeModelPickerOption.
bool offered(const Instance& instance, const QJsonObject& model, const QString& activeInstance, const QString& activeModel) {
  const QString slug = str(model, QLatin1String("slug"));
  if (instance.driver == QLatin1String("antigravity") && slug == kAntigravityDefault) return false;
  if (instance.ready()) return true;
  return instance.enabled && keepsUnlistedModel(instance.driver) && instance.instanceId == activeInstance &&
         slug == activeModel && model.value(QLatin1String("isUnavailable")).toBool();
}

// providerInstances.ts describeUnavailableInstance.
QString unavailableReason(const Instance& instance) {
  if (!instance.enabled || instance.status == QLatin1String("disabled")) {
    return instance.displayName + QStringLiteral(" — Disabled in settings.");
  }
  const QString kind = instance.status == QLatin1String("error")     ? QStringLiteral("Unavailable")
                       : instance.status == QLatin1String("warning") ? QStringLiteral("Limited")
                                                                     : QStringLiteral("Not ready");
  const QString message = instance.message.trimmed();
  return message.isEmpty() ? QStringLiteral("%1 — %2.").arg(instance.displayName, kind)
                           : QStringLiteral("%1 — %2. %3").arg(instance.displayName, kind, message);
}

bool showBadge(const Instance& instance, const QList<Instance>& visible) {
  if (!instance.accentColor.isEmpty()) return true;
  return std::count_if(visible.begin(), visible.end(), [&](const Instance& other) { return other.driver == instance.driver; }) > 1;
}

// packages/shared/src/model.ts resolveDescriptorChoiceValue.
QJsonValue choiceValue(const QJsonObject& descriptor, const QString& raw) {
  const QJsonArray choices = descriptor.value(QLatin1String("options")).toArray();
  const auto fallback = [&]() -> QJsonValue {
    if (descriptor.contains(QLatin1String("currentValue"))) return descriptor.value(QLatin1String("currentValue"));
    for (const QJsonValue& choice : choices) {
      if (choice.toObject().value(QLatin1String("isDefault")).toBool()) return choice.toObject().value(QLatin1String("id"));
    }
    return QJsonValue::Undefined;
  };
  const QString trimmed = raw.trimmed();
  if (trimmed.isEmpty()) return fallback();
  if (choices.isEmpty()) return trimmed;
  const bool known = std::any_of(choices.begin(), choices.end(),
                                 [&](const QJsonValue& choice) { return str(choice.toObject(), QLatin1String("id")) == trimmed; });
  if (known && descriptor.value(QLatin1String("promptInjectedValues")).toArray().contains(trimmed)) {
    for (const QJsonValue& choice : choices) {
      if (choice.toObject().value(QLatin1String("isDefault")).toBool()) return choice.toObject().value(QLatin1String("id"));
    }
    return QJsonValue::Undefined;
  }
  return known ? QJsonValue(trimmed) : fallback();
}

// getProviderOptionCurrentValue.
QJsonValue currentValue(const QJsonObject& descriptor) {
  if (str(descriptor, QLatin1String("type")) == QLatin1String("boolean")) return descriptor.value(QLatin1String("currentValue"));
  if (!str(descriptor, QLatin1String("currentValue")).isEmpty()) return descriptor.value(QLatin1String("currentValue"));
  for (const QJsonValue& choice : descriptor.value(QLatin1String("options")).toArray()) {
    if (choice.toObject().value(QLatin1String("isDefault")).toBool()) return choice.toObject().value(QLatin1String("id"));
  }
  return QJsonValue::Undefined;
}

QJsonArray selectionsOf(const QJsonArray& descriptors) {
  QJsonArray selections;
  for (const QJsonValue& value : descriptors) {
    const QJsonValue current = currentValue(value.toObject());
    if (current.isString() || current.isBool()) {
      selections.append(QJsonObject{{QStringLiteral("id"), value.toObject().value(QLatin1String("id"))}, {QStringLiteral("value"), current}});
    }
  }
  return selections;
}

// The last binding whose condition holds and whose shortcut matches wins
// (resolveShortcutCommand).
QString commandFor(const QList<keybindings::Binding>& bindings, bool mac, const keybindings::Context& context,
                   const QString& key, bool ctrl, bool meta, bool alt, bool shift) {
  for (auto it = bindings.crbegin(); it != bindings.crend(); ++it) {
    if (!keybindings::evaluate(it->when, context)) continue;
    const keybindings::Shortcut& s = it->shortcut;
    if (s.key != key) continue;
    const bool wantMeta = s.meta || (s.mod && mac);
    const bool wantCtrl = s.ctrl || (s.mod && !mac);
    if (meta == wantMeta && ctrl == wantCtrl && shift == s.shift && alt == s.alt) return it->command;
  }
  return {};
}

bool isSpace(QChar c) {
  return c == u' ' || c == u'\n' || c == u'\t' || c == u'\r';
}

struct Ranked {
  Suggestion item;
  int score;
  QString tieBreaker;
};

// insertRankedSearchResult with no limit: by score, then tie-breaker, stable.
QList<Suggestion> ranked(QList<Ranked> entries) {
  std::stable_sort(entries.begin(), entries.end(), [](const Ranked& a, const Ranked& b) {
    if (a.score != b.score) return a.score < b.score;
    return QString::localeAwareCompare(a.tieBreaker, b.tieBreaker) < 0;
  });
  QList<Suggestion> items;
  for (const Ranked& entry : entries) items.append(entry.item);
  return items;
}

std::optional<int> best(std::initializer_list<std::optional<int>> scores) {
  std::optional<int> result;
  for (const auto& score : scores) {
    if (score && (!result || *score < *result)) result = score;
  }
  return result;
}

QString skillLabel(const QJsonObject& skill) {
  const QString named = str(skill, QLatin1String("displayName")).trimmed();
  if (!named.isEmpty()) return named;
  QStringList words;
  for (const QString& word : str(skill, QLatin1String("name")).split(QRegularExpression(QStringLiteral("[\\s:_-]+")), Qt::SkipEmptyParts)) {
    words.append(word.left(1).toUpper() + word.mid(1));
  }
  return words.join(u' ');
}

// providerSkillSearch.ts scoreProviderSkill; `query` is already normalised.
std::optional<int> scoreSkill(const QJsonObject& skill, const QString& query) {
  return best({
      scoreQueryMatch(str(skill, QLatin1String("name")).toLower(), query, 0, 2, 4, 6, 100, QStringLiteral("-_/")),
      scoreQueryMatch(skillLabel(skill).toLower(), query, 1, 3, 5, 7, 110),
      scoreQueryMatch(str(skill, QLatin1String("shortDescription")).toLower(), query, 20, 22, 24, 26, std::nullopt),
      scoreQueryMatch(str(skill, QLatin1String("description")).toLower(), query, 30, 32, 34, 36, std::nullopt),
      scoreQueryMatch(str(skill, QLatin1String("scope")).toLower(), query, 40, 42, std::nullopt, 44, std::nullopt),
  });
}

// Enabled skills a user may start, one per name.
QList<QJsonObject> invocableSkills(const QJsonArray& skills) {
  QList<QJsonObject> result;
  QSet<QString> seen;
  for (const QJsonValue& value : skills) {
    const QJsonObject skill = value.toObject();
    if (!skill.value(QLatin1String("enabled")).toBool() || skill.value(QLatin1String("userInvocable")) == QJsonValue(false)) continue;
    const QString name = str(skill, QLatin1String("name")).trimmed().toLower();
    if (seen.contains(name)) continue;
    seen.insert(name);
    result.append(skill);
  }
  return result;
}

QString normalizeQuery(QString query, const QRegularExpression& leading) {
  query = query.trimmed();
  if (query.isEmpty()) return {};
  return query.remove(leading).toLower();
}

// serializeComposerFileLink: [name](path), the path URI-encoded.
QString fileLink(const QString& path) {
  const QString name = path.section(u'/', -1, -1, QString::SectionSkipEmpty);
  QString label = name.isEmpty() ? path : name;
  label.replace(u'\\', QStringLiteral("\\\\")).replace(u'[', QStringLiteral("\\[")).replace(u']', QStringLiteral("\\]"));
  // encodeURI, with ( ) # ? and \ escaped too.
  const QString destination = QString::fromUtf8(QUrl::toPercentEncoding(path, "/:@!$&'*+,;=-._~"));
  return QStringLiteral("[%1](%2) ").arg(label, destination);
}

}  // namespace

QList<Instance> instances(const QJsonArray& providers) {
  QList<Instance> list;
  for (const QJsonValue& value : providers) {
    const QJsonObject provider = value.toObject();
    Instance instance;
    instance.instanceId = str(provider, QLatin1String("instanceId"));
    instance.driver = str(provider, QLatin1String("driver"));
    if (instance.instanceId.isEmpty() || instance.driver.isEmpty()) continue;
    instance.displayName = displayNameOf(provider, instance.instanceId, instance.driver);
    static const QRegularExpression hex(QStringLiteral("^#[0-9a-fA-F]{6}$"));
    const QString accent = str(provider, QLatin1String("accentColor"));
    if (hex.match(accent).hasMatch()) instance.accentColor = accent;
    instance.iconUrl = registryIcon(instance.driver, str(provider, QLatin1String("iconUrl")));
    instance.groupKey = str(provider.value(QLatin1String("continuation")).toObject(), QLatin1String("groupKey"));
    instance.status = str(provider, QLatin1String("status"));
    instance.message = str(provider, QLatin1String("message"));
    instance.enabled = provider.value(QLatin1String("enabled")).toBool();
    instance.isDefault = instance.instanceId == instance.driver;
    instance.available = str(provider, QLatin1String("availability")) != QLatin1String("unavailable");
    instance.requiresNewThreadForModelChange = provider.value(QLatin1String("requiresNewThreadForModelChange")).toBool();
    instance.showInteractionModeToggle = provider.value(QLatin1String("showInteractionModeToggle")) != QJsonValue(false);
    for (const QJsonValue& mode : provider.value(QLatin1String("supportedRuntimeModes")).toArray()) {
      instance.runtimeModes.append(mode.toString());
    }
    instance.models = provider.value(QLatin1String("models")).toArray();
    instance.slashCommands = provider.value(QLatin1String("slashCommands")).toArray();
    instance.usageLimits = provider.value(QLatin1String("usageLimits")).toObject();
    instance.skills = provider.value(QLatin1String("skills")).toArray();
    list.append(instance);
  }
  QStringList drivers;
  for (const Instance& instance : list) {
    if (!drivers.contains(instance.driver)) drivers.append(instance.driver);
  }
  std::stable_sort(list.begin(), list.end(), [&drivers](const Instance& a, const Instance& b) {
    const qsizetype left = drivers.indexOf(a.driver);
    const qsizetype right = drivers.indexOf(b.driver);
    if (left != right) return left < right;
    return a.isDefault && !b.isDefault;
  });
  return list;
}

const Instance* find(const QList<Instance>& list, const QString& instanceId) {
  const auto it = std::find_if(list.begin(), list.end(), [&](const Instance& instance) { return instance.instanceId == instanceId; });
  return it == list.end() ? nullptr : &*it;
}

QJsonObject findModel(const Instance& instance, const QString& model) {
  if (model.isEmpty()) return {};
  for (const QJsonValue& value : instance.models) {
    if (str(value.toObject(), QLatin1String("slug")) == model) return value.toObject();
  }
  for (const QJsonValue& value : instance.models) {
    if (modelMatches(value.toObject(), model)) return value.toObject();
  }
  return {};
}

QString defaultModel(const Instance& instance) {
  QString firstBuiltIn;
  for (const QJsonValue& value : instance.models) {
    const QJsonObject model = value.toObject();
    if (model.value(QLatin1String("isCustom")).toBool()) continue;
    if (model.value(QLatin1String("isDefault")).toBool()) return str(model, QLatin1String("slug"));
    if (firstBuiltIn.isEmpty()) firstBuiltIn = str(model, QLatin1String("slug"));
  }
  if (!firstBuiltIn.isEmpty()) return firstBuiltIn;
  return instance.models.isEmpty() ? QString() : str(instance.models.first().toObject(), QLatin1String("slug"));
}

ModelPrefs modelPrefs(const QJsonValue& favorites, const QJsonValue& preferences) {
  ModelPrefs prefs;
  for (const QJsonValue& value : favorites.toArray()) {
    const QJsonObject favorite = value.toObject();
    prefs.favorites.insert(str(favorite, QLatin1String("provider")) + u'\n' + str(favorite, QLatin1String("model")));
  }
  prefs.preferences = preferences.toObject();
  return prefs;
}

QJsonArray toggleFavorite(const QJsonValue& favorites, const QString& instanceId, const QString& model) {
  QJsonArray next;
  bool removed = false;
  for (const QJsonValue& value : favorites.toArray()) {
    const QJsonObject favorite = value.toObject();
    if (str(favorite, QLatin1String("provider")) == instanceId && str(favorite, QLatin1String("model")) == model) {
      removed = true;
      continue;
    }
    next.append(favorite);
  }
  if (!removed) next.append(QJsonObject{{QStringLiteral("provider"), instanceId}, {QStringLiteral("model"), model}});
  return next;
}

// ChatView.logic.ts getStartedThreadModelChangeBlockReason, for a session
// that started (no provider handoff on the desktop).
std::optional<Block> blockReason(const QList<Instance>& list, const QString& currentInstance, const QString& currentModel,
                                 const QString& nextInstance, const QString& nextModel) {
  if (currentInstance == nextInstance && currentModel == nextModel) return std::nullopt;
  if (currentInstance != nextInstance) {
    return Block{QStringLiteral("Start a new chat to switch providers"),
                 QStringLiteral("This thread does not support switching providers after it has started.")};
  }
  const Instance* current = find(list, currentInstance);
  const Instance* next = find(list, nextInstance);
  if (!(current && current->requiresNewThreadForModelChange) && !(next && next->requiresNewThreadForModelChange)) {
    return std::nullopt;
  }
  return Block{QStringLiteral("Start a new chat to change models"),
               QStringLiteral("This provider does not allow switching models after a conversation has started.")};
}

QVariantList pickerInstances(const QList<Instance>& list, const ModelPrefs& prefs, const QString& selectedInstance,
                             const QString& selectedModel, const std::optional<Lock>& lock, bool started,
                             const QString& currentInstance, const QString& currentModel) {
  const auto matchesLock = [&lock](const Instance& instance) {
    return !lock || (instance.driver == lock->driver && (lock->groupKey.isEmpty() || instance.groupKey == lock->groupKey));
  };
  QList<Instance> visible;
  for (const Instance& instance : list) {
    if (instance.enabled) visible.append(instance);
  }
  QList<Instance> rail;
  for (const Instance& instance : visible) {
    if (matchesLock(instance)) rail.append(instance);
  }
  for (const Instance& instance : visible) {
    if (!matchesLock(instance)) rail.append(instance);
  }

  QVariantList result;
  for (const Instance& instance : rail) {
    const bool lockedOut = !matchesLock(instance);
    QList<QJsonObject> models;
    if (!lockedOut) {
      for (const QJsonObject& model : modelOptions(instance, prefs, selectedInstance, selectedModel)) {
        if (offered(instance, model, selectedInstance, selectedModel)) models.append(model);
      }
    }
    const auto favorite = [&](const QJsonObject& model) {
      return prefs.favorites.contains(instance.instanceId + u'\n' + str(model, QLatin1String("slug")));
    };
    std::stable_sort(models.begin(), models.end(), [&](const QJsonObject& a, const QJsonObject& b) { return favorite(a) && !favorite(b); });

    QVariantList shown;
    for (const QJsonObject& model : models) {
      const QString slug = str(model, QLatin1String("slug"));
      QVariant disabledReason;
      if (started) {
        if (const auto block = blockReason(list, currentInstance, currentModel, instance.instanceId, slug)) {
          disabledReason = block->description + QStringLiteral(" Start a new thread to use this model.");
        }
      }
      const auto orNull = [&](QLatin1StringView field) {
        const QString value = str(model, field);
        return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
      };
      shown.append(QVariantMap{
          {QStringLiteral("slug"), slug},
          {QStringLiteral("name"), str(model, QLatin1String("name")).isEmpty() ? slug : str(model, QLatin1String("name"))},
          {QStringLiteral("shortName"), orNull(QLatin1String("shortName"))},
          {QStringLiteral("subProvider"), orNull(QLatin1String("subProvider"))},
          {QStringLiteral("isFavorite"), favorite(model)},
          {QStringLiteral("isCustom"), model.value(QLatin1String("isCustom")).toBool()},
          {QStringLiteral("isNew"), str(model, QLatin1String("badge")) == QLatin1String("new")},
          {QStringLiteral("isLegacy"), model.value(QLatin1String("isLegacy")).toBool()},
          {QStringLiteral("isUnavailable"), model.value(QLatin1String("isUnavailable")).toBool()},
          {QStringLiteral("disabledReason"), disabledReason.isValid() ? disabledReason : QVariant::fromValue(nullptr)},
      });
    }
    QVariant reason = QVariant::fromValue(nullptr);
    if (!instance.ready()) {
      reason = unavailableReason(instance);
    } else if (lockedOut) {
      reason = instance.displayName + QStringLiteral(" is unavailable in this thread. Start a new thread to switch providers.");
    }
    const auto orNull = [](const QString& value) { return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value); };
    result.append(QVariantMap{
        {QStringLiteral("instanceId"), instance.instanceId},
        {QStringLiteral("driverKind"), instance.driver},
        {QStringLiteral("displayName"), instance.displayName},
        {QStringLiteral("accentColor"), orNull(instance.accentColor)},
        {QStringLiteral("iconUrl"), orNull(instance.iconUrl)},
        {QStringLiteral("initials"), initialsOf(instance.displayName)},
        {QStringLiteral("showBadge"), showBadge(instance, visible)},
        {QStringLiteral("status"), instance.status},
        {QStringLiteral("isAvailable"), !lockedOut && (instance.ready() || !shown.isEmpty())},
        {QStringLiteral("unavailableReason"), reason},
        {QStringLiteral("models"), shown},
    });
  }
  return result;
}

QJsonArray descriptors(const QJsonObject& model, const QJsonArray& selections, bool planModeEnabled) {
  QJsonArray result;
  for (const QJsonValue& value : model.value(QLatin1String("capabilities")).toObject().value(QLatin1String("optionDescriptors")).toArray()) {
    QJsonObject descriptor = value.toObject();
    const QString id = str(descriptor, QLatin1String("id"));
    const bool select = str(descriptor, QLatin1String("type")) == QLatin1String("select");
    if (!planModeEnabled && select && id == QLatin1String("agent")) {
      QJsonArray choices;
      for (const QJsonValue& choice : descriptor.value(QLatin1String("options")).toArray()) {
        if (str(choice.toObject(), QLatin1String("id")) != QLatin1String("plan")) choices.append(choice);
      }
      if (choices.isEmpty()) continue;
      descriptor.insert(QStringLiteral("options"), choices);
    }
    QJsonValue raw = descriptor.value(QLatin1String("currentValue"));
    for (const QJsonValue& selection : selections) {
      if (str(selection.toObject(), QLatin1String("id")) == id) raw = selection.toObject().value(QLatin1String("value"));
    }
    if (!select) {
      if (raw.isBool()) descriptor.insert(QStringLiteral("currentValue"), raw);
    } else {
      const QJsonValue current = choiceValue(descriptor, raw.isString() ? raw.toString() : str(descriptor, QLatin1String("currentValue")));
      if (current.isUndefined()) {
        descriptor.remove(QStringLiteral("currentValue"));
      } else {
        descriptor.insert(QStringLiteral("currentValue"), current);
      }
    }
    result.append(descriptor);
  }
  return result;
}

QVariantList shellOptions(const QJsonArray& descriptors) {
  QVariantList options;
  for (const QJsonValue& value : descriptors) {
    const QJsonObject descriptor = value.toObject();
    const bool select = str(descriptor, QLatin1String("type")) == QLatin1String("select");
    QVariantList choices;
    if (select) {
      for (const QJsonValue& choice : descriptor.value(QLatin1String("options")).toArray()) {
        choices.append(QVariantMap{{QStringLiteral("id"), str(choice.toObject(), QLatin1String("id"))},
                                   {QStringLiteral("label"), str(choice.toObject(), QLatin1String("label"))}});
      }
    }
    const QJsonValue current = descriptor.value(QLatin1String("currentValue"));
    options.append(QVariantMap{
        {QStringLiteral("id"), str(descriptor, QLatin1String("id"))},
        {QStringLiteral("label"), str(descriptor, QLatin1String("label"))},
        {QStringLiteral("type"), select ? QStringLiteral("select") : QStringLiteral("boolean")},
        {QStringLiteral("value"), current.isUndefined() ? QVariant::fromValue(nullptr) : current.toVariant()},
        {QStringLiteral("choices"), choices},
    });
  }
  return options;
}

std::optional<QJsonArray> applyOption(const QJsonArray& descriptors, const QString& id, const QVariant& value) {
  QJsonArray next;
  bool applied = false;
  for (const QJsonValue& entry : descriptors) {
    QJsonObject descriptor = entry.toObject();
    if (str(descriptor, QLatin1String("id")) == id) {
      if (str(descriptor, QLatin1String("type")) == QLatin1String("select")) {
        const QString choice = value.typeId() == QMetaType::QString ? value.toString() : QString();
        const QJsonArray choices = descriptor.value(QLatin1String("options")).toArray();
        if (std::any_of(choices.begin(), choices.end(),
                        [&](const QJsonValue& known) { return str(known.toObject(), QLatin1String("id")) == choice; })) {
          descriptor.insert(QStringLiteral("currentValue"), choice);
          applied = true;
        }
      } else if (value.typeId() == QMetaType::Bool) {
        descriptor.insert(QStringLiteral("currentValue"), value.toBool());
        applied = true;
      }
    }
    next.append(descriptor);
  }
  if (!applied) return std::nullopt;
  return selectionsOf(next);
}

QVariantList runtimeModes(const Instance* instance) {
  struct Mode {
    const char* value;
    const char* label;
    const char* description;
  };
  static const Mode modes[] = {
      {"approval-required", "Supervised", "Ask before commands and file changes."},
      {"auto-accept-edits", "Auto-accept edits", "Auto-approve edits, ask before other actions."},
      {"auto", "Auto", "Supported providers approve routine actions; others still ask."},
      {"full-access", "Full access", "Allow commands and edits without prompts."},
  };
  QVariantList result;
  for (const Mode& mode : modes) {
    const QString value = QString::fromLatin1(mode.value);
    if (instance && !instance->runtimeModes.isEmpty() && !instance->runtimeModes.contains(value)) continue;
    result.append(QVariantMap{{QStringLiteral("value"), value},
                              {QStringLiteral("label"), QString::fromLatin1(mode.label)},
                              {QStringLiteral("description"), QString::fromLatin1(mode.description)}});
  }
  return result;
}

// composer-logic.ts composerEnterIntents.
QVariantMap enterIntents(const QList<keybindings::Binding>& bindings, bool mac, const QString& sendShortcut, bool draft,
                         bool running) {
  const keybindings::Context context{{QStringLiteral("composerFocus"), true},
                                     {QStringLiteral("draftThreadRoute"), draft},
                                     {QStringLiteral("turnRunning"), running},
                                     {QStringLiteral("isDesktop"), true}};
  const auto table = [&](bool multiline) {
    QVariantMap intents;
    const bool needsModifier =
        sendShortcut == QLatin1String("mod-enter") || (sendShortcut == QLatin1String("mod-enter-multiline") && multiline);
    for (int mask = 0; mask < 16; ++mask) {
      const bool ctrl = mask & 1, meta = mask & 2, alt = mask & 4, shift = mask & 8;
      QStringList held;
      if (ctrl) held.append(QStringLiteral("ctrl"));
      if (meta) held.append(QStringLiteral("meta"));
      if (alt) held.append(QStringLiteral("alt"));
      if (shift) held.append(QStringLiteral("shift"));
      const QString command = commandFor(bindings, mac, context, QStringLiteral("enter"), ctrl, meta, alt, shift);
      QString intent;
      if (command == QLatin1String("composer.sendAlternate") && running) {
        intent = QStringLiteral("alternate");
      } else if (command == QLatin1String("composer.sendBackground") && draft) {
        intent = QStringLiteral("background");
      } else if (command.isEmpty() && !shift && !alt && (!needsModifier || ctrl || meta)) {
        intent = QStringLiteral("foreground");
      }
      if (!intent.isEmpty()) intents.insert(held.join(u'+'), intent);
    }
    return intents;
  };
  return {{QStringLiteral("singleLine"), table(false)}, {QStringLiteral("multiline"), table(true)}};
}

// keybindings.ts findEffectiveShortcutForCommand with the picker open.
QVariant pickerKey(const QList<keybindings::Binding>& bindings, bool mac, const QString& command) {
  const keybindings::Context context{{QStringLiteral("modelPickerOpen"), true}, {QStringLiteral("isDesktop"), true}};
  QSet<QString> claimed;
  for (auto it = bindings.crbegin(); it != bindings.crend(); ++it) {
    if (!keybindings::evaluate(it->when, context)) continue;
    const keybindings::Shortcut& s = it->shortcut;
    const bool meta = s.meta || (s.mod && mac);
    const bool ctrl = s.ctrl || (s.mod && !mac);
    const QString conflict = QStringLiteral("%1|%2|%3|%4|%5").arg(s.key).arg(meta).arg(ctrl).arg(s.shift).arg(s.alt);
    if (claimed.contains(conflict)) continue;
    claimed.insert(conflict);
    if (it->command != command) continue;
    return QVariantMap{{QStringLiteral("key"), s.key},
                       {QStringLiteral("ctrlKey"), ctrl},
                       {QStringLiteral("metaKey"), meta},
                       {QStringLiteral("shiftKey"), s.shift},
                       {QStringLiteral("altKey"), s.alt},
                       {QStringLiteral("label"), keybindings::label(s, mac)}};
  }
  return QVariant::fromValue(nullptr);
}

std::optional<Trigger> trigger(const QString& text, int cursor) {
  cursor = std::clamp(cursor, 0, int(text.size()));
  const int lineStart = cursor > 0 ? int(text.lastIndexOf(u'\n', cursor - 1)) + 1 : 0;
  const QString linePrefix = text.mid(lineStart, cursor - lineStart);
  if (linePrefix.startsWith(u'/')) {
    static const QRegularExpression command(QStringLiteral("^/(\\S*)$"));
    const QRegularExpressionMatch match = command.match(linePrefix);
    if (match.hasMatch()) return Trigger{QStringLiteral("slash-command"), match.captured(1), lineStart, cursor};
  }
  int tokenStart = cursor;
  while (tokenStart > 0 && !isSpace(text.at(tokenStart - 1))) --tokenStart;
  const QString token = text.mid(tokenStart, cursor - tokenStart);
  static const QRegularExpression pullRequest(QStringLiteral("^#([\\p{L}\\p{N}][\\p{L}\\p{N}_-]*)?$"),
                                              QRegularExpression::UseUnicodePropertiesOption);
  if (const QRegularExpressionMatch match = pullRequest.match(token); match.hasMatch()) {
    return Trigger{QStringLiteral("pull-request"), match.captured(1), tokenStart, cursor};
  }
  if (!token.isEmpty() && token.at(0).category() == QChar::Symbol_Currency) {
    return Trigger{QStringLiteral("skill"), token.mid(1), tokenStart, cursor};
  }
  if (token.startsWith(u'@')) return Trigger{QStringLiteral("path"), token.mid(1), tokenStart, cursor};
  return std::nullopt;
}

QList<Suggestion> slashItems(const Instance* instance, const Trigger& trigger, bool planModeEnabled, bool showSkills,
                             bool promptEmpty) {
  struct Item {
    Suggestion suggestion;
    int group;  // 0 the composer's, 1 the provider's commands, 2 skills
    QString name;
    QJsonObject skill;
  };
  QList<Item> items;
  const auto builtIn = [&items](const QString& command, const QString& description) {
    items.append({{QStringLiteral("slash:") + command, QStringLiteral("slash-command"), u'/' + command, description, {}}, 0, command, {}});
  };
  builtIn(QStringLiteral("model"), QStringLiteral("Switch response model for this thread"));
  if (planModeEnabled) {
    builtIn(QStringLiteral("plan"), QStringLiteral("Switch this thread into plan mode"));
    builtIn(QStringLiteral("default"), QStringLiteral("Switch this thread back to normal build mode"));
  }
  if (instance) {
    const QList<QJsonObject> skills = showSkills ? invocableSkills(instance->skills) : QList<QJsonObject>();
    QSet<QString> skillNames;
    for (const QJsonObject& skill : skills) skillNames.insert(str(skill, QLatin1String("name")).trimmed().toLower());
    if (trigger.start == 0) {
      for (const QJsonValue& value : instance->slashCommands) {
        const QJsonObject command = value.toObject();
        const QString name = str(command, QLatin1String("name"));
        if (skillNames.contains(name.trimmed().toLower())) continue;
        if (name == QLatin1String("compact") && !promptEmpty) continue;
        QString description = str(command, QLatin1String("description"));
        if (description.isEmpty()) description = str(command.value(QLatin1String("input")).toObject(), QLatin1String("hint"));
        if (description.isEmpty()) description = QStringLiteral("Run provider command");
        items.append({{QStringLiteral("provider-slash-command:%1:%2").arg(instance->driver, name), QStringLiteral("provider-slash-command"),
                       u'/' + name, description, u'/' + name + u' '},
                      1, name, {}});
      }
    }
    for (const QJsonObject& skill : skills) {
      const QString name = str(skill, QLatin1String("name"));
      QString description = str(skill, QLatin1String("shortDescription"));
      if (description.isEmpty()) description = str(skill, QLatin1String("description"));
      if (description.isEmpty() && !str(skill, QLatin1String("scope")).isEmpty()) {
        description = str(skill, QLatin1String("scope")) + QStringLiteral(" skill");
      }
      items.append({{QStringLiteral("skill:%1:%2").arg(instance->driver, name), QStringLiteral("skill"),
                     QStringLiteral("/skill:") + name, description, u'$' + name + u' '},
                    2, name, skill});
    }
  }

  static const QRegularExpression slashes(QStringLiteral("^/+"));
  const QString query = normalizeQuery(trigger.query, slashes);
  if (query.isEmpty()) {
    QList<Suggestion> all;
    for (const Item& item : items) all.append(item.suggestion);
    return all;
  }
  QList<Ranked> scored;
  const QString provider = instance ? instance->driver : QString();
  for (const Item& item : items) {
    std::optional<int> score;
    if (item.group == 2) {
      if (query == QLatin1String("skill")) {
        score = 0;
      } else {
        const QString skillQuery = query.startsWith(QLatin1String("skill:")) ? query.mid(6) : query;
        score = skillQuery.isEmpty() ? std::optional<int>(0) : scoreSkill(item.skill, skillQuery);
        if (!score && QStringLiteral("skill").startsWith(query)) score = std::numeric_limits<int>::max();
      }
    } else {
      score = best({scoreQueryMatch(item.name.toLower(), query, 0, 2, 4, 6, 100, QStringLiteral("-_/")),
                    scoreQueryMatch(item.suggestion.description.toLower(), query, 20, 22, 24, 26, std::nullopt)});
    }
    if (!score) continue;
    const QString tieBreaker = item.group == 0   ? QStringLiteral("0") + QChar(0) + item.name
                               : item.group == 1 ? QStringLiteral("1") + QChar(0) + item.name + QChar(0) + provider
                                                 : QStringLiteral("2") + QChar(0) + item.name + QChar(0) + provider;
    scored.append({item.suggestion, *score, tieBreaker});
  }
  return ranked(scored);
}

QList<Suggestion> skillItems(const Instance* instance, const Trigger& trigger) {
  if (!instance) return {};
  const auto toItem = [instance](const QJsonObject& skill) {
    const QString name = str(skill, QLatin1String("name"));
    QString description = str(skill, QLatin1String("shortDescription"));
    if (description.isEmpty()) description = str(skill, QLatin1String("description"));
    if (description.isEmpty()) {
      description = str(skill, QLatin1String("scope")).isEmpty() ? QStringLiteral("Run provider skill")
                                                                 : str(skill, QLatin1String("scope")) + QStringLiteral(" skill");
    }
    return Suggestion{QStringLiteral("skill:%1:%2").arg(instance->driver, name), QStringLiteral("skill"), skillLabel(skill),
                      description, u'$' + name + u' '};
  };
  static const QRegularExpression currency(QStringLiteral("^\\p{Sc}+"), QRegularExpression::UseUnicodePropertiesOption);
  const QString query = normalizeQuery(trigger.query, currency);
  const QList<QJsonObject> skills = invocableSkills(instance->skills);
  QList<Ranked> scored;
  for (const QJsonObject& skill : skills) {
    if (query.isEmpty()) {
      scored.append({toItem(skill), 0, QString()});
      continue;
    }
    const std::optional<int> score = scoreSkill(skill, query);
    if (score) scored.append({toItem(skill), *score, skillLabel(skill).toLower() + QChar(0) + str(skill, QLatin1String("name"))});
  }
  return query.isEmpty() ? [&] {
    QList<Suggestion> all;
    for (const Ranked& entry : scored) all.append(entry.item);
    return all;
  }()
                         : ranked(scored);
}

QList<Suggestion> pathItems(const QList<std::pair<QString, bool>>& entries) {
  QList<Suggestion> items;
  for (const auto& [path, directory] : entries) {
    const QString kind = directory ? QStringLiteral("directory") : QStringLiteral("file");
    const qsizetype slash = path.lastIndexOf(u'/');
    items.append({QStringLiteral("path:%1:%2").arg(kind, path), QStringLiteral("path"), slash < 0 ? path : path.mid(slash + 1),
                  slash < 0 ? QString() : path.left(slash), fileLink(path)});
  }
  return items;
}

QString pathLink(const QString& path) {
  return fileLink(path);
}

QString emptyText(const QString& kind) {
  if (kind == QLatin1String("skill")) return QStringLiteral("No skills found. Try / to browse provider commands.");
  if (kind == QLatin1String("path")) return QStringLiteral("No matching files or folders.");
  if (kind == QLatin1String("slash-command")) return QStringLiteral("No matching command.");
  return {};
}

std::optional<int> scoreQueryMatch(const QString& value, const QString& query, int exactBase, int prefixBase,
                                   std::optional<int> boundaryBase, std::optional<int> includesBase,
                                   std::optional<int> fuzzyBase, const QString& boundaryMarkers) {
  if (value.isEmpty() || query.isEmpty()) return std::nullopt;
  if (value == query) return exactBase;
  const int lengthPenalty = int(std::min<qsizetype>(64, std::max<qsizetype>(0, value.size() - query.size())));
  if (value.startsWith(query)) return prefixBase + lengthPenalty;
  if (boundaryBase) {
    std::optional<qsizetype> bestIndex;
    for (const QChar marker : boundaryMarkers) {
      const qsizetype index = value.indexOf(marker + query);
      if (index >= 0 && (!bestIndex || index + 1 < *bestIndex)) bestIndex = index + 1;
    }
    if (bestIndex) return *boundaryBase + int(*bestIndex) * 2 + lengthPenalty;
  }
  if (includesBase) {
    const qsizetype index = value.indexOf(query);
    if (index >= 0) return *includesBase + int(index) * 2 + lengthPenalty;
  }
  if (fuzzyBase) {
    qsizetype queryIndex = 0;
    qsizetype first = -1;
    qsizetype previous = -1;
    int gaps = 0;
    for (qsizetype i = 0; i < value.size(); ++i) {
      if (value.at(i) != query.at(queryIndex)) continue;
      if (first < 0) first = i;
      if (previous >= 0) gaps += int(i - previous - 1);
      previous = i;
      if (++queryIndex == query.size()) {
        const int span = int(i - first + 1 - query.size());
        const int length = int(std::min<qsizetype>(64, value.size() - query.size()));
        return *fuzzyBase + int(first) * 2 + gaps * 3 + span + length;
      }
    }
  }
  return std::nullopt;
}

Queued queued(const QList<QJsonObject>& runs, const QHash<QString, QJsonObject>& messages) {
  QList<QJsonObject> waiting;
  for (const QJsonObject& run : runs) {
    if (run.value(QLatin1String("status")).toString() == QLatin1String("queued")) waiting.append(run);
  }
  // By queue position, which the MC keeps whole; a run's id settles a tie, so
  // the order is the same whatever order the runs came in.
  std::sort(waiting.begin(), waiting.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const double left = a.value(QLatin1String("queuePosition")).toDouble(a.value(QLatin1String("ordinal")).toDouble());
    const double right = b.value(QLatin1String("queuePosition")).toDouble(b.value(QLatin1String("ordinal")).toDouble());
    if (left != right) return left < right;
    return a.value(QLatin1String("id")).toString() < b.value(QLatin1String("id")).toString();
  });
  Queued queued;
  for (const QJsonObject& run : waiting) {
    const QString runId = run.value(QLatin1String("id")).toString();
    const auto found = messages.constFind(run.value(QLatin1String("userMessageId")).toString());
    if (found == messages.cend()) continue;
    const QJsonObject& message = *found;
    if (message.value(QLatin1String("notification")).isObject() || message.value(QLatin1String("delegatedCompletion")).isObject() ||
        message.value(QLatin1String("providerWake")).toBool()) {
      const std::optional<timeline::Notice> notice = timeline::noticeOf(message);
      queued.waiting.append(QVariantMap{{QStringLiteral("runId"), runId},
                                        {QStringLiteral("summary"), notice && !notice->summary.isEmpty() ? notice->summary : QStringLiteral("Notification")},
                                        {QStringLiteral("outcome"), notice ? notice->outcome : QString()}});
      continue;
    }
    queued.queue.append(QVariantMap{{QStringLiteral("runId"), runId}, {QStringLiteral("text"), message.value(QLatin1String("text")).toString()}});
  }
  return queued;
}

}  // namespace composer
