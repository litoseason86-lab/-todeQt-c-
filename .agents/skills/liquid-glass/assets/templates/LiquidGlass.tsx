/**
 * LiquidGlass — React/TypeScript Component
 * ==========================================
 * A reusable Liquid Glass wrapper component that applies Apple's iOS 26/macOS 26
 * refraction effect to any children content.
 *
 * USAGE:
 *   <LiquidGlass width={300} height={56} radius={28}>
 *     <span>Get Started</span>
 *   </LiquidGlass>
 *
 * BROWSER SUPPORT:
 *   Full effect (refraction + specular): Chrome/Chromium only
 *   Fallback (frosted blur only): All modern browsers
 *
 * DEPENDENCIES: React 18+ (uses useId). No other dependencies.
 *
 * CUSTOMIZATION:
 *   All visual parameters are props. The displacement map is an inline SVG
 *   gradient data URI — no external assets needed.
 *   For custom/physics-accurate maps, generate with generate-displacement-map.py
 *   and pass the resulting data URI as the `displacementMapHref` prop.
 */

"use client"; // Next.js App Router compatibility

import React, { useId, useMemo } from "react";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface LiquidGlassProps {
  /** Width of the glass element in pixels */
  width: number;
  /** Height of the glass element in pixels */
  height: number;
  /** Border radius in pixels. Set to height/2 for a pill shape. */
  radius?: number;
  /**
   * Displacement scale intensity. Negative = magnifying (Apple-style inward lensing).
   * Positive = fish-eye (content shrinks toward center).
   * Try -20 (subtle) to -60 (dramatic). Default: -35
   */
  scale?: number;
  /** Backdrop blur radius in pixels. Default: 12 */
  blur?: number;
  /**
   * Glass tint color (CSS color string).
   * Default: 'rgba(255,255,255,0.18)' (light frosted glass)
   * For dark glass: 'rgba(0,0,0,0.2)'
   */
  tint?: string;
  /** Whether to apply chromatic aberration (3 feDisplacementMap passes). More GPU-intensive. Default: false */
  chromaticAberration?: boolean;
  /** Custom displacement map href (data URI or URL). If not provided, uses inline SVG gradient map. */
  displacementMapHref?: string;
  /** Additional CSS class names for the container */
  className?: string;
  /** Additional inline styles for the container */
  style?: React.CSSProperties;
  children?: React.ReactNode;
}

// ---------------------------------------------------------------------------
// Displacement map builder
// ---------------------------------------------------------------------------

/**
 * Builds an inline SVG gradient displacement map data URI.
 * Uses two linear gradients (X and Y) + a blurred neutral gray mask
 * to create edge-only refraction (center stays clean, edges warp).
 */
function buildDisplacementMapUri(width: number, height: number, radius: number): string {
  const blurStdDev = Math.max(5, Math.round(radius * 0.35));
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='${width}' height='${height}'>
  <defs>
    <linearGradient id='gx' x1='0%' y1='0%' x2='100%' y2='0%'>
      <stop offset='0%' stop-color='#000'/>
      <stop offset='100%' stop-color='#f00'/>
    </linearGradient>
    <linearGradient id='gy' x1='0%' y1='0%' x2='0%' y2='100%'>
      <stop offset='0%' stop-color='#000'/>
      <stop offset='100%' stop-color='#0f0'/>
    </linearGradient>
    <filter id='b'><feGaussianBlur stdDeviation='${blurStdDev}'/></filter>
  </defs>
  <rect width='${width}' height='${height}' rx='${radius}' fill='url(#gx)' style='mix-blend-mode:screen'/>
  <rect width='${width}' height='${height}' rx='${radius}' fill='url(#gy)' style='mix-blend-mode:screen'/>
  <rect width='${width}' height='${height}' rx='${radius}' fill='#808080' filter='url(#b)'/>
</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

// ---------------------------------------------------------------------------
// Browser detection
// ---------------------------------------------------------------------------

/**
 * Detects whether the current browser supports SVG filters in backdrop-filter.
 * Chrome/Chromium: true. Safari/Firefox: false (they support backdrop-filter
 * with standard functions like blur() but NOT with url() references).
 */
function supportsBackdropSvgFilter(): boolean {
  if (typeof window === "undefined") return false; // SSR
  // Check for Chrome/Chromium: navigator.userAgent contains "Chrome" but not "Edg" for Edge
  const ua = navigator.userAgent;
  return /Chrome\//.test(ua) && !/Edg\//.test(ua) || /Edg\//.test(ua);
}

// ---------------------------------------------------------------------------
// SVG Filter component
// ---------------------------------------------------------------------------

interface FilterDefsProps {
  filterId: string;
  width: number;
  height: number;
  radius: number;
  scale: number;
  displacementMapHref: string;
  chromaticAberration: boolean;
}

function FilterDefs({
  filterId,
  width,
  height,
  radius,
  scale,
  displacementMapHref,
  chromaticAberration,
}: FilterDefsProps) {
  const _ = radius; // used in map href

  if (!chromaticAberration) {
    // Simple single-pass displacement
    return (
      <svg
        xmlns="http://www.w3.org/2000/svg"
        width={0}
        height={0}
        style={{ position: "absolute", overflow: "hidden" }}
        aria-hidden="true"
      >
        <defs>
          <filter
            id={filterId}
            colorInterpolationFilters="sRGB"
            x="0%" y="0%" width="100%" height="100%"
          >
            <feImage
              result="dispMap"
              x={0} y={0}
              width={width} height={height}
              preserveAspectRatio="none"
              href={displacementMapHref}
            />
            <feDisplacementMap
              in="SourceGraphic"
              in2="dispMap"
              scale={scale}
              xChannelSelector="R"
              yChannelSelector="G"
            />
          </filter>
        </defs>
      </svg>
    );
  }

  // Chromatic aberration: three passes
  const scaleR = scale;
  const scaleG = Math.round(scale * 1.07); // Green disperses more
  const scaleB = Math.round(scale * 1.035);

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={0}
      height={0}
      style={{ position: "absolute", overflow: "hidden" }}
      aria-hidden="true"
    >
      <defs>
        <filter
          id={filterId}
          colorInterpolationFilters="sRGB"
          x="0%" y="0%" width="100%" height="100%"
        >
          <feImage
            result="dispMap"
            x={0} y={0}
            width={width} height={height}
            preserveAspectRatio="none"
            href={displacementMapHref}
          />
          {/* Red channel pass */}
          <feDisplacementMap in="SourceGraphic" in2="dispMap" scale={scaleR}
            xChannelSelector="R" yChannelSelector="G" result="dispR" />
          <feColorMatrix in="dispR" type="matrix"
            values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="Ronly" />
          {/* Green channel pass */}
          <feDisplacementMap in="SourceGraphic" in2="dispMap" scale={scaleG}
            xChannelSelector="R" yChannelSelector="G" result="dispG" />
          <feColorMatrix in="dispG" type="matrix"
            values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="Gonly" />
          {/* Blue channel pass */}
          <feDisplacementMap in="SourceGraphic" in2="dispMap" scale={scaleB}
            xChannelSelector="R" yChannelSelector="G" result="dispB" />
          <feColorMatrix in="dispB" type="matrix"
            values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="Bonly" />
          {/* Merge all channels */}
          <feBlend in="Ronly" in2="Gonly" mode="screen" result="RG" />
          <feBlend in="RG" in2="Bonly" mode="screen" />
        </filter>
      </defs>
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Main LiquidGlass component
// ---------------------------------------------------------------------------

export default function LiquidGlass({
  width,
  height,
  radius = Math.round(height / 2),
  scale = -35,
  blur = 12,
  tint = "rgba(255,255,255,0.18)",
  chromaticAberration = false,
  displacementMapHref,
  className,
  style,
  children,
}: LiquidGlassProps) {
  // Unique filter ID per component instance (React 18 useId)
  const id = useId();
  const filterId = `lg-filter-${id.replace(/:/g, "")}`;

  // Build or use the displacement map data URI
  const mapHref = useMemo(
    () => displacementMapHref ?? buildDisplacementMapUri(width, height, radius),
    [displacementMapHref, width, height, radius]
  );

  const isChrome = useMemo(() => supportsBackdropSvgFilter(), []);

  // Compose the backdrop-filter value
  const backdropFilterValue = isChrome
    ? `blur(${blur}px) url(#${filterId}) brightness(1.05) saturate(1.3)`
    : `blur(${blur}px) brightness(1.05) saturate(1.2)`;

  const containerStyle: React.CSSProperties = {
    position: "relative",
    width,
    height,
    borderRadius: radius,
    overflow: "hidden",
    ...style,
  };

  return (
    <>
      {/* Hidden SVG filter definition */}
      {isChrome && (
        <FilterDefs
          filterId={filterId}
          width={width}
          height={height}
          radius={radius}
          scale={scale}
          displacementMapHref={mapHref}
          chromaticAberration={chromaticAberration}
        />
      )}

      <div className={className} style={containerStyle}>
        {/* Layer 0: Refraction filter */}
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: "inherit",
            backdropFilter: backdropFilterValue,
            WebkitBackdropFilter: backdropFilterValue,
            isolation: "isolate",
          }}
        />

        {/* Layer 1: Semi-transparent tint */}
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: "inherit",
            background: tint,
          }}
        />

        {/* Layer 2: Specular rim highlight */}
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: "inherit",
            boxShadow: [
              "inset 0  1px 0 rgba(255,255,255,0.75)",
              "inset 0 -1px 0 rgba(255,255,255,0.15)",
              "inset  1px 0 rgba(255,255,255,0.20)",
              "inset -1px 0 rgba(255,255,255,0.20)",
            ].join(", "),
          }}
        />

        {/* Layer 3: Content */}
        <div style={{ position: "relative", zIndex: 10, height: "100%" }}>
          {children}
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Usage example (for reference — not rendered)
// ---------------------------------------------------------------------------

/*
// Basic button:
<LiquidGlass width={300} height={56} radius={28} style={{ cursor: "pointer" }}>
  <div style={{ display: "flex", alignItems: "center", justifyContent: "center",
                height: "100%", color: "#fff", fontWeight: 600, fontSize: 15 }}>
    Get Started
  </div>
</LiquidGlass>

// Card with chromatic aberration:
<LiquidGlass
  width={360} height={220} radius={20}
  scale={-45} blur={16}
  tint="rgba(255,255,255,0.10)"
  chromaticAberration
>
  <div style={{ padding: 28 }}>Card content</div>
</LiquidGlass>

// Dark glass variant:
<LiquidGlass
  width={320} height={60} radius={30}
  tint="rgba(0,0,0,0.25)"
  scale={-30} blur={18}
>
  Navigation
</LiquidGlass>
*/
