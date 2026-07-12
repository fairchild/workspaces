import { dirname } from "path";
import { fileURLToPath } from "url";
import { FlatCompat } from "@eslint/eslintrc";

// eslint-config-next 15.x ships eslintrc-style presets; FlatCompat bridges
// them into ESLint 9 flat config (the setup create-next-app generates).
const compat = new FlatCompat({
	baseDirectory: dirname(fileURLToPath(import.meta.url)),
});

const eslintConfig = [
	...compat.extends("next/core-web-vitals", "next/typescript"),
	{
		ignores: [
			".next/**",
			"artifacts/**",
			"node_modules/**",
			"output/**",
			"packages/folio/dist/**",
			"playwright-report/**",
			"test-results/**",
			"next-env.d.ts",
		],
	},
];

export default eslintConfig;
