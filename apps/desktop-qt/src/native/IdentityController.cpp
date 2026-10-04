#include "IdentityController.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>

#include "EnvironmentSettings.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ProjectIdentity.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"
#include "WorkspaceFiles.h"

namespace {

const NativeControllerRegistrar<IdentityController> registrar(
    QStringLiteral("identity"), {QStringLiteral("projectIcons"), QStringLiteral("projectIconPicker"), QStringLiteral("environmentIcons")});

QString text(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

// packages/contracts ENVIRONMENT_MACHINE_KINDS: each kind's label and the
// lucide icon that stands for it.
struct Machine {
  QString kind, label, icon;
};
const QList<Machine>& machines() {
  static const QList<Machine> list{
      {QStringLiteral("server"), QStringLiteral("Server"), QStringLiteral("server")},
      {QStringLiteral("cloud"), QStringLiteral("Cloud"), QStringLiteral("cloud")},
      {QStringLiteral("linux"), QStringLiteral("Linux"), QStringLiteral("terminal")},
      {QStringLiteral("desktop"), QStringLiteral("Desktop"), QStringLiteral("monitor")},
      {QStringLiteral("laptop"), QStringLiteral("Laptop"), QStringLiteral("laptop")},
      {QStringLiteral("mac-mini"), QStringLiteral("Mac mini"), QStringLiteral("cpu")},
      {QStringLiteral("mac-studio"), QStringLiteral("Mac Studio"), QStringLiteral("cpu")},
  };
  return list;
}

const Machine* machine(const QString& kind) {
  for (const Machine& entry : machines()) {
    if (entry.kind == kind) return &entry;
  }
  return nullptr;
}

}  // namespace

IdentityController::IdentityController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_settings(new EnvironmentSettings(client, this)) {}

void IdentityController::activate() {
  if (m_active) return;
  m_active = true;
  connect(m_store, &ShellStore::changed, this, [this] {
    refreshProjects();
    refreshEnvironments();
  });
  connect(m_settings, &EnvironmentSettings::changed, this, &IdentityController::refreshEnvironments);
  connect(m_settings, &EnvironmentSettings::frame, this, [this](const QString& environmentId, const QJsonObject& frame) {
    if (frame.value(QLatin1String("t")) != QLatin1String("config")) return;
    const QJsonValue descriptor = frame.value(QLatin1String("config")).toObject().value(QLatin1String("environment"));
    if (!descriptor.isObject() || m_descriptors.value(environmentId) == descriptor.toObject()) return;
    m_descriptors.insert(environmentId, descriptor.toObject());
    refreshEnvironments();
  });
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    // Another connection is another session.
    if (!ready) m_mayOperate.reset();
    refreshEnvironments();
  });
  refreshProjects();
  refreshEnvironments();
}

// --- Projects ------------------------------------------------------------------------

void IdentityController::refreshProjects() {
  QVariantMap icons;
  QSet<QString> seen;
  for (const QString& environmentId : m_store->environments()) {
    for (const QJsonObject& row : m_store->projectRows(environmentId)) {
      const QString key = environmentId + QLatin1Char(':') + text(row, "id");
      seen.insert(key);
      QVariantMap icon = projectidentity::icon(row);
      // Its own favicon, or the image the user picked, once the MC serves one.
      if (row.value(QLatin1String("projectIcon")).toObject().isEmpty()) {
        const QString asked = text(row, "workspaceRoot") + QLatin1Char('\n') + text(row, "faviconPath");
        if (m_favicons.value(key).asked != asked && m_store->environmentOnline(environmentId)) {
          m_favicons.insert(key, {asked, {}});
          requestFavicon(key, row);
        }
        if (const QString url = m_favicons.value(key).url; !url.isEmpty()) {
          icon = {{QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("url"), url}, {QStringLiteral("path"), text(row, "faviconPath")},
                  {QStringLiteral("automatic"), text(row, "faviconPath").isEmpty()}};
        }
      } else {
        m_favicons.remove(key);
      }
      icons.insert(key, icon);
    }
  }
  for (auto it = m_favicons.begin(); it != m_favicons.end();) it = seen.contains(it.key()) ? std::next(it) : m_favicons.erase(it);
  if (icons == m_projectIcons) return;
  m_projectIcons = icons;
  m_bridge->publish(QStringLiteral("projectIcons"), m_projectIcons);
}

void IdentityController::requestFavicon(const QString& key, const QJsonObject& row) {
  const QString asked = m_favicons.value(key).asked;
  QJsonObject resource{{QStringLiteral("_tag"), QStringLiteral("project-favicon")}, {QStringLiteral("cwd"), text(row, "workspaceRoot")}};
  if (!text(row, "faviconPath").isEmpty()) resource.insert(QStringLiteral("path"), text(row, "faviconPath"));
  m_client->call(this, key.left(key.indexOf(QLatin1Char(':'))), QStringLiteral("assets.createUrl"), QJsonObject{{QStringLiteral("resource"), resource}},
                 [this, key, asked](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_favicons.value(key).asked != asked) return;
                   const QString relative = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   // The MC names a project without a favicon this way: the monogram stays.
                   if (error || relative.isEmpty() || relative.endsWith(QLatin1String("project-favicon-missing"))) return;
                   m_favicons[key].url = m_client->origin().resolved(QUrl(relative)).toString();
                   refreshProjects();
                 });
}

void IdentityController::publishPicker() {
  QVariant state;
  if (m_picker) {
    QVariantList colors;
    for (const QString& color : projectidentity::colors()) {
      colors.append(QVariantMap{{QStringLiteral("name"), color}, {QStringLiteral("tint"), projectidentity::tint(color)}});
    }
    state = QVariantMap{{QStringLiteral("name"), m_picker->name},
                        {QStringLiteral("mode"), m_picker->mode},
                        {QStringLiteral("symbol"), m_picker->symbol},
                        {QStringLiteral("color"), m_picker->color},
                        {QStringLiteral("tint"), projectidentity::tint(m_picker->color)},
                        {QStringLiteral("letters"), m_picker->letters},
                        {QStringLiteral("emoji"), m_picker->emoji},
                        {QStringLiteral("error"), m_picker->error},
                        {QStringLiteral("symbols"), projectidentity::symbols()},
                        {QStringLiteral("colors"), colors},
                        {QStringLiteral("query"), m_picker->query},
                        {QStringLiteral("searching"), m_picker->searching},
                        {QStringLiteral("images"), m_picker->images}};
  }
  m_bridge->publish(QStringLiteral("projectIconPicker"), state);
}

void IdentityController::openPicker(const QString& projectKey, const QString& name) {
  const qsizetype colon = projectKey.indexOf(QLatin1Char(':'));
  const QJsonObject row = m_store->projectRow(projectKey.left(colon), projectKey.mid(colon + 1));
  if (row.isEmpty()) return;
  const projectidentity::Identity automatic = projectidentity::derive(name.isEmpty() ? text(row, "title") : name);
  const QVariantMap current = projectidentity::icon(row);
  Picker picker;
  picker.projectKey = projectKey;
  picker.name = name.isEmpty() ? text(row, "title") : name;
  picker.color = automatic.color;
  picker.letters = automatic.monogram;
  picker.emoji = QStringLiteral("💻");
  if (!current.value(QStringLiteral("automatic")).toBool()) {
    picker.mode = current.value(QStringLiteral("kind")).toString();
    if (picker.mode == QLatin1String("lucide")) picker.symbol = current.value(QStringLiteral("name")).toString();
    if (picker.mode == QLatin1String("monogram")) picker.letters = current.value(QStringLiteral("text")).toString();
    if (picker.mode == QLatin1String("emoji")) picker.emoji = current.value(QStringLiteral("emoji")).toString();
    if (picker.mode != QLatin1String("emoji")) picker.color = current.value(QStringLiteral("color")).toString();
  } else if (!text(row, "faviconPath").isEmpty()) {
    picker.mode = QStringLiteral("image");
  }
  m_picker = picker;
  publishPicker();
}

void IdentityController::setPicker(const QVariantMap& fields) {
  if (!m_picker) return;
  static const QStringList modes{QStringLiteral("lucide"), QStringLiteral("emoji"), QStringLiteral("monogram"), QStringLiteral("image")};
  if (const QString mode = fields.value(QStringLiteral("mode")).toString(); modes.contains(mode)) m_picker->mode = mode;
  if (const QString symbol = fields.value(QStringLiteral("symbol")).toString(); projectidentity::symbols().contains(symbol)) m_picker->symbol = symbol;
  if (const QString color = fields.value(QStringLiteral("color")).toString(); projectidentity::colors().contains(color)) m_picker->color = color;
  if (fields.contains(QStringLiteral("letters"))) m_picker->letters = fields.value(QStringLiteral("letters")).toString();
  if (fields.contains(QStringLiteral("emoji"))) m_picker->emoji = fields.value(QStringLiteral("emoji")).toString();
  m_picker->error.clear();
  publishPicker();
}

// Image files only: what can be an icon.
void IdentityController::search(const QString& query) {
  if (!m_picker) return;
  m_picker->query = query;
  const int request = ++m_picker->request;
  const qsizetype colon = m_picker->projectKey.indexOf(QLatin1Char(':'));
  const QString environmentId = m_picker->projectKey.left(colon);
  const QString cwd = text(m_store->projectRow(environmentId, m_picker->projectKey.mid(colon + 1)), "workspaceRoot");
  if (query.trimmed().isEmpty() || cwd.isEmpty()) {
    m_picker->searching = false;
    m_picker->images.clear();
    publishPicker();
    return;
  }
  m_picker->searching = true;
  publishPicker();
  WorkspaceFiles::searchEntries(m_client, this, environmentId, cwd, query.trimmed(), WorkspaceFiles::searchLimit,
                                [this, request](const QList<FileTreeModel::Entry>& entries, bool, const std::optional<QString>&) {
                                  if (!m_picker || m_picker->request != request) return;
                                  m_picker->searching = false;
                                  m_picker->images.clear();
                                  for (const FileTreeModel::Entry& entry : entries) {
                                    if (!entry.directory && projectidentity::isImage(entry.path)) m_picker->images.append(entry.path);
                                  }
                                  m_picker->images.sort();
                                  publishPicker();
                                });
}

void IdentityController::savePicker() {
  if (!m_picker) return;
  QJsonObject icon;
  if (m_picker->mode == QLatin1String("monogram")) {
    const QString letters = projectidentity::monogram(m_picker->letters);
    if (!projectidentity::validMonogram(letters)) {
      m_picker->error = tr("Use one or two letters or numbers.");
      publishPicker();
      return;
    }
    icon = projectidentity::wire(QStringLiteral("monogram"), letters, m_picker->color);
  } else if (m_picker->mode == QLatin1String("emoji")) {
    const QString emoji = m_picker->emoji.trimmed();
    if (emoji.isEmpty()) {
      m_picker->error = tr("Choose an emoji.");
      publishPicker();
      return;
    }
    icon = projectidentity::wire(QStringLiteral("emoji"), emoji, {});
  } else if (m_picker->mode == QLatin1String("lucide")) {
    icon = projectidentity::wire(QStringLiteral("lucide"), m_picker->symbol, m_picker->color);
  } else {
    m_picker->error = tr("Choose an image file.");
    publishPicker();
    return;
  }
  m_picker.reset();
  publishPicker();
  m_bridge->dispatch(QStringLiteral("projectSettings.icon"), QVariantMap{{QStringLiteral("icon"), icon.toVariantMap()}});
}

// --- Environments --------------------------------------------------------------------

QString IdentityController::lockOf(const QString& environmentId) const {
  if (!m_client->isReady() || !m_store->environmentOnline(environmentId) || !m_settings->settings(environmentId)) {
    return tr("Connect to this environment to change its icon.");
  }
  const QJsonObject capabilities = m_descriptors.value(environmentId).value(QLatin1String("capabilities")).toObject();
  if (capabilities.value(QLatin1String("environmentIcon")) != QJsonValue(true)) {
    return tr("This environment's server is too old to keep an icon. Update it to choose one.");
  }
  const bool own = environmentId == m_client->environment();
  if (own && m_mayOperate == false) return tr("Your session on this environment cannot change its settings.");
  return {};
}

void IdentityController::refreshEnvironments() {
  if (!m_active) return;
  const QStringList environments = m_store->environments();
  m_settings->setTargets(environments);
  QVariantMap icons;
  for (const QString& environmentId : environments) {
    const QString detected = text(m_descriptors.value(environmentId).value(QLatin1String("platform")).toObject(), "machine");
    const std::optional<QJsonObject> settings = m_settings->settings(environmentId);
    const QString chosen = settings ? text(*settings, "environmentIcon") : QString();
    const Machine* shown = machine(chosen);
    if (!shown) shown = machine(detected);
    if (!shown) shown = machine(QStringLiteral("server"));
    QVariantList kinds;
    for (const Machine& entry : machines()) {
      kinds.append(QVariantMap{{QStringLiteral("kind"), entry.kind}, {QStringLiteral("label"), entry.label}, {QStringLiteral("icon"), entry.icon}});
    }
    icons.insert(environmentId, QVariantMap{{QStringLiteral("kind"), shown->kind},
                                            {QStringLiteral("label"), shown->label},
                                            {QStringLiteral("icon"), shown->icon},
                                            {QStringLiteral("detected"), machine(detected) ? detected : QString()},
                                            {QStringLiteral("chosen"), machine(chosen) != nullptr},
                                            {QStringLiteral("lock"), lockOf(environmentId)},
                                            {QStringLiteral("kinds"), kinds}});
  }
  if (icons == m_environmentIcons) return;
  m_environmentIcons = icons;
  m_bridge->publish(QStringLiteral("environmentIcons"), m_environmentIcons);
}

void IdentityController::withSession(std::function<void()> then) {
  if (m_mayOperate || !m_client->isReady()) {
    then();
    return;
  }
  auto* http = new QNetworkAccessManager(this);
  QNetworkReply* reply = http->get(m_client->request(QStringLiteral("/api/auth/session")));
  connect(reply, &QNetworkReply::finished, this, [this, reply, http, then = std::move(then)] {
    const QJsonObject session = QJsonDocument::fromJson(reply->readAll()).object();
    // A session that lists its scopes and lacks this one may only look; an MC
    // that says nothing checks the write itself.
    const QJsonValue scopes = session.value(QLatin1String("scopes"));
    m_mayOperate = reply->error() != QNetworkReply::NoError || !scopes.isArray() || scopes.toArray().contains(QStringLiteral("orchestration:operate"));
    reply->deleteLater();
    http->deleteLater();
    refreshEnvironments();
    then();
  });
}

void IdentityController::setEnvironmentKind(const QString& environmentId, const QString& kind) {
  if (!machine(kind)) return;
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  if (const QString lock = lockOf(environmentId); !lock.isEmpty()) {
    toasts->error(tr("Icon not changed"), lock);
    return;
  }
  // With nothing detected the MC shows a server, so that kind clears the choice too.
  QString detected = text(m_descriptors.value(environmentId).value(QLatin1String("platform")).toObject(), "machine");
  if (!machine(detected)) detected = QStringLiteral("server");
  const QJsonValue value = kind == detected ? QJsonValue(QJsonValue::Null) : QJsonValue(kind);
  m_settings->change(
      [environmentId, value](QJsonObject settings, const QString& target) {
        return target == environmentId ? EnvironmentSettings::with(settings, QStringLiteral("environmentIcon"), value) : settings;
      },
      [toasts, environmentId](const QHash<QString, QString>& failed, int) {
        if (failed.contains(environmentId)) toasts->error(tr("Icon not changed"), failed.value(environmentId));
      });
}

bool IdentityController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("environmentIcon.set")) {
    const QString environmentId = map.value(QStringLiteral("environmentId")).toString();
    const QString kind = map.value(QStringLiteral("kind")).toString();
    withSession([this, environmentId, kind] { setEnvironmentKind(environmentId, kind); });
    return true;
  }
  if (!action.startsWith(QLatin1String("projectIcon."))) return false;
  if (action == QLatin1String("projectIcon.open")) {
    openPicker(map.value(QStringLiteral("projectKey")).toString(), map.value(QStringLiteral("name")).toString());
  } else if (action == QLatin1String("projectIcon.set")) {
    setPicker(map);
  } else if (action == QLatin1String("projectIcon.search")) {
    search(map.value(QStringLiteral("query")).toString());
  } else if (action == QLatin1String("projectIcon.save")) {
    savePicker();
  } else if (action == QLatin1String("projectIcon.image")) {
    if (m_picker && projectidentity::isImage(map.value(QStringLiteral("path")).toString())) {
      m_picker.reset();
      publishPicker();
      m_bridge->dispatch(QStringLiteral("projectSettings.icon"), QVariantMap{{QStringLiteral("faviconPath"), map.value(QStringLiteral("path"))}});
    }
  } else if (action == QLatin1String("projectIcon.cancel")) {
    m_picker.reset();
    publishPicker();
  } else {
    return false;
  }
  return true;
}
