#pragma once

#include <QList>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include "NativeController.h"

class McClient;
class ShellBridge;

// Settings → Open source licenses (the web's OpenSourceLicenses): the
// third-party notices this app ships, read from the manifest staged beside it
// (scripts/third-party-licenses.ts writes it; setManifestPath says where). No
// MC is asked, so it reads with none connected. The manifest is read when
// the page opens, and again on retry.
//
// Publishes `licenses`: {status: loading | ready | error, message, query,
// total, entries: [{key, name, version, license, where, sourceUrl}] (those
// the query matches), openKey, noticeText (the open entry's)}.
//
// Actions: `licenses.search {query}`, `licenses.open {key}` (the open one
// again, or null, closes it), `licenses.retry`.
class LicensesController : public QObject, public NativeController {
  Q_OBJECT

public:
  static inline const QString kSection = QStringLiteral("/settings/open-source-licenses");

  LicensesController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  // Where every window reads the manifest from (main.cpp, and each scenario).
  static void setManifestPath(const QString& path) { manifestPath() = path; }

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  struct Entry {
    QString key, name, version, license, noticeText, sourceUrl;
    QStringList bundles;
  };

  static QString& manifestPath() {
    static QString path;
    return path;
  }

  void load();
  void publish();

  ShellBridge* m_bridge;
  bool m_active = false;
  QString m_status = QStringLiteral("loading");
  QString m_message;
  QString m_query;
  QString m_openKey;
  QList<Entry> m_entries;
};
