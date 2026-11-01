import { motion, useReducedMotion } from "motion/react";

export function CallToAction() {
  const shouldReduceMotion = useReducedMotion();

  return (
    <section className="relative z-20 flex flex-col items-center justify-center border-border border-t bg-surface-raised px-6 py-20 text-center">
      <h2 className="mb-12 font-bold font-display text-5xl tracking-tighter md:text-8xl">
        Ready to <span className="text-accent">organize?</span>
      </h2>
      <motion.button
        onClick={() =>
          window.scrollTo({
            top: 0,
            behavior: shouldReduceMotion ? "auto" : "smooth",
          })
        }
        whileHover={{ scale: 1.05 }}
        whileTap={{ scale: 0.95 }}
        className="rounded-full bg-accent px-10 py-5 font-bold text-accent-foreground text-sm uppercase tracking-[0.2em] shadow-[0_0_40px_rgba(255,255,0,0.1)] transition-all hover:bg-accent-hover md:text-base"
      >
        Create Your first Board
      </motion.button>
    </section>
  );
}
