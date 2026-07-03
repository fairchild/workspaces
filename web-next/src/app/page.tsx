import Link from "next/link";

export default function Home() {
	return (
		<main className="flex h-screen flex-col items-center justify-center gap-6">
			<h1 className="font-display text-5xl italic text-mint">Spaces</h1>
			<p className="text-sm text-ink-muted">
				Coding sessions in the browser — greenfield rewrite in progress.
			</p>
			<Link
				href="/spike"
				className="border border-edge px-4 py-2 text-sm text-ink-muted hover:border-mint-muted hover:text-mint"
			>
				&gt; Phase 0 transcript spike
			</Link>
		</main>
	);
}
