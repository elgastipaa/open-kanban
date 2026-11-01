"use client";

import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { createClient } from "@/lib/supabase/client";
import type { WebSocketStatus } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

/**
 * Tracks the number of viewers on a board using Supabase Presence.
 * Each viewer gets a random ID on mount and is tracked/untracked on the channel.
 * Gracefully degrades on subscription or tracking errors.
 */
export function usePresence(presenceTopic: string) {
  const [viewerCount, setViewerCount] = useState(1);
  const [isConnected, setIsConnected] = useState(true);

  /** Track if we've already shown the error toast to avoid spam */
  const hasShownErrorRef = useRef(false);

  useEffect(() => {
    const supabase = createClient();
    const ch = supabase.channel(presenceTopic, {
      config: { private: true, presence: { key: generateUUID() } },
    });
    setViewerCount(1);

    ch.on("presence", { event: "sync" }, () => {
      const state = ch.presenceState();
      const count = Object.keys(state).length;
      setViewerCount(Math.max(count, 1));
    });

    ch.subscribe(async (status: WebSocketStatus) => {
      if (status === "SUBSCRIBED") {
        setIsConnected(true);
        hasShownErrorRef.current = false;
        try {
          await ch.track({ online_at: new Date().toISOString() });
        } catch {
          // Track failure is non-critical - viewer count may be inaccurate
        }
      }
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        setIsConnected(false);
        if (!hasShownErrorRef.current) {
          hasShownErrorRef.current = true;
          toast.error("La presencia en tiempo real está demorada", {
            description:
              "El número de personas conectadas puede no estar actualizado. Esto no afecta los cambios confirmados.",
          });
        }
      }
    });

    return () => {
      ch.untrack();
      supabase.removeChannel(ch);
    };
  }, [presenceTopic]);

  return { viewerCount, isConnected };
}
