#pragma once

#include <QByteArray>
#include <QList>
#include <QProcessEnvironment>
#include <QString>

#include <functional>
#include <memory>
#include <optional>

// The capture shortcut kept in the compositor's own config, on Niri and
// Hyprland: SnapShotController reviews the change with the user before it is
// written, then writes exactly what was reviewed.
//
// `preview` reads the config (and, on Niri, every file it includes), refuses
// one that is not safe to edit, and proposes the edit; `apply` writes only the
// last proposal, and only while none of the files read for it has changed. The
// write goes through a temporary file beside the config that Niri validates
// first; the original is kept as a backup, and Hyprland reloads afterwards.
// One change at a time: a preview while one is saving is refused.
//
// A refusal is the message the user reads, in `error`.
class CaptureShortcutConfig {
public:
  // One of `hyprctl -j binds`.
  struct HyprlandBind {
    int modmask = 0;
    QString key;
    QString dispatcher;
    QString arg;
  };
  // What the compositor is asked. The system's run `niri` and `hyprctl`;
  // tests stand in for them.
  struct Tools {
    // `niri validate --config <path>` passes.
    std::function<bool(const QString& path)> validateNiri;
    // The binds Hyprland has, or nullopt when it cannot say.
    std::function<std::optional<QList<HyprlandBind>>()> hyprlandBindings;
    // `hyprctl reload`, then `hyprctl configerrors`: what went wrong, or empty.
    std::function<QString()> reloadHyprland;
  };
  static Tools systemTools();

  enum class Format { Niri, Hyprland, HyprlandLua };

  // A chord as compositor configs take it: a letter, digit or F1-F24 with
  // Ctrl, Alt or Super (and Shift). `input` is a label, "Ctrl+Shift+2".
  struct Keys {
    QString label;      // Ctrl+Shift+2
    QString modifiers;  // CTRL SHIFT
    QString key;        // 2
    int mask = 0;       // Hyprland's modmask
  };
  static std::optional<Keys> keys(const QString& input, QString* error);
  static QString binding(Format format, const QString& appId, const QString& keys);
  // The Niri binding for Ctrl+Shift+2, which calls `endpoint`'s Capture.
  static QString niriBinding(const QString& appId);
  static inline const QString kNiriPath = QStringLiteral("/com/hal_c2/SnapShot");
  static inline const QString kNiriInterface = QStringLiteral("com.hal_c2.SnapShot");

  // Where each compositor reads its config by default.
  static QString niriConfigPath(const QProcessEnvironment& env);
  static QString hyprlandConfigPath(const QProcessEnvironment& env);
  static QString home(const QProcessEnvironment& env);

  struct Edit {
    QString after;
    QString shortcut;
  };
  // The config with HAL-C2's binding installed on `keys` (empty: the one there,
  // else Ctrl+Shift+2) or removed.
  static std::optional<Edit> edit(const QString& source, Format format, const QString& appId, bool install, const QString& keys,
                                  QString* error);

  struct Target {
    QString desktop;  // niri | hyprland
    QString path;
    QString appId;
  };
  struct Preview {
    QString id;
    QString path;
    QString resolvedPath;
    QString before;
    QString after;
    QString shortcut;
    bool install = true;
  };
  struct Applied {
    QString backupPath;
    QString warning;
  };

  CaptureShortcutConfig(QString home, Tools tools);
  ~CaptureShortcutConfig();

  std::optional<Preview> preview(const Target& target, bool install, const QString& keys, QString* error);
  std::optional<Applied> apply(const QString& id, const QString& desktop, QString* error);
  bool applying() const { return m_applying; }

  struct File;

private:
  struct Pending;
  bool checkHyprlandKeys(const QString& appId, const QString& shortcut, QString* error) const;
  bool unchanged(const Pending& pending, QString* error) const;

  QString m_home;
  Tools m_tools;
  std::unique_ptr<Pending> m_pending;
  bool m_applying = false;
};
