import type { Metadata } from "next";
import { Instrument_Serif, JetBrains_Mono } from "next/font/google";
import "./globals.css";

const instrumentSerif = Instrument_Serif({
	weight: "400",
	style: ["normal", "italic"],
	subsets: ["latin"],
	variable: "--font-instrument-serif",
});

const jetbrainsMono = JetBrains_Mono({
	subsets: ["latin"],
	variable: "--font-jetbrains-mono",
});

export const metadata: Metadata = {
	title: "Spaces",
	description: "Coding sessions in the browser",
};

export default function RootLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	return (
		<html lang="en">
			<body
				className={`${instrumentSerif.variable} ${jetbrainsMono.variable}`}
			>
				{children}
			</body>
		</html>
	);
}
