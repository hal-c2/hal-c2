#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <optional>

#include "NativeController.h"

class McClient;
class SettingsController;
class ShellBridge;

// The shell's theme, resolved natively and published as `theme` (the
// ShellThemeState shape: {id, appearance, colors, radius, fontUi, fontMono},
// colours as #rrggbb[aa], plus the device's font preferences: fontPrompt,
// fontTerminal and fontSizes {interface, prompt, code, terminal});
// ThemeStore paints it with theme.json on top.
//
// The choice is this device's (SettingsController's device preferences):
// `appearance` (system, light or dark), `theme` (an id; none is the standard
// look), `themeHalves` ({light, dark}: a theme per appearance, over `theme`)
// and `customThemes` (ThemeDefinition-shaped). Themes resolve by id from the
// built-ins (themes.json, generated from packages/shared themePalettes.ts),
// then this device's own, then those the MC publishes (`config.themes`), as
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
  // [{id, label, appearance, appearances, source, collection}], source one of
  // builtIn, custom, environment: what a picker offers. `collection` is the
  // label of the family a saved theme was installed with, or empty.
  Q_PROPERTY(QVariantList available READ available NOTIFY changed)
  // The colour roles a theme sets, in the order an editor lists them.
  Q_PROPERTY(QStringList roles READ roles CONSTANT)
  // Whether the window's theme editor is open (themeEditor.toggle); the
  // editor sets it back when it closes.
  Q_PROPERTY(bool editorOpen READ editorOpen WRITE setEditorOpen NOTIFY editorOpenChanged)
  // The draft the editor holds, unsaved changes included, for as long as it
  // is open: it outlives the page that opened it.
  Q_PROPERTY(QVariantMap editing READ editing NOTIFY editingChanged)
  // Picking a colour off the app: while `inspecting`, the window's
  // ThemeInspector hands the colour under the pointer to pick(), and `picked`
  // says which roles draw in it: {color, role (the first), roles, count}.
  Q_PROPERTY(bool inspecting READ inspecting WRITE setInspecting NOTIFY inspectChanged)
  Q_PROPERTY(QVariantMap picked READ picked NOTIFY inspectChanged)
  // The roles by family, as the editor's advanced view groups them:
  // [{title, roles}].
  Q_PROPERTY(QVariantList families READ families CONSTANT)
  // What an import in progress waits on: `importError` says why it stopped,
  // `importConflicts` names the themes already installed, which
  // resolveImport() updates, copies or drops.
  Q_PROPERTY(QString importError READ importError NOTIFY importChanged)
  Q_PROPERTY(QStringList importConflicts READ importConflicts NOTIFY importChanged)

public:
  ThemeController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  // Registers the appearance shortcut's command, and the palette's Change
  // theme (theme.select) and Change appearance (appearance.select) menus and
  // Toggle theme editor (themeEditor.toggle).
  void activate() override;
  // `appearance.cycle`, `theme.mode {mode}`, `theme.choose {id}` and
  // `theme.chooseHalf {appearance, id}` change the desktop's theme.
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
  // Asks first ("Remove “<label>”?"), then removes it.
  Q_INVOKABLE void requestRemove(const QString& id);
  // Several at once, as the variants picked from a collection: asked once,
  // removed in one save.
  Q_INVOKABLE void requestRemoveMany(const QStringList& ids);
  bool removeCustomMany(const QStringList& ids);

  // The editor. edit() opens it on a draft; setEditing() keeps what the user
  // changed since. Closing it drops the draft.
  QVariantMap editing() const { return m_editing; }
  Q_INVOKABLE void edit(const QVariantMap& draft);
  Q_INVOKABLE void setEditing(const QVariantMap& draft);
  QVariantList families() const;
  bool inspecting() const { return m_inspecting; }
  // Starting to inspect forgets the last pick; stopping (Escape) picks nothing.
  void setInspecting(bool inspecting);
  QVariantMap picked() const { return m_picked; }
  Q_INVOKABLE void pick(const QString& color);
  // A whole palette grown from a canvas and an accent (the web's
  // createVividThemeColors, simplified): surfaces step away from the canvas,
  // text is solved for contrast against it, the status colours stay standard.
  Q_INVOKABLE QVariantMap derive(const QString& canvas, const QString& accent) const;

  // Importing theme files (the web's theme file, version 1). Pasted JSON or
  // one file installs the theme and makes it active; several files install
  // without activating. A theme already installed waits for resolveImport.
  static constexpr qint64 kMaxThemeFileBytes = 256 * 1024;
  QString importError() const { return m_importError; }
  QStringList importConflicts() const;
  Q_INVOKABLE bool importText(const QString& json);
  Q_INVOKABLE void importFiles(const QStringList& paths);
  // `choice` is update, copy or cancel.
  Q_INVOKABLE void resolveImport(const QString& choice);
  Q_INVOKABLE void clearImport();
  // Writes the theme `id` as a theme file other clients import.
  Q_INVOKABLE bool exportTheme(const QString& id, const QString& path);

  // The operating system's appearance, followed in system mode. Tracked from
  // QStyleHints; tests set it.
  void setSystemDark(bool dark);

  // Any CSS colour a theme holds (hex, oklch(), a named colour) as
  // #rrggbb or #rrggbbaa; empty when it is not one.
  static QString canonicalColor(const QString& css);

signals:
  void changed();
  void editorOpenChanged();
  void editingChanged();
  void inspectChanged();
  void importChanged();

private:
  struct Definition {
    QString id;
    QString label;
    QString appearance;
    QJsonObject colors;
    QJsonObject variants;
    QString source;
    QString collection;
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
  QVariantMap m_editing;
  bool m_inspecting = false;
  QVariantMap m_picked;
  QString m_importError;
  // Parsed themes whose id is already installed.
  QJsonArray m_importConflicts;
  // Parses a theme file; `error` says why it is not one.
  std::optional<QJsonObject> parseFile(const QByteArray& text, QString* error) const;
  // A VS Code colour theme as one of our theme files.
  std::optional<QJsonObject> fromVsCodeTheme(const QJsonObject& file, QString* error) const;
  bool installed(const QString& id) const;
  // Adds or replaces saved themes in one save.
  bool install(const QJsonArray& themes, const QString& activate = {});
  void failImport(const QString& error);
  void told(const QJsonArray& themes, const QString& verb, const QString& description = {});
};
