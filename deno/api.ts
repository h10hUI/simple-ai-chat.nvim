import Anthropic from "@anthropic-ai/sdk";

export interface StreamInput {
  model: string;
  system?: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  max_tokens: number;
}

export async function* streamText(input: StreamInput): AsyncGenerator<string> {
  const client = new Anthropic();
  const stream = client.messages.stream({
    model: input.model,
    system: input.system || undefined,
    messages: input.messages,
    max_tokens: input.max_tokens,
  });
  for await (const event of stream) {
    if (
      event.type === "content_block_delta" &&
      event.delta.type === "text_delta"
    ) {
      yield event.delta.text;
    }
  }
}
