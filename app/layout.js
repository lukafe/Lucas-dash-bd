import "./globals.css";

export const metadata = {
  title: "Aurora · Monitor",
  description: "Monitor do outreach de fundraising (email e Telegram) do Lucas na CertiK",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }) {
  return (
    <html lang="pt-BR">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
        />
      </head>
      <body className="font-sans text-[14px] leading-relaxed antialiased">{children}</body>
    </html>
  );
}
