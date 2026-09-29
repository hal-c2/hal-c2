#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include "NativeController.h"

class NodeClient;
class SettingsController;
class ShellBridge;

// The shell's theme, resolved natively and published as `theme` (the
// ShellThemeState shape: {id, appearance, colors, radius, fontUi, fontMono},
// colours as #rrggbb[aa]); ThemeStore paints it with theme.json on top, and
// injects it into the page, which follows rather than leads.
//
// The choice is this device's (SettingsController's device preferences):
// `appearance` (system, light or dark), `theme` (an id; none is the standard
// look), `themeHalves` ({light, dark}: a theme per appearance, over `theme`)
// and `customThemes` (ThemeDefinition-shaped). Themes resolve by id from the
// built-ins (themes.json, generated from packages/shared themePalettes.ts),
// then this device's own, then those the node publishes (`config.themes`), as
// apps/web themePalette.ts getThemeDefinition does. One no longer published
// falls back to the standard look. The `Themes` QML singleton.
class ThemeController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(QString mode READ mode NOTIFY changed)
  Q_PROPERTY(QString themeId READ themeId NOTIFY changed)
  Q_PROPERTY(QVariantMap halves READ halves NOTIFY changed)
  // What is drawn: the resolved appearance and theme id.
  Q_PROPERTY(QString appearance READ appearance NOTIFY changed)
  Q_PROPERTY(QString resolvedId READ resolvedId NOTIFY changed)
  // [{id, label, appearance, appearances, source}], source one of builtIn,
  // custom, environment: what a picker offers.
  Q_PROPERTY(QVariantList available READ available NOTIFY changed)
  // The colour roles a theme sets, in the order an editor lists them.
  Q_PROPERTY(QStringList roles READ roles CONSTANT)
  // Whether the window's theme editor is open (themeEditor.toggle); the
  // editor sets it back when it closes.
  Q_PROPERTY(bool editorOpen READ editorOpen WRITE setEditorOpen NOTIFY editorOpenChanged)

public:
  ThemeController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  // Registers the appearance shortcut's command, and the palette's Change
  // theme (theme.select) and Change appearance (appearance.select) menus and
  // Toggle theme editor (themeEditor.toggle).
  void activate() override;
  // The page forwards its own theme commands here (`appearance.cycle`,
  // `theme.mode {mode}`, `theme.choose {id}`, `theme.chooseHalf {appearance,
  // id}`), so its shortcut and palette change the desktop's theme.
  bool handle(const QString& action, const QVariant& payload) override;

  QString mode() const;
  QString themeId() const;
  QVariantMap halves() const;
  QString appearance() const { return m_appearance; }
  QString resolvedId() const { return m_resolvedId; }
  QVariantList available() const;
  QStringList roles() const;
  bool editorOpen() const { return m_editorOpen; }
  void setEditorOpen(bool open);

  // Each saves to this device's preferences and returns false when that fails,
  // leaving the theme as it was and telling the user.
  Q_INVOKABLE bool setMode(const QString& mode);
  // A theme with one appearance takes that half and leaves the other alone;
  // any other replaces the choice, halves included. Empty is the standard look.
  Q_INVOKABLE bool choose(const QString& id);
  // Empty `id` clears that half.
  Q_INVOKABLE bool chooseHalf(const QString& appearance, const QString& id);
  // The appearance shortcut (appearance.cycle): system, light, dark and round
  // again, saying where it landed.
  Q_INVOKABLE bool cycleAppearance();
  // Back to the standard look following the system, in one save: on failure
  // the whole choice stays as it was.
  Q_INVOKABLE bool restoreDefaults();

  // This device's own themes. A draft is what the editor starts from:
  // {id, label, appearance, colors} with every role of `id` drawn in its
  // appearance (the active theme's for an empty id), and `id` empty for a new
  // theme. Saving one (a new id is made from its label) adds or replaces it
  // and applies it; the saved id, or empty when it could not be saved.
  Q_INVOKABLE QVariantMap draft(const QString& id = {}) const;
  Q_INVOKABLE QString saveCustom(const QVariantMap& theme);
  // Saves an editable copy ("<label> copy") of any theme offered; its id.
  Q_INVOKABLE QString duplicate(const QString& id);
  // Removes a saved theme; a choice that named it goes back to the standard look.
  Q_INVOKABLE bool removeCustom(const QString& id);

  // The operating system's appearance, followed in system mode. Tracked from
  // QStyleHints; tests set it.
  void setSystemDark(bool dark);

  // Any CSS colour a theme holds (hex, oklch(), a named colour) as
  // #rrggbb or #rrggbbaa; empty when it is not one.
  static QString canonicalColor(const QString& css);

signals:
  void changed();
  void editorOpenChanged();

private:
  struct Definition {
    QString id;
    QString label;
    QString appearance;
    QJsonObject colors;
    QJsonObject variants;
    QString source;
  };
  QList<Definition> definitions() const;
  std::optional<Definition> find(const QString& id) const;
  // The palette a definition draws in `appearance`, or empty when it has none.
  static QJsonObject colorsFor(const Definition& definition, const QString& appearance);
  // Saves the choice; a failure is toasted as `failure`.
  bool save(const QJsonObject& device, const QString& failure = {});
  void resolve();

  ShellBridge* m_bridge;
  SettingsController* m_settings;
  bool m_systemDark = false;
  QString m_appearance;
  QString m_resolvedId;
  QString m_cycleToast;
  bool m_editorOpen = false;
};
