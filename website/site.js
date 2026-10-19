// Vocalizer site: the hero demo, the delay scale, copy, and the latest release number.
document.documentElement.classList.add("js");

(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // The demo is the page's one authored moment: it opens with the music playing, then switches
  // itself on so the music falls away and the voice is left. Visitors can flip it back and forth.
  const canvas = document.getElementById("wave");
  const sw = document.getElementById("demo-switch");
  const label = document.getElementById("demo-label");
  const hero = document.getElementById("hero");
  if (canvas && sw) {
    const ctx = canvas.getContext("2d");
    let on = false, music = 1, t = 0, w = 0, h = 0, last = 0, visible = true, raf = 0, touched = false;

    const size = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = canvas.clientWidth; h = canvas.clientHeight;
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };

    // Speech-like envelope: syllables grouped into phrases with short pauses.
    const voiceEnv = (x) => {
      const phrase = Math.max(0, Math.sin(x * 0.9)) ** 0.6;
      return phrase * (0.55 + 0.45 * Math.abs(Math.sin(x * 6.3 + Math.sin(x * 2.1))));
    };

    const draw = () => {
      ctx.clearRect(0, 0, w, h);
      const mid = h / 2, bars = Math.max(48, Math.floor(w / 7)), bw = w / bars;

      // Music: wide, steady bars (drums and chords), sinking into the floor when filtered.
      if (music > 0.01) {
        ctx.fillStyle = `rgba(120, 110, 140, ${0.22 + 0.5 * music})`;
        for (let i = 0; i < bars; i++) {
          const beat = 0.55 + 0.45 * Math.abs(Math.sin((i + t * 9) * 0.55));
          const chord = 0.6 + 0.4 * Math.sin(i * 0.21 + t * 1.3);
          const a = h * 0.42 * beat * chord * music;
          ctx.fillRect(i * bw + 1, mid - a, Math.max(1, bw - 3), a * 2);
        }
      }

      // Voice: one continuous line that is always there; it brightens as the music leaves.
      const clarity = 1 - music;
      const g = ctx.createLinearGradient(0, 0, w, 0);
      g.addColorStop(0, "#7c3aed"); g.addColorStop(0.5, "#a96bff"); g.addColorStop(1, "#dcc0ff");
      ctx.save();
      ctx.globalAlpha = 0.55 + 0.45 * clarity;
      ctx.shadowColor = "rgba(160, 100, 255, 0.8)";
      ctx.shadowBlur = 12 * clarity;
      ctx.strokeStyle = g; ctx.lineWidth = 2.2 + 0.6 * clarity; ctx.lineJoin = "round";
      ctx.beginPath();
      for (let x = 0; x <= w; x += 2) {
        const u = (x / w) * 9 + t * 1.6;
        const amp = h * 0.36 * voiceEnv(u);
        const y = mid + amp * Math.sin(x * 0.11 + t * 14) * Math.sin(x * 0.023 + t * 3);
        x === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.restore();
    };

    const frame = (now) => {
      const dt = Math.min(0.05, (now - (last || now)) / 1000);
      last = now;
      // Exponential approach: fast at first, settling gently, and reversible mid-way.
      music += ((on ? 0 : 1) - music) * (1 - Math.exp(-dt / 0.32));
      t += dt * 0.36;
      draw();
      raf = visible ? requestAnimationFrame(frame) : 0;
    };

    const set = (value) => {
      on = value;
      sw.setAttribute("aria-checked", String(on));
      label.textContent = on ? "Vocalizer on" : "Vocalizer off";
      hero.classList.toggle("music", !on);
      if (reduce) { music = on ? 0 : 1; draw(); }
    };

    size();
    window.addEventListener("resize", () => { size(); if (reduce) draw(); });
    sw.addEventListener("click", () => { touched = true; set(!on); });

    if (reduce) {
      set(true);
    } else {
      draw();
      // Only animate while the demo is on screen.
      new IntersectionObserver(([e]) => {
        visible = e.isIntersecting;
        if (visible && !raf) { last = 0; raf = requestAnimationFrame(frame); }
      }).observe(canvas);
      // Let the visitor see the music for a beat, then switch Vocalizer on.
      setTimeout(() => { if (!touched) set(true); }, 1600);
    }
  }

  // The logo tells the story: tangled, random sound goes in, one clean wave comes out.
  const ins = [...document.querySelectorAll(".wave .in")];
  const out = document.querySelector(".wave .out");
  if (ins.length && out) {
    const X0 = 240, X1 = 462, STEP = 9, MID = 515;
    const n = Math.floor((X1 - X0) / STEP) + 1;
    // Each tangled line is value noise: random targets per point that drift to new random targets.
    const lines = ins.map((_, li) => ({
      from: Array.from({ length: n }, () => Math.random() * 2 - 1),
      to: Array.from({ length: n }, () => Math.random() * 2 - 1),
      p: Math.random(), speed: 2.2 + li * 0.9,
    }));
    const ease = (u) => u * u * (3 - 2 * u);
    const drawLogo = (dt, t) => {
      lines.forEach((L, li) => {
        L.p += dt * L.speed;
        if (L.p >= 1) { L.p -= 1; L.from = L.to; L.to = L.from.map(() => Math.random() * 2 - 1); }
        const k = ease(L.p);
        let d = "";
        for (let i = 0; i < n; i++) {
          const x = X0 + i * STEP;
          const env = 118 - 58 * (i / (n - 1)) ** 2;           // loud, squeezing toward the filter
          const y = MID + env * (L.from[i] + (L.to[i] - L.from[i]) * k) * (1 - li * 0.18);
          d += (i ? " L" : "M") + x.toFixed(1) + " " + y.toFixed(1);
        }
        ins[li].setAttribute("d", d);
      });
      // Out: a pure sine, flowing away from the filter.
      let o = "";
      for (let x = 606; x <= 796; x += 4) {
        const y = MID + 26 * Math.sin((x - 606) * (2 * Math.PI / 58) - t * 4.2);
        o += (x === 606 ? "M" : " L") + x + " " + y.toFixed(1);
      }
      out.setAttribute("d", o);
    };
    const heroBox = document.getElementById("hero");
    if (reduce) drawLogo(0, 0);
    else {
      let last = 0, t = 0, live = true, id = 0;
      const tick = (now) => {
        const dt = Math.min(0.05, (now - (last || now)) / 1000); last = now; t += dt;
        drawLogo(dt, t);
        id = live ? requestAnimationFrame(tick) : 0;
      };
      new IntersectionObserver(([e]) => {
        live = e.isIntersecting;
        if (live && !id) { last = 0; id = requestAnimationFrame(tick); }
      }).observe(heroBox.querySelector(".logo"));
    }
  }

  // The logo's waveform only moves while the hero is on screen.
  const heroEl = document.getElementById("hero");
  if (heroEl && "IntersectionObserver" in window) {
    new IntersectionObserver(([e]) => heroEl.classList.toggle("paused", !e.isIntersecting)).observe(heroEl);
  }

  // The delay scale draws its bars when it comes into view.
  const scale = document.getElementById("scale");
  if (scale) {
    if (reduce || !("IntersectionObserver" in window)) scale.classList.add("drawn");
    else {
      const io = new IntersectionObserver(([e]) => {
        if (e.isIntersecting) { scale.classList.add("drawn"); io.disconnect(); }
      }, { rootMargin: "0px 0px -80px 0px" });
      io.observe(scale);
      setTimeout(() => { if (scale.getBoundingClientRect().top < innerHeight) scale.classList.add("drawn"); }, 2500);
    }
  }

  // Copy the install command.
  const copy = document.getElementById("copy");
  if (copy) {
    copy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(document.getElementById("cmd").textContent); copy.textContent = "Copied"; }
      catch { copy.textContent = "Select it"; }
      setTimeout(() => (copy.textContent = "Copy"), 1600);
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
      if (asset) document.querySelectorAll("[data-size]").forEach((el) => (el.textContent = Math.round(asset.size / 1e6) + " MB"));
    })
    .catch(() => {});
})();
