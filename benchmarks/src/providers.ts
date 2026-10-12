export const providers = [
  "muse",
  "chatgpt",
  "claude",
  "grok",
  "codexCLI",
  "claudeCode",
  "dots",
  "grokbot",
  "os3",
  "hark",
] as const;
export type Provider = (typeof providers)[number];
export function observationMethod(method: string | null): string {
  if (!method) return "unsupported-or-unknown";
  if (
    method.startsWith("DOM") ||
    method.startsWith("web-") ||
    method.startsWith("scoped DOM")
  )
    return "DOM observation; native receipt";
  if (method.startsWith("Messages") || method.startsWith("messages"))
    return "Messages polling; native receipt";
  if (
    method.startsWith("CLI") ||
    method.startsWith("cli") ||
    method.startsWith("final-only native output")
  )
    return "CLI process observation; native receipt";
  if (
    method.startsWith("Grok Bot") ||
    method.startsWith("grokBot") ||
    method.startsWith("bot")
  )
    return "Bot callback; native receipt";
  return "unclassified observation method";
}
