"use client";

import { IconWifiOff } from "@tabler/icons-react";
import { AnimatePresence, motion } from "motion/react";
import { useOnlineStatus } from "@/hooks/use-online-status";

/**
 * Aviso que aparece cuando el navegador informa que no hay conexión.
 */
export function OfflineBanner() {
  const { isOnline } = useOnlineStatus();

  return (
    <AnimatePresence>
      {!isOnline && (
        <motion.div
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: "auto", opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={{ duration: 0.25, ease: "easeInOut" }}
          className="w-full overflow-hidden"
          role="alert"
          aria-live="assertive"
        >
          <div className="flex items-center justify-center gap-2 bg-accent px-4 py-2 font-medium text-accent-foreground text-sm">
            <IconWifiOff size={16} />
            <span>
              Sin conexión. Los cambios no se guardarán automáticamente.
            </span>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
