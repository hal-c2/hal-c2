#include "PullRequestLinkPreviews.h"

#include <QJsonValue>

namespace {

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// "just now", then minutes, hours and days ago.
QString ago(const QString& iso, const QDateTime& now) {
  const QDateTime at = QDateTime::fromString(iso, Qt::ISODateWithMs);
  if (!at.isValid()) return {};
  const qint64 seconds = std::max<qint64>(0, at.secsTo(now));
  if (seconds < 60) return QStringLiteral("just now");
  if (seconds < 3600) return QStringLiteral("%1m ago").arg(seconds / 60);
  if (seconds < 86400) return QStringLiteral("%1h ago").arg(seconds / 3600);
  return QStringLiteral("%1d ago").arg(seconds / 86400);
}

}  // namespace

PullRequestLinkPreviews::PullRequestLinkPreviews(Read read, Open review, Open browser, Open ordinary, QObject* parent)
    : QObject(parent), m_read(std::move(read)), m_review(std::move(review)), m_browser(std::move(browser)), m_ordinary(std::move(ordinary)) {}

void PullRequestLinkPreviews::setContext(const QString& environmentId, const QList<QJsonObject>& projects) {
  m_projects = projects;
  if (environmentId == m_environmentId) {
    // A project gone may leave the hovered link an ordinary one.
    if (!m_address.isEmpty() && !claim(m_address)) hover({});
    return;
  }
  m_environmentId = environmentId;
  ++m_epoch;
  m_entries.clear();
  m_following.clear();
  m_address.clear();
  emit changed();
}

std::optional<std::pair<PullRequestLink, QString>> PullRequestLinkPreviews::claim(const QString& url) const {
  if (m_environmentId.isEmpty()) return std::nullopt;
  const std::optional<PullRequestLink> link = PullRequestLinks::claim(url);
  if (!link) return std::nullopt;
  const QString project = PullRequestLinks::projectFor(m_projects, *link, true);
  if (project.isEmpty()) return std::nullopt;
  return std::pair{*link, project};
}

bool PullRequestLinkPreviews::claims(const QString& url) const {
  return claim(url).has_value();
}

QString PullRequestLinkPreviews::status() const {
  const auto found = m_entries.constFind(m_address);
  if (m_address.isEmpty() || found == m_entries.cend()) return {};
  if (found->pending) return QStringLiteral("loading");
  return found->preview ? QStringLiteral("ready") : QStringLiteral("failed");
}

// As the web's PullRequestLinkPreview wrote it: "Name (@login)", the login
// when the name says nothing more, and "ghost" for a deleted account.
QVariantMap PullRequestLinkPreviews::card() const {
  const auto found = m_entries.constFind(m_address);
  if (m_address.isEmpty() || found == m_entries.cend() || !found->preview) return {};
  const QJsonObject& preview = *found->preview;
  const QString state = text(preview, QLatin1String("state"));
  const bool draft = preview.value(QLatin1String("isDraft")).toBool();
  const QString stateLabel = state == QLatin1String("merged")   ? QStringLiteral("Merged")
                             : state == QLatin1String("closed") ? QStringLiteral("Closed")
                             : draft                            ? QStringLiteral("Draft")
                                                                : QStringLiteral("Open");
  const QJsonObject author = preview.value(QLatin1String("author")).toObject();
  const QString login = text(author, QLatin1String("login"));
  const QString name = text(author, QLatin1String("name"));
  const QString authorLabel = login.isEmpty()                        ? QStringLiteral("ghost")
                              : !name.isEmpty() && name != login ? QStringLiteral("%1 (@%2)").arg(name, login)
                                                                     : login;
  return {{QStringLiteral("repository"), text(preview, QLatin1String("repository"))},
          {QStringLiteral("number"), preview.value(QLatin1String("number")).toInt()},
          {QStringLiteral("state"), draft && state == QLatin1String("open") ? QStringLiteral("draft") : state},
          {QStringLiteral("stateLabel"), stateLabel},
          {QStringLiteral("title"), text(preview, QLatin1String("title"))},
          {QStringLiteral("author"), authorLabel},
          {QStringLiteral("opened"), ago(text(preview, QLatin1String("createdAt")), m_now())}};
}

void PullRequestLinkPreviews::hover(const QString& url) {
  const QString address = claim(url) ? url : QString();
  if (!address.isEmpty()) {
    const auto found = m_entries.constFind(address);
    if (found == m_entries.cend() || (!found->pending && !found->preview)) read(address);
  }
  if (address == m_address) return;
  m_address = address;
  emit changed();
}

void PullRequestLinkPreviews::follow(const QString& url, bool external) {
  m_following.clear();
  if (external) return m_browser(url);
  if (!claim(url)) return m_ordinary(url);
  const auto found = m_entries.constFind(url);
  // A read that failed on hover may succeed now.
  if (found == m_entries.cend() || (!found->pending && !found->preview)) read(url);
  m_following = url;
  if (!m_entries.value(url).pending) settle(url);
}

void PullRequestLinkPreviews::read(const QString& url) {
  const auto claimed = claim(url);
  if (!claimed) return;
  const auto& [link, project] = *claimed;
  m_entries.insert(url, Entry{});
  if (url == m_address) emit changed();
  const QJsonObject ref{{QStringLiteral("projectId"), project},
                        {QStringLiteral("host"), link.host},
                        {QStringLiteral("repository"), link.repository},
                        {QStringLiteral("number"), link.number}};
  const quint64 epoch = m_epoch;
  m_read(m_environmentId, ref, [this, epoch, url](const std::optional<QJsonObject>& preview) {
    if (epoch != m_epoch) return;
    const auto found = m_entries.find(url);
    if (found == m_entries.end() || !found->pending) return;
    found->pending = false;
    found->preview = preview;
    if (url == m_address) emit changed();
    if (url == m_following) settle(url);
  });
}

void PullRequestLinkPreviews::settle(const QString& url) {
  m_following.clear();
  const Entry entry = m_entries.value(url);
  const auto claimed = claim(url);
  if (entry.preview && claimed) {
    m_review(claimed->first.key());
  } else {
    m_browser(url);
  }
}
