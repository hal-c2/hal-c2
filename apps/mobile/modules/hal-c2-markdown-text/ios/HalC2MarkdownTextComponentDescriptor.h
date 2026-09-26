#pragma once

#include "HalC2MarkdownTextShadowNode.h"

#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>

namespace facebook::react {
using HalC2MarkdownTextComponentDescriptor = ConcreteComponentDescriptor<HalC2MarkdownTextShadowNode>;

void HalC2MarkdownTextSpec_registerComponentDescriptorsFromCodegen(
  std::shared_ptr<const ComponentDescriptorProviderRegistry> registry);
}
