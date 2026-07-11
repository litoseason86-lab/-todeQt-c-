# SVG Filter Pipeline Reference

## Table of Contents
1. How SVG filters work
2. Filter primitives used in Liquid Glass
3. Complete filter pipeline
4. Chromatic aberration step-by-step
5. The `isolation: isolate` requirement
6. Browser support matrix
7. Graceful degradation
8. Performance guidelines

---

## 1. How SVG filters work

SVG filters are a compositing pipeline. Each `<filter>` element contains a sequence of **filter primitives** — each reads from named inputs, processes pixels, and writes to a named `result` buffer. The final unnamed result (or the last node's output) is what gets rendered.

```html
<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"
     style="position:absolute;overflow:hidden">
  <defs>
    <filter id="my-filter" color-interpolation-filters="sRGB"
            x="0%" y="0%" width="100%" height="100%">
      <!-- primitives here, each writes to a result="name" buffer -->
    </filter>
  </defs>
</svg>
```

Reference the filter with CSS:
```css
/* Apply to the element itself */
filter: url(#my-filter);

/* Apply to BACKDROP (what's behind the element) — Chrome only with SVG URL */
backdrop-filter: url(#my-filter) blur(12px);
-webkit-backdrop-filter: url(#my-filter) blur(12px);
```

**`x`, `y`, `width`, `height` on `<filter>`:** These define the filter region. Set to `0%/0%/100%/100%` to ensure the full element area is processed. Leaving defaults can clip the filter.

---

## 2. Filter primitives used in Liquid Glass

### `<feImage>`

Loads an external image (PNG, SVG, data URI) into the filter pipeline as a named result.

```html
<feImage
  result="dispMap"
  x="0" y="0"
  width="300" height="56"
  preserveAspectRatio="none"
  href="data:image/png;base64,..."
/>
```

- `preserveAspectRatio="none"`: stretches image to fill exact dimensions. Required when the displacement map is sized differently from the element.
- `href` vs `xlink:href`: Use `href` (SVG 2.0 standard). `xlink:href` is deprecated but still works in older Chrome.
- **Dimensions must match** the rendered element exactly. Mismatch = misaligned refraction.

### `<feDisplacementMap>`

The core effect: warps one image based on color values from another.

```html
<feDisplacementMap
  in="SourceGraphic"    <!-- what to warp -->
  in2="dispMap"         <!-- the displacement map image -->
  scale="-35"           <!-- amplifier: negative = magnifying, positive = shrinking -->
  xChannelSelector="R"  <!-- R channel drives X offset -->
  yChannelSelector="G"  <!-- G channel drives Y offset -->
  result="displaced"
/>
```

**Pixel math:**
```
output(x,y) = source(x + (R/255 - 0.5)*scale, y + (G/255 - 0.5)*scale)
```

**`in` special values:**
- `SourceGraphic`: the original element content (or backdrop if used in `backdrop-filter`)
- `SourceAlpha`: alpha channel only
- Any named `result` from a previous primitive

### `<feGaussianBlur>`

Blurs an input. Used for:
- Softening the source before displacement (reduces aliasing)
- Blurring the neutral gray mask in the inline SVG displacement map

```html
<feGaussianBlur in="SourceGraphic" stdDeviation="1.5" result="blurred"/>
```

- `stdDeviation`: blur radius in pixels. `"2 4"` applies different blur per axis.

### `<feColorMatrix>`

Transforms color channels via a 5×4 matrix. Used for chromatic aberration to isolate individual RGB channels.

```html
<!-- Isolate Red channel only (zero out G and B) -->
<feColorMatrix in="dispR" type="matrix"
  values="1 0 0 0 0
          0 0 0 0 0
          0 0 0 0 0
          0 0 0 1 0"
  result="Ronly"
/>
```

Matrix format: 4 rows (R, G, B, A outputs) × 5 columns (R, G, B, A, constant inputs).
`values="r_r r_g r_b r_a r_const  g_r g_g ..."`

### `<feBlend>`

Composites two images together using blend modes.

```html
<feBlend in="Ronly" in2="Gonly" mode="screen" result="RG"/>
<feBlend in="RG"    in2="Bonly" mode="screen"/>
```

`mode="screen"`: adds images together (brightens). Good for combining isolated channels.

### `<feComposite>`

Composites two images using Porter-Duff operators. Used in specular lighting pipelines:
```html
<feComposite in="specLight" operator="arithmetic"
  k1="0" k2="1" k3="1" k4="0" result="litImage"/>
```

### `<feTurbulence>` (alternative approach)

Generates procedural noise. Simpler than displacement maps but less precise:
```html
<feTurbulence type="fractalNoise" baseFrequency="0.008" numOctaves="2"
              seed="92" result="noise"/>
<feGaussianBlur in="noise" stdDeviation="2" result="blurred"/>
<feDisplacementMap in="SourceGraphic" in2="blurred" scale="70"
                   xChannelSelector="R" yChannelSelector="G"/>
```

Pros: No external image asset, works anywhere SVG filters work.
Cons: Random organic texture instead of physics-based edge refraction. Keep `seed` fixed — `feTurbulence` is expensive to recalculate.

### `<feSpecularLighting>` (advanced)

Computes lighting from a bump map for realistic specular highlights:
```html
<feSpecularLighting in="softMap" surfaceScale="5"
  specularConstant="1" specularExponent="100"
  lighting-color="white" result="specLight">
  <fePointLight x="-200" y="-200" z="300"/>
</feSpecularLighting>
```

Produces physically-accurate specular highlights driven by the turbulence shape.

---

## 3. Complete filter pipeline

The minimal physics-accurate Liquid Glass filter:

```html
<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"
     style="position:absolute;overflow:hidden">
  <defs>
    <filter id="liquid-glass" color-interpolation-filters="sRGB"
            x="0%" y="0%" width="100%" height="100%">

      <!-- Step 1: Load the displacement map -->
      <feImage result="dispMap"
        x="0" y="0" width="ELEMENT_WIDTH" height="ELEMENT_HEIGHT"
        preserveAspectRatio="none"
        href="DISPLACEMENT_MAP_DATA_URI"
      />

      <!-- Step 2: Apply displacement (refraction) -->
      <feDisplacementMap
        in="SourceGraphic"
        in2="dispMap"
        scale="-35"
        xChannelSelector="R"
        yChannelSelector="G"
      />

    </filter>
  </defs>
</svg>
```

Apply to element:
```css
.glass-refract-layer {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
  -webkit-backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
  isolation: isolate;    /* REQUIRED — see section 5 */
}
```

---

## 4. Chromatic aberration step-by-step

Real glass disperses light: different wavelengths refract at different angles (prism effect). Replicate this by running three displacement passes with slightly different scale values:

```html
<filter id="liquid-glass-ca" color-interpolation-filters="sRGB"
        x="0%" y="0%" width="100%" height="100%">

  <!-- Shared displacement map -->
  <feImage result="dispMap" x="0" y="0"
    width="300" height="56" preserveAspectRatio="none"
    href="DISPLACEMENT_MAP_URI"/>

  <!-- Red: baseline scale -->
  <feDisplacementMap in="SourceGraphic" in2="dispMap"
    scale="-35" xChannelSelector="R" yChannelSelector="G" result="dispR"/>
  <feColorMatrix in="dispR" type="matrix"
    values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="Ronly"/>

  <!-- Green: 7% stronger (disperses more) -->
  <feDisplacementMap in="SourceGraphic" in2="dispMap"
    scale="-37" xChannelSelector="R" yChannelSelector="G" result="dispG"/>
  <feColorMatrix in="dispG" type="matrix"
    values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="Gonly"/>

  <!-- Blue: 3.5% stronger (between R and G) -->
  <feDisplacementMap in="SourceGraphic" in2="dispMap"
    scale="-36" xChannelSelector="R" yChannelSelector="G" result="dispB"/>
  <feColorMatrix in="dispB" type="matrix"
    values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="Bonly"/>

  <!-- Merge all three with screen blend -->
  <feBlend in="Ronly" in2="Gonly" mode="screen" result="RG"/>
  <feBlend in="RG"    in2="Bonly" mode="screen"/>

</filter>
```

**Scale spread:** A 5–10% difference between R and G creates subtle but visible chromatic fringing. More than 15% looks like a broken display.

---

## 5. The `isolation: isolate` requirement

The `.glass-refract-layer` div **must have `isolation: isolate`**. Without it, the element shares a stacking context with its siblings, and `backdrop-filter` may capture incorrect content or produce z-fighting artifacts.

```css
.glass-refract-layer {
  isolation: isolate;    /* creates its own stacking context */
  backdrop-filter: ...;
}
```

The parent container also needs `overflow: hidden` to clip the glass effect to the element boundary (otherwise refraction bleeds visually outside).

---

## 6. Browser support matrix

| Browser | `backdrop-filter: blur()` | `backdrop-filter: url(#svg-filter)` | SVG `filter: url()` |
|---------|--------------------------|-------------------------------------|---------------------|
| Chrome 76+ | ✅ | ✅ (full Liquid Glass) | ✅ |
| Edge 79+ (Chromium) | ✅ | ✅ (full Liquid Glass) | ✅ |
| Firefox 103+ | ✅ | ❌ | ✅ |
| Safari 9+ | ✅ (-webkit-) | ❌ | ✅ |
| IE / old Edge | ❌ | ❌ | partial |

**Key constraint:** Firefox and Safari support `backdrop-filter: blur()` but not `backdrop-filter: url(#svg-id)`. The SVG filter URL reference in backdrop-filter is Chrome/Chromium-exclusive.

**Workaround for Firefox/Safari:** Apply `filter: url(#id)` directly to a canvas element that captures a screenshot of the page (using html2canvas or similar). Much more complex, but achieves the effect cross-browser.

---

## 7. Graceful degradation

When the SVG URL is ignored by non-Chrome browsers, `blur()` still applies, giving a standard glassmorphism fallback:

```css
/* Works everywhere: frosted glass (no refraction) */
.glass-refract-layer {
  backdrop-filter: blur(12px) brightness(1.05) saturate(1.3);
  -webkit-backdrop-filter: blur(12px) brightness(1.05) saturate(1.3);
}

/* Chrome/Chromium only: adds SVG refraction on top of blur */
@supports (backdrop-filter: url(#x)) {
  .glass-refract-layer {
    backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
    -webkit-backdrop-filter: blur(12px) url(#liquid-glass) brightness(1.05) saturate(1.3);
  }
}
```

The `@supports` rule is optional — non-supporting browsers simply ignore the `url()` part of the value in the default rule, falling back to the blur naturally.

---

## 8. Performance guidelines

**Limit elements:** SVG displacement filters are GPU-composited. Each instance creates a new compositor layer. More than 5–6 glass elements on a single page can cause jank on lower-end hardware.

**Fix `feTurbulence` seed:** If using turbulence instead of a precomputed map, never let the seed animate on every frame. Each change forces a full GPU recalculation of the noise texture.

**Avoid animating `scale`:** Changing `scale` on `feDisplacementMap` via JS forces a filter recompute every frame. For hover/press animations, animate CSS transforms or opacity on the layers instead.

**`will-change: transform`:** Adding `will-change: transform` to the parent glass container promotes it to its own compositor layer, reducing paint invalidation when nearby content changes.

**Small blur radius:** `blur(12px)` is more performant than `blur(32px)`. Use the minimum blur that still looks frosted.

**One filter per page, multiple elements:** If multiple glass buttons share identical dimensions, they can all reference the same `<filter>` id. Only one filter needs to be defined in the `<svg>`.
