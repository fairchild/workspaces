/* Instance boundary for Folio's scoped visual contract and host token overrides. */
import type { HTMLAttributes, ReactNode } from "react";

export interface FolioRootProps extends HTMLAttributes<HTMLDivElement> {
	children: ReactNode;
}

export function FolioRoot({ children, ...props }: FolioRootProps) {
	return (
		<div {...props} data-folio-root="surface">
			{children}
		</div>
	);
}
