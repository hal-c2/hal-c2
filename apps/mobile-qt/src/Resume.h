#pragma once

#include <QObject>
#include <functional>
#include <optional>

class McClient;

// The phone back from a long stay in the background. The system may have
// frozen its socket there without closing it, and the check the client makes
// on coming to the foreground waits seconds for an answer that will not come.
// After `threshold` in the background, a connection that still looks ready is
// replaced at once (legacy apps/mobile: ten seconds). A shorter stay is left to
// that check, and a connection that is not ready to the client's own retry.
class Resume : public QObject {
public:
  // Milliseconds on a clock that keeps counting while the app is suspended.
  using Clock = std::function<qint64()>;

  explicit Resume(McClient* client, QObject* parent = nullptr);

  void setThreshold(int ms) {
    m_threshold = ms;
  }
  int threshold() const {
    return m_threshold;
  }
  void setClock(Clock clock) {
    m_clock = std::move(clock);
  }

  // The app's state as the system reports it (QGuiApplication::applicationStateChanged).
  void stateChanged(Qt::ApplicationState state);

private:
  McClient* m_client;
  int m_threshold = 10000;
  Clock m_clock;
  // When the app went to the background; empty while it is not there.
  std::optional<qint64> m_since;
};
