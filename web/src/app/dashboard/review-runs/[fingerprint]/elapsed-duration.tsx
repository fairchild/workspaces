"use client";

import { useEffect, useState } from "react";
import { formatDuration } from "./review-run-detail-view-model";

interface ElapsedDurationProps {
	startValue: string;
	endValue: string | null;
	initialNow: number;
}

export function ElapsedDuration({
	startValue,
	endValue,
	initialNow,
}: ElapsedDurationProps) {
	const [now, setNow] = useState(initialNow);

	useEffect(() => {
		if (endValue) return;
		setNow(Date.now());
		const interval = window.setInterval(() => setNow(Date.now()), 1000);
		return () => window.clearInterval(interval);
	}, [endValue]);

	return <>{formatDuration(startValue, endValue, now)}</>;
}
