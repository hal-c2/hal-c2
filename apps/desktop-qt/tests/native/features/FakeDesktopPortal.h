#pragma once

// The desktop portal (org.freedesktop.portal.Desktop) on a private session
// bus, so PortalSnapShot runs as it does on a desktop: its Screenshot
// properties and the GlobalShortcuts session, prompt and signals. The bus is
// a dbus-daemon of the test's own, with no services to start, so nothing on
// the user's session bus is touched.

#include <QStringList>

// How the desktop answers BindShortcuts.
enum class PortalAnswer { Grant, Unassigned, Refuse, Hold };

struct PortalDesktop {
  uint shortcutsVersion = 2;
  // Captures the window in front; false gives only the picker.
  bool windowCapture = true;
  // Properties.GetAll(Screenshot) fails, or waits for answerScreenshot().
  bool screenshotFails = false;
  bool holdScreenshot = false;
  bool sessionFails = false;
  PortalAnswer bind = PortalAnswer::Grant;
  // The keys the desktop shows for a granted shortcut; else the trigger's.
  QString label;
};

#ifdef HAL_C2_HAS_DBUS

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>

#include <optional>

class FakeDesktopPortal : public QDBusVirtualObject {
public:
  using Answer = PortalAnswer;
  using Desktop = PortalDesktop;

  // The portal, its bus started on first use.
  static FakeDesktopPortal& instance();
  // The connection the app's PortalSnapShot uses (PortalSnapShot::useBus).
  static QString appConnection();

  // A fresh desktop that owns the portal's name, with no session.
  void reset();
  // How long PortalSnapShot waits for a prompt, and making that wait short.
  static int promptTimeoutMs();
  void shortenPrompts();

  Desktop desktop;
  int creates = 0;
  int closes = 0;
  int configures = 0;
  // Each BindShortcuts' preferred trigger.
  QStringList triggers;

  bool sessionOpen() const { return !m_session.isEmpty(); }
  bool prompting() const { return m_held.has_value(); }
  bool screenshotHeld() const { return m_heldScreenshot.has_value(); }
  // The held prompt: the user approves (or refuses) it.
  void answer(bool approve);
  void answerScreenshot();
  // The service goes away and comes back, or just goes away.
  void restartService();
  void dropService();
  // The desktop closes HAL-C2's session, or reports its shortcut changed.
  void closeSession();
  void changeShortcut(const QString& label);

  QString introspect(const QString& path) const override;
  bool handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

private:
  FakeDesktopPortal();

  void respond(const QString& request, uint status, const QVariantMap& results);
  QVariantMap granted(const QString& label) const;

  QDBusConnection m_bus;
  QString m_session;
  QString m_shortcutId;
  QString m_trigger;
  struct Held {
    QString request;
  };
  std::optional<Held> m_held;
  std::optional<QDBusMessage> m_heldScreenshot;
};

#else

#include "Harness.h"

// No D-Bus here: a scenario on the desktop portal fails at its first step.
class FakeDesktopPortal {
public:
  using Answer = PortalAnswer;
  using Desktop = PortalDesktop;
  static FakeDesktopPortal& instance() {
    static FakeDesktopPortal portal;
    return portal;
  }
  void reset() { fail(QStringLiteral("this platform has no D-Bus for the desktop portal")); }
  static int promptTimeoutMs() { return 0; }
  void shortenPrompts() {}
  Desktop desktop;
  int creates = 0;
  int closes = 0;
  int configures = 0;
  QStringList triggers;
  bool sessionOpen() const { return false; }
  bool prompting() const { return false; }
  bool screenshotHeld() const { return false; }
  void answer(bool) {}
  void answerScreenshot() {}
  void restartService() {}
  void dropService() {}
  void closeSession() {}
  void changeShortcut(const QString&) {}
};

#endif
