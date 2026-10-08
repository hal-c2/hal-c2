// The composer's pure parts: what the text before the caret asks for
// (composer::trigger), starring models (composer::toggleFavorite) and the rich
// text drawing (ComposerHighlighter).

#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

#include "ComposerHighlighter.h"
#include "ComposerModel.h"
#include "Prop.h"

namespace {

// Text made of the characters the triggers and the Markdown care about.
rc::Gen<QString> composerText() {
  static const std::vector<QChar> alphabet{u'a', u'b', u' ', u'\n', u'/', u'@', u'#', u'$', u'*', u'_', u'`', u'~', u'-'};
  return rc::gen::map(rc::gen::container<std::vector<QChar>>(rc::gen::elementOf(alphabet)),
                      [](const std::vector<QChar>& chars) { return QString(chars.data(), qsizetype(chars.size())); });
}

}  // namespace

class ComposerPureProp : public QObject {
  Q_OBJECT

private slots:
  void triggerStaysBeforeTheCaret() {
    QVERIFY(rc::check("a trigger spans the text it was read from, ending at the caret", [] {
      const QString text = *composerText();
      // The caret at the start is a case of its own.
      const int cursor = *rc::gen::weightedOneOf<int>({{1, rc::gen::just(0)}, {3, rc::gen::inRange(0, int(text.size()) + 1)}});
      const auto found = composer::trigger(text, cursor);
      if (!found) return;
      RC_ASSERT(0 <= found->start);
      RC_ASSERT(found->start < found->end);
      RC_ASSERT(found->end == cursor);
      // The marker, then the query.
      RC_ASSERT(text.mid(found->start + 1, found->end - found->start - 1) == found->query);
    }));
  }

  void starringTogglesOneModel() {
    QVERIFY(rc::check("starring a model stars or unstars it alone", [] {
      const std::vector<QString> instances{QStringLiteral("codex"), QStringLiteral("claude")};
      const std::vector<QString> models{QStringLiteral("gpt-a"), QStringLiteral("gpt-b"), QStringLiteral("opus")};
      const auto toggles = *rc::gen::container<std::vector<std::pair<QString, QString>>>(
          rc::gen::pair(rc::gen::elementOf(instances), rc::gen::elementOf(models)));
      QJsonArray favorites;
      QSet<QString> expected;
      for (const auto& [instance, model] : toggles) {
        favorites = composer::toggleFavorite(favorites, instance, model);
        const QString key = instance + u'\n' + model;
        if (!expected.remove(key)) expected.insert(key);
        RC_ASSERT(composer::modelPrefs(favorites, QJsonValue()).favorites == expected);
        RC_ASSERT(favorites.size() == expected.size());
      }
    }));
  }

  void highlightingKeepsTheText() {
    QVERIFY(rc::check("rich text draws the draft without changing it, inside each line", [] {
      const QString text = *composerText();
      const bool rich = *rc::gen::arbitrary<bool>();
      QTextDocument document;
      document.setPlainText(text);
      ComposerHighlighter highlighter;
      highlighter.setRich(rich);
      highlighter.setDocument(&document);
      highlighter.rehighlight();
      RC_ASSERT(document.toPlainText() == text);
      for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
        const QList<QTextLayout::FormatRange> formats = block.layout()->formats();
        if (!rich) RC_ASSERT(formats.isEmpty());
        for (const QTextLayout::FormatRange& range : formats) {
          RC_ASSERT(range.start >= 0);
          RC_ASSERT(range.length > 0);
          RC_ASSERT(range.start + range.length <= block.length());
        }
      }
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerPureProp)
#include "tst_ComposerPureProp.moc"
