#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QVariantMap>

#include "NativeController.h"

class BrowserAutomationPage;
class BrowserPage;
class McClient;
class PreviewAutomationHost;
class ShellStore;

// The app as the browser agents drive, as the `PreviewAutomation` QML
// singleton: one PreviewAutomationHost per process, offered to every online
// MC of the cluster while this build has the in-app browser, with each
// browser tab's page (Browser::pages) attached under its MC tab id.
//
// A tab the agent acts on that no window shows comes up in the window showing
// its thread, unless the agent opened it asking not to be shown.
//
// `activity` is what the agent does in each tab, for the cue over its page
// (PreviewAutomationHost::activity).
class PreviewAutomationController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(QVariantMap activity READ activity NOTIFY activityChanged)
  // The cue keeps still (Settings' reduce motion, or the system's).
  Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY activityChanged)

public:
  PreviewAutomationController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~PreviewAutomationController() override;

  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  QVariantMap activity() const;
  bool reduceMotion() const;
  PreviewAutomationHost* host() const { return m_host; }

signals:
  void activityChanged();

private:
  void offer();
  void attachPages();
  void focus();

  McClient* m_client;
  ShellStore* m_store;
  PreviewAutomationHost* m_host = nullptr;
  // Each browser page's driver, and the tab it was attached under.
  struct Driven {
    QPointer<BrowserAutomationPage> driver;
    QString tabId;
  };
  QHash<BrowserPage*, Driven> m_driven;
};
