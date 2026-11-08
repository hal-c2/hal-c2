#pragma once

#include <QHash>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QUrl>
#include <QVariantMap>

// What the in-app browser's pages may ask for, and the questions they put to
// the user: one at a time, across every tab, as `Browser.permissions`.
//
// Most requests have a fixed answer (request()). Reading the clipboard is
// asked once per site and remembered while the app runs; one that comes
// while another question is on screen is refused without being remembered,
// so a page cannot queue prompts behind the one the user is reading. A link
// to another app (openLink()) waits its turn instead.
//
// A tab's brick (BrowserPanel) shows `question` when it is the tab's, holds
// the engine's request until the user answers (answer()), and drops its
// questions when its page goes (forget()). The engine's own permission store
// is off (main.cpp), so these are the only answers remembered.
class PagePermissions : public QObject {
  Q_OBJECT
  // The question on screen: {id, tabId, kind ("clipboard" or "link"),
  // origin, url}; empty while none is.
  Q_PROPERTY(QVariantMap question READ question NOTIFY questionChanged)

public:
  explicit PagePermissions(QObject* parent = nullptr) : QObject(parent) {}

  QVariantMap question() const;

  // How a request for `kind` from `origin` in tab `tabId` is answered: {answer: "grant" | "deny" | "ask", id}.
  // `kind` is one of clipboard, clipboard-write, notifications, geolocation, camera, microphone,
  // camera-and-microphone, screen, screen-and-audio, mouse-lock, fonts; anything else is refused.
  // "ask" puts question `id` to the user.
  Q_INVOKABLE QVariantMap request(const QString& tabId, const QString& origin, const QString& kind);
  // Asks whether the link `url` to another app may open; 0 when it is never
  // handed to the system (a local or inline address, or not a link at all).
  Q_INVOKABLE int openLink(const QString& tabId, const QUrl& url);
  // The user's answer to question `id`: the question, or empty when it is no
  // longer asked. A clipboard answer is remembered for its site.
  Q_INVOKABLE QVariantMap answer(int id, bool allow);
  // Drops tab `tabId`'s questions: its page went.
  Q_INVOKABLE void forget(const QString& tabId);
  // Forgets every answer and question, as quitting the app does.
  void clear();

  // Whether the engine shows `scheme`'s addresses itself (web, local and
  // inline ones), so a link to one is never handed to the system.
  static bool engineScheme(const QString& scheme) {
    static const QSet<QString> schemes{
        QStringLiteral("http"), QStringLiteral("https"),      QStringLiteral("about"),       QStringLiteral("data"),
        QStringLiteral("blob"), QStringLiteral("file"),       QStringLiteral("javascript"),  QStringLiteral("view-source"),
        QStringLiteral("ws"),   QStringLiteral("wss"),        QStringLiteral("filesystem"),  QStringLiteral("chrome"),
        QStringLiteral("qrc"),  QStringLiteral("devtools"),
    };
    return schemes.contains(scheme.toLower());
  }

signals:
  void questionChanged();

private:
  struct Question {
    int id = 0;
    QString tabId;
    QString kind;
    QString origin;
    QUrl url;
  };
  int ask(Question question);
  static QVariantMap mapOf(const Question& question);

  QList<Question> m_questions;  // the first is on screen
  QHash<QString, bool> m_clipboard;  // a site's remembered answer
  int m_next = 0;
};
