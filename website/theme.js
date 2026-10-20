// Applies a saved light/dark choice before the page paints (no flash). No choice: follow the Mac.
try {
  const t = localStorage.getItem("theme");
  if (t === "light" || t === "dark") document.documentElement.dataset.theme = t;
} catch {}
