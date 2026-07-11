#!/usr/bin/env python3
"""
Liquid Glass Displacement Map Generator
========================================
Generates a PNG displacement map for use with SVG feDisplacementMap filters
to create Apple-style Liquid Glass refraction effects.

Encoding: R channel = X displacement, G channel = Y displacement.
          128 = neutral (no displacement). 0 = max negative, 255 = max positive.
          actual_offset_px = (channel/255 - 0.5) * scale

Two modes:
  --mode sdf    (default) Signed Distance Field approach. Uses roundedRectSDF +
                smoothStep to compute displacement based on distance from edge.
                Fast, flexible, good for any rounded rectangle shape.

  --mode snell  Physics-based Snell's Law approach. Computes actual light
                refraction through a curved glass surface using four surface
                functions (squircle, circle, concave, lip). Physically accurate.

Usage:
  python generate-displacement-map.py --width 300 --height 56 --radius 28 [options]

Options:
  --width INT       Element width in pixels  (default: 300)
  --height INT      Element height in pixels (default: 56)
  --radius INT      Border radius in pixels  (default: 28)
  --bezel INT       Bezel thickness in pixels (SDF mode, default: radius)
  --mode MODE       sdf | snell               (default: sdf)
  --surface SURF    squircle|circle|concave|lip (Snell mode, default: squircle)
  --n2 FLOAT        Refractive index of glass (Snell mode, default: 1.5)
  --output FILE     Output PNG file path      (default: displacement-map.png)
  --datauri         Print base64 data URI to stdout (for embedding in HTML/SVG)

Examples:
  # SDF mode (simplest, no dependencies, great results):
  python generate-displacement-map.py --width 300 --height 56 --radius 28 --datauri

  # Snell's law physics mode:
  python generate-displacement-map.py --width 300 --height 56 --radius 28 \\
    --mode snell --surface squircle --n2 1.5 --output map.png

  # Card with larger bezel:
  python generate-displacement-map.py --width 360 --height 220 --radius 20 \\
    --bezel 30 --output card-map.png --datauri
"""

import argparse
import base64
import math
import struct
import zlib


# ---------------------------------------------------------------------------
# Shared utilities
# ---------------------------------------------------------------------------

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def smoothstep(edge0, edge1, x):
    """Hermite interpolation (Ken Perlin's smoothstep). Returns value in [0,1]."""
    t = clamp((x - edge0) / (edge1 - edge0) if edge1 != edge0 else 0.0, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)

def smootherstep(edge0, edge1, x):
    """Smoother variant used in Lip surface function."""
    t = clamp((x - edge0) / (edge1 - edge0) if edge1 != edge0 else 0.0, 0.0, 1.0)
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


# ---------------------------------------------------------------------------
# PNG writer (zero dependencies — uses stdlib zlib + struct)
# ---------------------------------------------------------------------------

def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    c = chunk_type + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

def write_png(width: int, height: int, pixels: list) -> bytes:
    """
    Write a 24-bit RGB PNG.
    pixels: flat list of (r, g, b) tuples, row-major order.
    Returns raw PNG bytes.
    """
    # PNG signature
    sig = b"\x89PNG\r\n\x1a\n"
    # IHDR
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    ihdr = _png_chunk(b"IHDR", ihdr_data)
    # IDAT — raw image data with filter byte per row
    raw_rows = []
    idx = 0
    for y in range(height):
        row = bytearray([0])  # filter type 0 = None
        for x in range(width):
            r, g, b = pixels[idx]
            row += bytes([clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255)])
            idx += 1
        raw_rows.append(bytes(row))
    compressed = zlib.compress(b"".join(raw_rows), 9)
    idat = _png_chunk(b"IDAT", compressed)
    iend = _png_chunk(b"IEND", b"")
    return sig + ihdr + idat + iend


# ---------------------------------------------------------------------------
# SDF approach
# ---------------------------------------------------------------------------

def rounded_rect_sdf(px: float, py: float, w: float, h: float, r: float) -> float:
    """
    Signed distance from point (px,py) to a rounded rectangle centered at origin
    with half-extents (w/2, h/2) and corner radius r.
    Returns negative inside, 0 on boundary, positive outside.
    """
    # Shift to center-origin coordinate system
    cx, cy = px - w / 2, py - h / 2
    hx, hy = w / 2 - r, h / 2 - r
    qx = abs(cx) - hx
    qy = abs(cy) - hy
    inner = min(max(qx, qy), 0.0)
    outer = math.sqrt(max(qx, 0.0) ** 2 + max(qy, 0.0) ** 2)
    return inner + outer - r

def generate_sdf_map(width: int, height: int, radius: int, bezel: int) -> list:
    """
    Generate displacement map using SDF approach.
    Displacement vectors point inward (toward center), magnitude proportional
    to how close a pixel is to the edge (within bezel zone).
    """
    pixels = []
    cx, cy = width / 2.0, height / 2.0
    r = float(radius)

    for py in range(height):
        for px in range(width):
            # SDF from the rounded rect border — negative inside, positive outside
            dist = rounded_rect_sdf(float(px) + 0.5, float(py) + 0.5, float(width), float(height), r)

            # We want displacement in the bezel zone: dist in (-bezel, 0)
            # dist ~0 = at the border (max displacement)
            # dist ~-bezel = deep inside flat zone (no displacement)
            # dist > 0 = outside (no displacement)
            if dist > 0 or dist < -bezel:
                # No displacement
                pixels.append((128, 128, 0))
            else:
                # t=1 at border, t=0 at bezel depth
                t = smoothstep(-float(bezel), 0.0, dist)
                # Inward direction = direction from pixel toward center
                dx_raw = cx - (px + 0.5)
                dy_raw = cy - (py + 0.5)
                length = math.sqrt(dx_raw ** 2 + dy_raw ** 2)
                if length < 1e-9:
                    pixels.append((128, 128, 0))
                    continue
                # Normalized inward vector
                nx = dx_raw / length
                ny = dy_raw / length
                # Displacement magnitude: max at edge, zero inside flat zone
                mag = t  # [0,1]
                # Encode: 128 = neutral, 255 = max positive, 0 = max negative
                # Inward = content appears to come from center side → positive displacement
                r_val = int(128 + mag * nx * 127)
                g_val = int(128 + mag * ny * 127)
                pixels.append((r_val, g_val, 0))

    return pixels


# ---------------------------------------------------------------------------
# Snell's Law approach
# ---------------------------------------------------------------------------

NUM_SAMPLES = 127  # Matches 8-bit resolution of displacement map (0-127 bezel range)

def surface_squircle(d: float) -> float:
    """
    Apple's preferred surface: Convex Squircle.
    y = (1 - (1-d)^4)^(1/4)
    Softer flat→curve transition than a circle. Smooth gradients, no harsh edges
    when shape is stretched to a rectangle. Optically thinner-looking bezel.
    """
    return (1.0 - (1.0 - d) ** 4) ** 0.25

def surface_circle(d: float) -> float:
    """
    Convex Circle. y = sqrt(1 - (1-d)^2)
    Simple circular arc (spherical dome). Harsher transition to flat interior
    than squircle — more visible refraction band at the inner edge.
    """
    val = 1.0 - (1.0 - d) ** 2
    return math.sqrt(max(val, 0.0))

def surface_concave(d: float) -> float:
    """
    Concave (bowl). y = 1 - surface_circle(d)
    Causes rays to diverge OUTWARD beyond the glass boundaries.
    Avoid unless you intentionally want outside-boundary sampling.
    """
    return 1.0 - surface_circle(d)

def surface_lip(d: float) -> float:
    """
    Lip: mix(Convex, Concave, smootherstep(d)).
    Raised rim, shallow center dip. Creates a rim-highlight-friendly profile.
    """
    t = smootherstep(0.0, 1.0, d)
    return (1.0 - t) * surface_squircle(d) + t * surface_concave(d)

SURFACES = {
    "squircle": surface_squircle,
    "circle": surface_circle,
    "concave": surface_concave,
    "lip": surface_lip,
}

def compute_snell_displacement(d: float, surface_fn, n2: float = 1.5) -> float:
    """
    Compute lateral displacement of a ray entering a glass surface at normalized
    distance d from the outer edge (d=0 = outer edge, d=1 = inner flat surface start).

    Uses Snell-Descartes Law: n1*sin(θ1) = n2*sin(θ2), with n1=1 (air).

    Returns displacement magnitude (in normalized units, to be scaled by bezel_px).
    Returns 0 if total internal reflection would occur.
    """
    n1 = 1.0
    delta = 1e-4
    h0 = surface_fn(max(d - delta, 0.0))
    h1 = surface_fn(min(d + delta, 1.0))
    derivative = (h1 - h0) / (2.0 * delta)

    # Normal to surface at this point: perpendicular to tangent
    # tangent = (delta_d, derivative); normal = (-derivative, 1) (rotated -90°)
    normal_x = -derivative
    normal_y = 1.0
    normal_len = math.sqrt(normal_x ** 2 + normal_y ** 2)
    if normal_len < 1e-9:
        return 0.0
    normal_x /= normal_len
    normal_y /= normal_len

    # Incident ray direction (straight down): (0, 1)
    incident_x, incident_y = 0.0, 1.0

    # Angle of incidence = angle between incident ray and surface normal
    cos_theta1 = incident_x * normal_x + incident_y * normal_y
    cos_theta1 = clamp(cos_theta1, -1.0, 1.0)
    sin_theta1 = math.sqrt(max(1.0 - cos_theta1 ** 2, 0.0))

    # Snell's Law
    sin_theta2 = sin_theta1 * n1 / n2
    if abs(sin_theta2) > 1.0:
        return 0.0  # Total internal reflection
    cos_theta2 = math.sqrt(max(1.0 - sin_theta2 ** 2, 0.0))

    # Refracted ray direction using vector form of Snell's Law
    # r = (n1/n2)*i + (n1/n2*cos_theta1 - cos_theta2)*n
    ratio = n1 / n2
    refracted_x = ratio * incident_x + (ratio * cos_theta1 - cos_theta2) * normal_x
    # We only care about the lateral (X) displacement
    return abs(refracted_x)

def generate_snell_map(width: int, height: int, radius: int, surface_name: str, n2: float) -> list:
    """
    Generate displacement map using Snell's Law physics.
    Pre-computes 127 displacement magnitudes along one radius,
    then applies them radially around the bezel.
    """
    surface_fn = SURFACES[surface_name]
    bezel = float(radius)

    # Pre-compute displacement magnitudes for 127 sample points
    magnitudes = []
    for i in range(NUM_SAMPLES):
        d = (i + 1) / NUM_SAMPLES  # d in (0, 1]
        mag = compute_snell_displacement(d, surface_fn, n2)
        magnitudes.append(mag)

    max_mag = max(magnitudes) if magnitudes else 1.0
    if max_mag < 1e-9:
        max_mag = 1.0

    # Normalize
    norm_magnitudes = [m / max_mag for m in magnitudes]

    cx, cy = width / 2.0, height / 2.0

    pixels = []
    for py in range(height):
        for px in range(width):
            dist = rounded_rect_sdf(float(px) + 0.5, float(py) + 0.5, float(width), float(height), float(radius))

            if dist > 0 or dist < -bezel:
                pixels.append((128, 128, 0))
                continue

            # Map dist to bezel sample index: dist=0 → index 126 (border), dist=-bezel → index 0
            t = clamp((-dist) / bezel, 0.0, 1.0)  # 0 at border, 1 deep inside
            idx = int((1.0 - t) * (NUM_SAMPLES - 1))
            idx = clamp(idx, 0, NUM_SAMPLES - 1)
            mag = norm_magnitudes[idx]

            # Direction: inward toward center
            dx_raw = cx - (px + 0.5)
            dy_raw = cy - (py + 0.5)
            length = math.sqrt(dx_raw ** 2 + dy_raw ** 2)
            if length < 1e-9:
                pixels.append((128, 128, 0))
                continue
            nx = dx_raw / length
            ny = dy_raw / length

            r_val = int(128 + mag * nx * 127)
            g_val = int(128 + mag * ny * 127)
            pixels.append((r_val, g_val, 0))

    return pixels


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate a Liquid Glass displacement map PNG.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--width",   type=int,   default=300,       help="Width in pixels (default: 300)")
    parser.add_argument("--height",  type=int,   default=56,        help="Height in pixels (default: 56)")
    parser.add_argument("--radius",  type=int,   default=28,        help="Border radius in pixels (default: 28)")
    parser.add_argument("--bezel",   type=int,   default=None,      help="Bezel thickness px (default: same as radius)")
    parser.add_argument("--mode",    choices=["sdf", "snell"], default="sdf", help="Generation mode (default: sdf)")
    parser.add_argument("--surface", choices=list(SURFACES.keys()), default="squircle",
                        help="Surface profile for snell mode (default: squircle)")
    parser.add_argument("--n2",      type=float, default=1.5,       help="Refractive index for snell mode (default: 1.5)")
    parser.add_argument("--output",  default="displacement-map.png", help="Output PNG file path")
    parser.add_argument("--datauri", action="store_true",           help="Print base64 data URI to stdout")
    args = parser.parse_args()

    bezel = args.bezel if args.bezel is not None else args.radius

    print(f"Generating {args.width}x{args.height} displacement map (mode={args.mode}, radius={args.radius}, bezel={bezel})...")

    if args.mode == "sdf":
        pixels = generate_sdf_map(args.width, args.height, args.radius, bezel)
    else:
        pixels = generate_snell_map(args.width, args.height, args.radius, args.surface, args.n2)

    png_bytes = write_png(args.width, args.height, pixels)

    with open(args.output, "wb") as f:
        f.write(png_bytes)
    print(f"Saved: {args.output} ({len(png_bytes)} bytes)")

    if args.datauri:
        b64 = base64.b64encode(png_bytes).decode("ascii")
        data_uri = f"data:image/png;base64,{b64}"
        print("\n--- DATA URI (copy into feImage href) ---")
        print(data_uri)
        print(f"\nUse with: <feDisplacementMap scale=\"{bezel}\" xChannelSelector=\"R\" yChannelSelector=\"G\"/>")


if __name__ == "__main__":
    main()
