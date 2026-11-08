#include "PagePermissions.h"

#include <QSet>

namespace {

const QString kClipboard = QStringLiteral("clipboard");
const QString kLink = QStringLiteral("link");

// What a page gets without asking: writing the clipboard (the engine still
// wants the user's click), the location, and locking the mouse pointer for
// games and 3D viewers (Escape frees it). The rest is refused.
const QSet<QString> kGranted{QStringLiteral("clipboard-write"), QStringLiteral("geolocation"), QStringLiteral("mouse-lock")};

QVariantMap answerOf(const QString& answer, int id = 0) {
  return {{QStringLiteral("answer"), answer}, {QStringLiteral("id"), id}};
}

}  // namespace

QVariantMap PagePermissions::mapOf(const Question& question) {
  return {{QStringLiteral("id"), question.id},
          {QStringLiteral("tabId"), question.tabId},
          {QStringLiteral("kind"), question.kind},
          {QStringLiteral("origin"), question.origin},
          {QStringLiteral("url"), question.url}};
}

QVariantMap PagePermissions::question() const {
  return m_questions.isEmpty() ? QVariantMap() : mapOf(m_questions.first());
}

QVariantMap PagePermissions::request(const QString& tabId, const QString& origin, const QString& kind) {
  if (kind != kClipboard) return answerOf(kGranted.contains(kind) ? QStringLiteral("grant") : QStringLiteral("deny"));
  if (const auto known = m_clipboard.constFind(origin); known != m_clipboard.cend())
    return answerOf(*known ? QStringLiteral("grant") : QStringLiteral("deny"));
  // One question at a time: a page asking again behind it is refused, not queued.
  if (!m_questions.isEmpty() || origin.isEmpty()) return answerOf(QStringLiteral("deny"));
  return answerOf(QStringLiteral("ask"), ask({0, tabId, kClipboard, origin, {}}));
}

int PagePermissions::openLink(const QString& tabId, const QUrl& url) {
  if (!url.isValid() || url.scheme().isEmpty() || engineScheme(url.scheme())) return 0;
  // The engine may ask twice for one click.
  for (const Question& waiting : std::as_const(m_questions))
    if (waiting.tabId == tabId && waiting.url == url) return waiting.id;
  return ask({0, tabId, kLink, url.scheme().toLower(), url});
}

int PagePermissions::ask(Question question) {
  question.id = ++m_next;
  m_questions.append(question);
  if (m_questions.size() == 1) emit questionChanged();
  return question.id;
}

QVariantMap PagePermissions::answer(int id, bool allow) {
  for (qsizetype i = 0; i < m_questions.size(); ++i) {
    if (m_questions.at(i).id != id) continue;
    const Question answered = m_questions.takeAt(i);
    if (answered.kind == kClipboard) m_clipboard.insert(answered.origin, allow);
    if (i == 0) emit questionChanged();
    return mapOf(answered);
  }
  return {};
}

void PagePermissions::forget(const QString& tabId) {
  const bool shown = !m_questions.isEmpty() && m_questions.first().tabId == tabId;
  m_questions.removeIf([&tabId](const Question& question) { return question.tabId == tabId; });
  if (shown) emit questionChanged();
}

void PagePermissions::clear() {
  m_clipboard.clear();
  const bool shown = !m_questions.isEmpty();
  m_questions.clear();
  if (shown) emit questionChanged();
}
