#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QUrl>

// Spawns the Node desktop host and waits for its `ready` line: where the
// shell's own client (McClient) connects, and its bearer.
class BackendProcess : public QObject {
  Q_OBJECT

public:
  struct Options {
    QString nodeExecutable;
    QString hostEntry;
    QStringList hostArguments;
  };

  explicit BackendProcess(Options options, QObject* parent = nullptr);

  void start();
  void stop();

signals:
  void ready(const QUrl& origin, const QString& token);
  void failed(const QString& message);

private:
  void readStdout();
  void handleLine(const QByteArray& line);

  Options m_options;
  QProcess m_process;
  QByteArray m_stdoutBuffer;
  bool m_announced = false;
  // The host said why it failed; its exit that follows adds nothing.
  bool m_reportedError = false;
  bool m_stopping = false;
};
