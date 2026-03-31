/**
 * AI agent with durable tool calls.
 *
 * Pattern: init → loop { callLLM → executeTool → updateContext } → synthesize
 *
 * Each LLM call and tool execution is checkpointed. If the agent crashes
 * mid-loop, it resumes from the last completed step — no re-burning tokens.
 */

import { DBOS } from "@dbos-inc/dbos-sdk";

// --- Types ---

interface AgentContext {
  messages: Array<{ role: string; content: string }>;
  toolResults: Array<{ tool: string; result: unknown }>;
}

interface LLMResponse {
  content: string;
  toolCall?: { name: string; args: Record<string, unknown> };
  done: boolean;
}

// --- Steps ---

async function callLLM(
  messages: Array<{ role: string; content: string }>,
): Promise<LLMResponse> {
  // Replace with your actual LLM API call
  // This is a step, so it's checkpointed and won't re-run on recovery
  const response = await fetch("https://api.example.com/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ messages, model: "claude-sonnet-4-20250514" }),
  });
  return await response.json();
}

async function executeTool(
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  // Dispatch to your tool implementations
  switch (name) {
    case "search":
      return { results: [`result for ${args.query}`] };
    case "calculate":
      return { result: eval(String(args.expression)) };
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

// --- Workflow ---

async function agentLoopWorkflow(
  userPrompt: string,
  maxIterations: number = 10,
): Promise<string> {
  const ctx: AgentContext = {
    messages: [{ role: "user", content: userPrompt }],
    toolResults: [],
  };

  for (let i = 0; i < maxIterations; i++) {
    // Checkpointed LLM call
    const response = await DBOS.runStep(
      () => callLLM(ctx.messages),
      { name: `llm-call-${i}`, retriesAllowed: true, maxAttempts: 3 },
    );

    ctx.messages.push({ role: "assistant", content: response.content });

    if (response.done || !response.toolCall) {
      return response.content;
    }

    // Checkpointed tool execution
    const toolResult = await DBOS.runStep(
      () => executeTool(response.toolCall!.name, response.toolCall!.args),
      { name: `tool-${response.toolCall.name}-${i}` },
    );

    ctx.toolResults.push({ tool: response.toolCall.name, result: toolResult });
    ctx.messages.push({
      role: "user",
      content: `Tool "${response.toolCall.name}" returned: ${JSON.stringify(toolResult)}`,
    });
  }

  return ctx.messages[ctx.messages.length - 1].content;
}

// --- Registration ---

export const agentLoop = DBOS.registerWorkflow(agentLoopWorkflow, {
  name: "agentLoop",
});
