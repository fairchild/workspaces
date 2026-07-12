import type { Metadata } from "next";
import { IBM_Plex_Mono, Newsreader } from "next/font/google";
import { themeInitScript } from "@fairchild/folio/theme";
import "@fairchild/folio/styles.css";
import "./globals.css";

const newsreader = Newsreader({
	subsets: ["latin"],
	style: ["normal", "italic"],
	axes: ["opsz"],
	variable: "--font-newsreader",
});

const plexMono = IBM_Plex_Mono({
	subsets: ["latin"],
	weight: ["400", "500"],
	style: ["normal", "italic"],
	variable: "--font-plex-mono",
});

export const metadata: Metadata = {
	title: "Spaces",
	description: "Coding sessions in the browser",
};

export default function RootLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	// data-theme is rewritten pre-paint by themeInitScript (hash > stored
	// choice > system preference), so the server-rendered value is only a
	// no-JS fallback — hence suppressHydrationWarning.
	// Font variables live on <html>: the @theme font tokens reference them
	// from :root, where a <body>-scoped variable would be invisible.
	return (
		<html
			lang="en"
			data-theme="light"
			suppressHydrationWarning
			className={`${newsreader.variable} ${plexMono.variable}`}
		>
			<body>
				<script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
				{children}
			</body>
		</html>
	);
}
