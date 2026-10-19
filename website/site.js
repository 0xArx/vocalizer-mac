// Vocalizer site: the waveform demo, the copy button, and the latest release number.
(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Demo: a voice line with music around it. Switching on fades the music out.
  const canvas = document.getElementById("wave");
  const sw = document.getElementById("demo-switch");
  const label = document.getElementById("demo-label");
  if (canvas && sw) {
    const ctx = canvas.getContext("2d");
    let on = true, music = 0.08, t = 0, w = 0, h = 0;

    const size = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = canvas.clientWidth; h = canvas.clientHeight;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    size();
    window.addEventListener("resize", size);

    // Speech-like envelope: syllables grouped into phrases with pauses.
    const voiceEnv = (x) => {
      const phrase = Math.max(0, Math.sin(x * 0.9)) ** 0.6;
      const syll = 0.55 + 0.45 * Math.abs(Math.sin(x * 6.3 + Math.sin(x * 2.1)));
      return phrase * syll;
    };

    const draw = () => {
      music += ((on ? 0.08 : 1) - music) * 0.06;
      ctx.clearRect(0, 0, w, h);
      const mid = h / 2, bars = Math.max(48, Math.floor(w / 7)), bw = w / bars;

      // Music: steady wide bars (drums and chords), grey.
      ctx.fillStyle = `rgba(110, 102, 128, ${0.25 + 0.55 * music})`;
      for (let i = 0; i < bars; i++) {
        const x = i * bw;
        const beat = 0.55 + 0.45 * Math.abs(Math.sin((i + t * 9) * 0.55));
        const chord = 0.6 + 0.4 * Math.sin(i * 0.21 + t * 1.3);
        const a = (h * 0.42) * beat * chord * music;
        ctx.fillRect(x + 1, mid - a, Math.max(1, bw - 3), a * 2);
      }

      // Voice: a smooth gradient waveform that always stays.
      const g = ctx.createLinearGradient(0, 0, w, 0);
      g.addColorStop(0, "#7c3aed"); g.addColorStop(0.5, "#a96bff"); g.addColorStop(1, "#e3c4ff");
      ctx.strokeStyle = g; ctx.lineWidth = 2.4; ctx.lineJoin = "round";
      ctx.beginPath();
      for (let x = 0; x <= w; x += 2) {
        const u = x / w * 9 + t * 1.6;
        const amp = h * 0.36 * voiceEnv(u);
        const y = mid + amp * Math.sin(x * 0.11 + t * 14) * Math.sin(x * 0.023 + t * 3);
        x === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();

      if (!reduce) { t += 0.006; requestAnimationFrame(draw); }
    };
    draw();

    sw.addEventListener("click", () => {
      on = !on;
      sw.setAttribute("aria-checked", String(on));
      label.textContent = on ? "Vocalizer on" : "Vocalizer off";
      if (reduce) { music = on ? 0.08 : 1; draw(); }
    });
  }

  // Copy the install command.
  const copy = document.getElementById("copy");
  if (copy) {
    copy.addEventListener("click", async () => {
      const text = document.getElementById("cmd").textContent;
      try { await navigator.clipboard.writeText(text); copy.textContent = "Copied"; }
      catch { copy.textContent = "Select and copy"; }
      setTimeout(() => (copy.textContent = "Copy"), 1800);
    });
  }

  // Show the latest release's version and size (the static text is the fallback).
  fetch("https://api.github.com/repos/0xArx/vocalizer-mac/releases/latest")
    .then((r) => (r.ok ? r.json() : null))
    .then((rel) => {
      if (!rel || !rel.tag_name) return;
      const v = rel.tag_name.replace(/^v/, "");
      document.querySelectorAll("[data-version]").forEach((el) => (el.textContent = "Version " + v));
      const asset = (rel.assets || []).find((a) => a.name === "Vocalizer-macOS.zip");
      if (asset) {
        const mb = Math.round(asset.size / 1e6);
        document.querySelectorAll("[data-size]").forEach((el) => (el.textContent = mb + " MB"));
      }
    })
    .catch(() => {});
})();

// Reveal blocks as they scroll into view, staggered within each grid.
(() => {
  const els = document.querySelectorAll(".reveal");
  document.querySelectorAll(".grid, .modes, .steps").forEach((g) =>
    [...g.children].forEach((c, i) => c.style.setProperty("--d", (i % 3) * 0.08 + "s")));
  if (!("IntersectionObserver" in window)) { els.forEach((e) => e.classList.add("in")); return; }
  const io = new IntersectionObserver((entries) => entries.forEach((e) => {
    if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }), { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
  els.forEach((e) => io.observe(e));
  // Safety net: anything already on screen after a moment is shown even if the observer never fired.
  setTimeout(() => els.forEach((e) => {
    if (e.getBoundingClientRect().top < window.innerHeight) e.classList.add("in");
  }), 1500);
})();
