// Settings → Project, Actions (the web's ProjectActionsSettings): the actions
// every project on the selected environments starts with
// (`defaultProjectScripts`), or with a project picked its own list, kept as
// that project's override on each environment with a checkout of it. A
// project without its own list offers its environment's defaults
// (ProjectScripts.h). An environment too old for project overrides is left
// out of a project's changes.
//
// Publishes `projectActions`: {open, project (one is picked), actions: [{id,
// name, command, setup, preview}] (the first selected environment's), mixed
// (the environments' lists differ), own (the project has its own list),
// importable: [{name, command}] (hal-c2.json's, not yet listed), fileInvalid
// (the checkout's hal-c2.json does not parse)}.
//
// Actions (`projectActions.`): `add {name, command, runOnWorktreeCreate?,
// previewUrl?}`, `remove {id}`, `reset` (a project inherits again), `import
// {name}` (one of `importable`).

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QRegularExpression>
#include <QSet>

#include <functional>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ProjectScripts.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("projectActions");
const QString kSection = QStringLiteral("/settings/projects");
const QString kScripts = QStringLiteral("defaultProjectScripts");
const QString kOverrides = QStringLiteral("projectSettingsOverrides");
const QString kFile = QStringLiteral("hal-c2.json");

QString text(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

// projectScripts.ts normalizeScriptId, made unique among `taken`.
QString scriptId(const QString& name, const QSet<QString>& taken) {
  static const QRegularExpression other(QStringLiteral("[^a-z0-9]+"));
  QString base = name.trimmed().toLower().replace(other, QStringLiteral("-"));
  while (base.startsWith(QLatin1Char('-'))) base.remove(0, 1);
  while (base.endsWith(QLatin1Char('-'))) base.chop(1);
  if (base.isEmpty()) base = QStringLiteral("script");
  if (!taken.contains(base)) return base;
  for (int suffix = 2;; ++suffix) {
    const QString candidate = QStringLiteral("%1-%2").arg(base).arg(suffix);
    if (!taken.contains(candidate)) return candidate;
  }
}

class ProjectActionsController : public QObject, public NativeController {
public:
  ProjectActionsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* shell = NativeShell::of(this);
    auto* navigation = shell->controller<NavigationController>();
    const auto follow = [this, navigation] {
      m_open = navigation->route().kind == QLatin1String("settings") && navigation->route().section == kSection;
      update();
    };
    connect(navigation, &NavigationController::changed, this, follow);
    connect(scope(), &SettingsScopeController::changed, this, &ProjectActionsController::update);
    connect(m_store, &ShellStore::changed, this, &ProjectActionsController::update);
    follow();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("projectActions."))) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("projectActions.add")) {
      add(QJsonObject::fromVariantMap(input));
    } else if (action == QLatin1String("projectActions.remove")) {
      const QString id = input.value(QStringLiteral("id")).toString();
      persist([id](QJsonArray scripts) {
        for (qsizetype i = scripts.size() - 1; i >= 0; --i) {
          if (text(scripts.at(i).toObject(), "id") == id) scripts.removeAt(i);
        }
        return QJsonValue(scripts);
      });
    } else if (action == QLatin1String("projectActions.reset")) {
      // No list of its own: the environment's defaults again.
      if (scope()->projectScope()) persist([](QJsonArray) { return QJsonValue(QJsonValue::Undefined); });
    } else if (action == QLatin1String("projectActions.import")) {
      for (const QJsonValue& script : importable()) {
        if (text(script.toObject(), "name") == input.value(QStringLiteral("name")).toString()) add(script.toObject());
      }
    }
    return true;
  }

private:
  struct Target {
    QString environmentId;
    QString projectId;  // empty at environment scope
    QJsonObject settings;
  };

  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The connected environments a change is written to; at project scope only
  // those whose server keeps project overrides.
  QList<Target> targets() const {
    QList<Target> result;
    const bool project = scope()->projectScope();
    const QStringList old = project ? scope()->lacking(kOverrides) : QStringList();
    for (const QString& environmentId : scope()->targets()) {
      const auto settings = scope()->settings(environmentId);
      if (!settings || old.contains(environmentId)) continue;
      result.append({environmentId, project ? scope()->projectOn(environmentId) : QString(), *settings});
    }
    return result;
  }

  QJsonArray ownScripts(const Target& target) const {
    return m_store->projectRow(target.environmentId, target.projectId).value(QLatin1String("scripts")).toArray();
  }

  QJsonArray scriptsOn(const Target& target) const {
    if (target.projectId.isEmpty()) return target.settings.value(kScripts).toArray();
    return projectScripts::resolve(target.settings, target.projectId, ownScripts(target));
  }

  // hal-c2.json's actions that are not listed yet, by name or command.
  QJsonArray importable() const {
    const QList<Target> selected = targets();
    const QJsonArray listed = selected.isEmpty() ? QJsonArray() : scriptsOn(selected.first());
    QJsonArray result;
    for (const QJsonValue& value : m_fileScripts) {
      const QJsonObject script = value.toObject();
      const bool known = std::any_of(listed.cbegin(), listed.cend(), [&script](const QJsonValue& other) {
        return text(other.toObject(), "command") == text(script, "command") ||
               text(other.toObject(), "name").compare(text(script, "name"), Qt::CaseInsensitive) == 0;
      });
      if (!known) result.append(script);
    }
    return result;
  }

  void add(const QJsonObject& input) {
    const QString name = text(input, "name").trimmed();
    const QString command = text(input, "command").trimmed();
    if (name.isEmpty() || command.isEmpty()) return;
    QSet<QString> taken;
    for (const Target& target : targets()) {
      for (const QJsonValue& script : scriptsOn(target)) taken.insert(text(script.toObject(), "id"));
      for (const QJsonValue& script : target.settings.value(kScripts).toArray()) taken.insert(text(script.toObject(), "id"));
    }
    const bool setup = input.value(QLatin1String("runOnWorktreeCreate")).toBool();
    QJsonObject script{{QStringLiteral("id"), scriptId(name, taken)},
                       {QStringLiteral("name"), name},
                       {QStringLiteral("command"), command},
                       {QStringLiteral("icon"), text(input, "icon").isEmpty() ? QStringLiteral("play") : text(input, "icon")},
                       {QStringLiteral("runOnWorktreeCreate"), setup}};
    if (setup && input.contains(QLatin1String("async"))) script.insert(QStringLiteral("async"), input.value(QLatin1String("async")));
    if (!text(input, "previewUrl").trimmed().isEmpty()) {
      script.insert(QStringLiteral("previewUrl"), text(input, "previewUrl").trimmed());
      script.insert(QStringLiteral("autoOpenPreview"), input.value(QLatin1String("autoOpenPreview")).toBool());
    }
    persist([script, setup](QJsonArray scripts) {
      // One action is the setup script.
      if (setup) {
        for (qsizetype i = 0; i < scripts.size(); ++i) {
          QJsonObject other = scripts.at(i).toObject();
          other.insert(QStringLiteral("runOnWorktreeCreate"), false);
          scripts.replace(i, other);
        }
      }
      scripts.append(script);
      return QJsonValue(scripts);
    });
  }

  // Applies `transform` to each target's list; undefined drops a project's own list.
  void persist(const std::function<QJsonValue(QJsonArray)>& transform) {
    const QList<Target> selected = targets();
    if (selected.isEmpty()) {
      NativeShell::of(this)->controller<ToastController>()->error(QStringLiteral("Actions not saved"),
                                                                 QStringLiteral("No available machine, or another action change is saving."));
      return;
    }
    // What each target's list is now, by its environment and project.
    QHash<QString, QJsonArray> current;
    QSet<QString> environments;
    for (const Target& target : selected) {
      current.insert(target.projectId, scriptsOn(target));
      if (target.projectId.isEmpty()) environments.insert(target.environmentId);
    }
    const bool project = scope()->projectScope();
    scope()->write(
        [transform, current, project](QJsonObject settings, const QString& projectId) {
          if (project) {
            // An environment left out (too old for overrides) is not written to.
            if (!current.contains(projectId)) return settings;
            return SettingsScopeController::withOverride(settings, projectId, kScripts, transform(current.value(projectId)));
          }
          const QJsonValue next = transform(settings.value(kScripts).toArray());
          settings.insert(kScripts, next.isArray() ? next : QJsonValue(QJsonArray()));
          return settings;
        },
        QStringLiteral("Failed to save project actions"));
  }

  // Reads the picked project's hal-c2.json from its first checkout.
  void readFile() {
    QString environmentId;
    QString root;
    if (m_open && scope()->projectScope()) {
      for (const QString& candidate : scope()->targets()) {
        root = text(m_store->projectRow(candidate, scope()->projectOn(candidate)), "workspaceRoot");
        if (root.isEmpty()) continue;
        environmentId = candidate;
        break;
      }
    }
    const QString key = environmentId + QLatin1Char('\n') + root;
    if (key == m_fileKey) return;
    m_fileKey = key;
    m_fileScripts = {};
    m_fileInvalid = false;
    if (environmentId.isEmpty()) return;
    m_client->call(this, environmentId, QStringLiteral("projects.readFile"),
                   QJsonObject{{QStringLiteral("cwd"), root}, {QStringLiteral("relativePath"), kFile}},
                   [this, key](const QJsonValue& result, const std::optional<QString>& error) {
                     // No hal-c2.json is no actions to import.
                     if (key != m_fileKey || error || result.toObject().value(QLatin1String("truncated")).toBool()) return;
                     parse(result.toObject().value(QLatin1String("contents")).toString());
                     publish();
                   });
  }

  // packages/shared halC2ProjectFile.ts: a file that does not decode is ignored whole.
  void parse(const QString& contents) {
    const QJsonDocument document = QJsonDocument::fromJson(contents.toUtf8());
    const QJsonValue scripts = document.object().value(QLatin1String("scripts"));
    bool valid = document.isObject() && (scripts.isUndefined() || scripts.isArray());
    for (const QJsonValue& script : scripts.toArray()) {
      valid = valid && script.isObject() && !text(script.toObject(), "name").trimmed().isEmpty() &&
              !text(script.toObject(), "command").trimmed().isEmpty();
    }
    m_fileInvalid = !valid;
    m_fileScripts = valid ? scripts.toArray() : QJsonArray();
  }

  void update() {
    if (!m_active) return;
    readFile();
    publish();
  }

  void publish() {
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    const QList<Target> selected = targets();
    const QJsonArray listed = selected.isEmpty() ? QJsonArray() : scriptsOn(selected.first());
    bool mixed = false;
    for (const Target& target : selected) mixed = mixed || scriptsOn(target) != listed;
    QVariantList actions;
    for (const QJsonValue& value : listed) {
      const QJsonObject script = value.toObject();
      actions.append(QVariantMap{{QStringLiteral("id"), text(script, "id")},
                                 {QStringLiteral("name"), text(script, "name")},
                                 {QStringLiteral("command"), text(script, "command")},
                                 {QStringLiteral("setup"), script.value(QLatin1String("runOnWorktreeCreate")).toBool()},
                                 {QStringLiteral("preview"), !text(script, "previewUrl").isEmpty()}});
    }
    QVariantList imports;
    for (const QJsonValue& value : importable()) {
      imports.append(QVariantMap{{QStringLiteral("name"), text(value.toObject(), "name")}, {QStringLiteral("command"), text(value.toObject(), "command")}});
    }
    const bool project = scope()->projectScope();
    bool own = false;
    for (const Target& target : selected) own = own || (project && !projectScripts::inherits(target.settings, target.projectId, ownScripts(target)));
    m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), true},
                                        {QStringLiteral("project"), project},
                                        {QStringLiteral("available"), !selected.isEmpty()},
                                        {QStringLiteral("actions"), actions},
                                        {QStringLiteral("mixed"), mixed},
                                        {QStringLiteral("own"), own},
                                        {QStringLiteral("importable"), imports},
                                        {QStringLiteral("fileInvalid"), m_fileInvalid}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QString m_fileKey;
  QJsonArray m_fileScripts;
  bool m_fileInvalid = false;
};

const NativeControllerRegistrar<ProjectActionsController> registrar(QStringLiteral("projectActions"), {kKey});

}  // namespace
