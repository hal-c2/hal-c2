#pragma once

#include <QColor>
#include <QPointer>
#include <QQuickTextDocument>
#include <QSyntaxHighlighter>

// The composer's rich text (Settings → General, "Rich text composer"): the
// draft stays Markdown, and while `rich` is on its inline formatting is drawn
// as it will read: **bold** bold, *italic* slanted, `code` in the code font,
// ~~struck~~ struck through and headings bold, with the markers dimmed beside
// them. Off, the text is plain. QML: ComposerHighlighter { document:
// input.textDocument; rich: true }.
class ComposerHighlighter : public QSyntaxHighlighter {
  Q_OBJECT
  Q_PROPERTY(QQuickTextDocument* document READ quickDocument WRITE setQuickDocument NOTIFY documentChanged)
  Q_PROPERTY(bool rich READ rich WRITE setRich NOTIFY richChanged)
  Q_PROPERTY(QColor markerColor READ markerColor WRITE setMarkerColor NOTIFY markerColorChanged)
  Q_PROPERTY(QString codeFont READ codeFont WRITE setCodeFont NOTIFY codeFontChanged)

public:
  explicit ComposerHighlighter(QObject* parent = nullptr);

  QQuickTextDocument* quickDocument() const { return m_document; }
  void setQuickDocument(QQuickTextDocument* document);
  bool rich() const { return m_rich; }
  void setRich(bool rich);
  QColor markerColor() const { return m_markerColor; }
  void setMarkerColor(const QColor& color);
  QString codeFont() const { return m_codeFont; }
  void setCodeFont(const QString& family);

signals:
  void documentChanged();
  void richChanged();
  void markerColorChanged();
  void codeFontChanged();

protected:
  void highlightBlock(const QString& text) override;

private:
  QPointer<QQuickTextDocument> m_document;
  bool m_rich = false;
  QColor m_markerColor;
  QString m_codeFont;
};
