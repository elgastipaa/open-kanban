/** biome-ignore-all lint/style/noNonNullAssertion: Manually verified */
import { createBrowserClient } from "@supabase/ssr";

let sessionEpoch = 0;
let sessionRequestController = new AbortController();

export function getSessionEpoch(): number {
  return sessionEpoch;
}

export function abortPendingSessionRequests(): void {
  sessionEpoch += 1;
  sessionRequestController.abort();
  sessionRequestController = new AbortController();
}

function fetchForCurrentSession(input: RequestInfo | URL, init?: RequestInit) {
  const signals = [sessionRequestController.signal, init?.signal].filter(
    (signal): signal is AbortSignal => signal !== null && signal !== undefined,
  );
  const signal = signals.length === 1 ? signals[0] : AbortSignal.any(signals);
  return globalThis.fetch(input, { ...init, signal });
}

export function createClient() {
  let client: ReturnType<typeof createBrowserClient>;

  client = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_PUBLIC_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      global: { fetch: fetchForCurrentSession },
      realtime: {
        worker: true,
        heartbeatCallback: (status) => {
          if (status === "disconnected") {
            client?.realtime?.connect();
          }
        },
      },
    },
  );

  return client;
}
