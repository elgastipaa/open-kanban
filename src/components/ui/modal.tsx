"use client";

import { IconX } from "@tabler/icons-react";
import {
  type MouseEvent,
  type ReactNode,
  useId,
  useLayoutEffect,
  useRef,
} from "react";
import { createPortal } from "react-dom";
import { getModalFocusReturnTarget, ModalStack } from "@/lib/modal-stack";

const activeModals = new ModalStack();
const focusableSelector =
  'button:not([disabled]):not([tabindex="-1"]), input:not([disabled]):not([tabindex="-1"]), textarea:not([disabled]):not([tabindex="-1"]), select:not([disabled]):not([tabindex="-1"]), a[href]:not([tabindex="-1"]), [tabindex]:not([tabindex="-1"])';

interface ModalProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
  fullScreenMobile?: boolean;
  closeLabel?: string;
  onAfterClose?: () => void;
  returnFocusTo?: () => HTMLElement | null;
}

export function Modal({
  open,
  onClose,
  title,
  children,
  fullScreenMobile = false,
  closeLabel = "Cerrar ventana",
  onAfterClose,
  returnFocusTo,
}: ModalProps) {
  const overlayRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const modalTokenRef = useRef(Symbol("modal"));
  const onCloseRef = useRef(onClose);
  const onAfterCloseRef = useRef(onAfterClose);
  const returnFocusToRef = useRef(returnFocusTo);
  const titleId = useId();
  onCloseRef.current = onClose;
  onAfterCloseRef.current = onAfterClose;
  returnFocusToRef.current = returnFocusTo;

  // Keep keyboard focus in the dialog and return it to the opener on close.
  useLayoutEffect(() => {
    if (!open) return;
    const activeElement = document.activeElement;
    returnFocusRef.current =
      activeElement instanceof HTMLElement ? activeElement : null;
    const deactivateModal = activeModals.activate(
      modalTokenRef.current,
      document.body,
    );

    const dialog = dialogRef.current;
    const requested = dialog?.querySelector<HTMLElement>(
      "[data-modal-autofocus]",
    );
    const firstFocusable =
      dialog?.querySelector<HTMLElement>(focusableSelector);
    (requested ?? firstFocusable ?? dialog)?.focus({ preventScroll: true });

    function handleKeyDown(event: KeyboardEvent) {
      if (!activeModals.isTop(modalTokenRef.current)) return;
      if (event.key === "Escape") {
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab") return;

      const focusable = Array.from(
        dialogRef.current?.querySelectorAll<HTMLElement>(focusableSelector) ??
          [],
      ).filter((element) => element.getClientRects().length > 0);
      const first = focusable[0];
      const last = focusable.at(-1);
      if (!first || !last) {
        event.preventDefault();
        dialogRef.current?.focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      deactivateModal();
      const returnTarget = getModalFocusReturnTarget(
        returnFocusToRef.current?.(),
        returnFocusRef.current,
      );
      if (returnTarget?.isConnected) {
        returnTarget.focus({ preventScroll: true });
      }
      onAfterCloseRef.current?.();
    };
  }, [open]);

  if (!open) return null;

  function handleOverlayClick(e: MouseEvent<HTMLButtonElement>) {
    if (e.target === overlayRef.current) onClose();
  }

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-0 backdrop-blur-sm sm:p-4"
      style={{ animation: "fade-in 150ms ease-out" }}
    >
      {/* Clickable backdrop */}
      <button
        ref={overlayRef}
        type="button"
        aria-label={closeLabel}
        onClick={handleOverlayClick}
        tabIndex={-1}
        className="absolute inset-0 cursor-default bg-black/60"
      />

      {/* Modal content */}
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        tabIndex={-1}
        className={`relative w-full overflow-y-auto border border-border bg-surface-overlay shadow-2xl ${
          fullScreenMobile
            ? "h-dvh max-h-dvh max-w-none rounded-none p-4 sm:h-auto sm:max-h-[calc(100dvh-2rem)] sm:max-w-2xl sm:rounded-xl sm:p-6"
            : "max-h-[calc(100dvh-2rem)] max-w-md rounded-xl p-6"
        }`}
        style={{ animation: "scale-in 150ms ease-out" }}
      >
        {title && (
          <div className="mb-4 flex items-center justify-between">
            <h2
              id={titleId}
              className="font-semibold text-base text-text-primary"
            >
              {title}
            </h2>
            <button
              type="button"
              aria-label={closeLabel}
              onClick={onClose}
              className="cursor-pointer rounded-md p-1 text-text-muted transition-colors hover:bg-surface-raised hover:text-text-primary"
            >
              <IconX size={18} />
            </button>
          </div>
        )}
        {children}
      </div>
    </div>,
    document.body,
  );
}
