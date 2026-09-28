#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
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

public:
  ThemeController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString&, const QVariant&) override { return false; }

  QString mode() const;
  QString themeId() const;
  QVariantMap halves() const;
  QString appearance() const { return m_appearance; }
  QString resolvedId() const { return m_resolvedId; }
  QVariantList available() const;

  // Each saves to this device's preferences and returns false when that fails,
  // leaving the theme as it was.
  Q_INVOKABLE bool setMode(const QString& mode);
  // A theme with one appearance takes that half and leaves the other alone;
  // any other replaces the choice, halves included. Empty is the standard look.
  Q_INVOKABLE bool choose(const QString& id);
  // Empty `id` clears that half.
  Q_INVOKABLE bool chooseHalf(const QString& appearance, const QString& id);

  // The operating system's appearance, followed in system mode. Tracked from
  // QStyleHints; tests set it.
  void setSystemDark(bool dark);

  // Any CSS colour a theme holds (hex, oklch(), a named colour) as
  // #rrggbb or #rrggbbaa; empty when it is not one.
  static QString canonicalColor(const QString& css);

signals:
  void changed();

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
  bool save(QJsonObject device);
  void resolve();

  ShellBridge* m_bridge;
  SettingsController* m_settings;
  bool m_systemDark = false;
  QString m_appearance;
  QString m_resolvedId;
};
