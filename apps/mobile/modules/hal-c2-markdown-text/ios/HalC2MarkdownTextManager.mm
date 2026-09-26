#import <React/RCTViewManager.h>
#import <React/RCTUIManager.h>
#import "RCTBridge.h"
#import "Utils.h"

@interface HalC2MarkdownTextManager : RCTViewManager
@end

@implementation HalC2MarkdownTextManager

RCT_EXPORT_MODULE(HalC2MarkdownText)

- (UIView *)view
{
  return [[UIView alloc] init];
}

RCT_CUSTOM_VIEW_PROPERTY(color, NSString, UIView)
{
}

@end

@interface HalC2MarkdownTextRunManager : RCTViewManager
@end

@implementation HalC2MarkdownTextRunManager

RCT_EXPORT_MODULE(HalC2MarkdownTextRun)

- (UIView *)view
{
  return nil;
}

@end
