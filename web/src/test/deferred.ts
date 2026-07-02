/**
 * A promise whose resolve/reject are exposed to the caller, for tests that
 * need to control exactly when an in-flight fetch settles (e.g. asserting
 * that switching props mid-request doesn't let a stale response win a race).
 */
export interface Deferred<T> {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (reason?: unknown) => void;
}

export function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (reason?: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}
