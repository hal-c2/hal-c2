#include "UsagePricesController.h"

#include <QJsonArray>
#include <QRegularExpression>

#include "EnvironmentSettings.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<UsagePricesController> registrar(QStringLiteral("usagePrices"), {QStringLiteral("usagePrices")});

const QString kKey = QStringLiteral("usagePrices");
const QString kOverrides = QStringLiteral("usagePriceOverrides");

struct Field {
  QString key;
  QString label;
  bool optional;
};

const QList<Field>& fields() {
  static const QList<Field> list{{QStringLiteral("inputCostPerMillionTokens"), QStringLiteral("Input"), false},
                                 {QStringLiteral("outputCostPerMillionTokens"), QStringLiteral("Output"), false},
                                 {QStringLiteral("cacheReadCostPerMillionTokens"), QStringLiteral("Cache read"), true},
                                 {QStringLiteral("cacheWriteCostPerMillionTokens"), QStringLiteral("Cache write"), true}};
  return list;
}

// A saved rate as the field shows it; empty when the price does not set it.
QString shown(const QJsonObject& price, const QString& field) {
  const QJsonValue value = price.value(field);
  return value.isDouble() ? QString::number(value.toDouble(), 'g', 15) : QString();
}

}  // namespace

UsagePricesController::UsagePricesController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_settings(new EnvironmentSettings(client, this)) {
  connect(m_settings, &EnvironmentSettings::changed, this, &UsagePricesController::publish);
}

void UsagePricesController::activate() {
  if (m_active) return;
  m_active = true;
  // An environment that comes back is read again, so it can be saved to.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (!m_open) return;
    // One paired while the dialog is open joins it.
    const QStringList targets = chosen();
    const bool moved = targets != m_targets;
    m_targets = targets;
    QSet<QString> online;
    for (const QString& id : std::as_const(m_targets)) {
      if (m_store->environmentOnline(id)) online.insert(id);
    }
    if (moved || online != m_online) follow();
    publish();
  });
  publish();
}

bool UsagePricesController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("usagePrices."))) return false;
  const QVariantMap input = payload.toMap();
  const QString model = input.value(QStringLiteral("model")).toString().trimmed();
  if (action == QLatin1String("usagePrices.open")) {
    setOpen(true);
  } else if (action == QLatin1String("usagePrices.close")) {
    setOpen(false);
  } else if (!m_open) {
    return true;
  } else if (action == QLatin1String("usagePrices.add")) {
    if (model.isEmpty()) {
      m_error = tr("Enter a model ID.");
    } else {
      m_error.clear();
      bool known = false;
      for (const QString& id : std::as_const(m_targets)) known = known || prices(id).contains(model);
      draft(model).isNew = !known;
    }
    publish();
  } else if (action == QLatin1String("usagePrices.edit")) {
    if (model.isEmpty()) return true;
    draft(model).values.insert(input.value(QStringLiteral("field")).toString(), input.value(QStringLiteral("value")).toString());
    publish();
  } else if (action == QLatin1String("usagePrices.remove") || action == QLatin1String("usagePrices.restore")) {
    if (model.isEmpty()) return true;
    draft(model).removed = action == QLatin1String("usagePrices.remove");
    publish();
  } else if (action == QLatin1String("usagePrices.save")) {
    save(m_targets);
  } else if (action == QLatin1String("usagePrices.retry")) {
    QStringList failed;
    for (const QString& id : std::as_const(m_targets)) {
      if (!m_results.value(id).isEmpty()) failed.append(id);
    }
    if (!failed.isEmpty()) save(failed);
  } else {
    return false;
  }
  return true;
}

QStringList UsagePricesController::chosen() const {
  const QString filter = m_bridge->state()->value(QStringLiteral("usage")).toMap().value(QStringLiteral("environmentId")).toString();
  QStringList targets;
  for (const QString& id : m_store->environments()) {
    if (m_store->servesEnvironment(id) && (filter.isEmpty() || id == filter)) targets.append(id);
  }
  // This machine first, the rest by name.
  std::sort(targets.begin(), targets.end(), [this](const QString& a, const QString& b) {
    const bool ownA = a == m_client->environment(), ownB = b == m_client->environment();
    return ownA != ownB ? ownA : label(a) < label(b);
  });
  return targets;
}

void UsagePricesController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  m_drafts.clear();
  m_results.clear();
  m_error.clear();
  m_targets.clear();
  if (open) m_targets = chosen();
  follow();
  publish();
}

void UsagePricesController::follow() {
  m_online.clear();
  for (const QString& id : std::as_const(m_targets)) {
    if (m_store->environmentOnline(id)) m_online.insert(id);
  }
  // Afresh: a subscription an offline environment refused is not sent again.
  m_settings->setTargets({});
  m_settings->setTargets(m_targets);
}

UsagePricesController::Draft& UsagePricesController::draft(const QString& model) {
  for (Draft& draft : m_drafts) {
    if (draft.model == model) return draft;
  }
  m_drafts.append(Draft{model, false, false, {}});
  return m_drafts.last();
}

QJsonObject UsagePricesController::prices(const QString& environmentId, bool* known) const {
  const std::optional<QJsonObject> settings = m_settings->settings(environmentId);
  if (known) *known = settings.has_value();
  return settings ? settings->value(kOverrides).toObject() : QJsonObject();
}

QString UsagePricesController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  if (!label.isEmpty()) return label;
  return environmentId == m_client->environment() ? tr("This machine") : environmentId;
}

// Only edited cells replace rates; the others keep each environment's own.
QJsonObject UsagePricesController::edited(const QJsonObject& current, const QString& where, QString* error) const {
  static const QRegularExpression number(QStringLiteral("^(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:e[+-]?\\d+)?$"), QRegularExpression::CaseInsensitiveOption);
  QJsonObject next = current;
  for (const Draft& draft : m_drafts) {
    if (draft.removed) {
      next.remove(draft.model);
      continue;
    }
    if (draft.values.isEmpty()) continue;
    const QJsonObject original = current.value(draft.model).toObject();
    QJsonObject price;
    for (const Field& field : fields()) {
      const QString text = (draft.values.contains(field.key) ? draft.values.value(field.key) : shown(original, field.key)).trimmed();
      if (text.isEmpty()) {
        if (field.optional) continue;
        if (error) *error = tr("%1 is required on %2.").arg(field.label, where);
        return current;
      }
      bool ok = false;
      const double value = text.toDouble(&ok);
      if (!ok || value < 0 || !number.match(text).hasMatch()) {
        if (error) *error = tr("Use non-negative numbers for prices.");
        return current;
      }
      price.insert(field.key, value);
    }
    next.insert(draft.model, price);
  }
  return next;
}

void UsagePricesController::save(const QStringList& targets) {
  if (!m_writing.isEmpty()) return;
  // A draft that cannot be saved somewhere stops the save before anything is written.
  m_error.clear();
  for (const QString& id : targets) {
    bool known = false;
    const QJsonObject current = prices(id, &known);
    QString error;
    if (known) edited(current, label(id), &error);
    if (!error.isEmpty()) {
      m_error = error;
      publish();
      return;
    }
  }
  for (const QString& id : targets) {
    m_results.remove(id);
    m_writing.insert(id);
  }
  publish();
  // Each destination settles on its own.
  for (const QString& id : targets) write(id, 3);
}

void UsagePricesController::write(const QString& environmentId, int retries) {
  m_client->call(this, environmentId, QStringLiteral("hal-c2.readSettings"), QJsonObject{},
                 [this, environmentId, retries](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error) return settled(environmentId, tr("Could not save. Try again."));
                   const QJsonObject read = result.toObject();
                   QJsonObject settings = read.value(QLatin1String("settings")).toObject();
                   const QJsonObject current = settings.value(kOverrides).toObject();
                   const QJsonObject next = edited(current, label(environmentId), nullptr);
                   if (next == current) return settled(environmentId, QString());
                   if (next.isEmpty()) settings.remove(kOverrides);
                   else settings.insert(kOverrides, next);
                   m_client->call(this, environmentId, QStringLiteral("hal-c2.writeSettings"),
                                  QJsonObject{{QStringLiteral("settings"), settings}, {QStringLiteral("version"), read.value(QLatin1String("version"))}},
                                  [this, environmentId, retries](const QJsonValue& answer, const std::optional<QString>& writeError) {
                                    if (!writeError) return settled(environmentId, QString());
                                    // Another client saved in between: read and edit again.
                                    if (answer.toObject().value(QLatin1String("_tag")) == QLatin1String("StaleSettings") && retries > 0) {
                                      return write(environmentId, retries - 1);
                                    }
                                    settled(environmentId, tr("Could not save. Try again."));
                                  });
                 });
}

void UsagePricesController::settled(const QString& environmentId, const QString& error) {
  m_writing.remove(environmentId);
  m_results.insert(environmentId, error);
  if (m_writing.isEmpty()) {
    // Saved everywhere, the edits are what the environments hold now.
    const bool failed = std::any_of(m_results.cbegin(), m_results.cend(), [](const QString& result) { return !result.isEmpty(); });
    if (!failed && m_results.size() == m_targets.size()) m_drafts.clear();
  }
  publish();
}

void UsagePricesController::publish() {
  if (!m_active) return;
  QVariantList targets;
  bool anyFailed = false;
  for (const QString& id : std::as_const(m_targets)) {
    const bool settledHere = m_results.contains(id);
    const QString error = m_results.value(id);
    anyFailed = anyFailed || (settledHere && !error.isEmpty());
    targets.append(QVariantMap{{QStringLiteral("id"), id},
                               {QStringLiteral("label"), label(id)},
                               {QStringLiteral("status"), !settledHere ? QString() : error.isEmpty() ? QStringLiteral("Saved") : QStringLiteral("Not saved")},
                               {QStringLiteral("error"), error}});
  }
  // Every model a chosen environment prices, by name, then the ones being added.
  QStringList models;
  bool unavailable = false;
  for (const QString& id : std::as_const(m_targets)) {
    bool known = false;
    const QJsonObject current = prices(id, &known);
    unavailable = unavailable || !known;
    for (auto it = current.begin(); it != current.end(); ++it) {
      if (!models.contains(it.key())) models.append(it.key());
    }
  }
  models.sort();
  for (const Draft& draft : std::as_const(m_drafts)) {
    if (!models.contains(draft.model)) models.append(draft.model);
  }
  QVariantList rows;
  for (const QString& model : std::as_const(models)) {
    const auto found = std::find_if(m_drafts.cbegin(), m_drafts.cend(), [&](const Draft& draft) { return draft.model == model; });
    QVariantMap cells;
    for (const Field& field : fields()) {
      QStringList values;
      bool priced = false;
      for (const QString& id : std::as_const(m_targets)) {
        const QJsonObject current = prices(id);
        priced = priced || current.contains(model);
        values.append(current.contains(model) ? shown(current.value(model).toObject(), field.key) : QStringLiteral("\n"));
      }
      QString value, placeholder;
      if (unavailable) {
        placeholder = QStringLiteral("Unavailable");
      } else if (std::any_of(values.cbegin(), values.cend(), [&](const QString& other) { return other != values.first(); })) {
        placeholder = QStringLiteral("Mixed");
      } else {
        value = values.value(0) == QLatin1String("\n") ? QString() : values.value(0);
        placeholder = !priced ? QStringLiteral("Automatic") : field.optional ? QStringLiteral("Input rate") : QStringLiteral("0.00");
      }
      if (found != m_drafts.cend() && found->values.contains(field.key)) value = found->values.value(field.key);
      cells.insert(field.key, QVariantMap{{QStringLiteral("value"), value}, {QStringLiteral("placeholder"), placeholder}});
    }
    rows.append(QVariantMap{{QStringLiteral("model"), model},
                            {QStringLiteral("isNew"), found != m_drafts.cend() && found->isNew},
                            {QStringLiteral("removed"), found != m_drafts.cend() && found->removed},
                            {QStringLiteral("cells"), cells}});
  }
  m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), m_open},
                                      {QStringLiteral("saving"), !m_writing.isEmpty()},
                                      {QStringLiteral("error"), m_error},
                                      {QStringLiteral("targets"), targets},
                                      {QStringLiteral("rows"), rows},
                                      {QStringLiteral("canRetry"), anyFailed && m_writing.isEmpty()}});
}
