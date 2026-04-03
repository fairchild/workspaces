import type { ComputeBackendId } from "../types";
import type { ComputeProvider, ComputeProviderAvailability } from "./types";

/**
 * Registry of compute providers, mirroring Swift WorkspaceProviderRegistry.
 * Maps provider IDs to implementations and provides default selection.
 */
export class ComputeProviderRegistry {
	private providers: Map<ComputeBackendId, ComputeProvider>;
	private defaultId: ComputeBackendId;

	constructor(
		providers: ComputeProvider[],
		defaultId: ComputeBackendId = "vercel-sandbox",
	) {
		this.providers = new Map();
		for (const p of providers) {
			this.providers.set(p.descriptor.id, p);
		}
		this.defaultId = defaultId;
	}

	get(id: ComputeBackendId): ComputeProvider | undefined {
		return this.providers.get(id);
	}

	getDefault(): ComputeProvider {
		const provider = this.providers.get(this.defaultId);
		if (!provider) {
			throw new Error(
				`Default compute provider '${this.defaultId}' not registered`,
			);
		}
		return provider;
	}

	all(): ComputeProvider[] {
		return [...this.providers.values()];
	}

	async listAvailable(): Promise<
		Array<{ id: ComputeBackendId; availability: ComputeProviderAvailability }>
	> {
		const results = await Promise.all(
			this.all().map(async (p) => ({
				id: p.descriptor.id,
				availability: await p.checkAvailability(),
			})),
		);
		return results;
	}
}

/** Lazy singleton — same pattern as getBot() in bot.ts */
let _registry: ComputeProviderRegistry | undefined;
let _registryPromise: Promise<ComputeProviderRegistry> | undefined;

export async function getRegistry(): Promise<ComputeProviderRegistry> {
	if (_registry) return _registry;
	if (_registryPromise) return _registryPromise;

	_registryPromise = (async () => {
		const [
			{ VercelSandboxProvider },
			{ DaytonaProvider },
			{ GitHubActionsProvider },
		] = await Promise.all([
			import("./vercel-sandbox"),
			import("./daytona"),
			import("./github-actions"),
		]);

		const providers = [
			new VercelSandboxProvider(),
			new DaytonaProvider(),
			new GitHubActionsProvider(),
		];

		if (process.env.MOCK_AGENT === "1") {
			const { MockComputeProvider } = await import("./mock-provider");
			_registry = new ComputeProviderRegistry(
				[...providers, new MockComputeProvider()],
				"mock",
			);
		} else {
			_registry = new ComputeProviderRegistry(providers);
		}
		return _registry;
	})();

	return _registryPromise;
}
