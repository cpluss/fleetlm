import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "FleetLM × Next.js Demo",
  description: "Chat UI + webhook example powered by FleetLM."
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
