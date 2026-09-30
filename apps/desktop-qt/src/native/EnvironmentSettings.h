#pragma once

#include <QHash>
#include <QJsonObject>
#include <QJsonValue>
#include <QObject>
#include <QStringList>

#include <functional>
#include <optional>

class NodeClient;

// A setting across the selected environments (the web's scopedSettings.ts):
// the settings documents of a few environments, read as one value that may
// be mixed, and changed on each of them.
//
// Each target's `config` shape brings its settings document (`config`, then
// `config.settings`). A reading takes the first target's value as the one to
// show and says whether any other target differs. A change applies an edit to
// every target that has answered, each read and written at its own version
// (`hal-c2.readSettings` / `hal-c2.writeSettings`, a stale write edited again),
// and reports which targets could not save, so one failing machine does not
// hide the others' saves.
//
//   EnvironmentSettings scope(client);
//   scope.setTargets({laptop, buildBox});
//   const auto interval = scope.read(QStringLiteral("backgroundActivity.profile"));
//   scope.change([](QJsonObject settings, const QString&) { ...; return settings; },
//                [](const QStringList& failed, int saved) { ... });
//
// A project scope is an edit of `projectSettingsOverrides[<project>]` on each
// target, and a pick that reads it; the model itself knows only documents.
class EnvironmentSettings : public QObject {
  Q_OBJECT

public:
  // The new document from a target's current one.
  using Edit = std::function<QJsonObject(QJsonObject settings, const QString& environmentId)>;
  // The targets that could not save (with why, by environment) and how many did.
  using Done = std::function<void(const QHash<QString, QString>& failed, int saved)>;
  using Pick = std::function<QJsonValue(const QJsonObject& settings, const QString& environmentId)>;

  struct Reading {
    // The first answering target's value; undefined when none has answered.
    QJsonValue value = QJsonValue(QJsonValue::Undefined);
    // Another answering target holds something else.
    bool mixed = false;
    // How many targets have answered.
    int known = 0;
  };

  explicit EnvironmentSettings(NodeClient* client, QObject* parent = nullptr);
  ~EnvironmentSettings() override;

  // Follows these environments' settings, and nothing else; in the order a
  // reading prefers them.
  void setTargets(const QStringList& environmentIds);
  QStringList targets() const { return m_targets; }
  // Whether every target has answered.
  bool ready() const;
  std::optional<QJsonObject> settings(const QString& environmentId) const;

  Reading read(const Pick& pick) const;
  // A value by dotted path, as `Settings.value` reads one.
  Reading read(const QString& path) const;
  static QJsonValue at(const QJsonObject& settings, const QString& path);
  // `settings` with the dotted path set; undefined or null removes it.
  static QJsonObject with(QJsonObject settings, const QString& path, const QJsonValue& value);

  // Applies `edit` on every target; one that has not answered counts as failed
  // ("not connected"). An edit that changes nothing writes nothing.
  void change(const Edit& edit, const Done& done = {});

signals:
  // A target's settings arrived or changed, or the targets did.
  void changed();
  // Every frame a target's `config` shape sends, settings or not (providers,
  // themes), for owners that need more of the environment's config.
  void frame(const QString& environmentId, const QJsonObject& frame);

private:
  struct Target {
    int subscription = -1;
    std::optional<QJsonObject> settings;
  };
  void attempt(const QString& environmentId, const Edit& edit, int retries, std::function<void(std::optional<QString>)> done);

  NodeClient* m_client;
  QStringList m_targets;
  QHash<QString, Target> m_followed;
};
