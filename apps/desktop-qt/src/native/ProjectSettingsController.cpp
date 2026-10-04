// Settings → Project, natively (the web's ProjectsSettings and
// ProjectSettingsPanel): the picked logical project's name and icon, which
// every checkout in the scope takes (`project.update` on each, in turn), its
// checkouts and removing them (ProjectController asks first), and how new
// threads start: the model, permissions, workspace and worktree submodules,
// as the project's overrides or, with no project picked, the environments'
// defaults (the web keeps the last two on General, whose native page holds
// only this device's settings).
//
// Publishes `projectSettings`: {open, status (pick | empty | missing |
// checkout-missing | ready), message (what shows instead of the project),
// name, icon: {label, emoji, custom}, checkouts: [{key, environment, path}]
// (listed when there are several), note (where its other settings are), removal:
// {title, description, button},
// available (an environment is connected), and each default (model,
// permissions, workspace, submodules): {value, label, mixed, resettable},
// the model's also {automatic, none (no providers), models: [{key, label}]},
// and the others' {options: [{value, label, description}]}}.
//
// Actions (`projectSettings.`): `rename {title}`, `icon {emoji | icon |
// faviconPath}` (without one, back to automatic), `remove {key}` (one checkout, else every
// checkout in the scope), `model {key}` ("" for automatic), `permissions
// {value}`, `workspace {value}`, `submodules {value}`, `reset {key}` (model |
// permissions | workspace | submodules).

#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "ProjectController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("projectSettings");
const QString kSection = QStringLiteral("/settings/projects");
const QString kModel = QStringLiteral("defaultModelSelection");

QString at(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

struct Option {
  QString value, label, description;
};

// A default a row edits: its settings key, its choices, and what applies
// when the environment leaves it unset (null for the file-backed ones).
struct Choice {
  QString key;
  QString builtIn;
  QList<Option> options;
};

const QHash<QString, Choice>& choices() {
  static const QHash<QString, Choice> map{
      {QStringLiteral("permissions"),
       {QStringLiteral("defaultRuntimeMode"),
        QStringLiteral("full-access"),
        {{QStringLiteral("approval-required"), QStringLiteral("Supervised"), QStringLiteral("Ask before commands and file changes.")},
         {QStringLiteral("auto-accept-edits"), QStringLiteral("Auto-accept edits"), QStringLiteral("Auto-approve edits, ask before other actions.")},
         {QStringLiteral("auto"), QStringLiteral("Auto"), QStringLiteral("Supported providers approve routine actions; others still ask.")},
         {QStringLiteral("full-access"), QStringLiteral("Full access"), QStringLiteral("Allow commands and edits without prompts.")}}}},
      {QStringLiteral("workspace"),
       {QStringLiteral("defaultThreadEnvMode"),
        QStringLiteral("local"),
        {{QStringLiteral("local"), QStringLiteral("Current checkout"), {}}, {QStringLiteral("worktree"), QStringLiteral("New worktree"), {}}}}},
      {QStringLiteral("submodules"),
       {QStringLiteral("worktreeSubmodules"),
        QStringLiteral("recursive"),
        {{QStringLiteral("recursive"), QStringLiteral("Recursive"), {}},
         {QStringLiteral("top-level"), QStringLiteral("Top level only"), {}},
         {QStringLiteral("none"), QStringLiteral("Skip"), {}}}}},
  };
  return map;
}

// The project's value of `key` (its override), else the environment's.
QJsonValue effective(const QJsonObject& settings, const QString& projectId, const QString& key) {
  if (!projectId.isEmpty()) {
    const QJsonValue own = SettingsScopeController::overrideOf(settings, projectId, key);
    if (!own.isUndefined()) return own;
  }
  return settings.value(key);
}

QString keyOf(const QJsonObject& selection) {
  return selection.isEmpty() ? QString() : at(selection, "instanceId") + QLatin1Char(':') + at(selection, "model");
}

QString providerName(const QJsonObject& entry) {
  return at(entry, "displayName").isEmpty() ? at(entry, "instanceId") : at(entry, "displayName");
}

// The providers a new thread can start with.
QJsonArray usable(const QJsonArray& providers) {
  QJsonArray result;
  for (const QJsonValue& value : providers) {
    const QJsonObject entry = value.toObject();
    if (!entry.value(QLatin1String("enabled")).toBool(true) || !entry.value(QLatin1String("installed")).toBool(true)) continue;
    if (at(entry, "availability") == QLatin1String("unavailable")) continue;
    result.append(entry);
  }
  return result;
}

bool offers(const QJsonArray& providers, const QString& instanceId, const QString& model) {
  for (const QJsonValue& value : usable(providers)) {
    const QJsonObject entry = value.toObject();
    if (at(entry, "instanceId") != instanceId) continue;
    for (const QJsonValue& slug : entry.value(QLatin1String("models")).toArray()) {
      if (at(slug.toObject(), "slug") == model) return true;
    }
  }
  return false;
}

// What the icon row says: the chosen icon, the chosen file, or Automatic.
QString iconLabel(const QJsonObject& row) {
  const QJsonObject icon = row.value(QLatin1String("projectIcon")).toObject();
  const QString monogram = at(icon, "monogramText").isEmpty() ? at(icon, "text") : at(icon, "monogramText");
  if (at(icon, "kind") == QLatin1String("emoji")) return at(icon, "emoji");
  if (!monogram.isEmpty()) return monogram + QStringLiteral(" · ") + at(icon, "color");
  if (at(icon, "kind") == QLatin1String("lucide")) return at(icon, "name") + QStringLiteral(" · ") + at(icon, "color");
  return at(row, "faviconPath").isEmpty() ? QStringLiteral("Automatic") : at(row, "faviconPath");
}

}  // namespace

class ProjectSettingsController : public QObject, public NativeController {
public:
  ProjectSettingsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    connect(navigation, &NavigationController::changed, this, [this, navigation] {
      const bool open = navigation->route().kind == QLatin1String("settings") && navigation->route().section == kSection;
      if (open == m_open) return;
      m_open = open;
      publish();
    });
    connect(scope(), &SettingsScopeController::changed, this, &ProjectSettingsController::publish);
    // Names, icons and checkouts arrive as rows.
    connect(m_store, &ShellStore::changed, this, [this] {
      QMetaObject::invokeMethod(this, &ProjectSettingsController::publish, Qt::QueuedConnection);
    });
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(kKey + QLatin1Char('.'))) return false;
    const QString name = action.mid(kKey.size() + 1);
    const QVariantMap input = payload.toMap();
    if (!m_open) return true;
    if (name == QLatin1String("rename")) {
      rename(input.value(QStringLiteral("title")).toString().trimmed());
    } else if (name == QLatin1String("icon")) {
      // An emoji typed here, an icon as the picker made it (IdentityController),
      // or an image file of the project; none of them is back to automatic.
      const QString emoji = input.value(QStringLiteral("emoji")).toString().trimmed();
      const QJsonObject picked = QJsonObject::fromVariantMap(input.value(QStringLiteral("icon")).toMap());
      const QString image = input.value(QStringLiteral("faviconPath")).toString().trimmed();
      update({{QStringLiteral("projectIcon"), !picked.isEmpty() ? QJsonValue(picked)
                                              : emoji.isEmpty() ? QJsonValue(QJsonValue::Null)
                                                                : QJsonValue(QJsonObject{{QStringLiteral("kind"), QStringLiteral("emoji")},
                                                                                         {QStringLiteral("emoji"), emoji}})},
              {QStringLiteral("faviconPath"), image.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(image)}},
             QStringLiteral("Failed to update project icon"));
    } else if (name == QLatin1String("remove")) {
      remove(input.value(QStringLiteral("key")).toString());
    } else if (name == QLatin1String("model")) {
      setModel(input.value(QStringLiteral("key")).toString());
    } else if (choices().contains(name)) {
      const Choice& choice = choices().value(name);
      const QString value = input.value(QStringLiteral("value")).toString();
      if (std::none_of(choice.options.cbegin(), choice.options.cend(), [&value](const Option& option) { return option.value == value; })) {
        return true;
      }
      set(choice.key, value);
    } else if (name == QLatin1String("reset")) {
      reset(input.value(QStringLiteral("key")).toString());
    }
    return true;
  }

private:
  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }
  ToastController* toasts() const { return NativeShell::of(this)->controller<ToastController>(); }

  // The picked project's checkouts in the scope, and whether others lie
  // outside it; none when no project is picked or it is gone.
  QList<sidebar::Project> members(bool* others = nullptr) const {
    const sidebar::ProjectGroup* group = NativeShell::of(this)->sidebar()->group(scope()->projectKey());
    QList<sidebar::Project> result;
    if (group == nullptr) return result;
    const QString environment = scope()->environmentFilter();
    for (const sidebar::Project& member : group->members) {
      if (environment.isEmpty() || member.environmentId == environment) result.append(member);
    }
    if (others) *others = result.size() < group->members.size();
    return result;
  }

  QString displayName() const {
    const sidebar::ProjectGroup* group = NativeShell::of(this)->sidebar()->group(scope()->projectKey());
    return group ? group->summary.value(QStringLiteral("displayName")).toString() : QString();
  }

  void rename(const QString& title) {
    if (title.isEmpty()) {
      toasts()->show(QStringLiteral("warning"), QStringLiteral("Project title cannot be empty"));
      publish();
      return;
    }
    const QList<sidebar::Project> checkouts = members();
    if (std::all_of(checkouts.cbegin(), checkouts.cend(), [&title](const sidebar::Project& member) { return member.title == title; })) return;
    update({{QStringLiteral("title"), title}}, QStringLiteral("Failed to rename project"));
  }

  // A name or icon is each checkout's own field, so it goes to every one;
  // one on an environment that is not connected stops it before it starts.
  void update(const QJsonObject& fields, const QString& failureTitle) {
    const QList<sidebar::Project> checkouts = members();
    if (checkouts.isEmpty()) return;
    for (const sidebar::Project& member : checkouts) {
      if (m_store->environmentOnline(member.environmentId)) continue;
      toasts()->error(failureTitle, QStringLiteral("Connect %1 and try again.").arg(scope()->label(member.environmentId)));
      publish();
      return;
    }
    send(checkouts, fields, failureTitle, checkouts.size() > 1);
  }

  void send(QList<sidebar::Project> rest, const QJsonObject& fields, const QString& failureTitle, bool several) {
    if (rest.isEmpty()) return;
    const sidebar::Project member = rest.takeFirst();
    QJsonObject command = fields;
    command.insert(QStringLiteral("type"), QStringLiteral("project.update"));
    command.insert(QStringLiteral("projectId"), member.id);
    const QPointer<ProjectSettingsController> self(this);
    m_client->call(this, member.environmentId, QStringLiteral("projects.mutate"), command,
                   [self, rest, fields, failureTitle, several, member](const QJsonValue&, const std::optional<QString>& error) {
                     if (!self) return;
                     if (error) {
                       // Earlier checkouts took it; say where it stopped.
                       self->toasts()->error(several ? QStringLiteral("%1 on %2").arg(failureTitle, self->scope()->label(member.environmentId))
                                                     : failureTitle,
                                             *error);
                       self->publish();
                       return;
                     }
                     self->send(rest, fields, failureTitle, several);
                   });
  }

  void remove(const QString& key) {
    bool others = false;
    const QList<sidebar::Project> checkouts = members(&others);
    QStringList keys;
    QString title = displayName();
    for (const sidebar::Project& member : checkouts) {
      if (!key.isEmpty() && member.key() != key) continue;
      keys.append(member.key());
      if (!key.isEmpty()) title = member.title;
    }
    if (keys.isEmpty()) return;
    const bool whole = keys.size() == checkouts.size();
    NativeShell::of(this)->controller<ProjectController>()->askToRemove(
        keys, others || !whole ? QStringLiteral("checkout") : QStringLiteral("project"), title);
  }

  // Writes `key` for the scope: the project's override, or the environments' value.
  void set(const QString& key, const QJsonValue& value, const QString& failureTitle = {}) {
    scope()->write(
        [key, value](QJsonObject settings, const QString& projectId) {
          if (!projectId.isEmpty()) return SettingsScopeController::withOverride(settings, projectId, key, value);
          settings.insert(key, value);
          return settings;
        },
        failureTitle);
  }

  // A model every selected environment can start threads with, or automatic.
  void setModel(const QString& key) {
    if (key.isEmpty()) {
      set(kModel, QJsonValue::Null);
      return;
    }
    const qsizetype colon = key.indexOf(QLatin1Char(':'));
    if (colon <= 0) return;
    const QString instanceId = key.left(colon);
    const QString model = key.mid(colon + 1);
    for (const QString& environmentId : scope()->targets()) {
      if (offers(scope()->providers(environmentId), instanceId, model)) continue;
      toasts()->error(QStringLiteral("Default model not saved"),
                      QStringLiteral("This model is unavailable on %1. Select that environment to choose its model separately.")
                          .arg(scope()->label(environmentId)));
      publish();
      return;
    }
    set(kModel, QJsonObject{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}});
  }

  void reset(const QString& name) {
    QString key;
    QJsonValue value = QJsonValue::Null;
    if (name == QLatin1String("model")) {
      key = kModel;
    } else if (choices().contains(name)) {
      key = choices().value(name).key;
      // The permissions have a default of their own; the others defer to the
      // checkout's hal-c2.json when unset.
      if (name == QLatin1String("permissions")) value = choices().value(name).builtIn;
    } else {
      return;
    }
    scope()->write([key, value](QJsonObject settings, const QString& projectId) {
      if (!projectId.isEmpty()) return SettingsScopeController::withOverride(settings, projectId, key, QJsonValue(QJsonValue::Undefined));
      settings.insert(key, value);
      return settings;
    });
  }

  // Whether the row has something to reset: a project's override, or an
  // environment value off its default.
  bool resettable(const QString& key, const QJsonValue& fallback) const {
    const auto reading = scope()->read([key, fallback](const QJsonObject& settings, const QString& projectId) {
      if (!projectId.isEmpty()) return QJsonValue(!SettingsScopeController::overrideOf(settings, projectId, key).isUndefined());
      const QJsonValue value = settings.value(key);
      return QJsonValue(!value.isUndefined() && !value.isNull() && value != fallback);
    });
    return reading.mixed || reading.value.toBool();
  }

  QVariantMap choiceRow(const QString& name) const {
    const Choice& choice = choices().value(name);
    const auto reading = scope()->read([&choice](const QJsonObject& settings, const QString& projectId) {
      const QJsonValue value = effective(settings, projectId, choice.key);
      return value.isString() ? value : QJsonValue(choice.builtIn);
    });
    const QString value = reading.mixed || scope()->targets().isEmpty() ? QString() : reading.value.toString();
    QString label = scope()->targets().isEmpty() ? QStringLiteral("Unavailable") : QStringLiteral("Mixed");
    QVariantList options;
    for (const Option& option : choice.options) {
      if (option.value == value) label = option.label;
      options.append(QVariantMap{{QStringLiteral("value"), option.value},
                                 {QStringLiteral("label"), option.label},
                                 {QStringLiteral("description"), option.description}});
    }
    return {{QStringLiteral("value"), value},
            {QStringLiteral("label"), label},
            {QStringLiteral("mixed"), reading.mixed},
            {QStringLiteral("resettable"), resettable(choice.key, name == QLatin1String("permissions") ? QJsonValue(choice.builtIn)
                                                                                                        : QJsonValue(QJsonValue::Null))},
            {QStringLiteral("options"), options}};
  }

  QVariantMap modelRow() const {
    const auto reading = scope()->read([](const QJsonObject& settings, const QString& projectId) {
      const QJsonValue value = effective(settings, projectId, kModel);
      return value.isObject() ? value : QJsonValue(QJsonValue::Null);
    });
    const QStringList targets = scope()->targets();
    const QString key = reading.mixed ? QString() : keyOf(reading.value.toObject());
    QVariantList models;
    QString label = targets.isEmpty() ? QStringLiteral("Unavailable") : reading.mixed ? QStringLiteral("Mixed") : QStringLiteral("Automatic");
    if (!targets.isEmpty()) {
      for (const QJsonValue& value : usable(scope()->providers(targets.first()))) {
        const QJsonObject entry = value.toObject();
        for (const QJsonValue& slug : entry.value(QLatin1String("models")).toArray()) {
          const QJsonObject model = slug.toObject();
          if (model.value(QLatin1String("isLegacy")).toBool()) continue;
          const QString modelKey = at(entry, "instanceId") + QLatin1Char(':') + at(model, "slug");
          const QString text = providerName(entry) + QStringLiteral(" · ") + (at(model, "name").isEmpty() ? at(model, "slug") : at(model, "name"));
          if (modelKey == key) label = text;
          models.append(QVariantMap{{QStringLiteral("key"), modelKey}, {QStringLiteral("label"), text}});
        }
      }
    }
    // A model no provider offers now still names itself.
    if (!key.isEmpty() && label == QLatin1String("Automatic")) label = key + QStringLiteral(" (Unavailable)");
    return {{QStringLiteral("value"), key},
            {QStringLiteral("label"), label},
            {QStringLiteral("mixed"), reading.mixed},
            {QStringLiteral("automatic"), !reading.mixed && key.isEmpty()},
            {QStringLiteral("none"), !targets.isEmpty() && models.isEmpty()},
            {QStringLiteral("resettable"), resettable(kModel, QJsonValue(QJsonValue::Null))},
            {QStringLiteral("models"), models}};
  }

  // What shows in place of the project, "" when it shows.
  std::pair<QString, QString> status(const QList<sidebar::Project>& checkouts) const {
    if (!scope()->projectScope()) {
      if (NativeShell::of(this)->sidebar()->groups().isEmpty()) {
        return {QStringLiteral("empty"), QStringLiteral("Add a project from the sidebar to configure it here.")};
      }
      return {QStringLiteral("pick"), QStringLiteral("Choose a project to manage its name, icon, checkouts and actions.")};
    }
    if (NativeShell::of(this)->sidebar()->group(scope()->projectKey()) == nullptr) {
      return {QStringLiteral("missing"), QStringLiteral("This project is no longer available.")};
    }
    if (checkouts.isEmpty()) {
      return {QStringLiteral("checkout-missing"), QStringLiteral("This checkout is no longer available in the selected project and environment.")};
    }
    return {QStringLiteral("ready"), {}};
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    bool others = false;
    const QList<sidebar::Project> checkouts = members(&others);
    const auto [state, message] = status(checkouts);
    QVariantMap published{{QStringLiteral("open"), true},
                          {QStringLiteral("status"), state},
                          {QStringLiteral("message"), message},
                          {QStringLiteral("available"), !scope()->targets().isEmpty()},
                          {QStringLiteral("model"), modelRow()}};
    for (const QString& name : {QStringLiteral("permissions"), QStringLiteral("workspace"), QStringLiteral("submodules")}) {
      published.insert(name, choiceRow(name));
    }
    if (state == QLatin1String("ready")) {
      published.insert(QStringLiteral("note"), QStringLiteral("Can't find a setting? Keep this project picked above and hop to any other settings page."));
      // The icon of the first checkout whose environment is connected.
      sidebar::Project representative = checkouts.first();
      for (const sidebar::Project& member : checkouts) {
        if (m_store->environmentOnline(member.environmentId)) {
          representative = member;
          break;
        }
      }
      const QJsonObject row = m_store->projectRow(representative.environmentId, representative.id);
      bool custom = false;
      QVariantList listed;
      for (const sidebar::Project& member : checkouts) {
        const QJsonObject own = m_store->projectRow(member.environmentId, member.id);
        custom = custom || !own.value(QLatin1String("projectIcon")).isNull() && !own.value(QLatin1String("projectIcon")).isUndefined() ||
                 !at(own, "faviconPath").isEmpty();
        listed.append(QVariantMap{{QStringLiteral("key"), member.key()},
                                  {QStringLiteral("environment"), scope()->label(member.environmentId)},
                                  {QStringLiteral("path"), member.workspaceRoot}});
      }
      const int count = int(checkouts.size());
      published.insert(QStringLiteral("name"), displayName());
      published.insert(QStringLiteral("icon"),
                       QVariantMap{{QStringLiteral("label"), iconLabel(row)},
                                   {QStringLiteral("emoji"), at(row.value(QLatin1String("projectIcon")).toObject(), "emoji")},
                                   {QStringLiteral("custom"), custom}});
      published.insert(QStringLiteral("checkouts"), listed);
      published.insert(
          QStringLiteral("removal"),
          QVariantMap{
              {QStringLiteral("title"), others ? QStringLiteral("Remove checkout")
                                        : count > 1 ? QStringLiteral("Remove this project everywhere")
                                                    : QStringLiteral("Remove project")},
              {QStringLiteral("description"),
               others ? QStringLiteral("Deletes the selected machine's checkout entries and their threads. Other machines and files on disk are not touched.")
               : count > 1
                   ? QStringLiteral("Deletes all %1 checkout entries and their threads on every machine. Files on disk are not touched.").arg(count)
                   : QStringLiteral("Deletes the project entry and its threads. Files on disk are not touched.")},
              {QStringLiteral("button"), others ? QStringLiteral("Remove checkout")
                                         : count > 1 ? QStringLiteral("Remove all entries")
                                                     : QStringLiteral("Remove project")}});
    }
    m_bridge->publish(kKey, published);
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
};

namespace {

const NativeControllerRegistrar<ProjectSettingsController> registrar(QStringLiteral("projectSettings"), {kKey});

}  // namespace
