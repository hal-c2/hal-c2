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

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Where a thread's terminals run: the environment that owns the thread (the
// MC routes its shapes and RPCs there), and the launch context every terminal
// of the thread starts with.
struct TerminalPlace {
  QString environmentId;
  QString threadId;
  QString cwd;
  QString worktreePath;  // empty without a worktree
  QJsonObject env;
  QJsonArray scripts;
  // A provider's setup terminal: the MC runs it with that instance's env and home.
  QString providerInstanceId;

  QJsonObject launchInput(const QString& terminalId) const;
};

// One terminal the drawer shows: attached to the MC's session with a
// `terminal` shape for as long as it lives. The QML Terminal feeds `write` and
// `resize` and draws `output`; `replaced` hands it a whole new screen (attach,
// reattach after a reconnect, clear, restart). The transcript lets a Terminal
// created after the attach (a reloaded rice) catch up.
class TerminalSession : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString terminalId READ terminalId CONSTANT)

public:
  TerminalSession(McClient* client, const TerminalPlace& place, const QString& terminalId, QSize size,
                  QObject* parent = nullptr);
  ~TerminalSession() override;

  QString terminalId() const { return m_terminalId; }
  QSize size() const { return m_sent; }

  Q_INVOKABLE QString transcript() const { return m_transcript.join(QString()); }
  // Keystrokes, pastes and replies from the Terminal: sent one request at a
  // time, since the MC runs each RPC on its own and would reorder them.
  Q_INVOKABLE void write(const QString& data);
  // Only the latest size matters; one resize is in flight at a time.
  Q_INVOKABLE void resize(int columns, int rows);

signals:
  void output(const QString& data);
  void replaced(const QString& history);
  void resized(QSize size);
  // The MC closed the terminal (from this or another client).
  void closed();
  // Its shell ended on its own.
  void exited();
  // The first snapshot arrived: the shell is running.
  void attached();
  // The MC refused to open the terminal.
  void failed(const QString& reason);

private:
  void onFrame(const QJsonObject& frame);
  void append(const QString& data);
  void replace(const QString& history);
  void note(const QString& text);
  void flushWrites();
  void flushResize();

  McClient* m_client;
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

// The terminals of the thread on screen, the drawer's and the right panel's,
// one row per session, with where each one sits: its split group, its slot
// in the group's row or column, and whether it is the one its group shows
// focused. Rows are inserted and removed one by one so the Terminal items
// made for the others keep their screens.
class TerminalTabs : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
  enum Role {
    TerminalIdRole = Qt::UserRole + 1,
    LabelRole,
    BusyRole,
    SessionRole,
    GroupRole,
    PanelRole,
    SlotRole,
    SpanRole,
    VerticalRole,
    CurrentRole,
  };

  struct Row {
    QString terminalId;
    QString label;
    bool busy = false;
    TerminalSession* session = nullptr;
    // The split group; a terminal never split is a group of its own.
    QString group;
    // In a right panel tab rather than the drawer.
    bool panel = false;
    // Its place among the group's `span` terminals, left to right or top to bottom.
    int slot = 0;
    int span = 1;
    // Stacked rather than side by side.
    bool vertical = false;
    // The one its group has active (the drawer's active terminal, or a
    // panel tab's).
    bool current = false;

    bool sameLayout(const Row& other) const;
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
  // Empties the model and hands its sessions over, alive, by terminal id.
  QHash<QString, TerminalSession*> take();
  // Everything but the session.
  void update(int index, const Row& row);
  void clear();

signals:
  void countChanged();

private:
  QList<Row> m_rows;
};

// The thread's terminals, native: the drawer's (which thread's are shown,
// whether the drawer is open and how tall, its tabs) and the right panel's
// terminal tabs, and the RPCs behind them. The thread (drafts too), its
// project root, worktree and scripts are WorkspaceController's place; the
// terminals come from the MC. They are attached the first time the drawer
// opens on that thread (or a panel tab does) and stay attached while the
// thread is on screen, so hiding the drawer keeps their output, and for the
// last few threads the user left (maxParkedThreads), so does coming back.
//
// Terminals split into groups as the web's drawer does: `terminal.split` and
// `terminal.splitVertical {terminalId?}` add a terminal beside or under one
// (the payload's, else the focused one, else the drawer's active one), at
// most four to a group. A group made for the right panel (addPanelGroup) is
// shown in a `terminal:<group>` tab and never in the drawer; the drawer shows
// every other group, one tab each. Ids are shared: at most six per thread.
class TerminalController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(bool available READ available NOTIFY changed)
  Q_PROPERTY(bool open READ isOpen NOTIFY changed)
  Q_PROPERTY(int height READ height NOTIFY changed)
  Q_PROPERTY(QString activeTerminalId READ activeTerminalId NOTIFY changed)
  // The drawer's shown group (its active terminal's).
  Q_PROPERTY(QString activeGroup READ activeGroup NOTIFY changed)
  // {group: terminal count} for every split or panel group.
  Q_PROPERTY(QVariantMap groupSizes READ groupSizes NOTIFY changed)
  Q_PROPERTY(TerminalTabs* tabs READ tabs CONSTANT)

public:
  static constexpr int maxTerminals = 6;
  static constexpr int maxPerGroup = 4;
  static constexpr int minimumHeight = 180;
  // Threads the user left whose terminals stay attached (the web's
  // MAX_HIDDEN_MOUNTED_TERMINAL_THREADS): coming back shows what they printed
  // meanwhile, with no new attach.
  static constexpr int maxParkedThreads = 10;

  TerminalController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool isActive() const { return m_active; }
  bool handle(const QString& action, const QVariant& payload) override;

  // Where the drawer's height and, per thread, whether it is open and on
  // which terminal are kept across restarts; read at once.
  void setStorePath(const QString& path);

  bool available() const { return m_place.has_value(); }
  bool isOpen() const;
  int height() const { return m_height; }
  QString activeTerminalId() const;
  QString activeGroup() const;
  QVariantMap groupSizes() const;
  TerminalTabs* tabs() { return &m_tabs; }
  // The thread whose terminals these are ("<environment>:<thread id>").
  QString threadKey() const { return m_threadKey; }

  // A terminal took the keyboard: it becomes its group's active one, and the
  // one split and keybindings act on.
  Q_INVOKABLE void focusTerminal(const QString& terminalId);
  // Opens a terminal in a new group of the right panel's; returns the group,
  // or nothing when the thread has no place for terminals or no room.
  QString addPanelGroup();
  // The right panel's groups of a thread, in the order they were added.
  QStringList panelGroups(const QString& threadKey) const;
  // Closes every terminal of the group (deleting their history).
  void closeGroup(const QString& group);
  // Asks before the user's own close of `ids`, as the web's
  // confirmTerminalClose: one question naming every terminal. `accepted` runs
  // on yes; with nothing to close it runs at once.
  void confirmClose(const QStringList& ids, std::function<void()> accepted);
  // The terminals of a split or panel group.
  QStringList groupTerminals(const QString& group) const;
  // As the web app's runProjectScript: in the active terminal, or a new one when
  // that one is busy. False without a place or such a script.
  bool runScript(const QString& scriptId);

signals:
  void changed();
  // The terminal's drawer or panel tab should give it the keyboard.
  void focusRequested(const QString& terminalId);

private:
  struct Summary {
    QString label;
    bool busy = false;
  };
  // A split group, or a right panel tab's.
  struct Group {
    QString id;
    QStringList terminals;
    bool vertical = false;
    bool panel = false;
    QString active;
  };
  struct ThreadUi {
    bool open = false;
    // The drawer's active terminal.
    QString active;
    // Split and panel groups; any other terminal is a group of its own.
    QList<Group> groups;
    // Opened here and not yet listed by the MC.
    QSet<QString> local;
    // Closed here; ignored until the MC confirms.
    QSet<QString> closing;
    // Read from the store and not yet checked against the MC's terminals:
    // the drawer waits for the list rather than open on a terminal that is gone.
    bool restored = false;
  };

  std::optional<TerminalPlace> placeOfWorkspace() const;
  void refresh();
  void syncTabs();
  QStringList terminalIds() const;
  // The drawer's terminals (none of the panel's) among `ids`.
  QStringList drawerIds(const ThreadUi& ui, const QStringList& ids) const;
  static Group* groupOf(ThreadUi& ui, const QString& terminalId);
  static const Group* groupOf(const ThreadUi& ui, const QString& terminalId);
  void split(const QString& terminalId, bool vertical);
  void watch(const QString& environmentId);
  void onTerminals(const QString& environmentId, const QJsonObject& event);
  bool setOpen(bool open);
  void openTerminal(const QString& terminalId);
  void closeTerminal(const QString& terminalId);
  QString nextTerminalId() const;
  TerminalSession* session(const QString& terminalId) const;
  void toast(const QString& title, const QString& description);
  void followLink(const QString& kind, const QString& text, const QString& reportedCwd);
  void save();

  ShellBridge* m_bridge;
  McClient* m_client;
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
  // Terminals the MC lists, per thread key.
  QHash<QString, QMap<QString, Summary>> m_known;
  // The `terminals` subscription per environment.
  QHash<QString, int> m_watched;
  TerminalTabs m_tabs;
  // The terminal that last had the keyboard.
  QString m_focused;
  int m_groupCount = 0;
  // The attached sessions of threads the user left, and where they ran.
  struct Parked {
    QString cwd;
    QHash<QString, TerminalSession*> sessions;
  };
  QHash<QString, Parked> m_parked;
  // Oldest first.
  QStringList m_parkedOrder;
  void park(const QString& threadKey, const QString& cwd);
  void dropParked(const QString& threadKey);
  QString m_storePath;
  QByteArray m_saved;
  // Threads in the order their drawers were last used, oldest first.
  QStringList m_recent;
};
