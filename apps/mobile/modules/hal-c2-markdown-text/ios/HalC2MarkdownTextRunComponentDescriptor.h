#pragma once

#include "HalC2MarkdownTextRunShadowNode.h"

#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>

namespace facebook::react {
using HalC2MarkdownTextRunComponentDescriptor = ConcreteComponentDescriptor<HalC2MarkdownTextRunShadowNode>;

void HalC2MarkdownTextRunSpec_registerComponentDescriptorsFromCodegen(
  std::shared_ptr<const ComponentDescriptorProviderRegistry> registry);
}
