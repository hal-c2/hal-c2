#include "HalC2MarkdownTextShadowNode.h"
#include "HalC2MarkdownTextRunShadowNode.h"
#import "HalC2ContextChip.h"
#include <react/renderer/components/view/ViewShadowNode.h>
#import <react/renderer/textlayoutmanager/RCTAttributedTextUtils.h>

#include <algorithm>
#include <cmath>

namespace facebook::react {

static constexpr Float ParagraphStyleEncodingOffset = 1000;
static constexpr auto FileAttachmentNativeIdPrefix = "hal-c2-file:";
static constexpr auto SkillAttachmentNativeIdPrefix = "hal-c2-skill:";
static constexpr auto LinkAttachmentNativeIdPrefix = "hal-c2-link:";

static void applyParagraphStyles(
    NSMutableAttributedString *attributedString,
    const std::vector<HalC2MarkdownTextParagraphStyleRange> &styleRanges)
{
  for (const auto &styleRange : styleRanges) {
    if (styleRange.length == 0 || styleRange.location >= attributedString.length) {
      continue;
    }

    const NSRange markerRange = NSMakeRange(
        styleRange.location,
        MIN(styleRange.length, attributedString.length - styleRange.location));
    const NSRange paragraphRange = [attributedString.string paragraphRangeForRange:markerRange];
    const NSParagraphStyle *existingStyle =
        [attributedString attribute:NSParagraphStyleAttributeName
                            atIndex:paragraphRange.location
                     effectiveRange:nil];
    NSMutableParagraphStyle *paragraphStyle =
        existingStyle ? [existingStyle mutableCopy] : [NSMutableParagraphStyle new];
    paragraphStyle.firstLineHeadIndent = styleRange.firstLineHeadIndent;
    paragraphStyle.headIndent = styleRange.headIndent;
    paragraphStyle.paragraphSpacing = styleRange.paragraphSpacing;
    paragraphStyle.tabStops = @[
      [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft
                                      location:styleRange.headIndent
                                       options:@{}]
    ];
    paragraphStyle.defaultTabInterval = styleRange.headIndent;
    [attributedString addAttribute:NSParagraphStyleAttributeName
                             value:paragraphStyle
                             range:paragraphRange];
  }
}

static void applyAttachments(
    NSMutableAttributedString *attributedString,
    const std::vector<HalC2MarkdownTextAttachmentRange> &attachmentRanges)
{
  for (const auto &attachmentRange : attachmentRanges) {
    if (attachmentRange.length == 0 || attachmentRange.location >= attributedString.length) {
      continue;
    }

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = [[UIImage alloc] init];
    const CGFloat attachmentSize = HalC2MarkdownTextAttachmentSize(attachmentRange);
    attachment.bounds = CGRectMake(
        0,
        HalC2MarkdownTextAttachmentBaselineOffset(attachmentRange),
        attachmentSize,
        attachmentSize);
    NSDictionary *runAttributes =
        [attributedString attributesAtIndex:attachmentRange.location effectiveRange:nil];
    if (attachmentRange.chipWidth > 0) {
      attachment.bounds = HalC2ContextChipBounds(
          runAttributes[NSFontAttributeName],
          CGSizeMake(attachmentRange.chipWidth, attachmentRange.chipHeight));
    }
    const NSRange range = NSMakeRange(
        attachmentRange.location,
        MIN(attachmentRange.length, attributedString.length - attachmentRange.location));
    [attributedString replaceCharactersInRange:range
                          withAttributedString:HalC2MarkdownTextAttachmentString(attachment, runAttributes)];
  }
}

HalC2MarkdownTextShadowNode::HalC2MarkdownTextShadowNode(
   const ShadowNode& sourceShadowNode,
   const ShadowNodeFragment& fragment
) : ConcreteViewShadowNode(sourceShadowNode, fragment) {
};

Size HalC2MarkdownTextShadowNode::measureContent(
  const LayoutContext& layoutContext,
  const LayoutConstraints& layoutConstraints) const {
    const auto &baseProps = getConcreteProps();

    auto baseTextAttributes = TextAttributes::defaultTextAttributes();
    baseTextAttributes.backgroundColor = baseProps.backgroundColor;
    baseTextAttributes.allowFontScaling = baseProps.allowFontScaling;

    Float fontSizeMultiplier = 1.0;
    if (baseTextAttributes.allowFontScaling) {
      fontSizeMultiplier = layoutContext.fontSizeMultiplier;
    }

    auto baseAttributedString = AttributedString{};
    auto paragraphStyleRanges = std::vector<HalC2MarkdownTextParagraphStyleRange>{};
    auto attachmentRanges = std::vector<HalC2MarkdownTextAttachmentRange>{};
    size_t utf16Offset = 0;
    const auto &children = getChildren();
    for (size_t i = 0; i < children.size(); i++) {
      const auto child = children[i].get();
      if (auto textViewChild = dynamic_cast<const HalC2MarkdownTextRunShadowNode *>(child)) {
        auto &props = textViewChild->getConcreteProps();
        auto fragment = AttributedString::Fragment{};
        auto textAttributes = TextAttributes::defaultTextAttributes();

        textAttributes.allowFontScaling = baseProps.allowFontScaling;
        textAttributes.backgroundColor = props.backgroundColor;
        textAttributes.fontSize = props.fontSize * fontSizeMultiplier;
        textAttributes.lineHeight = props.lineHeight * fontSizeMultiplier;
        textAttributes.foregroundColor = props.color;
        const bool hasParagraphStyle = props.shadowRadius >= ParagraphStyleEncodingOffset;
        if (!hasParagraphStyle) {
          textAttributes.textShadowColor = props.shadowColor;
          textAttributes.textShadowOffset = props.shadowOffset;
          textAttributes.textShadowRadius = props.shadowRadius;
        }
        textAttributes.letterSpacing = props.letterSpacing;
        textAttributes.textDecorationColor = props.textDecorationColor;
        textAttributes.fontFamily = props.fontFamily;

        if (props.fontStyle == HalC2MarkdownTextRunFontStyle::Italic) {
          textAttributes.fontStyle = FontStyle::Italic;
        } else {
          textAttributes.fontStyle = FontStyle::Normal;
        }

        if (props.fontWeight == HalC2MarkdownTextRunFontWeight::Bold) {
          textAttributes.fontWeight = FontWeight::Bold;
        } else if (props.fontWeight == HalC2MarkdownTextRunFontWeight::UltraLight) {
          textAttributes.fontWeight = FontWeight::UltraLight;
        } else if (props.fontWeight == HalC2MarkdownTextRunFontWeight::Light) {
          textAttributes.fontWeight = FontWeight::Light;
        } else if (props.fontWeight == HalC2MarkdownTextRunFontWeight::Medium) {
          textAttributes.fontWeight = FontWeight::Medium;
        } else if (props.fontWeight == HalC2MarkdownTextRunFontWeight::Semibold) {
          textAttributes.fontWeight = FontWeight::Semibold;
        } else if (props.fontWeight == HalC2MarkdownTextRunFontWeight::Heavy) {
          textAttributes.fontWeight = FontWeight::Heavy;
        } else {
          textAttributes.fontWeight = FontWeight::Regular;
        }

        if (props.textDecorationLine == HalC2MarkdownTextRunTextDecorationLine::LineThrough) {
          textAttributes.textDecorationLineType = TextDecorationLineType::Strikethrough;
        } else if (props.textDecorationLine == HalC2MarkdownTextRunTextDecorationLine::Underline) {
          textAttributes.textDecorationLineType = TextDecorationLineType::Underline;
        } else {
          textAttributes.textDecorationLineType = TextDecorationLineType::None;
        }

        if (props.textDecorationStyle == HalC2MarkdownTextRunTextDecorationStyle::Solid) {
          textAttributes.textDecorationStyle = TextDecorationStyle::Solid;
        } else if (props.textDecorationStyle == HalC2MarkdownTextRunTextDecorationStyle::Dotted) {
          textAttributes.textDecorationStyle = TextDecorationStyle::Dotted;
        } else if (props.textDecorationStyle == HalC2MarkdownTextRunTextDecorationStyle::Dashed) {
          textAttributes.textDecorationStyle = TextDecorationStyle::Dashed;
        } else if (props.textDecorationStyle == HalC2MarkdownTextRunTextDecorationStyle::Double) {
          textAttributes.textDecorationStyle = TextDecorationStyle::Double;
        }

        if (props.textAlign == HalC2MarkdownTextRunTextAlign::Left) {
          textAttributes.alignment = TextAlignment::Left;
        } else if (props.textAlign == HalC2MarkdownTextRunTextAlign::Right) {
          textAttributes.alignment = TextAlignment::Right;
        } else if (props.textAlign == HalC2MarkdownTextRunTextAlign::Center) {
          textAttributes.alignment = TextAlignment::Center;
        } else if (props.textAlign == HalC2MarkdownTextRunTextAlign::Justify) {
          textAttributes.alignment = TextAlignment::Justified;
        } else if (props.textAlign == HalC2MarkdownTextRunTextAlign::Auto) {
          textAttributes.alignment = TextAlignment::Natural;
        }

        textAttributes.backgroundColor = props.backgroundColor;

        fragment.string = props.text;
        fragment.textAttributes = textAttributes;

        NSString *fragmentText = [NSString stringWithUTF8String:props.text.c_str()];
        const size_t fragmentLength = fragmentText.length;
        if (hasParagraphStyle) {
          paragraphStyleRanges.push_back(HalC2MarkdownTextParagraphStyleRange{
              utf16Offset,
              fragmentLength,
              props.shadowOffset.width,
              props.shadowOffset.height,
              props.shadowRadius - ParagraphStyleEncodingOffset,
          });
        }
        if (props.nativeId.rfind("hal-c2-chip:", 0) == 0 && fragmentLength > 0) {
          const std::string uri = props.nativeId.substr(3);
          NSMutableDictionary *payload =
              [HalC2ContextChipPayload([NSString stringWithUTF8String:uri.c_str()]) mutableCopy];
          // Chips must scale with the paragraph or smaller Dynamic Type sizes clip them.
          // Store the scaled payload so measurement and the rendered bitmap use the same font.
          payload[@"fontSizeMultiplier"] = @(fontSizeMultiplier);
          NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
          NSString *scaledUri = [@"chip:" stringByAppendingString:
              [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
          const CGFloat maxWidth = std::isfinite(layoutConstraints.maximumSize.width)
              ? layoutConstraints.maximumSize.width : 320;
          const CGSize size = HalC2ContextChipSize(payload, maxWidth);
          attachmentRanges.push_back(HalC2MarkdownTextAttachmentRange{
              utf16Offset, 1, std::string(scaledUri.UTF8String), false,
              static_cast<Float>(size.width), static_cast<Float>(size.height),
          });
        } else if (props.nativeId.rfind(FileAttachmentNativeIdPrefix, 0) == 0 && fragmentLength > 0) {
          attachmentRanges.push_back(HalC2MarkdownTextAttachmentRange{
              utf16Offset,
              1,
              props.nativeId.substr(std::char_traits<char>::length(FileAttachmentNativeIdPrefix)),
              false,
          });
        } else if (
            props.nativeId.rfind(SkillAttachmentNativeIdPrefix, 0) == 0 && fragmentLength > 0) {
          attachmentRanges.push_back(HalC2MarkdownTextAttachmentRange{
              utf16Offset,
              1,
              props.nativeId.substr(
                  std::char_traits<char>::length(SkillAttachmentNativeIdPrefix)),
              false,
          });
        } else if (
            props.nativeId.rfind(LinkAttachmentNativeIdPrefix, 0) == 0 && fragmentLength > 0) {
          attachmentRanges.push_back(HalC2MarkdownTextAttachmentRange{
              utf16Offset,
              1,
              props.nativeId.substr(std::char_traits<char>::length(LinkAttachmentNativeIdPrefix)),
              true,
          });
        }
        utf16Offset += fragmentLength;
        baseAttributedString.appendFragment(std::move(fragment));
      }
    }

    _attributedString = baseAttributedString;
    _paragraphStyleRanges = paragraphStyleRanges;
    _attachmentRanges = attachmentRanges;

    NSMutableAttributedString *convertedAttributedString =
        [RCTNSAttributedStringFromAttributedString(baseAttributedString) mutableCopy];
    applyParagraphStyles(convertedAttributedString, paragraphStyleRanges);
    applyAttachments(convertedAttributedString, attachmentRanges);
    // TextKit stacks a paragraph's extra line height above the glyphs. React Native's own
    // layout manager centres them with a baseline offset; do the same, after attachments
    // so chips shift with the words.
    RCTApplyBaselineOffset(convertedAttributedString);

    const CGFloat maximumWidth = std::isfinite(layoutConstraints.maximumSize.width)
        ? layoutConstraints.maximumSize.width
        : CGFLOAT_MAX;
    NSTextStorage *textStorage =
        [[NSTextStorage alloc] initWithAttributedString:convertedAttributedString];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    layoutManager.usesFontLeading = NO;
    NSTextContainer *textContainer =
        [[NSTextContainer alloc] initWithSize:CGSizeMake(maximumWidth, CGFLOAT_MAX)];
    textContainer.lineFragmentPadding = 0;
    textContainer.maximumNumberOfLines = baseProps.numberOfLines;
    if (baseProps.ellipsizeMode == HalC2MarkdownTextEllipsizeMode::Head) {
      textContainer.lineBreakMode = NSLineBreakByTruncatingHead;
    } else if (baseProps.ellipsizeMode == HalC2MarkdownTextEllipsizeMode::Middle) {
      textContainer.lineBreakMode = NSLineBreakByTruncatingMiddle;
    } else if (baseProps.ellipsizeMode == HalC2MarkdownTextEllipsizeMode::Tail) {
      textContainer.lineBreakMode = NSLineBreakByTruncatingTail;
    } else {
      textContainer.lineBreakMode = NSLineBreakByClipping;
    }
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];
    [layoutManager ensureLayoutForTextContainer:textContainer];
    const CGRect usedRect = [layoutManager usedRectForTextContainer:textContainer];

    return {
        std::clamp(
            static_cast<Float>(std::ceil(usedRect.size.width)),
            layoutConstraints.minimumSize.width,
            layoutConstraints.maximumSize.width),
        std::clamp(
            static_cast<Float>(std::ceil(usedRect.size.height)),
            layoutConstraints.minimumSize.height,
            layoutConstraints.maximumSize.height),
    };
}

void HalC2MarkdownTextShadowNode::layout(LayoutContext layoutContext) {
  ensureUnsealed();
  setStateData(HalC2MarkdownTextStateReal{
    _attributedString,
    _paragraphStyleRanges,
    _attachmentRanges,
  });
}
}
