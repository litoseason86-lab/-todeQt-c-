---
name: liquid-glass
description: Implement Apple's Liquid Glass UI effect (iOS 26 / macOS 26) using CSS and SVG displacement filters. Use this skill when asked to create liquid glass effects, frosted glass components, iOS 26 glass UI, glassmorphism with refraction, glass buttons/cards/navbars, feDisplacementMap refraction effects, or any UI that needs realistic glass-like distortion of background content. Teaches the full technique from physics (Snell's law, SDF) to ready-to-use HTML/React/CSS templates.
---

# Liquid Glass

Apple's Liquid Glass (iOS 26 / macOS 26) goes beyond simple `backdrop-filter: blur()`. It uses SVG `feDisplacementMap` to simulate **light refraction through curved glass**. Background content physically warps at the element's edges, as if viewed through real glass.

## What makes it different from glassmorphism

Glassmorphism = frosted blur only. Liquid Glass = frosted blur + **edge refraction** (background warps near borders). The technique is `backdrop-filter: url(#svg-filter)` — Chrome/Chromium only for the full effect; Firefox/Safari gracefully degrade to blur.

## Four-layer composition

Every Liquid Glass element stacks four layers:

```html
<div class="glass">                    <!-- position:relative; overflow:hidden -->
  <div class="glass__refract"></div>   <!-- Layer 0: backdrop-filter + SVG filter -->
  <div class="glass__tint"></div>      <!-- Layer 1: semi-transparent color tint -->
  <div class="glass__specular"></div>  <!-- Layer 2: inset box-shadow rim highlight -->
  <div class="glass__content">...</div><!-- Layer 3: your actual content -->
</div>
```

```css
.glass { position: relative; border-radius: 28px; overflow: hidden; }

/* Layer 0: Refraction (Chrome only for SVG filter URL) */
.glass__refract {
  position: absolute; inset: 0; border-radius: inherit;
  backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
  -webkit-backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
  isolation: isolate;   /* REQUIRED — creates stacking context */
}

/* Layer 1: Glass tint */
.glass__tint {
  position: absolute; inset: 0; border-radius: inherit;
  background: rgba(255, 255, 255, 0.18);
}

/* Layer 2: Specular rim (top edge bright, bottom edge subtle) */
.glass__specular {
  position: absolute; inset: 0; border-radius: inherit;
  box-shadow:
    inset 0  1px 0 rgba(255,255,255,0.75),
    inset 0 -1px 0 rgba(255,255,255,0.15);
}

/* Layer 3: Content */
.glass__content { position: relative; z-index: 10; }
```

## SVG filter (the refraction engine)

Define once in a hidden `<svg>` anywhere in the DOM:

```html
<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"
     style="position:absolute;overflow:hidden">
  <defs>
    <filter id="liquid-glass" color-interpolation-filters="sRGB"
            x="0%" y="0%" width="100%" height="100%">
      <feImage result="dispMap"
        x="0" y="0" width="ELEMENT_WIDTH" height="ELEMENT_HEIGHT"
        preserveAspectRatio="none"
        href="DISPLACEMENT_MAP_DATA_URI"
      />
      <feDisplacementMap
        in="SourceGraphic" in2="dispMap"
        scale="-35"
        xChannelSelector="R" yChannelSelector="G"
      />
    </filter>
  </defs>
</svg>
```

`scale` is the key parameter: **negative = magnifying** (Apple-style), positive = fish-eye.

## Displacement map — the key concept

The displacement map is an image where **color = movement instruction**:
- R channel = horizontal shift (128 = neutral, 255 = max right, 0 = max left)
- G channel = vertical shift (128 = neutral, 255 = max down, 0 = max up)
- `scale` amplifies: `actual_px = (channel/255 - 0.5) × scale`

Edge pixels have non-neutral R/G → sample content from slightly inward → looks like refracted glass. Center pixels have R=G=128 → no displacement → flat glass surface.

## Workflow

**Path A — Copy a pre-baked template (fastest)**
Ready-to-use files in `assets/templates/`:
- `glass-button.html` — 300×56 pill CTA button, vivid demo background
- `glass-card.html` — 360×220 card with full chromatic aberration
- `glass-pill-navbar.html` — Apple-style 3-item tab bar with nested active state
- `LiquidGlass.tsx` — React/TypeScript component (React 18+, no external dependencies)

Open any HTML file in Chrome to see the full effect.

**Path B — Generate a custom displacement map**
For elements with non-standard dimensions or physics-precise refraction:
```bash
python scripts/generate-displacement-map.py \
  --width 400 --height 80 --radius 40 \
  --mode sdf --output map.png --datauri
```
Copy the printed data URI into `<feImage href="...">`. Two modes: `sdf` (fast, great results) and `snell` (physics-accurate Snell's law).

## Key parameters

| Parameter | What it does | Range |
|-----------|-------------|-------|
| `scale` on feDisplacementMap | Refraction strength. Negative = magnify. | -20 (subtle) to -50 (dramatic) |
| `blur` in backdrop-filter | Frosted glass thickness | 8–20px |
| tint layer background | Glass color + opacity | rgba(255,255,255, 0.12–0.25) |
| specular top box-shadow alpha | Rim highlight brightness | 0.5–0.9 |

## Browser compatibility

**Full effect:** Chrome 76+ / Edge 79+ (Chromium) only.
**Fallback (blur only):** All modern browsers — Firefox/Safari ignore the `url()` part automatically, keeping the blur.

```css
/* No @supports needed — automatic graceful degradation */
backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
/* Firefox/Safari see: blur(12px) brightness(1.05) saturate(1.3) ✓ */
/* Chrome sees full pipeline ✓ */
```

## Chromatic aberration (advanced)

Run three `feDisplacementMap` passes (R/G/B) with slightly different scale values (±5–7%), isolate each channel with `feColorMatrix`, merge with `feBlend mode="screen"`. See `assets/templates/glass-card.html` for a complete working example.

## Learn more

- **Physics deep-dive** (Snell's law, SDF, surface functions, pitfalls): `references/physics.md`
- **SVG filter primitives A–Z**, pipeline, browser compat, performance: `references/filter-pipeline.md`
- **Generator script** usage: `python scripts/generate-displacement-map.py --help`
