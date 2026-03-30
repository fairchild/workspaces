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

export function getRegistry(): ComputeProviderRegistry {
	if (!_registry) {
		// Import providers lazily to avoid circular deps
		const { VercelSandboxProvider } = require("./vercel-sandbox") as {
			VercelSandboxProvider: new () => ComputeProvider;
		};
		const { DaytonaProvider } = require("./daytona") as {
			DaytonaProvider: new () => ComputeProvider;
		};
		const { GitHubActionsProvider } = require("./github-actions") as {
			GitHubActionsProvider: new () => ComputeProvider;
		};

		_registry = new ComputeProviderRegistry([
			new VercelSandboxProvider(),
			new DaytonaProvider(),
			new GitHubActionsProvider(),
		]);
	}
	return _registry;
}
