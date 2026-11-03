"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  loadAccountViewPreferences,
  resetAccountViewPreferences,
  saveAccountViewPreference,
} from "@/lib/view-preference-actions";
import {
  beginViewPreferenceChange,
  createViewPreferenceState,
  reconcileViewPreferenceSnapshot,
  resolveViewPreferenceConflict,
  settleViewPreferenceSave,
  type ViewPreferenceContext,
  type ViewPreferenceDrafts,
  type ViewPreferenceKey,
  type ViewPreferenceResetResult,
  type ViewPreferenceSaveResult,
  type ViewPreferenceSnapshot,
  type ViewPreferenceState,
  type ViewPreferenceValue,
  viewPreferenceContextKey,
} from "@/lib/view-preference-state";

interface UseViewPreferencesOptions {
  accountId: string;
  context: ViewPreferenceContext;
  initialSnapshot?: ViewPreferenceSnapshot | null;
  initialDrafts?: ViewPreferenceDrafts;
  initialLoadFailed?: boolean;
}

export function useViewPreferences({
  accountId,
  context,
  initialSnapshot = null,
  initialDrafts = {},
  initialLoadFailed = false,
}: UseViewPreferencesOptions) {
  const [state, setState] = useState(() =>
    createViewPreferenceState(
      accountId,
      context,
      initialSnapshot,
      initialDrafts,
    ),
  );
  const [isLoading, setIsLoading] = useState(false);
  const [loadFailed, setLoadFailed] = useState(initialLoadFailed);
  const [resetConflict, setResetConflict] =
    useState<ViewPreferenceSnapshot | null>(null);
  const [resetFailed, setResetFailed] = useState(false);
  const stateRef = useRef(state);
  const contextRequestRef = useRef(0);
  const refreshRequestRef = useRef(0);
  const resetRequestRef = useRef(0);
  const initialContextKey = viewPreferenceContextKey(context);
  const inputContextRef = useRef({ accountId, contextKey: initialContextKey });
  stateRef.current = state;

  const save = useCallback(
    async (
      requestState: ViewPreferenceState,
      preferenceKey: string,
      value: ViewPreferenceValue,
      expectedVersion: number,
    ) => {
      const requestAccountId = requestState.accountId;
      const requestContextKey = requestState.contextKey;
      if (!requestAccountId) return;

      let result: ViewPreferenceSaveResult;
      try {
        result = await saveAccountViewPreference(
          requestState.context,
          preferenceKey,
          value,
          expectedVersion,
        );
      } catch {
        result = { status: "error", preference_key: preferenceKey };
      }

      setState((current) =>
        current.accountId === requestAccountId &&
        current.contextKey === requestContextKey
          ? settleViewPreferenceSave(current, result)
          : current,
      );
    },
    [],
  );

  const changePreference = useCallback(
    (preferenceKey: ViewPreferenceKey | string, value: ViewPreferenceValue) => {
      const current = stateRef.current;
      const next = beginViewPreferenceChange(current, preferenceKey, value);
      if (next === current) return;
      stateRef.current = next;
      setState(next);
      void save(
        current,
        preferenceKey,
        value,
        current.versions[preferenceKey] ?? 0,
      );
    },
    [save],
  );

  const retryPreference = useCallback(
    (preferenceKey: string) => {
      const current = stateRef.current;
      if (
        current.errors[preferenceKey] !== "error" ||
        current.saving[preferenceKey] ||
        current.conflicts[preferenceKey] ||
        current.accessLost
      ) {
        return;
      }
      const value = current.values[preferenceKey];
      if (value === undefined) return;
      const next: ViewPreferenceState = {
        ...current,
        saving: { ...current.saving, [preferenceKey]: true },
        errors: omitKey(current.errors, preferenceKey),
      };
      stateRef.current = next;
      setState(next);
      void save(
        next,
        preferenceKey,
        value,
        current.versions[preferenceKey] ?? 0,
      );
    },
    [save],
  );

  const resolveConflict = useCallback(
    (preferenceKey: string, resolution: "load-saved" | "keep-local") => {
      const current = stateRef.current;
      const result = resolveViewPreferenceConflict(
        current,
        preferenceKey,
        resolution,
      );
      if ("command" in result) {
        stateRef.current = result.state;
        setState(result.state);
        void save(
          result.state,
          result.command.preference_key,
          result.command.value,
          result.command.expected_version,
        );
        return;
      }
      stateRef.current = result;
      setState(result);
    },
    [save],
  );

  const switchContext = useCallback(
    async (nextContext: ViewPreferenceContext) => {
      refreshRequestRef.current += 1;
      resetRequestRef.current += 1;
      setResetConflict(null);
      setResetFailed(false);
      const requestId = ++contextRequestRef.current;
      const nextState = createViewPreferenceState(accountId, nextContext);
      stateRef.current = nextState;
      setState(nextState);
      setLoadFailed(false);
      setIsLoading(true);
      try {
        const snapshot = await loadAccountViewPreferences(nextContext);
        if (requestId !== contextRequestRef.current) return;
        const loadedState = createViewPreferenceState(
          accountId,
          nextContext,
          snapshot,
        );
        stateRef.current = loadedState;
        setState(loadedState);
        setLoadFailed(false);
      } catch {
        if (requestId !== contextRequestRef.current) return;
        setLoadFailed(true);
      } finally {
        if (requestId === contextRequestRef.current) setIsLoading(false);
      }
    },
    [accountId],
  );

  const retryLoad = useCallback(() => {
    void switchContext(stateRef.current.context);
  }, [switchContext]);

  const submitReset = useCallback(
    async (
      requestState: ViewPreferenceState,
      expectedVersions: Record<string, number>,
    ) => {
      const requestId = ++resetRequestRef.current;
      const requestAccountId = requestState.accountId;
      const requestContextKey = requestState.contextKey;
      if (!requestAccountId) return;

      let result: ViewPreferenceResetResult;
      try {
        result = await resetAccountViewPreferences(
          requestState.context,
          expectedVersions,
        );
      } catch {
        result = { status: "error" };
      }
      if (requestId !== resetRequestRef.current) return;
      const latest = stateRef.current;
      if (
        latest.accountId !== requestAccountId ||
        latest.contextKey !== requestContextKey
      ) {
        return;
      }

      if (result.status === "unavailable") {
        const unavailable = reconcileViewPreferenceSnapshot(latest, {
          status: "unavailable",
        });
        stateRef.current = unavailable;
        setState(unavailable);
        setResetConflict(null);
        setResetFailed(false);
        return;
      }
      if (result.status === "error") {
        setResetFailed(true);
        return;
      }
      if (result.status === "conflict") {
        setResetConflict(result.snapshot);
        setResetFailed(false);
        return;
      }

      const resetState = createViewPreferenceState(
        requestAccountId,
        requestState.context,
        result.snapshot,
      );
      stateRef.current = resetState;
      setState(resetState);
      setResetConflict(null);
      setResetFailed(false);
    },
    [],
  );

  const resetPreferences = useCallback(() => {
    setResetConflict(null);
    setResetFailed(false);
    void submitReset(stateRef.current, stateRef.current.versions);
  }, [submitReset]);

  const resolveResetConflict = useCallback(
    (resolution: "load-current" | "confirm-reset") => {
      const current = stateRef.current;
      if (
        !resetConflict ||
        current.contextKey !==
          viewPreferenceContextKey({
            type: resetConflict.context_type ?? current.context.type,
            boardId: resetConflict.board_id ?? null,
          })
      ) {
        return;
      }
      if (resolution === "load-current") {
        const loaded = createViewPreferenceState(
          current.accountId,
          current.context,
          resetConflict,
        );
        stateRef.current = loaded;
        setState(loaded);
        setResetConflict(null);
        return;
      }
      const versions = Object.fromEntries(
        Object.entries(resetConflict.preferences ?? {}).map(([key, item]) => [
          key,
          item.version,
        ]),
      );
      setResetConflict(null);
      void submitReset(current, versions);
    },
    [resetConflict, submitReset],
  );

  const refreshCurrent = useCallback(async () => {
    const current = stateRef.current;
    if (current.accessLost || !current.accountId) return;
    const requestId = ++refreshRequestRef.current;
    const requestContextKey = current.contextKey;
    const requestAccountId = current.accountId;
    try {
      const snapshot = await loadAccountViewPreferences(current.context);
      if (requestId !== refreshRequestRef.current) return;
      setState((latest) => {
        if (
          latest.contextKey !== requestContextKey ||
          latest.accountId !== requestAccountId
        ) {
          return latest;
        }
        const reconciled = reconcileViewPreferenceSnapshot(latest, snapshot);
        stateRef.current = reconciled;
        return reconciled;
      });
      setLoadFailed(false);
    } catch {
      if (requestId === refreshRequestRef.current) setLoadFailed(true);
    }
  }, []);

  useEffect(() => {
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") void refreshCurrent();
    };
    window.addEventListener("focus", refreshWhenVisible);
    document.addEventListener("visibilitychange", refreshWhenVisible);
    const interval = window.setInterval(refreshWhenVisible, 30_000);
    return () => {
      window.removeEventListener("focus", refreshWhenVisible);
      document.removeEventListener("visibilitychange", refreshWhenVisible);
      window.clearInterval(interval);
      refreshRequestRef.current += 1;
    };
  }, [refreshCurrent]);

  useEffect(() => {
    const previousInput = inputContextRef.current;
    if (
      previousInput.accountId === accountId &&
      previousInput.contextKey === initialContextKey
    ) {
      return;
    }
    inputContextRef.current = { accountId, contextKey: initialContextKey };
    void switchContext(context);
  }, [accountId, context, initialContextKey, switchContext]);

  return {
    state,
    isLoading,
    loadFailed,
    changePreference,
    retryPreference,
    resolveConflict,
    switchContext,
    retryLoad,
    refreshCurrent,
    resetPreferences,
    resetConflict,
    resetFailed,
    resolveResetConflict,
  };
}

function omitKey<T>(record: Record<string, T>, key: string): Record<string, T> {
  const next = { ...record };
  delete next[key];
  return next;
}
