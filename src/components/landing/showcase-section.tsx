import {
  motion,
  useReducedMotion,
  useScroll,
  useTransform,
} from "motion/react";
import { useRef } from "react";

function MockCard({
  h,
  border = "solid",
}: {
  h: string;
  border?: "solid" | "dashed";
}) {
  return (
    <div
      className={`${h} rounded-2xl border bg-surface-overlay ${
        border === "dashed"
          ? "border-border-hover border-dashed bg-surface-overlay/30"
          : "border-border shadow-xl"
      } relative flex flex-col gap-3 overflow-hidden p-4 sm:p-5`}
    >
      {border === "solid" && (
        <>
          <div className="mb-1 flex gap-2">
            <div className="h-2 w-8 rounded bg-surface-hover"></div>
            <div className="h-2 w-12 rounded bg-surface-column"></div>
          </div>
          <div className="h-3 w-[85%] rounded bg-border-hover sm:h-4"></div>
          <div className="h-3 w-[50%] rounded bg-surface-hover sm:h-4"></div>
          <div className="mt-auto flex items-center justify-between">
            <div className="h-2 w-10 rounded bg-surface-column"></div>
            <div className="h-6 w-6 rounded-full bg-surface-column"></div>
          </div>
        </>
      )}
    </div>
  );
}

export function ShowcaseSection() {
  const ref = useRef(null);
  const shouldReduceMotion = useReducedMotion();
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start end", "end start"],
  });

  const y1 = useTransform(scrollYProgress, [0, 1], [50, -250]);
  const y2 = useTransform(scrollYProgress, [0, 1], [0, 200]);
  const y3 = useTransform(scrollYProgress, [0, 1], [150, -150]);

  return (
    <section
      ref={ref}
      className="pointer-events-none relative flex h-[90vh] items-center justify-center overflow-hidden border-border border-y/0"
    >
      {/* Subtle vignette mask around the edge of the showcase */}
      <div className="mask-[radial-gradient(ellipse_at_center,transparent_10%,black_80%)] absolute inset-0 z-10 bg-surface-raised/80" />

      <div className="z-0 mt-18 flex w-full max-w-6xl items-start justify-center gap-4 px-4 sm:gap-6 md:gap-8">
        {/* Column 1 */}
        <motion.div
          style={shouldReduceMotion ? undefined : { y: y1 }}
          className="flex w-1/3 max-w-[280px] flex-col gap-4 opacity-60"
        >
          <div className="mb-2 flex items-center justify-between px-1">
            <div className="h-3 w-16 rounded-full bg-surface-hover"></div>
            <div className="flex h-4 w-6 items-center justify-center rounded bg-surface-column font-mono text-[10px] text-text-muted sm:text-xs">
              3
            </div>
          </div>
          <MockCard h="h-32" />
          <MockCard h="h-40" />
          <MockCard h="h-48" />
          <MockCard h="h-24" border="dashed" />
        </motion.div>

        {/* Column 2 (Accent / In Focus) */}
        <motion.div
          style={shouldReduceMotion ? undefined : { y: y2 }}
          className="z-20 mt-12 flex w-1/3 max-w-[280px] scale-105 flex-col gap-4 sm:scale-110"
        >
          <div className="mb-2 flex items-center justify-between px-1">
            <div className="flex items-center gap-2">
              <div className="h-2 w-2 animate-pulse rounded-full bg-accent shadow-[0_0_8px_var(--color-accent)]"></div>
              <div className="h-3 w-20 rounded-full bg-text-muted/50"></div>
            </div>
            <div className="flex h-4 w-6 items-center justify-center rounded bg-accent/20 font-medium font-mono text-[10px] text-accent sm:text-xs">
              2
            </div>
          </div>

          <MockCard h="h-36" />

          {/* Accent Card */}
          <div className="group relative">
            <div className="-inset-1 absolute rounded-2xl bg-linear-to-b from-accent/50 to-transparent opacity-30 blur"></div>
            <div className="relative flex flex-col gap-4 rounded-2xl border border-accent/50 bg-surface-base p-5 shadow-[0_0_30px_rgba(225,255,0,0.15)]">
              <div className="h-4 w-[90%] rounded bg-text-primary sm:h-5"></div>
              <div className="h-4 w-[70%] rounded bg-text-muted sm:h-5"></div>
              <div className="mt-2 flex items-end justify-between">
                <div className="-space-x-2 flex">
                  <div className="h-8 w-8 rounded-full border-2 border-border-hover bg-surface-column"></div>
                  <div className="flex h-8 w-8 items-center justify-center rounded-full border-2 border-border-hover bg-accent">
                    <div className="h-2 w-2 rounded-full bg-surface-base"></div>
                  </div>
                </div>
                <div className="h-2 w-12 rounded bg-accent/30"></div>
              </div>
            </div>
          </div>

          <MockCard h="h-32" />
        </motion.div>

        {/* Column 3 */}
        <motion.div
          style={shouldReduceMotion ? undefined : { y: y3 }}
          className="mt-[-50px] flex w-1/3 max-w-[280px] flex-col gap-4 opacity-40"
        >
          <div className="mb-2 flex items-center justify-between px-1">
            <div className="h-3 w-24 rounded-full bg-surface-hover"></div>
            <div className="flex h-4 w-6 items-center justify-center rounded bg-surface-column font-mono text-[10px] text-text-muted sm:text-xs">
              5
            </div>
          </div>
          <MockCard h="h-40" />
          <MockCard h="h-28" />
          <MockCard h="h-48" />
          <MockCard h="h-32" />
        </motion.div>
      </div>
    </section>
  );
}
