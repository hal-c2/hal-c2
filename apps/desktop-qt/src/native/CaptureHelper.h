#pragma once

#include <QImage>
#include <QObject>
#include <QString>
#include <QStringList>

#include <functional>

class QProcess;

// The capture helper KDE Plasma and Hyprland capture through: an executable
// this build carries (native/kde-snap-shot, native/hyprland-snap-shot) that
// setup copies into the user's data directory, where the desktop lets it
// capture. KDE grants KWin's ScreenShot2 to an installed program named by a
// desktop entry beside it; Hyprland asks for screen-sharing the first time.
//
// Nothing is written until `perform()` is asked to install or remove it, and
// nothing that is a link, or a desktop entry this helper did not write, is
// ever written over. `check()` reads what is installed and asks the helper,
// `capture()` has it capture the window in front.
class CaptureHelper : public QObject {
  Q_OBJECT

public:
  enum class Kind { Kde, Hyprland };

  struct State {
    // Empty until checked; else not-installed, update-required, error or ready.
    QString status;
    QString message;
    bool feedbackAvailable = false;
  };

  struct Paths {
    // The executable this build carries; empty or missing when it carries none.
    QString bundle;
    // XDG_DATA_HOME's: the helper goes under <dataHome>/hal-c2, KDE's desktop
    // entry under <dataHome>/applications.
    QString dataHome;
  };

  CaptureHelper(Kind kind, const Paths& paths, QObject* parent = nullptr);
  ~CaptureHelper() override;

  Kind kind() const { return m_kind; }
  State state() const { return m_state; }
  bool busy() const { return m_busy; }
  QString executable() const;
  QString installAction() const { return m_kind == Kind::Kde ? QStringLiteral("install-kde-helper") : QStringLiteral("install-hyprland-helper"); }
  QString removeAction() const { return m_kind == Kind::Kde ? QStringLiteral("remove-kde-helper") : QStringLiteral("remove-hyprland-helper"); }

  // Reads what is installed and asks a current helper whether it can capture.
  void check();
  // install-kde-helper, remove-kde-helper, install-hyprland-helper or
  // remove-hyprland-helper: `performed` with an empty error when done, then a check.
  void perform(const QString& action);
  // Checks, then captures the window in front: `captured` or `failed`.
  void capture();

  static QString executableName(Kind kind);
  // Where this build's helper and the user's data directory are.
  static Paths defaultPaths(Kind kind);

  // Tests stand in for both paths, for where KDE's service tools are found
  // (kbuildsycoca6, systemd-run), and how long the helper is waited for.
  using PathsFor = std::function<Paths(Kind)>;
  static void setPaths(PathsFor paths);
  static void setToolPath(const QStringList& directories);
  static void setTimeout(int ms);
  static constexpr int kTimeoutMs = 20'000;

signals:
  void changed();
  void performed(const QString& error);
  void captured(const QImage& image, const QString& appName, const QString& windowTitle);
  void failed(const QString& message);

private:
  using Done = std::function<void(const QString& error, const QByteArray& out)>;
  // Runs `program` (a path, or a tool found on the tool path), at most one at a time.
  void run(const QString& program, const QStringList& arguments, Done done);
  // What the files say, before the helper is asked; ready means "ask it".
  State files() const;
  QString entryPath() const;
  QString entryText() const;
  QString missing() const;
  // A run's error the way this desktop's helper words it.
  QString runError(const QString& program, const QByteArray& stderr) const;
  QString install(const QByteArray& bundle);
  void refreshServices(std::function<void(const QString& error)> done);
  void setState(const State& state);

  Kind m_kind;
  Paths m_paths;
  State m_state;
  bool m_busy = false;
  QProcess* m_process = nullptr;
  QString m_captureDir;
};
