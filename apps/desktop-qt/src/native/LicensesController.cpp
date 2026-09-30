#include "LicensesController.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUrl>

#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<LicensesController> registrar(QStringLiteral("licenses"), {QStringLiteral("licenses")});

// packages/shared thirdPartyLicenses.ts's BUNDLE_LABELS.
QString bundleLabel(const QString& bundle) {
  static const QHash<QString, QString> labels{
      {QStringLiteral("android"), QStringLiteral("Android")},
      {QStringLiteral("assets"), QStringLiteral("Assets")},
      {QStringLiteral("desktop"), QStringLiteral("Desktop")},
      {QStringLiteral("desktop-qt"), QStringLiteral("Qt desktop")},
      {QStringLiteral("device-tools"), QStringLiteral("Device tools")},
      {QStringLiteral("ios"), QStringLiteral("iOS")},
      {QStringLiteral("mobile"), QStringLiteral("Mobile")},
      {QStringLiteral("server"), QStringLiteral("Server")},
      {QStringLiteral("web"), QStringLiteral("Web")},
  };
  return labels.value(bundle, bundle);
}

QVariant nullable(const QString& value) {
  return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
}

}  // namespace

LicensesController::LicensesController(ShellBridge* bridge, NodeClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {}

void LicensesController::activate() {
  if (m_active) return;
  m_active = true;
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  auto opened = [navigation] { return navigation->route() == NavigationController::Route::settings(kSection); };
  // Read when the page opens, until it has read.
  auto open = [this, opened] {
    if (opened() && m_status != QLatin1String("ready")) load();
  };
  connect(navigation, &NavigationController::changed, this, open);
  publish();
  open();
}

bool LicensesController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("licenses."))) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("licenses.search")) {
    m_query = input.value(QStringLiteral("query")).toString();
  } else if (action == QLatin1String("licenses.open")) {
    const QString key = input.value(QStringLiteral("key")).toString();
    m_openKey = key == m_openKey ? QString() : key;
  } else if (action == QLatin1String("licenses.retry")) {
    load();
    return true;
  }
  publish();
  return true;
}

// decodeThirdPartyLicenseManifest: schema 1, each entry with bundles, a
// license, a name and its notice text.
void LicensesController::load() {
  m_status = QStringLiteral("loading");
  m_entries.clear();
  QFile file(manifestPath());
  const auto fail = [this](const QString& message) {
    m_status = QStringLiteral("error");
    m_message = message;
    m_entries.clear();
    publish();
  };
  if (manifestPath().isEmpty() || !file.open(QIODevice::ReadOnly)) {
    fail(QStringLiteral("The license manifest could not load."));
    return;
  }
  const QJsonObject manifest = QJsonDocument::fromJson(file.readAll()).object();
  if (manifest.value(QLatin1String("schemaVersion")).toInt() != 1 || !manifest.value(QLatin1String("entries")).isArray()) {
    fail(QStringLiteral("The open-source license manifest has an unsupported format."));
    return;
  }
  const QJsonArray entries = manifest.value(QLatin1String("entries")).toArray();
  for (qsizetype index = 0; index < entries.size(); ++index) {
    const QJsonObject value = entries.at(index).toObject();
    Entry entry{{},
                value.value(QLatin1String("name")).toString(),
                value.value(QLatin1String("version")).toString(),
                value.value(QLatin1String("license")).toString(),
                value.value(QLatin1String("noticeText")).toString(),
                value.value(QLatin1String("sourceUrl")).toString(),
                {}};
    for (const QJsonValue& bundle : value.value(QLatin1String("bundles")).toArray()) entry.bundles << bundle.toString();
    if (entry.name.isEmpty() || entry.license.isEmpty() || entry.bundles.isEmpty()) {
      fail(QStringLiteral("License entry %1 has an invalid shape.").arg(index + 1));
      return;
    }
    entry.key = value.value(QLatin1String("kind")).toString() + QLatin1Char(':') + entry.name + QLatin1Char('@') + entry.version;
    m_entries.append(entry);
  }
  m_status = QStringLiteral("ready");
  m_message.clear();
  publish();
}

// filterThirdPartyLicenseEntries: every word of the query is in the name,
// version, license or a bundle.
void LicensesController::publish() {
  if (!m_active) return;
  static const QRegularExpression space(QStringLiteral("\\s+"));
  const QStringList terms = m_query.trimmed().toLower().split(space, Qt::SkipEmptyParts);
  QVariantList listed;
  QString noticeText;
  for (const Entry& entry : m_entries) {
    const QString searchable = (QStringList{entry.name, entry.version, entry.license} + entry.bundles).join(QLatin1Char(' ')).toLower();
    if (!std::all_of(terms.cbegin(), terms.cend(), [&](const QString& term) { return searchable.contains(term); })) continue;
    QStringList where;
    for (const QString& bundle : entry.bundles) where << bundleLabel(bundle);
    listed.append(QVariantMap{
        {QStringLiteral("key"), entry.key},
        {QStringLiteral("name"), entry.name},
        {QStringLiteral("version"), nullable(entry.version)},
        {QStringLiteral("license"), entry.license},
        {QStringLiteral("where"), where.join(QStringLiteral(", "))},
        {QStringLiteral("sourceUrl"), nullable(entry.sourceUrl)},
    });
    if (entry.key == m_openKey) noticeText = entry.noticeText;
  }
  m_bridge->publish(QStringLiteral("licenses"),
                    QVariantMap{
                        {QStringLiteral("status"), m_status},
                        {QStringLiteral("message"), nullable(m_message)},
                        {QStringLiteral("query"), m_query},
                        {QStringLiteral("total"), m_entries.size()},
                        {QStringLiteral("entries"), listed},
                        {QStringLiteral("openKey"), nullable(noticeText.isEmpty() ? QString() : m_openKey)},
                        {QStringLiteral("noticeText"), nullable(noticeText)},
                    });
}
