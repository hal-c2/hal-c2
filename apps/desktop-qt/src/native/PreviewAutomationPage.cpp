#include "PreviewAutomationPage.h"

#include <QDateTime>

namespace {

QString now() { return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs); }

}  // namespace

QJsonArray PreviewAutomationPage::consoleEntries() const { return m_console; }

void PreviewAutomationPage::addConsoleEntry(const QString& level, const QString& text, const QString& source) {
  QJsonObject entry{{QStringLiteral("level"), level}, {QStringLiteral("text"), text}, {QStringLiteral("timestamp"), now()}};
  if (!source.isEmpty()) entry.insert(QStringLiteral("source"), source);
  m_console.append(entry);
  while (m_console.size() > kConsoleEntries) m_console.removeFirst();
}

void PreviewAutomationPage::addFailedLoad(const QUrl& url, const QString& error) {
  m_failedLoads.append(QJsonObject{
      {QStringLiteral("url"), url.toString()},
      {QStringLiteral("method"), QStringLiteral("GET")},
      {QStringLiteral("status"), QJsonValue::Null},
      {QStringLiteral("failed"), true},
      {QStringLiteral("errorText"), error},
      {QStringLiteral("timestamp"), now()},
  });
  while (m_failedLoads.size() > kConsoleEntries) m_failedLoads.removeFirst();
}
