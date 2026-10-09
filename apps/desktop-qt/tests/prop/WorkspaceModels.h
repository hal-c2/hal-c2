#pragma once

// What the workspace properties check of a Qt list model besides its rows:
// that QAbstractItemModelTester has nothing to say, and that a view following
// only the model's signals (ModelMirror) sees what data() says now, so no row
// changes without the signal a ListView redraws on.
//
//   ModelMirror mirror(&model);
//   ... run a command ...
//   RC_ASSERT(mirror.problems().isEmpty());

#include <QAbstractItemModel>
#include <QAbstractItemModelTester>
#include <QHash>
#include <QList>
#include <QLoggingCategory>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <algorithm>
#include <memory>

namespace halc2::prop {

class ModelMirror {
public:
  explicit ModelMirror(QAbstractItemModel* model) : m_model(model) {
    m_roles = model->roleNames().keys();
    std::sort(m_roles.begin(), m_roles.end());
    m_rows = read(0, model->rowCount() - 1);
    using M = QAbstractItemModel;
    m_connections = {
        QObject::connect(model, &M::rowsInserted, [this](const QModelIndex&, int first, int last) {
          const QList<Row> rows = read(first, last);
          for (int i = 0; i < rows.size(); ++i) m_rows.insert(first + i, rows.at(i));
        }),
        QObject::connect(model, &M::rowsRemoved, [this](const QModelIndex&, int first, int last) {
          if (first < 0 || last >= m_rows.size() || last < first) {
            m_problems.append(QStringLiteral("rowsRemoved %1..%2 of %3 rows").arg(first).arg(last).arg(m_rows.size()));
            return;
          }
          m_rows.remove(first, last - first + 1);
        }),
        QObject::connect(model, &M::rowsMoved, [this](const QModelIndex&, int first, int last, const QModelIndex&, int to) {
          const QList<Row> moved = m_rows.mid(first, last - first + 1);
          m_rows.remove(first, last - first + 1);
          const int at = to > first ? to - int(moved.size()) : to;
          for (int i = 0; i < moved.size(); ++i) m_rows.insert(at + i, moved.at(i));
        }),
        QObject::connect(model, &M::dataChanged, [this](const QModelIndex& from, const QModelIndex& to, const QList<int>& roles) {
          for (int row = from.row(); row <= to.row() && row < m_rows.size(); ++row) {
            for (const int role : roles.isEmpty() ? m_roles : roles) {
              m_rows[row].insert(role, m_model->data(m_model->index(row, 0), role));
            }
          }
        }),
        QObject::connect(model, &M::modelReset, [this] { m_rows = read(0, m_model->rowCount() - 1); }),
        QObject::connect(model, &M::layoutChanged, [this] { m_rows = read(0, m_model->rowCount() - 1); }),
    };
    m_tester = std::make_unique<QAbstractItemModelTester>(model, QAbstractItemModelTester::FailureReportingMode::Warning);
    s_current = this;
    m_previous = qInstallMessageHandler(&ModelMirror::onMessage);
  }

  ~ModelMirror() {
    qInstallMessageHandler(m_previous);
    s_current = nullptr;
    for (const auto& connection : m_connections) QObject::disconnect(connection);
  }

  // What the tester reported and where the signals and data() disagree now; empty when nothing.
  QStringList problems() const {
    QStringList problems = m_problems;
    const QList<Row> now = read(0, m_model->rowCount() - 1);
    if (now.size() != m_rows.size()) {
      problems.append(QStringLiteral("the signals say %1 rows, the model has %2").arg(m_rows.size()).arg(now.size()));
      return problems;
    }
    const QHash<int, QByteArray> names = m_model->roleNames();
    for (int row = 0; row < now.size(); ++row) {
      for (const int role : m_roles) {
        if (now.at(row).value(role) != m_rows.at(row).value(role)) {
          problems.append(QStringLiteral("row %1 %2 is %3 without a signal (was %4)")
                              .arg(row)
                              .arg(QString::fromUtf8(names.value(role)), now.at(row).value(role).toString(),
                                   m_rows.at(row).value(role).toString()));
        }
      }
    }
    return problems;
  }

private:
  using Row = QHash<int, QVariant>;

  QList<Row> read(int first, int last) const {
    QList<Row> rows;
    for (int row = first; row <= last; ++row) {
      Row values;
      for (const int role : m_roles) values.insert(role, m_model->data(m_model->index(row, 0), role));
      rows.append(values);
    }
    return rows;
  }

  static void onMessage(QtMsgType type, const QMessageLogContext& context, const QString& message) {
    if (s_current && context.category && QLatin1String(context.category) == QLatin1String("qt.modeltest") && type >= QtWarningMsg) {
      s_current->m_problems.append(message);
      return;
    }
    if (s_current && s_current->m_previous) s_current->m_previous(type, context, message);
  }

  static inline ModelMirror* s_current = nullptr;
  QAbstractItemModel* m_model;
  QList<int> m_roles;
  QList<Row> m_rows;
  QStringList m_problems;
  QList<QMetaObject::Connection> m_connections;
  std::unique_ptr<QAbstractItemModelTester> m_tester;
  QtMessageHandler m_previous = nullptr;
};

}  // namespace halc2::prop
