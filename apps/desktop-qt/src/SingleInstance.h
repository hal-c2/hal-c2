#pragma once

#include <QLocalServer>
#include <QObject>
#include <QStringList>

#include <functional>

// One running app per HAL-C2 home takes the folders a later launch names:
// `hal-c2-qt ~/code/api` while the app runs hands the folder to the running
// window and exits, so no second MC starts on the same home. The channel is a
// local socket named after the home's state directory.
class SingleInstance : public QObject {
  Q_OBJECT

public:
  explicit SingleInstance(const QString& stateDir, QObject* parent = nullptr);

  // The later launch: hands `folders` to the app already running on this
  // home. False when none is, and the caller starts up as usual.
  static bool forward(const QString& stateDir, const QStringList& folders);

  // The running app: listens for later launches; `open` gets their folders.
  bool listen(std::function<void(const QStringList& folders)> open);

private:
  static QString serverName(const QString& stateDir);

  QString m_name;
  QLocalServer m_server;
};
