import { streamText } from "./api.ts";

if (!Deno.env.get("ANTHROPIC_API_KEY")) {
  console.error("ANTHROPIC_API_KEY is not set");
  Deno.exit(1);
}

const raw = await new Response(Deno.stdin.readable).text();
const input = JSON.parse(raw);

const encoder = new TextEncoder();
try {
  for await (const delta of streamText(input)) {
    await Deno.stdout.write(encoder.encode(delta));
  }
  await Deno.stdout.write(encoder.encode("\n[DONE]\n"));
} catch (err) {
  const e = err as Error;
  console.error(`${e.name}: ${e.message}`);
  Deno.exit(1);
}
