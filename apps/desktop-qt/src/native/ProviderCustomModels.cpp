#include "ProviderCustomModels.h"

#include <QSet>
#include <QVariantMap>

namespace ProviderCustomModels {

namespace {

constexpr int kMaxSlugLength = 256;

QVariantMap choice(const QString& id, const QString& label, bool isDefault = false) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("label"), label}, {QStringLiteral("isDefault"), isDefault}};
}

QVariantMap option(const QString& id, const QString& label, const QString& type, const QVariantList& choices = {}) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("label"), label}, {QStringLiteral("type"), type}, {QStringLiteral("choices"), choices}};
}

QVariantList effort(const QString& fallback = QStringLiteral("medium")) {
  return {choice(QStringLiteral("low"), QStringLiteral("Low"), fallback == QLatin1String("low")),
          choice(QStringLiteral("medium"), QStringLiteral("Medium"), fallback == QLatin1String("medium")),
          choice(QStringLiteral("high"), QStringLiteral("High"), fallback == QLatin1String("high")),
          choice(QStringLiteral("xhigh"), QStringLiteral("Extra High"))};
}

// A stored descriptor as editor options; `promptInjectedValues` are left out.
QVariantMap editorOption(const QJsonObject& descriptor) {
  const QString type = descriptor.value(QLatin1String("type")).toString() == QLatin1String("boolean") ? QStringLiteral("boolean")
                                                                                                        : QStringLiteral("select");
  QSet<QString> injected;
  for (const QJsonValue& value : descriptor.value(QLatin1String("promptInjectedValues")).toArray()) injected.insert(value.toString());
  const QString current = descriptor.value(QLatin1String("currentValue")).toString();
  QJsonArray options;
  for (const QJsonValue& value : descriptor.value(QLatin1String("options")).toArray()) {
    if (!injected.contains(value.toObject().value(QLatin1String("id")).toString())) options.append(value);
  }
  QString chosen;
  for (const QJsonValue& value : std::as_const(options)) {
    if (!current.isEmpty() && value.toObject().value(QLatin1String("id")).toString() == current) chosen = current;
  }
  if (chosen.isEmpty()) {
    for (const QJsonValue& value : std::as_const(options)) {
      if (value.toObject().value(QLatin1String("isDefault")).toBool()) {
        chosen = value.toObject().value(QLatin1String("id")).toString();
        break;
      }
    }
  }
  QVariantList choices;
  if (type == QLatin1String("select")) {
    for (const QJsonValue& value : std::as_const(options)) {
      const QString id = value.toObject().value(QLatin1String("id")).toString();
      choices.append(choice(id, value.toObject().value(QLatin1String("label")).toString(), !chosen.isEmpty() && id == chosen));
    }
  }
  return option(descriptor.value(QLatin1String("id")).toString(), descriptor.value(QLatin1String("label")).toString(), type, choices);
}

QVariantList editorOptions(const QJsonObject& capabilities, const QString& driver = {}) {
  QVariantList result;
  for (const QJsonValue& value : capabilities.value(QLatin1String("optionDescriptors")).toArray()) {
    const QJsonObject descriptor = value.toObject();
    // Claude's context choices need runtime suffixes a custom model does not carry.
    if (driver == QLatin1String("claudeAgent") && descriptor.value(QLatin1String("id")) == QLatin1String("contextWindow")) continue;
    result.append(editorOption(descriptor));
  }
  return result;
}

}  // namespace

QVariantList read(const QJsonValue& setting) {
  QVariantList result;
  QSet<QString> seen;
  for (const QJsonValue& value : setting.toArray()) {
    const QJsonObject entry = value.isString() ? QJsonObject{{QStringLiteral("slug"), value}} : value.toObject();
    const QString slug = entry.value(QLatin1String("slug")).toString().trimmed();
    if (slug.isEmpty() || seen.contains(slug)) continue;
    seen.insert(slug);
    const QString name = entry.value(QLatin1String("name")).toString().trimmed();
    result.append(QVariantMap{{QStringLiteral("slug"), slug},
                              {QStringLiteral("name"), name == slug ? QString() : name},
                              {QStringLiteral("options"), editorOptions(entry.value(QLatin1String("capabilities")).toObject())}});
  }
  return result;
}

QString refusal(const QString& slug, const QJsonArray& models, const QJsonValue& setting) {
  const QString trimmed = slug.trimmed();
  if (trimmed.isEmpty()) return QStringLiteral("Enter a model slug.");
  for (const QJsonValue& value : models) {
    const QJsonObject model = value.toObject();
    if (!model.value(QLatin1String("isCustom")).toBool() && model.value(QLatin1String("slug")).toString() == trimmed) {
      return QStringLiteral("That model is already built in.");
    }
  }
  if (trimmed.size() > kMaxSlugLength) return QStringLiteral("Model slugs must be %1 characters or less.").arg(kMaxSlugLength);
  for (const QVariant& saved : read(setting)) {
    if (saved.toMap().value(QStringLiteral("slug")).toString() == trimmed) return QStringLiteral("That custom model is already saved.");
  }
  return {};
}

QString problem(const QVariantList& options) {
  QSet<QString> ids;
  for (qsizetype index = 0; index < options.size(); ++index) {
    const QVariantMap option = options.at(index).toMap();
    const QString position = QStringLiteral("Option %1").arg(index + 1);
    const QString id = option.value(QStringLiteral("id")).toString().trimmed();
    if (id.isEmpty()) return position + QStringLiteral(" needs an id.");
    if (ids.contains(id)) return QStringLiteral("%1: id \"%2\" is used twice.").arg(position, id);
    ids.insert(id);
    if (option.value(QStringLiteral("label")).toString().trimmed().isEmpty()) return position + QStringLiteral(" needs a label.");
    if (option.value(QStringLiteral("type")).toString() == QLatin1String("boolean")) continue;
    const QVariantList choices = option.value(QStringLiteral("choices")).toList();
    if (choices.isEmpty()) return position + QStringLiteral(" needs at least one choice.");
    QSet<QString> seen;
    for (const QVariant& value : choices) {
      const QString choiceId = value.toMap().value(QStringLiteral("id")).toString().trimmed();
      if (choiceId.isEmpty()) return position + QStringLiteral(" has a choice without a value.");
      if (seen.contains(choiceId)) return QStringLiteral("%1: choice \"%2\" is used twice.").arg(position, choiceId);
      seen.insert(choiceId);
    }
  }
  return {};
}

QJsonValue setting(const QString& slug, const QString& name, const QVariantList& options) {
  const QString trimmedName = name.trimmed();
  QJsonArray descriptors;
  for (const QVariant& value : options) {
    const QVariantMap option = value.toMap();
    QJsonObject descriptor{{QStringLiteral("id"), option.value(QStringLiteral("id")).toString().trimmed()},
                           {QStringLiteral("label"), option.value(QStringLiteral("label")).toString().trimmed()}};
    if (option.value(QStringLiteral("type")).toString() == QLatin1String("boolean")) {
      descriptor.insert(QStringLiteral("type"), QStringLiteral("boolean"));
    } else {
      descriptor.insert(QStringLiteral("type"), QStringLiteral("select"));
      QJsonArray choices;
      QString current;
      for (const QVariant& entry : option.value(QStringLiteral("choices")).toList()) {
        const QVariantMap choice = entry.toMap();
        const QString id = choice.value(QStringLiteral("id")).toString().trimmed();
        const QString label = choice.value(QStringLiteral("label")).toString().trimmed();
        QJsonObject stored{{QStringLiteral("id"), id}, {QStringLiteral("label"), label.isEmpty() ? id : label}};
        // Only one choice is the default.
        if (choice.value(QStringLiteral("isDefault")).toBool() && current.isEmpty()) {
          stored.insert(QStringLiteral("isDefault"), true);
          current = id;
        }
        choices.append(stored);
      }
      descriptor.insert(QStringLiteral("options"), choices);
      if (!current.isEmpty()) descriptor.insert(QStringLiteral("currentValue"), current);
    }
    descriptors.append(descriptor);
  }
  if ((trimmedName.isEmpty() || trimmedName == slug) && descriptors.isEmpty()) return slug;
  QJsonObject entry{{QStringLiteral("slug"), slug}};
  if (!trimmedName.isEmpty() && trimmedName != slug) entry.insert(QStringLiteral("name"), trimmedName);
  if (!descriptors.isEmpty()) {
    entry.insert(QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), descriptors}});
  }
  return entry;
}

QVariantList presets(const QString& driver) {
  const QString speed = QStringLiteral("serviceTier");
  if (driver == QLatin1String("codex")) {
    return {option(QStringLiteral("reasoningEffort"), QStringLiteral("Reasoning"), QStringLiteral("select"), effort()),
            option(speed, QStringLiteral("Speed"), QStringLiteral("select"),
                   {choice(QStringLiteral("default"), QStringLiteral("Standard"), true), choice(QStringLiteral("fast"), QStringLiteral("Fast"))})};
  }
  if (driver == QLatin1String("claudeAgent")) {
    QVariantList claude = effort(QStringLiteral("high"));
    claude.append(choice(QStringLiteral("max"), QStringLiteral("Max")));
    return {option(QStringLiteral("effort"), QStringLiteral("Reasoning"), QStringLiteral("select"), claude),
            option(QStringLiteral("fastMode"), QStringLiteral("Fast Mode"), QStringLiteral("boolean")),
            option(QStringLiteral("thinking"), QStringLiteral("Thinking"), QStringLiteral("boolean"))};
  }
  if (driver == QLatin1String("cursor")) {
    return {option(QStringLiteral("reasoning"), QStringLiteral("Reasoning"), QStringLiteral("select"), effort()),
            option(QStringLiteral("fastMode"), QStringLiteral("Fast Mode"), QStringLiteral("boolean")),
            option(QStringLiteral("thinking"), QStringLiteral("Thinking"), QStringLiteral("boolean"))};
  }
  if (driver == QLatin1String("grok")) return {option(QStringLiteral("reasoningEffort"), QStringLiteral("Reasoning"), QStringLiteral("select"), effort())};
  if (driver == QLatin1String("pi")) {
    return {option(QStringLiteral("thinking"), QStringLiteral("Thinking"), QStringLiteral("select"),
                   {choice(QStringLiteral("off"), QStringLiteral("Off")), choice(QStringLiteral("minimal"), QStringLiteral("Minimal")),
                    choice(QStringLiteral("low"), QStringLiteral("Low")), choice(QStringLiteral("medium"), QStringLiteral("Medium"), true),
                    choice(QStringLiteral("high"), QStringLiteral("High")), choice(QStringLiteral("xhigh"), QStringLiteral("Extra High")),
                    choice(QStringLiteral("max"), QStringLiteral("Max"))})};
  }
  if (driver == QLatin1String("opencode")) {
    return {option(QStringLiteral("variant"), QStringLiteral("Reasoning"), QStringLiteral("select"), effort()),
            option(QStringLiteral("agent"), QStringLiteral("Agent"), QStringLiteral("select"),
                   {choice(QStringLiteral("build"), QStringLiteral("Build"), true), choice(QStringLiteral("plan"), QStringLiteral("Plan"))})};
  }
  return {};
}

QVariantList copyable(const QJsonArray& models, const QString& driver) {
  QVariantList result;
  for (const QJsonValue& value : models) {
    const QJsonObject model = value.toObject();
    if (model.value(QLatin1String("isCustom")).toBool()) continue;
    const QVariantList options = editorOptions(model.value(QLatin1String("capabilities")).toObject(), driver);
    if (options.isEmpty()) continue;
    const QString slug = model.value(QLatin1String("slug")).toString();
    const QString name = model.value(QLatin1String("name")).toString();
    result.append(QVariantMap{{QStringLiteral("slug"), slug}, {QStringLiteral("name"), name.isEmpty() ? slug : name}, {QStringLiteral("options"), options}});
  }
  return result;
}

}  // namespace ProviderCustomModels
