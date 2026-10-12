export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
  ) {
    super(code);
  }
}
export function requireValue(
  value: unknown,
  code = "invalid_input",
  status = 400,
): asserts value {
  if (!value) throw new HttpError(status, code);
}
export const securityHeaders = {
  "cache-control": "no-store, max-age=0",
  "x-robots-tag": "noindex, nofollow, noarchive",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "content-security-policy":
    "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
};
export function json(value: unknown, status = 200) {
  return Response.json(value, { status, headers: securityHeaders });
}
export function text(value: unknown, max = 10000): string {
  requireValue(typeof value === "string" && value.length <= max);
  return value;
}
export function id(value: unknown): string {
  const s = text(value, 128);
  requireValue(/^[A-Za-z0-9._:-]{1,128}$/.test(s));
  return s;
}
export function object(value: unknown): Record<string, unknown> {
  requireValue(value && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}
export function keys(value: Record<string, unknown>, allowed: string[]) {
  requireValue(
    Object.keys(value).every((k) => allowed.includes(k)),
    "unknown_fields",
  );
}
export async function body(
  request: Request,
  max = 1024 * 1024,
): Promise<{ value: unknown; raw: string }> {
  requireValue(
    !request.headers.has("content-encoding"),
    "compressed_input_not_supported",
    415,
  );
  requireValue(
    request.headers.get("content-type")?.split(";")[0] === "application/json",
    "json_required",
    415,
  );
  const reader = request.body?.getReader();
  requireValue(reader, "body_required");
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > max) {
        await reader.cancel();
        throw new HttpError(413, "body_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const data = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk, offset);
    offset += chunk.length;
  }
  let raw: string;
  try {
    raw = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
      data,
    );
    return { value: JSON.parse(raw), raw };
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}
export function canonical(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string")
    return JSON.stringify(value);
  if (typeof value === "number") {
    requireValue(Number.isSafeInteger(value), "integer_required");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  const obj = object(value);
  const names = Object.keys(obj).sort();
  requireValue(
    names.every((k) => /^[\x20-\x7e]+$/.test(k)),
    "ascii_keys_required",
  );
  return (
    "{" +
    names.map((k) => JSON.stringify(k) + ":" + canonical(obj[k])).join(",") +
    "}"
  );
}
export async function hash(value: string | Uint8Array): Promise<string> {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : value;
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  )
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
export const now = () => new Date().toISOString();
