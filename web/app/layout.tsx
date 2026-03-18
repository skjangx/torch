// Root layout stays as a pass-through. The localized site routes define their
// own document in app/[locale]/layout.tsx, and auth routes define theirs in
// app/handler/layout.tsx.

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
