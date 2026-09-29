// Settings → Source Control, natively (the web's SourceControlSettingsPanel):
// the repository defaults, the version control and hosting tools the node
// finds (`server.discoverSourceControl`), Git's background fetch interval, and
// how source control text is written. The settings rows follow the settings
// scope (SettingsScopeController), a project's as its overrides; discovery
// scans the scope's first connected environment, which names itself when
// several are selected.
//
// Publishes `sourceControlSettings`: {open, projectScope,
// discovery: {status: none | loading | ready | error, scanning, message, and
// what shows instead of the tools (title and detail, "" while they show),
// suffix (" · <environment>" when several are selected), versionControl and
// providers: [{kind, label, version, comingSoon, available, enabled,
// authLabel ("" for a version control tool), authWarning, summary,
// hasAccount, account (only while revealed), revealed, git}]},
// fetchInterval: {seconds, preset, custom, mixed, environmentWide},
// autoPull, templates: {value, mixed, overridden},
// mergeMethod: {value: last | merge | squash | rebase, mixed, overridden},
// writingStyle: {mode, mixed, description, instructions, instructionsMixed,
// dirty, overridden}, writerModel: {available, on, mixed, key, canEnable,
// overridden, models: [{key, label, reason}]}}.
//
// Actions (`sourceControlSettings.`): `scan`, `reveal {kind, revealed}`,
// `fetchInterval {seconds}`, `resetFetchInterval`, `autoPull {enabled}`,
// `mergeMethod {method}`, `writingMode {mode}`, `instructions {text}` (with
// the style mixed, sets custom instructions everywhere), `templates
// {enabled}`, `writerModel {enabled}`, `pickWriterModel {key}` ("instance:
// model"), and `reset {key}`: at a project scope the override goes, otherwise
// the environment default comes back.

#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QSet>
#include <QVariantMap>

#include <algorithm>
#include <cmath>

#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("sourceControlSettings");
const QString kSection = QStringLiteral("/settings/source-control");
const QString kFetchKey = QStringLiteral("automaticGitFetchInterval");
const QString kStyle = QStringLiteral("sourceControlWritingStyle");
const QString kWriter = QStringLiteral("sourceControlWriterModelSelection");

QString at(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

// An Option from the wire: {_tag: "Some", value} or {_tag: "None"}; a bare
// value is taken as is.
QString option(const QJsonValue& value) {
  if (value.isObject()) {
    const QJsonObject tagged = value.toObject();
    return tagged.value(QLatin1String("_tag")) == QLatin1String("Some") ? tagged.value(QLatin1String("value")).toString().trimmed() : QString();
  }
  return value.toString().trimmed();
}

// The node's background activity presets' Git fetch intervals
// (HalC2.BackgroundPolicy), in seconds.
int presetFetchSeconds(const QString& profile) {
  if (profile == QLatin1String("performance")) return 15;
  if (profile == QLatin1String("battery-saver")) return 0;
  return 30;
}

QString baseProfile(const QJsonObject& activity) {
  const QString profile = activity.value(QLatin1String("profile")).toString();
  const QString base = profile == QLatin1String("custom") ? activity.value(QLatin1String("baseProfile")).toString() : profile;
  return base == QLatin1String("performance") || base == QLatin1String("battery-saver") ? base : QStringLiteral("balanced");
}

int fetchSeconds(const QJsonObject& settings) {
  const QJsonObject activity = settings.value(QLatin1String("backgroundActivity")).toObject();
  const QJsonObject overrides = activity.value(QLatin1String("overrides")).toObject();
  if (activity.value(QLatin1String("profile")) == QLatin1String("custom") && overrides.value(kFetchKey).isDouble()) {
    return int(std::lround(overrides.value(kFetchKey).toDouble() / 1000));
  }
  return presetFetchSeconds(baseProfile(activity));
}

// The web's backgroundActivityOverrideSettings: a custom profile on the
// current base, keeping a custom profile's other overrides.
QJsonObject withFetchSeconds(QJsonObject settings, std::optional<int> seconds) {
  const QJsonObject activity = settings.value(QLatin1String("backgroundActivity")).toObject();
  QJsonObject overrides = activity.value(QLatin1String("profile")) == QLatin1String("custom")
                              ? activity.value(QLatin1String("overrides")).toObject()
                              : QJsonObject{};
  if (seconds) overrides.insert(kFetchKey, qint64(*seconds) * 1000);
  else overrides.remove(kFetchKey);
  settings.insert(QStringLiteral("backgroundActivity"), QJsonObject{{QStringLiteral("schemaVersion"), 1},
                                                                    {QStringLiteral("profile"), QStringLiteral("custom")},
                                                                    {QStringLiteral("baseProfile"), baseProfile(activity)},
                                                                    {QStringLiteral("overrides"), overrides}});
  return settings;
}

// The defaults a document leaves out (ServerSettings).
QJsonValue fallback(const QString& key) {
  if (key == QLatin1String("defaultAutoPull")) return false;
  if (key == kStyle) {
    return QJsonObject{{QStringLiteral("mode"), QStringLiteral("repo_conventions")},
                       {QStringLiteral("customInstructions"), QString()},
                       {QStringLiteral("followChangeRequestTemplates"), true}};
  }
  return QJsonValue::Null;
}

// A key's value for the project (its override), or the environment's.
QJsonValue effective(const QJsonObject& settings, const QString& projectId, const QString& key) {
  QJsonValue value = settings.value(key);
  if (!projectId.isEmpty()) {
    const QJsonValue own = SettingsScopeController::overrideOf(settings, projectId, key);
    if (!own.isUndefined()) value = own;
  }
  if (key == kStyle) {
    QJsonObject style = fallback(kStyle).toObject();
    const QJsonObject set = value.toObject();
    for (auto it = set.begin(); it != set.end(); ++it) style.insert(it.key(), it.value());
    return style;
  }
  return value.isUndefined() || value.isNull() ? fallback(key) : value;
}

struct Mode {
  QString id, label, description;
};

const QList<Mode>& modes() {
  static const QList<Mode> list{
      {QStringLiteral("repo_conventions"), QStringLiteral("Repository conventions"),
       QStringLiteral("In each project, matches recent change descriptions and change request titles.")},
      {QStringLiteral("conventional_commits"), QStringLiteral("Conventional Commits"),
       QStringLiteral("Use Conventional Commit prefixes and keep change request text concise.")},
      {QStringLiteral("custom"), QStringLiteral("Custom instructions"),
       QStringLiteral("Use your instructions for change descriptions and change requests in every project.")},
  };
  return list;
}

QVariant variant(const QJsonValue& value) {
  return value.isUndefined() || value.isNull() ? QVariant::fromValue(nullptr) : value.toVariant();
}

QString providerName(const QJsonObject& entry) {
  return at(entry, "displayName").isEmpty() ? at(entry, "instanceId") : at(entry, "displayName");
}

// Why a provider's models cannot write source control text, "" when they can.
QString providerProblem(const QJsonObject& entry) {
  if (!entry.value(QLatin1String("enabled")).toBool(true)) return QStringLiteral("%1 is turned off.").arg(providerName(entry));
  if (!entry.value(QLatin1String("installed")).toBool(true) || at(entry, "availability") == QLatin1String("unavailable")) {
    return QStringLiteral("%1 is not available.").arg(providerName(entry));
  }
  if (at(entry.value(QLatin1String("auth")).toObject(), "status") == QLatin1String("unauthenticated")) {
    return QStringLiteral("%1 is not signed in.").arg(providerName(entry));
  }
  return {};
}

QString keyOf(const QJsonObject& selection) {
  return selection.isEmpty() ? QString() : at(selection, "instanceId") + QLatin1Char(':') + at(selection, "model");
}

}  // namespace

class SourceControlSettingsController : public QObject, public NativeController {
public:
  SourceControlSettingsController(ShellBridge* bridge, NodeClient* client, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    m_bridge->claimKey(kKey);
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    connect(navigation, &NavigationController::changed, this, [this, navigation] {
      const bool open = navigation->route().kind == QLatin1String("settings") && navigation->route().section == kSection;
      if (open == m_open) return;
      m_open = open;
      m_scanned.clear();
      follow();
    });
    connect(scope(), &SettingsScopeController::changed, this, &SourceControlSettingsController::follow);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(kKey + QLatin1Char('.'))) return false;
    const QString name = action.mid(kKey.size() + 1);
    const QVariantMap input = payload.toMap();
    if (name == QLatin1String("scan")) {
      scan();
    } else if (name == QLatin1String("reveal")) {
      const QString kind = input.value(QStringLiteral("kind")).toString();
      if (input.value(QStringLiteral("revealed")).toBool()) m_revealed.insert(kind);
      else m_revealed.remove(kind);
      publish();
    } else if (name == QLatin1String("fetchInterval") || name == QLatin1String("resetFetchInterval")) {
      // Background activity is the environment's; a project cannot override it.
      if (scope()->projectScope()) return true;
      std::optional<int> seconds;
      if (name == QLatin1String("fetchInterval")) {
        const double value = input.value(QStringLiteral("seconds")).toDouble();
        seconds = std::isfinite(value) ? std::max(0, int(std::lround(value))) : 0;
      }
      scope()->write([seconds](QJsonObject settings, const QString&) { return withFetchSeconds(settings, seconds); });
    } else if (name == QLatin1String("autoPull")) {
      set(QStringLiteral("defaultAutoPull"), [enabled = input.value(QStringLiteral("enabled")).toBool()](const QJsonValue&) { return enabled; });
    } else if (name == QLatin1String("mergeMethod")) {
      const QString method = input.value(QStringLiteral("method")).toString();
      const bool known = method == QLatin1String("merge") || method == QLatin1String("squash") || method == QLatin1String("rebase");
      set(QStringLiteral("pullRequestMergeMethod"), [method, known](const QJsonValue&) { return known ? QJsonValue(method) : QJsonValue::Null; });
    } else if (name == QLatin1String("writingMode")) {
      const QString mode = input.value(QStringLiteral("mode")).toString();
      if (std::none_of(modes().begin(), modes().end(), [&](const Mode& entry) { return entry.id == mode; })) return true;
      setStyle({{QStringLiteral("mode"), mode}});
    } else if (name == QLatin1String("instructions")) {
      const QString text = input.value(QStringLiteral("text")).toString().trimmed();
      const auto reading = scope()->read([](const QJsonObject& settings, const QString& projectId) {
        const QJsonObject style = effective(settings, projectId, kStyle).toObject();
        return QJsonValue(QJsonArray{style.value(QLatin1String("mode")), style.value(QLatin1String("customInstructions"))});
      });
      // Instructions for all: the one style every selected environment takes.
      QJsonObject patch{{QStringLiteral("customInstructions"), text}};
      if (reading.mixed) patch.insert(QStringLiteral("mode"), QStringLiteral("custom"));
      setStyle(patch);
    } else if (name == QLatin1String("templates")) {
      setStyle({{QStringLiteral("followChangeRequestTemplates"), input.value(QStringLiteral("enabled")).toBool()}});
    } else if (name == QLatin1String("writerModel")) {
      if (!input.value(QStringLiteral("enabled")).toBool()) {
        set(kWriter, [](const QJsonValue&) { return QJsonValue::Null; });
      } else if (const QString key = defaultWriter(); !key.isEmpty()) {
        pickWriter(key);
      }
    } else if (name == QLatin1String("pickWriterModel")) {
      pickWriter(input.value(QStringLiteral("key")).toString());
    } else if (name == QLatin1String("reset")) {
      reset(input.value(QStringLiteral("key")).toString());
    }
    return true;
  }

private:
  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The environment discovery scans: the scope's first connected one.
  QString scanned() const {
    const QStringList targets = scope()->targets();
    return targets.isEmpty() ? QString() : targets.first();
  }

  void follow() {
    if (m_open && !scanned().isEmpty() && !m_scanned.contains(scanned())) scan();
    publish();
  }

  void scan() {
    const QString environmentId = scanned();
    if (!m_open || environmentId.isEmpty()) return;
    m_scanned.insert(environmentId);
    Discovery& discovery = m_discovery[environmentId];
    discovery.scanning = true;
    const int seq = ++discovery.seq;
    const QPointer<SourceControlSettingsController> self(this);
    m_client->call(this, environmentId, QStringLiteral("server.discoverSourceControl"), QJsonObject{},
                   [self, environmentId, seq](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!self) return;
                     Discovery& discovery = self->m_discovery[environmentId];
                     if (discovery.seq != seq) return;
                     discovery.scanning = false;
                     // A failed scan says so rather than showing what an older one found.
                     discovery.error = error ? (error->isEmpty() ? QStringLiteral("The scan failed.") : *error) : QString();
                     discovery.result = error ? QJsonObject() : result.toObject();
                     discovery.loaded = !error;
                     self->publish();
                   });
    publish();
  }

  // Writes `key` for the scope: a project's override, or the environment's value.
  void set(const QString& key, const std::function<QJsonValue(const QJsonValue& current)>& next, const QString& failureTitle = {}) {
    scope()->write(
        [key, next](QJsonObject settings, const QString& projectId) {
          const QJsonValue value = next(effective(settings, projectId, key));
          if (!projectId.isEmpty()) return SettingsScopeController::withOverride(settings, projectId, key, value);
          settings.insert(key, value);
          return settings;
        },
        failureTitle);
  }

  // The writing style is one object; a change keeps its other fields as each
  // environment (or project) has them.
  void setStyle(const QJsonObject& patch) {
    set(kStyle, [patch](const QJsonValue& current) {
      QJsonObject style = current.toObject();
      for (auto it = patch.begin(); it != patch.end(); ++it) style.insert(it.key(), it.value());
      return style;
    });
  }

  void reset(const QString& key) {
    if (key != QLatin1String("defaultAutoPull") && key != QLatin1String("pullRequestMergeMethod") && key != kStyle &&
        key != QLatin1String("followChangeRequestTemplates") && key != kWriter) {
      return;
    }
    scope()->write([key](QJsonObject settings, const QString& projectId) {
      if (!projectId.isEmpty()) {
        // Templates live in the style object; the override goes with it.
        return SettingsScopeController::withOverride(settings, projectId, key == QLatin1String("followChangeRequestTemplates") ? kStyle : key,
                                                     QJsonValue(QJsonValue::Undefined));
      }
      if (key == kStyle || key == QLatin1String("followChangeRequestTemplates")) {
        QJsonObject style = effective(settings, {}, kStyle).toObject();
        const QJsonObject defaults = fallback(kStyle).toObject();
        const QStringList fields = key == kStyle ? QStringList{QStringLiteral("mode"), QStringLiteral("customInstructions")}
                                                 : QStringList{QStringLiteral("followChangeRequestTemplates")};
        for (const QString& field : fields) style.insert(field, defaults.value(field));
        settings.insert(kStyle, style);
      } else {
        settings.insert(key, fallback(key));
      }
      return settings;
    });
  }

  // The providers of the first target that can write text.
  QJsonArray writers() const {
    QJsonArray result;
    for (const QJsonValue& value : scope()->providers(scanned())) {
      if (value.toObject().value(QLatin1String("supportsTextGeneration")) == QJsonValue(false)) continue;
      result.append(value);
    }
    return result;
  }

  // What a model cannot be picked for across the scope, "" when it can:
  // every target must offer it from a usable provider.
  QString writerProblem(const QString& key) const {
    const qsizetype colon = key.indexOf(QLatin1Char(':'));
    if (colon <= 0) return QStringLiteral("Choose a model.");
    const QString instanceId = key.left(colon);
    const QString slug = key.mid(colon + 1);
    for (const QString& environmentId : scope()->targets()) {
      bool offered = false;
      for (const QJsonValue& value : scope()->providers(environmentId)) {
        const QJsonObject entry = value.toObject();
        if (at(entry, "instanceId") != instanceId) continue;
        const QString problem = providerProblem(entry);
        if (!problem.isEmpty()) return environmentId == scanned() ? problem : unavailableOn(environmentId);
        for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
          offered = offered || at(model.toObject(), "slug") == slug;
        }
      }
      if (!offered) return unavailableOn(environmentId);
    }
    return {};
  }

  QString unavailableOn(const QString& environmentId) const {
    return QStringLiteral("This model is unavailable on %1. Select that environment to choose its model separately.").arg(scope()->label(environmentId));
  }

  void pickWriter(const QString& key) {
    const QString problem = writerProblem(key);
    if (!problem.isEmpty()) {
      if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
        toasts->error(QStringLiteral("Source control writer model not saved"), problem);
      }
      return;
    }
    const qsizetype colon = key.indexOf(QLatin1Char(':'));
    const QJsonObject selection{{QStringLiteral("instanceId"), key.left(colon)}, {QStringLiteral("model"), key.mid(colon + 1)}};
    set(kWriter, [selection](const QJsonValue&) { return selection; }, QStringLiteral("Source control writer model not saved"));
  }

  // Turning the writer model on starts from the text generation model, or the
  // first provider's default.
  QString defaultWriter() const {
    const QJsonObject settings = scope()->settings(scanned()).value_or(QJsonObject());
    const QString configured = keyOf(settings.value(QLatin1String("textGenerationModelSelection")).toObject());
    if (!configured.isEmpty() && writerProblem(configured).isEmpty()) return configured;
    QString first;
    for (const QJsonValue& value : writers()) {
      const QJsonObject entry = value.toObject();
      if (!providerProblem(entry).isEmpty()) continue;
      for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
        const QString key = at(entry, "instanceId") + QLatin1Char(':') + at(model.toObject(), "slug");
        if (model.toObject().value(QLatin1String("isDefault")).toBool()) return key;
        if (first.isEmpty()) first = key;
      }
    }
    return first;
  }

  QVariantMap item(const QJsonObject& item, bool provider) const {
    const QString kind = at(item, "kind");
    const QString label = at(item, "label");
    const QString hint = at(item, "installHint");
    const bool available = at(item, "status") == QLatin1String("available");
    const bool comingSoon = !provider && !item.value(QLatin1String("implemented")).toBool(true);
    const QJsonObject auth = item.value(QLatin1String("auth")).toObject();
    const QString authStatus = at(auth, "status");
    const QString account = option(auth.value(QLatin1String("account")));
    QString summary = QStringLiteral("Available");
    QString authLabel;
    if (provider) {
      authLabel = authStatus == QLatin1String("authenticated")     ? QStringLiteral("Authenticated")
                  : authStatus == QLatin1String("unauthenticated") ? QStringLiteral("Not authenticated")
                                                                   : QStringLiteral("Status unknown");
    }
    if (comingSoon) {
      summary = QStringLiteral("Support for %1 is coming soon.").arg(label);
    } else if (!available) {
      summary = QStringLiteral("Not available on this server: %1").arg(hint);
    } else if (provider && authStatus == QLatin1String("authenticated")) {
      summary = QStringLiteral("Authenticated");
    } else if (provider && at(item, "executable").isEmpty()) {
      summary = QStringLiteral("Available. %1").arg(hint);
    } else if (provider && authStatus == QLatin1String("unauthenticated")) {
      summary = QStringLiteral(
                    "%1 is not authenticated on this server. Sign in or configure credentials using the %2 tool on the server host to "
                    "enable change request features.")
                    .arg(label, at(item, "executable"));
    } else if (provider) {
      const QString detail = option(auth.value(QLatin1String("detail")));
      summary = QStringLiteral("Could not verify %1. %2").arg(label, detail.isEmpty() ? hint : detail);
    }
    const bool shown = available && authStatus == QLatin1String("authenticated") && !account.isEmpty();
    const bool revealed = shown && m_revealed.contains(kind);
    return {{QStringLiteral("kind"), kind},
            {QStringLiteral("label"), label},
            {QStringLiteral("version"), option(item.value(QLatin1String("version")))},
            {QStringLiteral("comingSoon"), comingSoon},
            {QStringLiteral("available"), available},
            {QStringLiteral("enabled"), provider ? available && authStatus == QLatin1String("authenticated") : available && !comingSoon},
            {QStringLiteral("authLabel"), authLabel},
            {QStringLiteral("authWarning"), provider && authStatus == QLatin1String("unauthenticated")},
            {QStringLiteral("summary"), summary},
            {QStringLiteral("hasAccount"), shown},
            {QStringLiteral("revealed"), revealed},
            {QStringLiteral("account"), revealed ? account : QString()},
            {QStringLiteral("git"), !provider && kind == QLatin1String("git")}};
  }

  QVariantMap discovery() const {
    const QString environmentId = scanned();
    if (environmentId.isEmpty()) {
      return {{QStringLiteral("status"), QStringLiteral("none")},
              {QStringLiteral("title"), QStringLiteral("Connect an environment to inspect its version control tools and hosting integrations.")}};
    }
    const Discovery discovery = m_discovery.value(environmentId);
    QVariantList versionControl, providers;
    for (const QJsonValue& value : discovery.result.value(QLatin1String("versionControlSystems")).toArray()) {
      versionControl.append(item(value.toObject(), false));
    }
    for (const QJsonValue& value : discovery.result.value(QLatin1String("sourceControlProviders")).toArray()) {
      providers.append(item(value.toObject(), true));
    }
    QString status = QStringLiteral("ready");
    if (!discovery.loaded) status = discovery.error.isEmpty() ? QStringLiteral("loading") : QStringLiteral("error");
    // What shows instead of the tools, when they do not.
    QString title, detail;
    if (status == QLatin1String("loading")) {
      title = QStringLiteral("Scanning the server environment…");
    } else if (status == QLatin1String("error")) {
      title = QStringLiteral("Could not scan the server environment");
      detail = discovery.error;
    } else if (versionControl.isEmpty() && providers.isEmpty()) {
      title = QStringLiteral("Nothing detected yet");
      detail = QStringLiteral("Install Git on the server, add optional hosting integrations or credentials your workspace needs, then rescan.");
    }
    return {{QStringLiteral("status"), status},
            {QStringLiteral("title"), title},
            {QStringLiteral("detail"), detail},
            {QStringLiteral("scanning"), discovery.scanning},
            {QStringLiteral("message"), discovery.error},
            {QStringLiteral("suffix"), scope()->targets().size() > 1 ? QStringLiteral(" · ") + scope()->label(environmentId) : QString()},
            {QStringLiteral("versionControl"), versionControl},
            {QStringLiteral("providers"), providers}};
  }

  // Whether the project scope's checkouts override `key`.
  bool overridden(const QString& key) const {
    if (!scope()->projectScope()) return false;
    const auto reading = scope()->read([key](const QJsonObject& settings, const QString& projectId) {
      return QJsonValue(!SettingsScopeController::overrideOf(settings, projectId, key).isUndefined());
    });
    return reading.mixed || reading.value.toBool();
  }

  QVariantMap row(const QString& key) const {
    const auto reading = scope()->read([key](const QJsonObject& settings, const QString& projectId) { return effective(settings, projectId, key); });
    return {{QStringLiteral("value"), variant(reading.value.isUndefined() ? fallback(key) : reading.value)},
            {QStringLiteral("mixed"), reading.mixed},
            {QStringLiteral("overridden"), overridden(key)}};
  }

  EnvironmentSettings::Reading styleField(const QString& field) const {
    return scope()->read([field](const QJsonObject& settings, const QString& projectId) {
      return effective(settings, projectId, kStyle).toObject().value(field);
    });
  }

  QVariantMap writerModel() const {
    const auto reading = scope()->read([](const QJsonObject& settings, const QString& projectId) { return effective(settings, projectId, kWriter); });
    const QString key = keyOf(reading.value.toObject());
    QVariantList models;
    bool kept = key.isEmpty();
    for (const QJsonValue& value : writers()) {
      const QJsonObject entry = value.toObject();
      for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
        const QJsonObject slug = model.toObject();
        if (slug.value(QLatin1String("isLegacy")).toBool()) continue;
        const QString modelKey = at(entry, "instanceId") + QLatin1Char(':') + at(slug, "slug");
        const QString name = at(slug, "name").isEmpty() ? at(slug, "slug") : at(slug, "name");
        models.append(QVariantMap{{QStringLiteral("key"), modelKey},
                                  {QStringLiteral("label"), providerName(entry) + QStringLiteral(" · ") + name},
                                  {QStringLiteral("reason"), writerProblem(modelKey)}});
        kept = kept || modelKey == key;
      }
    }
    if (!kept) {
      models.append(QVariantMap{{QStringLiteral("key"), key},
                                {QStringLiteral("label"), key + QStringLiteral(" (Unavailable)")},
                                {QStringLiteral("reason"), writerProblem(key)}});
    }
    return {{QStringLiteral("available"), !scope()->targets().isEmpty()},
            {QStringLiteral("on"), reading.mixed || !key.isEmpty()},
            {QStringLiteral("mixed"), reading.mixed},
            {QStringLiteral("key"), reading.mixed ? QString() : key},
            {QStringLiteral("canEnable"), !defaultWriter().isEmpty()},
            {QStringLiteral("overridden"), overridden(kWriter)},
            {QStringLiteral("models"), models}};
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    SettingsScopeController* scope = this->scope();
    const bool project = scope->projectScope();

    const auto fetch = scope->read([](const QJsonObject& settings, const QString&) { return QJsonValue(fetchSeconds(settings)); });
    const auto preset = scope->read([](const QJsonObject& settings, const QString&) {
      return QJsonValue(presetFetchSeconds(baseProfile(settings.value(QLatin1String("backgroundActivity")).toObject())));
    });
    const int seconds = fetch.value.toInt(30);

    QVariantMap merge = row(QStringLiteral("pullRequestMergeMethod"));
    if (merge.value(QStringLiteral("value")).isNull()) merge.insert(QStringLiteral("value"), QStringLiteral("last"));

    const auto mode = styleField(QStringLiteral("mode"));
    const auto instructions = styleField(QStringLiteral("customInstructions"));
    const auto templates = styleField(QStringLiteral("followChangeRequestTemplates"));
    const QString modeId = mode.value.toString(QStringLiteral("repo_conventions"));
    QString description;
    for (const Mode& entry : modes()) {
      if (entry.id == modeId) description = entry.description;
    }
    const bool styleMixed = mode.mixed || instructions.mixed;
    const bool styleOverridden = overridden(kStyle);

    m_bridge->publish(
        kKey, QVariantMap{
                  {QStringLiteral("open"), true},
                  {QStringLiteral("projectScope"), project},
                  {QStringLiteral("discovery"), discovery()},
                  {QStringLiteral("fetchInterval"), QVariantMap{{QStringLiteral("seconds"), seconds},
                                                                {QStringLiteral("preset"), preset.value.toInt(30)},
                                                                {QStringLiteral("custom"), fetch.mixed || preset.mixed || seconds != preset.value.toInt(30)},
                                                                {QStringLiteral("mixed"), fetch.mixed},
                                                                {QStringLiteral("environmentWide"), project}}},
                  {QStringLiteral("autoPull"), row(QStringLiteral("defaultAutoPull"))},
                  {QStringLiteral("mergeMethod"), merge},
                  {QStringLiteral("writingStyle"),
                   QVariantMap{{QStringLiteral("mode"), mode.mixed ? QString() : modeId},
                               {QStringLiteral("mixed"), styleMixed},
                               {QStringLiteral("description"), description},
                               {QStringLiteral("instructions"), instructions.value.toString()},
                               {QStringLiteral("instructionsMixed"), instructions.mixed},
                               {QStringLiteral("dirty"), styleMixed || modeId != QLatin1String("repo_conventions") || !instructions.value.toString().isEmpty() ||
                                                             styleOverridden},
                               {QStringLiteral("overridden"), styleOverridden}}},
                  {QStringLiteral("templates"), QVariantMap{{QStringLiteral("value"), templates.value.toBool(true)},
                                                            {QStringLiteral("mixed"), templates.mixed},
                                                            {QStringLiteral("overridden"), styleOverridden}}},
                  {QStringLiteral("writerModel"), writerModel()},
              });
  }

  struct Discovery {
    QJsonObject result;
    QString error;
    bool loaded = false;
    bool scanning = false;
    int seq = 0;
  };

  ShellBridge* m_bridge;
  NodeClient* m_client;
  bool m_active = false;
  bool m_open = false;
  QHash<QString, Discovery> m_discovery;
  // Environments scanned since the section opened.
  QSet<QString> m_scanned;
  // The hosts whose signed-in account is shown.
  QSet<QString> m_revealed;
};

namespace {
const NativeControllerRegistrar<SourceControlSettingsController> registrar(kKey, {kKey});
}  // namespace
