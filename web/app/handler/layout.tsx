import { StackProvider, StackTheme } from "@stackframe/stack";

import { stackServerApp } from "@/lib/stack";
import "../globals.css";

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <StackTheme>
          <StackProvider app={stackServerApp}>{children}</StackProvider>
        </StackTheme>
      </body>
    </html>
  );
}
