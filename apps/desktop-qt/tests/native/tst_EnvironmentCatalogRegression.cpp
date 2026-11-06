// What tests/prop/tst_EnvironmentCatalogProp.cpp found in EnvironmentCatalog.

#include <QtTest>

#include "EnvironmentCatalog.h"
#include "SecretStore.h"

class EnvironmentCatalogRegression : public QObject {
  Q_OBJECT

private slots:
  // A damaged record was set aside under a name with millisecond resolution:
  // damaged again and read within the same millisecond, the rename found that
  // name taken, and the second damaged record was neither kept nor reported.
  void aSecondDamagedRecordIsSetAsideToo() {
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("saved-environments.json"));
    MemorySecretStore store(std::make_shared<MemorySecretStore::Keys>());
    QStringList asides;
    for (int round = 0; round < 3; ++round) {
      QFile file(path);
      QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
      file.write("{\"version\": 1, \"environments\": [{\"id\": \"r" + QByteArray::number(round));
      file.close();
      EnvironmentCatalog catalog(path, &store);
      catalog.load();
      QVERIFY(!catalog.damaged().isEmpty());
      QVERIFY(!asides.contains(catalog.damaged()));
      asides.append(catalog.damaged());
    }
    for (int round = 0; round < 3; ++round) {
      QFile aside(asides.at(round));
      QVERIFY(aside.open(QIODevice::ReadOnly));
      QVERIFY(aside.readAll().endsWith("\"r" + QByteArray::number(round)));
    }
  }
};

QTEST_GUILESS_MAIN(EnvironmentCatalogRegression)
#include "tst_EnvironmentCatalogRegression.moc"
