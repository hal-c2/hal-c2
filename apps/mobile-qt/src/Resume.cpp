#include "Resume.h"

#include <QDateTime>
#include <QGuiApplication>
#include <utility>

#include "McClient.h"

Resume::Resume(McClient* client, QObject* parent) : QObject(parent), m_client(client), m_clock([] { return QDateTime::currentMSecsSinceEpoch(); }) {
  if (qGuiApp) connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, &Resume::stateChanged);
}

void Resume::stateChanged(Qt::ApplicationState state) {
  switch (state) {
    case Qt::ApplicationHidden:
    case Qt::ApplicationSuspended:
      // Counted from when it left; a move from hidden to suspended is the same stay.
      if (!m_since) m_since = m_clock();
      return;
    case Qt::ApplicationInactive:
      // A notification shade or a system dialog over the app is no stay away.
      return;
    case Qt::ApplicationActive:
      break;
  }
  const std::optional<qint64> since = std::exchange(m_since, std::nullopt);
  if (since && m_clock() - *since >= m_threshold && m_client->isReady()) m_client->reconnect();
}
