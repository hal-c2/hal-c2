#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QObject>
#include <QSet>
#include <QSize>
#include <QStringList>
#include <QVariant>

#include <optional>

class NodeClient;
class ShellBridge;
class ShellStore;

// Where a thread's terminals run: the node that owns the thread, and the
// launch context every terminal of the thread starts with.
struct TerminalPlace {
  QString node;
  QString environmentId;
  QString threadId;
  QString cwd;
  QString worktreePath;  // empty without a worktree
  QJsonObject env;
  QJsonArray scripts;

  QJsonObject launchInput(const QString& terminalId) const;
};

// One terminal the drawer shows: attached to the node's session with a
// `terminal` shape for as long as it lives. The QML Terminal feeds `write` and
// `resize` and draws `output`; `replaced` hands it a whole new screen (attach,
// reattach after a reconnect, clear, restart). The transcript lets a Terminal
// created after the attach (a reloaded rice) catch up.
class TerminalSession : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString terminalId READ terminalId CONSTANT)

public:
  TerminalSession(NodeClient* client, const TerminalPlace& place, const QString& terminalId, QSize size,
                  QObject* parent = nullptr);
  ~TerminalSession() override;

  QString terminalId() const { return m_terminalId; }
  QSize size() const { return m_sent; }

  Q_INVOKABLE QString transcript() const { return m_transcript.join(QString()); }
  // Keystrokes, pastes and replies from the Terminal: sent one request at a
  // time, since the node runs each RPC on its own and would reorder them.
  Q_INVOKABLE void write(const QString& data);
  // Only the latest size matters; one resize is in flight at a time.
  Q_INVOKABLE void resize(int columns, int rows);

signals:
  void output(const QString& data);
  void replaced(const QString& history);
  void resized(QSize size);
  // The node closed the terminal (from this or another client).
  void closed();

private:
  void onFrame(const QJsonObject& frame);
  void append(const QString& data);
  void replace(const QString& history);
  void note(const QString& text);
  void flushWrites();
  void flushResize();

  NodeClient* m_client;
  QString m_environmentId;
  QString m_threadId;
  QString m_terminalId;
  int m_subscription = 0;
  bool m_attached = false;
  QStringList m_transcript;
  qsizetype m_transcriptSize = 0;
  QString m_pendingWrite;
  bool m_writing = false;
  QSize m_wanted;
  QSize m_sent;
  bool m_resizing = false;
};

// The drawer's terminals for the thread on screen, one row per session.
// Rows are inserted and removed one by one so the Terminal items the drawer
// made for the others keep their screens.
class TerminalTabs : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
  enum Role { TerminalIdRole = Qt::UserRole + 1, LabelRole, BusyRole, SessionRole };

  struct Row {
    QString terminalId;
    QString label;
    bool busy = false;
    TerminalSession* session = nullptr;
  };

  using QAbstractListModel::QAbstractListModel;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  const QList<Row>& rows() const { return m_rows; }
  int indexOf(const QString& terminalId) const;
  void insert(int index, const Row& row);
  // Deletes the row's session.
  void remove(int index);
  void update(int index, const QString& label, bool busy);
  void clear();

signals:
  void countChanged();

private:
  QList<Row> m_rows;
};

// The terminal drawer, native: which thread's terminals are shown, whether the
// drawer is open and how tall, the tabs, and the RPCs behind them. The thread
// (drafts too), its project root, worktree and scripts are what the page shows
// in its header (`workspace`); the terminals come from the node. They are
// attached the first time the drawer opens on that thread and stay attached
// while the thread is on screen, so hiding the drawer keeps their output.
class TerminalController : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool available READ available NOTIFY changed)
  Q_PROPERTY(bool open READ isOpen NOTIFY changed)
  Q_PROPERTY(int height READ height NOTIFY changed)
  Q_PROPERTY(QString activeTerminalId READ activeTerminalId NOTIFY changed)
  Q_PROPERTY(TerminalTabs* tabs READ tabs CONSTANT)

public:
  static constexpr int maxTerminals = 6;
  static constexpr int minimumHeight = 180;

  TerminalController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate();
  bool isActive() const { return m_active; }
  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

  bool available() const { return m_place.has_value(); }
  bool isOpen() const;
  int height() const { return m_height; }
  QString activeTerminalId() const;
  TerminalTabs* tabs() { return &m_tabs; }

signals:
  void changed();
  // The drawer should move the keyboard to the active terminal.
  void focusRequested();

private:
  struct Summary {
    QString label;
    bool busy = false;
  };
  struct ThreadUi {
    bool open = false;
    QString active;
    // Opened here and not yet listed by the node.
    QSet<QString> local;
    // Closed here; ignored until the node confirms.
    QSet<QString> closing;
  };

  std::optional<TerminalPlace> placeFor(const QVariantMap& workspace) const;
  void refresh();
  void syncTabs();
  QStringList terminalIds() const;
  void watch(const QString& node, const QString& environmentId);
  void onTerminals(const QString& environmentId, const QJsonObject& event);
  bool setOpen(bool open);
  void openTerminal(const QString& terminalId);
  void closeTerminal(const QString& terminalId);
  void runScript(const QString& scriptId);
  QString nextTerminalId() const;
  TerminalSession* session(const QString& terminalId) const;
  void toast(const QString& title, const QString& description);

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QString m_threadKey;
  std::optional<TerminalPlace> m_place;
  // Whether the thread on screen has its terminals attached.
  bool m_attached = false;
  int m_height = 280;
  // The size the last terminal settled on, for the next one to open at.
  QSize m_size;
  QHash<QString, ThreadUi> m_ui;
  // Terminals the node lists, per thread key.
  QHash<QString, QMap<QString, Summary>> m_known;
  // The `terminals` subscription per node name.
  QHash<QString, int> m_watched;
  TerminalTabs m_tabs;
};
