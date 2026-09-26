#pragma once

#include <react/renderer/components/HalC2MarkdownTextSpec/EventEmitters.h>
#include <react/renderer/components/HalC2MarkdownTextSpec/Props.h>
#include <react/renderer/components/HalC2MarkdownTextSpec/States.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>

namespace facebook::react {
extern const char HalC2MarkdownTextRunComponentName[];

using HalC2MarkdownTextRunShadowNode = ConcreteViewShadowNode<
    HalC2MarkdownTextRunComponentName,
    HalC2MarkdownTextRunProps,
    HalC2MarkdownTextRunEventEmitter,
    HalC2MarkdownTextRunState>;
}
