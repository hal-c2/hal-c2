#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "PullRequestLinks.h"

// What a pull request link in the conversation shows on hover and where a
// click on it goes, as the web's PullRequestLinkPreview and
// useOpenPrLink did. A link is claimed when some project of the thread's
// environment can read it (PullRequestLinks::projectFor); the rest are
// ordinary links.
//
// Hovering reads the pull request through pullRequests.preview, once per
// link while it reads or has read; a link that could not be read is read
// again on the next hover. A click opens the review once the MC has read the
// pull request, and the address in the browser when it could not: a "#123"
// GitHub wrote through /issues/ is a pull request only if the host says so.
// Only the latest click acts, and a new environment forgets the clicks and
// reads of the previous one.
class PullRequestLinkPreviews : public QObject {
  Q_OBJECT
  // The hovered link, while it is claimed.
  Q_PROPERTY(QString address READ address NOTIFY changed)
  // "", "loading", "ready" or "failed", for address.
  Q_PROPERTY(QString status READ status NOTIFY changed)
  // repository, number, state, stateLabel, title, author and opened; ready only.
  Q_PROPERTY(QVariantMap card READ card NOTIFY changed)

public:
  // The preview, or nothing when the MC could not read it.
  using Reply = std::function<void(const std::optional<QJsonObject>& preview)>;
  using Read = std::function<void(const QString& environmentId, const QJsonObject& ref, Reply reply)>;
  using Open = std::function<void(const QString& target)>;

  // review gets "host/repository#number"; browser and ordinary the address.
  PullRequestLinkPreviews(Read read, Open review, Open browser, Open ordinary, QObject* parent = nullptr);

  void setContext(const QString& environmentId, const QList<QJsonObject>& projects);
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  QString address() const { return m_address; }
  QString status() const;
  QVariantMap card() const;

  Q_INVOKABLE bool claims(const QString& url) const;
  // "" when the pointer leaves.
  Q_INVOKABLE void hover(const QString& url);
  // external: the modifier that forces the browser.
  Q_INVOKABLE void follow(const QString& url, bool external);

signals:
  void changed();

private:
  struct Entry {
    bool pending = true;
    std::optional<QJsonObject> preview;
  };

  std::optional<std::pair<PullRequestLink, QString>> claim(const QString& url) const;
  void read(const QString& url);
  void settle(const QString& url);

  Read m_read;
  Open m_review;
  Open m_browser;
  Open m_ordinary;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QString m_environmentId;
  QList<QJsonObject> m_projects;
  // Bumped with the environment, so a late reply from the previous one is dropped.
  quint64 m_epoch = 0;
  QHash<QString, Entry> m_entries;
  QString m_address;
  QString m_following;
};
