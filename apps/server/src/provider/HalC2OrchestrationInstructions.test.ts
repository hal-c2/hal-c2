import { assert, describe, it } from "@effect/vitest";

import {
  HALC2_ORCHESTRATION_INSTRUCTIONS,
  halc2AcpPromptWithInstructions,
  halc2OrchestrationPromptForFirstRun,
  halc2OrchestrationSystemPrompt,
} from "./HalC2OrchestrationInstructions.ts";

describe("HAL-C2 orchestration provider instructions", () => {
  it("distinguishes delegated subagents from ordinary top-level threads", () => {
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "Use `delegate_task`");
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "ordinary top-level HAL-C2 conversations");
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "Never use them merely");
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "cross-provider");
  });

  it("documents structured schedules instead of JSON strings", () => {
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "structured object, never as JSON text");
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, '"everyMs":3600000');
    assert.include(HALC2_ORCHESTRATION_INSTRUCTIONS, "bindToCurrentThread=false");
  });

  it("injects prompt fallback only for an MCP-enabled first run", () => {
    const prompt = "Inspect the repository.";
    const injected = halc2OrchestrationPromptForFirstRun({
      prompt,
      runOrdinal: 1,
      hasHalC2Mcp: true,
    });

    assert.include(injected, "<halc2_orchestration_instructions>");
    assert.include(injected, `<user_request>\n${prompt}\n</user_request>`);
    assert.equal(
      halc2OrchestrationPromptForFirstRun({ prompt, runOrdinal: 2, hasHalC2Mcp: true }),
      prompt,
    );
    assert.equal(
      halc2OrchestrationPromptForFirstRun({ prompt, runOrdinal: 1, hasHalC2Mcp: false }),
      prompt,
    );
  });

  it("only exposes the system prompt when the HAL-C2 MCP server is attached", () => {
    assert.equal(halc2OrchestrationSystemPrompt(false), undefined);
    assert.equal(halc2OrchestrationSystemPrompt(true), HALC2_ORCHESTRATION_INSTRUCTIONS);
  });

  it("gives ACP sessions provider-neutral mode, browser, and orchestration guidance", () => {
    const injected = halc2AcpPromptWithInstructions({
      prompt: "Inspect the repository.",
      state: { interactionMode: "default", hasHalC2Mcp: true },
    });

    assert.include(injected, "HAL-C2 interaction mode: Default");
    assert.include(injected, "HAL-C2 collaborative browser");
    assert.include(injected, "HAL-C2 orchestration");
    assert.include(injected, "<user_request>\nInspect the repository.\n</user_request>");
  });

  it("reinjects ACP guidance only when mode or tool availability changes", () => {
    const prompt = "Continue.";
    const defaultState = { interactionMode: "default", hasHalC2Mcp: true } as const;

    assert.equal(
      halc2AcpPromptWithInstructions({ prompt, state: defaultState, previousState: defaultState }),
      prompt,
    );
    assert.include(
      halc2AcpPromptWithInstructions({
        prompt,
        state: { ...defaultState, interactionMode: "plan" },
        previousState: defaultState,
      }),
      "HAL-C2 interaction mode: Plan",
    );
    const withoutMcp = halc2AcpPromptWithInstructions({
      prompt,
      state: { interactionMode: "default", hasHalC2Mcp: false },
    });
    assert.include(withoutMcp, "HAL-C2 interaction mode: Default");
    assert.notInclude(withoutMcp, "HAL-C2 collaborative browser");
    assert.notInclude(withoutMcp, "HAL-C2 orchestration");
  });
});
