// Settings → Storage: the cleanup
// rules the MC sweeps by (HalC2.StorageCleanup), across the settings scope
// (SettingsScopeController). At a project scope only the worktree rules show,
// as the project's `worktreeCleanup` override: inherited, off, or its own
// rules.
//
// Publishes `storageSettings`: {status: ready | loading | unsupported,
// notice (why nothing shows), eligible [{id, label}] (environments that can
// show it), projectScope, mode: {value: inherit | off | custom, mixed},
// worktrees and artifacts: [{key, title, description, days (a retention in
// days rather than a switch), value (bool, or days and null for off),
// mixed}] (worktrees empty while a project inherits or is off)}.
//
// Actions: `storageSettings.set {key, value}` (a days rule takes a number of
// days, or null to turn it off), `storageSettings.mode {mode}`.

#include <QJsonObject>
#include <QVariantMap>

#include <algorithm>
#include <cmath>

#include "NativeController.h"
#include "NativeShell.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"

class StorageSettingsController : public QObject, public NativeController {
public:
  StorageSettingsController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(scope(), &SettingsScopeController::changed, this, &StorageSettingsController::publish);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("storageSettings."))) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("storageSettings.set")) {
      const QString key = input.value(QStringLiteral("key")).toString();
      const Rule* rule = find(key);
      if (rule == nullptr) return true;
      QJsonValue value = QJsonValue::fromVariant(input.value(QStringLiteral("value")));
      if (rule->days) {
        value = value.isDouble() ? QJsonValue(std::clamp(int(std::lround(value.toDouble())), 1, 3650)) : QJsonValue(QJsonValue::Null);
      } else {
        value = value.toBool();
      }
      if (scope()->projectScope()) {
        if (!rule->worktree) return true;
        scope()->write([key, value](QJsonObject settings, const QString& projectId) {
          QJsonObject rules = worktreeRules(settings, projectId);
          rules.insert(key, value);
          return SettingsScopeController::withOverride(
              settings, projectId, QStringLiteral("worktreeCleanup"),
              QJsonObject{{QStringLiteral("mode"), QStringLiteral("custom")}, {QStringLiteral("rules"), rules}});
        });
      } else {
        scope()->write([key, value](QJsonObject settings, const QString&) {
          QJsonObject storage = settings.value(QLatin1String("storageCleanup")).toObject();
          storage.insert(key, value);
          settings.insert(QStringLiteral("storageCleanup"), storage);
          return settings;
        });
      }
    } else if (action == QLatin1String("storageSettings.mode")) {
      const QString mode = input.value(QStringLiteral("mode")).toString();
      if (!scope()->projectScope()) return true;
      scope()->write([mode](QJsonObject settings, const QString& projectId) {
        QJsonValue value(QJsonValue::Undefined);
        if (mode == QLatin1String("off")) {
          value = QJsonObject{{QStringLiteral("mode"), QStringLiteral("off")}};
        } else if (mode == QLatin1String("custom")) {
          // Custom rules start from the ones the project had.
          value = QJsonObject{{QStringLiteral("mode"), QStringLiteral("custom")}, {QStringLiteral("rules"), worktreeRules(settings, projectId)}};
        }
        return SettingsScopeController::withOverride(settings, projectId, QStringLiteral("worktreeCleanup"), value);
      });
    }
    return true;
  }

private:
  struct Rule {
    QString key, title, description;
    bool days;
    bool worktree;
  };

  static const QList<Rule>& rules() {
    static const QList<Rule> list{
        {QStringLiteral("worktreeOnDelete"), QStringLiteral("Delete worktrees with deleted threads"),
         QStringLiteral("Remove unused worktrees when active or archived threads are deleted. Worktrees with local changes are kept."), false, true},
        {QStringLiteral("worktreeAfterDays"), QStringLiteral("Delete inactive worktrees"),
         QStringLiteral("Remove worktrees after their threads have been inactive for this many days. Branches and thread history are kept."), true,
         true},
        {QStringLiteral("worktreeOnMerge"), QStringLiteral("Delete merged worktrees"),
         QStringLiteral("Remove worktrees whose pull request is merged and whose commits are included in the default branch."), false, true},
        {QStringLiteral("worktreeUnchanged"), QStringLiteral("Delete unchanged worktrees"),
         QStringLiteral("Remove worktrees with no commits beyond the default branch."), false, true},
        {QStringLiteral("browserArtifactsAfterDays"), QStringLiteral("Delete old browser artifacts"),
         QStringLiteral("Delete saved browser captures after this many days. Older capture links will no longer open."), true, false},
        {QStringLiteral("logsAfterDays"), QStringLiteral("Delete old rotated logs"),
         QStringLiteral("Delete inactive rotated log files after this many days. Current logs are kept."), true, false},
    };
    return list;
  }

  static const Rule* find(const QString& key) {
    for (const Rule& rule : rules()) {
      if (rule.key == key) return &rule;
    }
    return nullptr;
  }

  // The project's `worktreeCleanup` mode: inherit, off or custom.
  static QString mode(const QJsonObject& settings, const QString& projectId) {
    const QJsonValue policy = SettingsScopeController::overrideOf(settings, projectId, QStringLiteral("worktreeCleanup"));
    const QString mode = policy.toObject().value(QLatin1String("mode")).toString();
    return mode == QLatin1String("off") || mode == QLatin1String("custom") ? mode : QStringLiteral("inherit");
  }

  // resolveWorktreeCleanup: the rules a project (or, with none, the
  // environment) sweeps worktrees by, each with its default.
  static QJsonObject worktreeRules(const QJsonObject& settings, const QString& projectId) {
    QJsonObject policy = settings.value(QLatin1String("worktreeCleanup")).toObject();
    if (!projectId.isEmpty() && mode(settings, projectId) != QLatin1String("inherit")) {
      policy = SettingsScopeController::overrideOf(settings, projectId, QStringLiteral("worktreeCleanup")).toObject();
    }
    const QString policyMode = policy.value(QLatin1String("mode")).toString();
    const QJsonObject source = policyMode == QLatin1String("custom") ? policy.value(QLatin1String("rules")).toObject()
                               : policyMode == QLatin1String("off")  ? QJsonObject{}
                                                                     : settings.value(QLatin1String("storageCleanup")).toObject();
    QJsonObject result;
    for (const Rule& rule : rules()) {
      if (!rule.worktree) continue;
      const QJsonValue value = source.value(rule.key);
      result.insert(rule.key, rule.days ? (value.isDouble() ? value : QJsonValue(QJsonValue::Null)) : QJsonValue(value.toBool()));
    }
    return result;
  }

  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  void publish() {
    if (!m_active) return;
    SettingsScopeController* scope = this->scope();
    const bool project = scope->projectScope();
    QVariantMap state{{QStringLiteral("projectScope"), project}};
    const QStringList lacking = scope->lacking(project ? QStringLiteral("projectWorktreeCleanup") : QStringLiteral("storageCleanup"));
    const auto reading = scope->read([](const QJsonObject& settings, const QString&) { return QJsonValue(settings); });
    if (!lacking.isEmpty()) {
      QVariantList eligible;
      for (const QString& environmentId : scope->targets()) {
        if (!lacking.contains(environmentId)) {
          eligible.append(QVariantMap{{QStringLiteral("id"), environmentId}, {QStringLiteral("label"), scope->label(environmentId)}});
        }
      }
      state.insert(QStringLiteral("status"), QStringLiteral("unsupported"));
      state.insert(QStringLiteral("notice"),
                   project ? QStringLiteral("Update the selected machines to configure project worktree cleanup.")
                           : QStringLiteral("Update the selected environments to use storage cleanup, or choose a machine that supports it."));
      state.insert(QStringLiteral("eligible"), project ? QVariantList{} : eligible);
    } else if (reading.known == 0) {
      state.insert(QStringLiteral("status"), QStringLiteral("loading"));
    } else {
      state.insert(QStringLiteral("status"), QStringLiteral("ready"));
    }
    const auto modeReading = scope->read([](const QJsonObject& settings, const QString& projectId) { return QJsonValue(mode(settings, projectId)); });
    state.insert(QStringLiteral("mode"), QVariantMap{{QStringLiteral("value"), modeReading.value.toString(QStringLiteral("inherit"))},
                                                     {QStringLiteral("mixed"), modeReading.mixed}});
    const bool showWorktrees = !project || (!modeReading.mixed && modeReading.value.toString() == QLatin1String("custom"));
    QVariantList worktrees, artifacts;
    for (const Rule& rule : rules()) {
      if (rule.worktree ? !showWorktrees : project) continue;
      const QString key = rule.key;
      const auto value = scope->read([key](const QJsonObject& settings, const QString& projectId) {
        if (find(key)->worktree) return worktreeRules(settings, projectId).value(key);
        const QJsonValue value = settings.value(QLatin1String("storageCleanup")).toObject().value(key);
        return value.isDouble() ? value : QJsonValue(QJsonValue::Null);
      });
      (rule.worktree ? worktrees : artifacts)
          .append(QVariantMap{{QStringLiteral("key"), rule.key},
                              {QStringLiteral("title"), rule.title},
                              {QStringLiteral("description"), rule.description},
                              {QStringLiteral("days"), rule.days},
                              {QStringLiteral("value"), value.value.isUndefined() ? QVariant::fromValue(nullptr) : value.value.toVariant()},
                              {QStringLiteral("mixed"), value.mixed}});
    }
    state.insert(QStringLiteral("worktrees"), worktrees);
    state.insert(QStringLiteral("artifacts"), artifacts);
    m_bridge->publish(QStringLiteral("storageSettings"), state);
  }

  ShellBridge* m_bridge;
  bool m_active = false;
};

namespace {
const NativeControllerRegistrar<StorageSettingsController> registrar(QStringLiteral("storageSettings"), {QStringLiteral("storageSettings")});
}  // namespace
