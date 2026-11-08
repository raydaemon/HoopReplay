"use client";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { X } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useI18n } from "@/lib/i18n";

/**
 * Destructive confirmations run through this dialog instead of window.confirm so the
 * prompt is styled, testable, and consistent with the rest of the shadcn/ui surface.
 */
export function ConfirmDialog(
  { open, title, description, confirmLabel, confirmVariant = "destructive", onConfirm, onOpenChange }: {
    open: boolean;
    title: string;
    description: string;
    confirmLabel?: string;
    /** Destructive by default; pass "default" for confirmations that do not delete anything. */
    confirmVariant?: "destructive" | "default";
    onConfirm: () => void;
    onOpenChange: (open: boolean) => void;
  },
) {
  const { t } = useI18n();
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <button
          type="button"
          aria-label={t("Cancel")}
          onClick={() => onOpenChange(false)}
          className="absolute right-3 top-3 text-muted-foreground transition-colors hover:text-foreground"
        >
          <X className="size-4" />
        </button>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="whitespace-nowrap">{t("Cancel")}</AlertDialogCancel>
          <AlertDialogAction
            className={cn("whitespace-nowrap", buttonVariants({ variant: confirmVariant }))}
            onClick={onConfirm}
          >
            {confirmLabel ?? t("Delete")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
