#pragma once

#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// What the open thread's provider says when it cannot run a turn
// (`providerNotice`; ProviderNoticeController.cpp).
class ProviderNoticeController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Notice {
    // Empty when the provider has nothing to say; what a dismissal hides.
    QString key;
    QString title;
    QString message;
    bool warning = false;
    // Whether provider setup can install or sign it in.
    bool setup = false;
  };
  // The web's ProviderStatusBanner, for one ServerProvider entry.
  static Notice noticeOf(const QJsonObject& provider);

  ProviderNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  QString openKey() const;
  // The provider entry the open thread runs on, or empty.
  QJsonObject provider(const QString& key) const;
  void publish();

  ShellBridge* m_bridge;
  ShellStore* m_store;
  bool m_active = false;
  // Notices the user dismissed, by key; each names its provider instance.
  QSet<QString> m_dismissed;
};
