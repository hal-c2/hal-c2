#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QUrl>

// Spawns the Node desktop host and waits for its `ready` line: the URL to hand
// to the web view and, for the node the host started, where the shell's own
// client (NodeClient) connects.
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
  void ready(const QUrl& url);
  // Emitted before `ready` for every node launch: where the shell's own client
  // connects and its bearer. A URL that is not a node comes without it.
  void nodeAvailable(const QUrl& origin, const QString& token);
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
