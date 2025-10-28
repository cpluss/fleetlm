import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Fastpaca Chat Demo",
  description: "Next.js chat example with context management powered by Fastpaca."
};

export default function RootLayout({
  children
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
