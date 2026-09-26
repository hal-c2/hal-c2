#pragma once

#include <react/renderer/components/HalC2MarkdownTextSpec/EventEmitters.h>
#include <react/renderer/components/HalC2MarkdownTextSpec/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/textlayoutmanager/TextLayoutManager.h>
#include <react/renderer/core/LayoutContext.h>
#include <react/renderer/core/ShadowNode.h>

#include <string>
#include <vector>

namespace facebook::react {

extern const char HalC2MarkdownTextComponentName[];

struct HalC2MarkdownTextParagraphStyleRange {
  size_t location;
  size_t length;
  Float firstLineHeadIndent;
  Float headIndent;
  Float paragraphSpacing;
};

struct HalC2MarkdownTextAttachmentRange {
  size_t location;
  size_t length;
  std::string imageUri;
  /// Recolor the loaded image with the run's foreground color, like `sf:` symbols.
  bool tintWithForeground;
  Float chipWidth = 0;
  Float chipHeight = 0;
};

inline Float HalC2MarkdownTextAttachmentSize(const HalC2MarkdownTextAttachmentRange &) {
  return 14;
}

inline Float HalC2MarkdownTextAttachmentBaselineOffset(
    const HalC2MarkdownTextAttachmentRange &) {
  return -2;
}

class HalC2MarkdownTextStateReal final {
 public:
  AttributedString attributedString;
  std::vector<HalC2MarkdownTextParagraphStyleRange> paragraphStyleRanges;
  std::vector<HalC2MarkdownTextAttachmentRange> attachmentRanges;
};

class HalC2MarkdownTextShadowNode final : public ConcreteViewShadowNode<
HalC2MarkdownTextComponentName,
HalC2MarkdownTextProps,
HalC2MarkdownTextEventEmitter,
HalC2MarkdownTextStateReal> {
public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  HalC2MarkdownTextShadowNode(
   const ShadowNode& sourceShadowNode,
   const ShadowNodeFragment& fragment
  );

  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::LeafYogaNode);
    traits.set(ShadowNodeTraits::Trait::MeasurableYogaNode);
    return traits;
  }

  void layout(LayoutContext layoutContext) override;

  Size measureContent(
      const LayoutContext& layoutContext,
      const LayoutConstraints& layoutConstraints) const override;

private:
  mutable AttributedString _attributedString;
  mutable std::vector<HalC2MarkdownTextParagraphStyleRange> _paragraphStyleRanges;
  mutable std::vector<HalC2MarkdownTextAttachmentRange> _attachmentRanges;
};
} // namespace facebook::React
