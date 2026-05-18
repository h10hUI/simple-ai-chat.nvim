import Anthropic from "@anthropic-ai/sdk";

export interface StreamInput {
  model: string;
  system?: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  max_tokens: number;
}

const EPHEMERAL = { type: "ephemeral" as const };

export async function* streamText(input: StreamInput): AsyncGenerator<string> {
  const client = new Anthropic();

  // system に cache_control を付与（初回ターンから効く）
  const system = input.system && input.system.length > 0
    ? [{ type: "text" as const, text: input.system, cache_control: EPHEMERAL }]
    : undefined;

  // multi-turn 履歴をキャッシュするため、最後から 2 番目の message（直前 assistant）に
  // breakpoint を入れる。初回送信時（messages.length === 1）は何もしない。
  const cacheIdx = input.messages.length - 2;
  const messages = input.messages.map((m, i) => {
    if (i === cacheIdx) {
      return {
        role: m.role,
        content: [
          { type: "text" as const, text: m.content, cache_control: EPHEMERAL },
        ],
      };
    }
    return { role: m.role, content: m.content };
  });

  const stream = client.messages.stream({
    model: input.model,
    system,
    messages,
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

  // ストリーム完了後、usage を stderr に "USAGE:{json}" 形式で出力
  try {
    const final = await stream.finalMessage();
    const usageLine = "USAGE:" + JSON.stringify(final.usage);
    await Deno.stderr.write(new TextEncoder().encode(usageLine + "\n"));
  } catch (_) {
    // usage 取得失敗は無視
  }
}
