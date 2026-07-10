"use client";

/*
 * Natural tail-following for a live session turn. One retargetable animator
 * tracks streamed layout growth, yields immediately to upward user scrolling,
 * and rearms when the reader returns to the document tail.
 */
import { useEffect, useRef } from "react";

const FOLLOW_GAP_PX = 16;
const FOLLOW_SETTLE_PX = 0.5;
const FOLLOW_MAX_STEP_PX = 24;
const FOLLOW_RESUME_THRESHOLD_PX = 48;
const FOLLOW_TIME_CONSTANT_MS = 120;

export function useTurnFollow({
	active,
	scopeId,
	userMessageId,
}: {
	active: boolean;
	scopeId: string;
	userMessageId: string | null;
}) {
	const followedUserMessageIdRef = useRef<string | null>(null);

	useEffect(() => {
		if (!userMessageId) return;
		const finishingFollow =
			!active && followedUserMessageIdRef.current === userMessageId;
		if (!active && !finishingFollow) return;

		const scope = `[data-turn-follow-scope="${CSS.escape(scopeId)}"]`;
		const turn = document.querySelector<HTMLElement>(
			`${scope} section[data-turn="recent"]`,
		);
		const compose = document.querySelector<HTMLElement>(
			`${scope} [data-compose-boundary]`,
		);
		if (!turn || !compose) return;

		const scrollRoot = document.documentElement;
		const previousOverflowAnchor = scrollRoot.style.overflowAnchor;
		if (active) scrollRoot.style.overflowAnchor = "none";

		let measureFrame = 0;
		let animationFrame = 0;
		let lastAnimationAt = 0;
		let targetScrollY = window.scrollY;
		let followPaused = false;
		let lastTouchY: number | null = null;
		const reduceMotion = window.matchMedia(
			"(prefers-reduced-motion: reduce)",
		).matches;

		const animate = (at: number) => {
			animationFrame = 0;
			if (followPaused) return;
			const currentScrollY = window.scrollY;
			const remaining = targetScrollY - currentScrollY;
			if (remaining <= FOLLOW_SETTLE_PX) {
				if (remaining > 0)
					window.scrollTo({ top: targetScrollY, behavior: "auto" });
				lastAnimationAt = 0;
				return;
			}

			const elapsed = lastAnimationAt
				? Math.min(at - lastAnimationAt, 64)
				: 1_000 / 60;
			lastAnimationAt = at;
			const easedStep =
				remaining * (1 - Math.exp(-elapsed / FOLLOW_TIME_CONSTANT_MS));
			const step = Math.min(
				remaining,
				FOLLOW_MAX_STEP_PX,
				Math.max(FOLLOW_SETTLE_PX, easedStep),
			);
			window.scrollTo({ top: currentScrollY + step, behavior: "auto" });
			animationFrame = window.requestAnimationFrame(animate);
		};

		const updateTarget = () => {
			measureFrame = 0;
			if (followPaused) return;
			const overflow =
				turn.getBoundingClientRect().bottom -
				(compose.getBoundingClientRect().top - FOLLOW_GAP_PX);
			if (overflow <= 0) return;

			const maxScrollY = Math.max(
				0,
				document.documentElement.scrollHeight - window.innerHeight,
			);
			targetScrollY = Math.max(
				targetScrollY,
				Math.min(window.scrollY + overflow, maxScrollY),
			);
			if (reduceMotion) {
				window.scrollTo({ top: targetScrollY, behavior: "auto" });
				return;
			}
			if (!animationFrame) animationFrame = window.requestAnimationFrame(animate);
		};

		const follow = () => {
			if (!followPaused && !measureFrame)
				measureFrame = window.requestAnimationFrame(updateTarget);
		};
		const stopFollowing = () => {
			window.cancelAnimationFrame(measureFrame);
			window.cancelAnimationFrame(animationFrame);
			measureFrame = 0;
			animationFrame = 0;
		};
		const pauseFollowing = () => {
			followPaused = true;
			followedUserMessageIdRef.current = null;
			stopFollowing();
		};
		const handleScroll = () => {
			if (!followPaused) return;
			const distanceFromTail = Math.max(
				0,
				document.documentElement.scrollHeight -
					window.innerHeight -
					window.scrollY,
			);
			if (distanceFromTail > FOLLOW_RESUME_THRESHOLD_PX) return;
			followPaused = false;
			followedUserMessageIdRef.current = userMessageId;
			targetScrollY = window.scrollY;
			lastAnimationAt = 0;
			follow();
		};
		const handleWheel = (event: WheelEvent) => {
			if (event.deltaY < 0) pauseFollowing();
		};
		const handleTouchStart = (event: TouchEvent) => {
			lastTouchY = event.touches[0]?.clientY ?? null;
		};
		const handleTouchMove = (event: TouchEvent) => {
			const touchY = event.touches[0]?.clientY;
			if (touchY === undefined) return;
			if (lastTouchY !== null && touchY > lastTouchY + 4) pauseFollowing();
			lastTouchY = touchY;
		};
		const handleTouchEnd = () => {
			lastTouchY = null;
		};
		const handleKeyDown = (event: KeyboardEvent) => {
			const target = event.target as HTMLElement | null;
			if (target?.matches("input, textarea, [contenteditable='true']")) return;
			if (
				event.key === "ArrowUp" ||
				event.key === "PageUp" ||
				event.key === "Home" ||
				(event.key === " " && event.shiftKey)
			)
				pauseFollowing();
		};

		if (finishingFollow) {
			followedUserMessageIdRef.current = null;
			follow();
			return stopFollowing;
		}

		followedUserMessageIdRef.current = userMessageId;
		const observer = new ResizeObserver(follow);
		observer.observe(turn);
		observer.observe(compose);
		window.addEventListener("resize", follow);
		window.addEventListener("scroll", handleScroll, { passive: true });
		window.addEventListener("wheel", handleWheel, { passive: true });
		window.addEventListener("touchstart", handleTouchStart, { passive: true });
		window.addEventListener("touchmove", handleTouchMove, { passive: true });
		window.addEventListener("touchend", handleTouchEnd, { passive: true });
		window.addEventListener("keydown", handleKeyDown);
		follow();
		return () => {
			observer.disconnect();
			window.removeEventListener("resize", follow);
			window.removeEventListener("scroll", handleScroll);
			window.removeEventListener("wheel", handleWheel);
			window.removeEventListener("touchstart", handleTouchStart);
			window.removeEventListener("touchmove", handleTouchMove);
			window.removeEventListener("touchend", handleTouchEnd);
			window.removeEventListener("keydown", handleKeyDown);
			stopFollowing();
			scrollRoot.style.overflowAnchor = previousOverflowAnchor;
		};
	}, [active, scopeId, userMessageId]);
}
