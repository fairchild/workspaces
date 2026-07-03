import Link from "next/link";

export default function Home() {
	return (
		<main className="flex h-screen flex-col items-center justify-center gap-6">
			<h1 className="font-serif text-5xl italic">Spaces</h1>
			<p className="font-mono text-[13px] text-muted">
				Coding sessions in the browser — greenfield rewrite in progress.
			</p>
			<nav className="flex gap-3 font-mono text-[13px]">
				<Link
					href="/sessions/demo"
					className="rounded-md border border-line-strong px-4 py-2 text-muted transition-colors hover:border-accent hover:text-accent"
				>
					Folio session demo
				</Link>
				<Link
					href="/spike"
					className="rounded-md border border-line-strong px-4 py-2 text-muted transition-colors hover:border-accent hover:text-accent"
				>
					&gt; Phase 0 transcript spike
				</Link>
			</nav>
		</main>
	);
}
