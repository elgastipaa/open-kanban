"use client";

import { useSyncExternalStore } from "react";
import { ChromaFlow, Shader, Swirl } from "shaders/react";
import { useThemePreference } from "@/components/theme/theme-preference-provider";
import GrainOverlay from "./gradient-overlay";

function subscribeToColorScheme(onChange: () => void) {
  const preference = window.matchMedia("(prefers-color-scheme: light)");
  preference.addEventListener("change", onChange);
  return () => preference.removeEventListener("change", onChange);
}

function getPrefersLightScheme() {
  return window.matchMedia("(prefers-color-scheme: light)").matches;
}

function subscribeToReducedMotion(onChange: () => void) {
  const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
  preference.addEventListener("change", onChange);
  return () => preference.removeEventListener("change", onChange);
}

function getPrefersReducedMotion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export const BackgroundLayer = () => {
  const { state } = useThemePreference();
  const prefersLight = useSyncExternalStore(
    subscribeToColorScheme,
    getPrefersLightScheme,
    () => false,
  );
  const prefersReducedMotion = useSyncExternalStore(
    subscribeToReducedMotion,
    getPrefersReducedMotion,
    () => false,
  );
  const lightTheme =
    state.theme === "light" || (state.theme === "system" && prefersLight);

  return (
    <>
      <GrainOverlay />
      {!prefersReducedMotion && (
        <Shader
          className="pointer-events-none absolute inset-0 z-0"
          style={{
            maskImage:
              "linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,0.6) 50%, rgba(0,0,0,0) 100%)",
            WebkitMaskImage:
              "linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,0.6) 50%, rgba(0,0,0,0) 100%)",
          }}
        >
          <Swirl
            colorA={lightTheme ? "#f8f8f6" : "#000"}
            colorB="#e1ff0015"
            speed={1}
            detail={0.8}
            blend={50}
          />
          <ChromaFlow
            baseColor="#e1ff00"
            upColor="#ff3300"
            downColor="#d1d1d1"
            leftColor="#e19136"
            rightColor="#e19136"
            intensity={0.9}
            radius={1.8}
            momentum={25}
            maskType="alpha"
            opacity={0.97}
          />
        </Shader>
      )}
    </>
  );
};
