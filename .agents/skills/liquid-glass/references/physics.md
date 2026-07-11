# Liquid Glass Physics Reference

## Table of Contents
1. What the displacement map actually does
2. Displacement map encoding rules
3. Approach A: Signed Distance Field (SDF)
4. Approach B: Snell's Law (physics)
5. Surface functions (Snell's mode)
6. Parameter effects table
7. Common pitfalls

---

## 1. What the displacement map actually does

`feDisplacementMap` reads each pixel P(x, y) in the output from a **different position** in the source image:

```
output(x, y) = source(x + offsetX, y + offsetY)
offsetX = (R/255 - 0.5) * scale
offsetY = (G/255 - 0.5) * scale
```

So the displacement map is an image where **color encodes pixel movement instructions**:
- R channel = how much to shift sampling point left/right
- G channel = how much to shift sampling point up/down
- R=128, G=128 = no movement (neutral gray)
- R=255 = max rightward shift (`+scale/2` pixels)
- R=0   = max leftward shift (`-scale/2` pixels)

For a glass lens, edge pixels should sample from slightly inward (toward center), creating the "light bends through curved glass" illusion.

---

## 2. Displacement map encoding rules

```
channel_value = clamp(round(128 + normalized_offset * 127), 0, 255)
```

To decode a channel back to pixel offset:
```
pixel_offset = (channel_value / 255 - 0.5) * scale
```

The `scale` attribute on `<feDisplacementMap>` is the amplifier. The PNG only stores normalized [-1, 1] values; `scale` determines actual pixel magnitude.

**Critical:** Always set `color-interpolation-filters="sRGB"` on the `<filter>` element. Without it, browsers may apply gamma correction to the color channels before using them as displacement values, causing incorrect results.

---

## 3. Approach A: Signed Distance Field (SDF)

The SDF approach computes how far each pixel is from the nearest rounded rectangle border, then uses that distance to determine displacement magnitude. Simple, fast, works for any shape.

### roundedRectSDF

```python
def rounded_rect_sdf(px, py, w, h, r):
    """Returns signed distance: negative inside, 0 on border, positive outside."""
    cx, cy = px - w/2, py - h/2    # center-origin coordinates
    hx, hy = w/2 - r, h/2 - r     # half-extents minus radius
    qx = abs(cx) - hx
    qy = abs(cy) - hy
    inner = min(max(qx, qy), 0.0)
    outer = sqrt(max(qx, 0)**2 + max(qy, 0)**2)
    return inner + outer - r
```

### smoothStep

```python
def smoothstep(edge0, edge1, x):
    """Hermite smooth interpolation. Returns 0..1."""
    t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
```

Smoothstep is crucial: linear falloff looks artificial. The cubic `t²(3-2t)` creates a "slow→fast→slow" rhythm that mimics how glass gradually thickens toward its center.

### Full SDF pipeline

```python
dist = rounded_rect_sdf(px, py, width, height, radius)

if dist > 0 or dist < -bezel_width:
    # Outside glass or inside flat center: no displacement
    R, G = 128, 128
else:
    # Bezel zone: dist in [-bezel_width, 0]
    t = smoothstep(-bezel_width, 0.0, dist)  # 1.0 at edge, 0.0 at depth

    # Direction: inward unit vector from pixel toward center
    inward_x = (center_x - px) / distance_to_center
    inward_y = (center_y - py) / distance_to_center

    R = round(128 + t * inward_x * 127)
    G = round(128 + t * inward_y * 127)
```

The `scale` value you pass to `feDisplacementMap` should equal `bezel_width` (in pixels). This way the normalized [0,1] magnitude maps to at most `bezel_width` pixels of actual displacement.

---

## 4. Approach B: Snell's Law (physics)

Snell-Descartes Law describes how light bends at a material boundary:

```
n1 · sin(θ1) = n2 · sin(θ2)
```

Where:
- `n1 = 1.0` (air — index of refraction)
- `n2 = 1.5` (glass — typical soda-lime glass)
- `θ1` = angle of incoming ray relative to surface normal
- `θ2` = angle of refracted ray relative to normal

When `n2 > n1`, the ray bends **toward** the normal (toward the glass surface center), which is why glass magnifies. The greater the angle of incidence, the more the ray bends.

### Simplifying assumptions (kube.io approach)

These assumptions make the computation tractable:
1. All incident rays travel straight down (orthogonal to the screen plane)
2. The glass surface is described by a 2D cross-section (surface function)
3. Only one refraction event (entry into glass, not exit)
4. Shapes are rounded rectangles formed by stretching circles

### Vector form of Snell's Law

```python
ratio = n1 / n2
# refracted_direction = ratio * incident + (ratio * cos_i - cos_r) * normal
refracted_x = ratio * incident_x + (ratio * cos_i - cos_r) * normal_x
refracted_y = ratio * incident_y + (ratio * cos_i - cos_r) * normal_y
```

The lateral displacement (what gets encoded in the map) is the horizontal component of how far the refracted ray has traveled by the time it exits the bezel.

### Pre-computation (127 samples)

Because the displacement magnitude depends only on distance from the border (not position around it), compute it once for 127 sample points (`d` from 0 to 1 across the bezel), then look up by distance for each pixel:

```python
magnitudes = []
for i in range(127):
    d = (i + 1) / 127   # 0 = outer edge, 1 = flat interior start
    mag = compute_snell_displacement(d, surface_fn, n2)
    magnitudes.append(mag)

max_mag = max(magnitudes)
norm_magnitudes = [m / max_mag for m in magnitudes]
```

The `scale` attribute then equals `max_mag * bezel_width_px` to convert normalized → actual pixel displacement.

---

## 5. Surface functions (Snell's mode)

The surface function `f(d)` describes the glass profile: how tall the glass is at normalized position `d` (0 = outer edge, 1 = inner flat surface start).

### Convex Squircle — Apple's preferred

```
f(d) = (1 - (1-d)^4)^(1/4)
```

A "super-ellipse" arc. The flat→curve transition is softer than a circle: the bezel starts nearly flat at the outer edge, curves more steeply near the inner edge. This keeps refraction gradients smooth even when the shape is stretched into a wide rectangle. Optically, the bezel appears thinner than its physical size (less harsh banding).

**Use when:** building anything that needs to match Apple's aesthetic, or when the glass will be stretched/resized.

### Convex Circle

```
f(d) = sqrt(1 - (1-d)^2)
```

A standard circular arc (spherical dome cross-section). Produces stronger, more pronounced refraction near the inner edge. Looks great for circular elements; shows a harsh band when stretched into a rectangle.

**Use when:** the element is always circular, or you want maximum edge refraction.

### Concave

```
f(d) = 1 - ConvexCircle(d)
```

A bowl shape. Rays diverge **outward** beyond the glass boundary — content outside the element appears through the glass. This requires sampling pixels outside the element bounds, which `backdrop-filter` cannot do.

**Avoid unless:** intentionally creating a concave lens / magnifying glass effect with explicit overflow.

### Lip

```
f(d) = mix(Squircle(d), Concave(d), smootherstep(d))
```

A raised rim that dips toward the center. Creates a prominent outer ring with a shallow interior bowl. Used in Apple's Toggle/Switch component.

**Use when:** building toggle controls, switch buttons, or elements that need a raised bezel rim.

---

## 6. Parameter effects table

| Parameter | Low value | High value | Recommended |
|-----------|-----------|------------|-------------|
| `scale` (feDisplacementMap) | Subtle, barely visible refraction | Strong magnification / distortion | -25 to -45 |
| `bezel_width` | Thin glass edge, minimal refraction band | Wide bezel with broad warping zone | radius × 0.5 to radius |
| `n2` (Snell's mode) | 1.1: barely any bending | 2.0: strong prism effect | 1.5 (glass) |
| `blur` (backdrop-filter) | 4px: sharp content visible | 24px: heavily frosted | 10–16px |
| tint opacity | 0.05: almost invisible | 0.35: opaque tinted panel | 0.15–0.22 |
| specular top alpha | 0.2: barely lit | 1.0: bright chrome rim | 0.6–0.8 |

---

## 7. Common pitfalls

**Wrong `scale` direction:** Positive scale creates a fish-eye (content shrinks). Apple's effect uses negative scale (magnifying lens). If the effect looks like it's pushing content outward instead of sampling inward, negate `scale`.

**Concave surface + backdrop-filter:** Concave maps create displacement vectors that point beyond the element boundary. `backdrop-filter` only samples pixels within the element's own bounds — you'll get mirrored edge artifacts. Use convex surfaces.

**Circle vs Squircle on rectangles:** The Circle surface function creates a harsh inner refraction band (visible dark ring) when stretched to a wide button. Switch to Squircle for non-circular elements.

**Missing `color-interpolation-filters="sRGB"`:** Without this, Chrome may apply gamma to the R/G channel values before using them as displacement offsets. This causes the center of the displacement map to shift away from 128 (neutral), introducing unintended warping everywhere.

**Filter dimensions mismatch:** The `<feImage>` dimensions in `width` and `height` must exactly match the rendered element's pixel size. A mismatch causes the displacement map to scale/stretch, producing misaligned refraction (edges don't line up with the visible border). Always hardcode the element dimensions or regenerate the map when dimensions change.

**Too many glass elements:** Each `feDisplacementMap` composite is GPU-intensive. Limit to 3–5 glass elements per page. Chromatic aberration (3 passes) triples the cost.
