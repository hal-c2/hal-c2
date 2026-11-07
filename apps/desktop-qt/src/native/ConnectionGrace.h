#pragma once

#include <QString>

// Whether a connection coming back up is still held back from the user
// (ConnectionHealthController's `settling`). Told each state the connection's
// icon shows (`see`), and when the grace ran out (`expire`); the owner runs the
// grace's timer for as long as it is `settling()`.
//
// Only a reconnect is held back: a connection that was never up says it is
// connecting at once. What needs the user (no network, pairing, an update, an
// MC that will not send its data) spends the grace until the next connection.
class ConnectionGrace {
public:
  // `state` is the icon's: ready | connecting | retrying | offline |
  // needsPairing | blocked.
  void see(const QString& state) {
    if (state == QLatin1String("ready")) {
      m_now = Now::Up;
    } else if (state == QLatin1String("connecting") || state == QLatin1String("retrying")) {
      if (m_now == Now::Up) m_now = Now::Settling;
    } else {
      m_now = Now::Shown;
    }
  }
  void expire() {
    if (m_now == Now::Settling) m_now = Now::Shown;
  }
  bool settling() const { return m_now == Now::Settling; }

private:
  // Shown: never up, or a problem or the grace's end since it last was.
  enum class Now { Shown, Up, Settling };
  Now m_now = Now::Shown;
};
