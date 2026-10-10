#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariant>

#include <optional>

#include "NativeController.h"

class EnvironmentSettings;
class McClient;
class ShellBridge;
class ShellStore;

// What tells projects and environments apart at a glance.
//
// Publishes `projectIcons`: every project's icon by `<environmentId>:<projectId>`,
//   {kind (monogram | emoji | lucide | image), text, emoji, name, color, tint,
//    url (an image's, on the MC), path, automatic}.
// A project with no icon of its own shows the monogram and colour derived
// from its name until the MC serves a favicon for it (`assets.createUrl`
// project-favicon): its own, or the image file the user picked.
//
// The picker (ProjectIconPicker.qml), opened from Settings → Projects, is
// `projectIconPicker`, null while closed:
//   {name, mode (lucide | emoji | monogram | image), symbol, color, letters,
//    emoji, error, symbols, colors: [{name, tint}], query, searching,
//    images: [paths]}
// Actions: `projectIcon.open {projectKey, name}`, `projectIcon.set {mode?,
// symbol?, color?, letters?, emoji?}`, `projectIcon.search {query}` (image
// files of the project only), `projectIcon.save` (a monogram must be one or
// two letters or numbers), `projectIcon.image {path}` and `projectIcon.cancel`.
// Saving goes through `projectSettings.icon`, which writes every checkout in
// the settings' scope.
//
// Publishes `environmentIcons`: by environment, {kind (server | cloud | linux |
// desktop | laptop | mac-mini | mac-studio), detected, icon (the lucide name),
// label, lock (why it cannot be changed, or "")}. `environmentIcon.set
// {environmentId, kind}` saves the `environmentIcon` setting there; the
// detected kind clears it. The session's own scopes come from the MC's
// `/api/auth/session`, asked once an icon is about to change.
class IdentityController : public QObject, public NativeController {
  Q_OBJECT

public:
  IdentityController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  struct Picker {
    QString projectKey;
    QString name;
    QString mode = QStringLiteral("lucide");
    QString symbol = QStringLiteral("folder-code");
    QString color;
    QString letters;
    QString emoji;
    QString error;
    QString query;
    bool searching = false;
    QStringList images;
    int request = 0;
  };

  void refreshProjects();
  void requestFavicon(const QString& key, const QJsonObject& row);
  void publishProjects();
  void publishPicker();
  void openPicker(const QString& projectKey, const QString& name);
  void setPicker(const QVariantMap& fields);
  void search(const QString& query);
  void savePicker();
  void refreshEnvironments();
  void setEnvironmentKind(const QString& environmentId, const QString& kind);
  QString lockOf(const QString& environmentId) const;
  // Asks the MC what this session may do, then runs `then`.
  void withSession(std::function<void()> then);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  EnvironmentSettings* m_settings;
  bool m_active = false;
  // A project's favicon on its MC: the key it was asked for (the checkout
  // and the picked file) and the URL that came, empty for none.
  struct Favicon {
    QString asked;
    QString url;
  };
  QHash<QString, Favicon> m_favicons;
  QVariantMap m_projectIcons;
  std::optional<Picker> m_picker;
  // Each environment's `environment` descriptor from its config.
  QHash<QString, QJsonObject> m_descriptors;
  QVariantMap m_environmentIcons;
  // Whether this session may change the MC's own environment; unknown until asked.
  std::optional<bool> m_mayOperate;
};
