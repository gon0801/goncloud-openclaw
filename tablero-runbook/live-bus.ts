/**
 * live-bus.ts — sync fire-and-forget al BFF de Gonserver (opcional).
 *
 * Tras un `runbook.progress.set` exitoso avisa:
 *   POST ${LIVE_BUS_URL}/sync/progress/${fase}
 *   Authorization: Bearer ${LIVE_WRITE_TOKEN}
 *
 * Sin LIVE_WRITE_TOKEN → no-op. Nunca lanza ni bloquea el RPC. Timeout ~2 s.
 * Default de URL: loopback; en Tailscale documentado `http://100.127.167.103:8787`.
 */
export const DEFAULT_LIVE_BUS_URL = "http://127.0.0.1:8787";
export const LIVE_BUS_TIMEOUT_MS = 2_000;

type FetchLike = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

let fetchInyectado: FetchLike | undefined;

/** Solo tests: sustituye `fetch` sin tocar el global. */
export function _setFetchForTest(fn: FetchLike | undefined): void {
  fetchInyectado = fn;
}

function leerEnv(): { url: string; token: string | undefined } {
  const raw = process.env["LIVE_BUS_URL"];
  const url =
    typeof raw === "string" && raw.length > 0
      ? raw.replace(/\/+$/, "")
      : DEFAULT_LIVE_BUS_URL;
  const tok = process.env["LIVE_WRITE_TOKEN"];
  const token =
    typeof tok === "string" && tok.length > 0 ? tok : undefined;
  return { url, token };
}

/**
 * Avisa al bus de progreso. Fire-and-forget: el caller no espera ni atrapa.
 * Cualquier fallo (red, abort, fetch ausente) se traga.
 */
export function syncProgress(fase: string): void {
  try {
    const { url, token } = leerEnv();
    if (!token) return;

    const fetchFn = fetchInyectado ?? globalThis.fetch;
    if (typeof fetchFn !== "function") return;

    const target = `${url}/sync/progress/${encodeURIComponent(fase)}`;
    void Promise.resolve(
      fetchFn(target, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(LIVE_BUS_TIMEOUT_MS),
      }),
    ).catch(() => {
      /* fail-open: el tablero no depende del bus */
    });
  } catch {
    /* nunca propagar */
  }
}
