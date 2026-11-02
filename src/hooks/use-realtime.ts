"use client";

import type { RealtimeChannel } from "@supabase/supabase-js";
import { useEffect, useRef } from "react";
import { toast } from "sonner";
import { createClient } from "@/lib/supabase/client";
import type { WebSocketStatus } from "@/lib/types";

interface UseRealtimeOptions {
  authEpoch: string | number;
  syncTopic: string;
  onSync: () => void;
  onReconnect: () => void | Promise<void>;
  onBoardDeleted?: () => void;
}

/**
 * Subscribes to content-free database broadcasts. The client never publishes
 * board invalidation signals; each received signal only starts authorized
 * session validation and board reads.
 */
export function useRealtime({
  authEpoch,
  syncTopic,
  onSync,
  onReconnect,
  onBoardDeleted,
}: UseRealtimeOptions) {
  const channelRef = useRef<RealtimeChannel | null>(null);
  const currentEpochRef = useRef(authEpoch);
  currentEpochRef.current = authEpoch;
  const currentTopicRef = useRef(syncTopic);
  currentTopicRef.current = syncTopic;
  const onSyncRef = useRef(onSync);
  onSyncRef.current = onSync;
  const onReconnectRef = useRef(onReconnect);
  onReconnectRef.current = onReconnect;
  const onBoardDeletedRef = useRef(onBoardDeleted);
  onBoardDeletedRef.current = onBoardDeleted;
  const hasShownErrorRef = useRef(false);

  useEffect(() => {
    let active = true;
    const supabase = createClient();
    const subscribedEpoch = authEpoch;
    const subscribedTopic = syncTopic;
    const isCurrentChannel = () =>
      active &&
      String(currentEpochRef.current) === String(subscribedEpoch) &&
      currentTopicRef.current === subscribedTopic;
    const ch = supabase.channel(syncTopic, { config: { private: true } });

    ch.on("broadcast", { event: "sync" }, () => {
      if (isCurrentChannel()) onSyncRef.current();
    });

    ch.on("broadcast", { event: "revalidate" }, () => {
      if (!isCurrentChannel()) return;
      void onReconnectRef.current();
      onSyncRef.current();
    });

    ch.on("broadcast", { event: "board-deleted" }, () => {
      if (isCurrentChannel()) onBoardDeletedRef.current?.();
    });

    ch.subscribe((status: WebSocketStatus) => {
      if (!isCurrentChannel()) return;
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        if (!hasShownErrorRef.current) {
          hasShownErrorRef.current = true;
          toast.error("La sincronización en tiempo real está demorada", {
            description:
              "Los cambios confirmados permanecen guardados. Las actualizaciones de otras personas pueden tardar hasta reconectar.",
          });
        }
        void onReconnectRef.current();
      }
      if (status === "SUBSCRIBED") {
        hasShownErrorRef.current = false;
        void onReconnectRef.current();
        onSyncRef.current();
      }
    });

    channelRef.current = ch;

    return () => {
      active = false;
      if (channelRef.current === ch) channelRef.current = null;
      supabase.removeChannel(ch);
    };
  }, [authEpoch, syncTopic]);
}
