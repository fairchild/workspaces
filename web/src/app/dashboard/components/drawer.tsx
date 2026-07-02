"use client";

/**
 * Off-canvas overlay drawer for narrow viewports. Renders arbitrary content
 * (the real Sidebar or ActivityFeed) as a focus-trapped modal panel that slides
 * in from the left or right, with a click-to-dismiss backdrop. Escape closes it,
 * Tab is trapped inside, and focus is restored to the trigger on close.
 */

import { useEffect, useRef } from "react";
import styles from "./drawer.module.css";

const FOCUSABLE_SELECTOR =
	'a[href], button:not([disabled]), textarea, input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

interface DrawerProps {
	open: boolean;
	onClose: () => void;
	side: "left" | "right";
	label: string;
	id: string;
	children: React.ReactNode;
}

export function Drawer({
	open,
	onClose,
	side,
	label,
	id,
	children,
}: DrawerProps) {
	const panelRef = useRef<HTMLDivElement>(null);
	const restoreFocusRef = useRef<HTMLElement | null>(null);

	useEffect(() => {
		if (!open) return;

		restoreFocusRef.current = document.activeElement as HTMLElement | null;
		const panel = panelRef.current;

		const focusables = () =>
			Array.from(
				panel?.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR) ?? [],
			).filter((el) => el.offsetParent !== null);

		// Move focus into the drawer once it opens.
		(focusables()[0] ?? panel)?.focus();

		const handleKeyDown = (e: KeyboardEvent) => {
			if (e.key === "Escape") {
				e.preventDefault();
				onClose();
				return;
			}
			if (e.key !== "Tab" || !panel) return;
			const items = focusables();
			if (items.length === 0) {
				e.preventDefault();
				panel.focus();
				return;
			}
			const first = items[0];
			const last = items[items.length - 1];
			const active = document.activeElement;
			if (e.shiftKey && (active === first || active === panel)) {
				e.preventDefault();
				last.focus();
			} else if (!e.shiftKey && active === last) {
				e.preventDefault();
				first.focus();
			}
		};

		document.addEventListener("keydown", handleKeyDown);
		const prevOverflow = document.body.style.overflow;
		document.body.style.overflow = "hidden";

		return () => {
			document.removeEventListener("keydown", handleKeyDown);
			document.body.style.overflow = prevOverflow;
			restoreFocusRef.current?.focus?.();
		};
	}, [open, onClose]);

	if (!open) return null;

	return (
		<div className={styles.overlay}>
			<button
				type="button"
				className={styles.backdrop}
				aria-label="Close"
				tabIndex={-1}
				onClick={onClose}
			/>
			<div
				ref={panelRef}
				id={id}
				className={`${styles.panel} ${side === "left" ? styles.panelLeft : styles.panelRight}`}
				// biome-ignore lint/a11y/useSemanticElements: native <dialog> conflicts with the custom overlay + focus-trap; role="dialog" + aria-modal announce the modal correctly
				role="dialog"
				aria-modal="true"
				aria-label={label}
				tabIndex={-1}
			>
				{children}
			</div>
		</div>
	);
}
