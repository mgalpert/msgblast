import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing} from 'remotion';

export const C = {
  bg: '#fbfbfd',
  ink: '#1d1d1f',
  sub: '#6e6e73',
  faint: '#86868b',
  line: '#e5e5ea',
  blue: '#0a84ff',
  green: '#28cd41',
  card: '#ffffff',
  dark: '#000000',
};

export const FONT =
  '"SF Pro Display", -apple-system, BlinkMacSystemFont, "Inter Display", Inter, "Helvetica Neue", sans-serif';
export const TEXT_FONT = '"SF Pro Text", -apple-system, BlinkMacSystemFont, Inter, "Helvetica Neue", sans-serif';
export const MONO = '"SF Mono", Menlo, "DejaVu Sans Mono", monospace';

const ease = Easing.bezier(0.25, 0.1, 0.25, 1);

/** 0→1 over [start, start+dur] with a smooth ease. */
export const useProgress = (start: number, dur: number) => {
  const frame = useCurrentFrame();
  return interpolate(frame, [start, start + dur], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: ease,
  });
};

export const useSpring = (delay = 0, damping = 200, durationInFrames?: number) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return spring({frame: frame - delay, fps, config: {damping}, durationInFrames});
};

/** Fade + rise entrance, and an optional fade-out before the scene ends. */
export const Reveal: React.FC<{
  delay?: number;
  out?: number;
  rise?: number;
  blur?: boolean;
  style?: React.CSSProperties;
  children: React.ReactNode;
}> = ({delay = 0, out, rise = 24, blur = true, style, children}) => {
  const frame = useCurrentFrame();
  const p = useSpring(delay, 200, 28);
  const o = out === undefined ? 1 : interpolate(frame, [out, out + 12], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <div
      style={{
        opacity: p * o,
        transform: `translateY(${(1 - p) * rise}px)`,
        filter: blur ? `blur(${(1 - p) * 8}px)` : undefined,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

export const Headline: React.FC<{children: React.ReactNode; size?: number; color?: string; style?: React.CSSProperties}> = ({
  children,
  size = 96,
  color = C.ink,
  style,
}) => (
  <div
    style={{
      fontFamily: FONT,
      fontWeight: 700,
      fontSize: size,
      letterSpacing: -size * 0.028,
      lineHeight: 1.05,
      color,
      ...style,
    }}
  >
    {children}
  </div>
);

export const Sub: React.FC<{children: React.ReactNode; size?: number; style?: React.CSSProperties}> = ({children, size = 34, style}) => (
  <div style={{fontFamily: FONT, fontWeight: 500, fontSize: size, letterSpacing: -size * 0.012, lineHeight: 1.3, color: C.sub, ...style}}>
    {children}
  </div>
);

/** Word-by-word headline, the way product films set a line. */
export const WordReveal: React.FC<{text: string; delay?: number; size?: number; stagger?: number; color?: string; style?: React.CSSProperties}> = ({
  text,
  delay = 0,
  size = 120,
  stagger = 4,
  color = C.ink,
  style,
}) => {
  const words = text.split(' ');
  return (
    <Headline size={size} color={color} style={{display: 'flex', flexWrap: 'wrap', justifyContent: 'center', columnGap: size * 0.26, ...style}}>
      {words.map((w, i) => (
        <Reveal key={i} delay={delay + i * stagger} rise={size * 0.3}>
          {w}
        </Reveal>
      ))}
    </Headline>
  );
};

export const AppIcon: React.FC<{size: number; style?: React.CSSProperties}> = ({size, style}) => (
  <Img
    src={staticFile('img/app-icon.png')}
    style={{width: size, height: size, filter: `drop-shadow(0 ${size * 0.06}px ${size * 0.12}px rgba(30,160,40,0.28))`, ...style}}
  />
);

export const AgentIcon: React.FC<{src: string; size: number; style?: React.CSSProperties}> = ({src, size, style}) => (
  <Img
    src={staticFile(`img/${src}`)}
    style={{width: size, height: size, borderRadius: size * 0.225, objectFit: 'cover', boxShadow: '0 6px 18px rgba(0,0,0,0.12)', ...style}}
  />
);

/** A plain iPhone silhouette drawn in CSS around a screen. */
export const Phone: React.FC<{height: number; children: React.ReactNode; style?: React.CSSProperties; dark?: boolean}> = ({
  height,
  children,
  style,
  dark,
}) => {
  const ratio = 1206 / 2622;
  const bezel = height * 0.018;
  const w = height * ratio + bezel * 2;
  const h = height + bezel * 2;
  const r = height * 0.115;
  return (
    <div
      style={{
        width: w,
        height: h,
        borderRadius: r,
        background: 'linear-gradient(145deg,#3a3a3c,#1c1c1e 40%,#0b0b0c)',
        padding: bezel,
        boxShadow: '0 50px 100px -20px rgba(0,0,0,0.28), 0 30px 60px -30px rgba(0,0,0,0.35), inset 0 0 0 2px #48484a',
        position: 'relative',
        ...style,
      }}
    >
      <div
        style={{
          width: '100%',
          height: '100%',
          borderRadius: r - bezel,
          overflow: 'hidden',
          position: 'relative',
          background: dark ? '#000' : '#fff',
        }}
      >
        {children}
        <div
          style={{
            position: 'absolute',
            top: height * 0.014,
            left: '50%',
            transform: 'translateX(-50%)',
            width: height * 0.135,
            height: height * 0.038,
            borderRadius: 999,
            background: '#000',
          }}
        />
      </div>
    </div>
  );
};

export const Screenshot: React.FC<{src: string; style?: React.CSSProperties}> = ({src, style}) => (
  <Img src={staticFile(`img/${src}`)} style={{position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover', ...style}} />
);

/** A clean macOS window with traffic lights. */
export const MacWindow: React.FC<{
  width: number;
  height: number;
  title?: string;
  children: React.ReactNode;
  style?: React.CSSProperties;
  sidebar?: React.ReactNode;
  sidebarWidth?: number;
}> = ({width, height, title, children, style, sidebar, sidebarWidth = 250}) => (
  <div
    style={{
      width,
      height,
      borderRadius: 18,
      background: '#fff',
      overflow: 'hidden',
      position: 'relative',
      display: 'flex',
      boxShadow: '0 40px 90px -20px rgba(0,0,0,0.25), 0 0 0 1px rgba(0,0,0,0.08)',
      fontFamily: TEXT_FONT,
      ...style,
    }}
  >
    {sidebar ? (
      <div style={{width: sidebarWidth, background: '#f2f2f4', borderRight: '1px solid #e3e3e6', padding: '54px 12px 12px', position: 'relative'}}>
        {sidebar}
      </div>
    ) : null}
    <div style={{flex: 1, position: 'relative', display: 'flex', flexDirection: 'column'}}>
      {title ? (
        <div style={{height: 52, display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 600, fontSize: 15, color: '#3c3c43'}}>
          {title}
        </div>
      ) : (
        <div style={{height: 52}} />
      )}
      <div style={{flex: 1, position: 'relative'}}>{children}</div>
    </div>
    <div style={{position: 'absolute', top: 20, left: 20, display: 'flex', gap: 8}}>
      {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
        <div key={c} style={{width: 13, height: 13, borderRadius: 99, background: c, boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.15)'}} />
      ))}
    </div>
  </div>
);

export const Toggle: React.FC<{on: number}> = ({on}) => (
  <div style={{width: 42, height: 24, borderRadius: 99, background: on > 0.5 ? C.blue : '#d1d1d6', position: 'relative', transition: 'none'}}>
    <div
      style={{
        position: 'absolute',
        top: 2,
        left: 2 + on * 18,
        width: 20,
        height: 20,
        borderRadius: 99,
        background: '#fff',
        boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
      }}
    />
  </div>
);

/** Decorative code pattern. Deliberately not a real, scannable code. */
export const PseudoQR: React.FC<{size: number; seed?: number}> = ({size, seed = 7}) => {
  const n = 25;
  const cell = size / n;
  let s = seed;
  const rnd = () => {
    s = (s * 16807) % 2147483647;
    return s / 2147483647;
  };
  const finder = (x: number, y: number) => {
    const inBox = (bx: number, by: number) => x >= bx && x < bx + 7 && y >= by && y < by + 7;
    for (const [bx, by] of [
      [0, 0],
      [n - 7, 0],
      [0, n - 7],
    ]) {
      if (inBox(bx, by)) {
        const dx = x - bx;
        const dy = y - by;
        const ring = Math.min(dx, dy, 6 - dx, 6 - dy);
        return ring === 0 || ring >= 2 ? 1 : 0;
      }
    }
    return -1;
  };
  const rects: React.ReactNode[] = [];
  for (let y = 0; y < n; y++)
    for (let x = 0; x < n; x++) {
      const f = finder(x, y);
      const on = f === -1 ? rnd() > 0.52 : f === 1;
      if (on) rects.push(<rect key={`${x}-${y}`} x={x * cell} y={y * cell} width={cell + 0.3} height={cell + 0.3} fill="#111" />);
    }
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      {rects}
    </svg>
  );
};

export const Check: React.FC<{size: number; color?: string; p?: number}> = ({size, color = C.green, p = 1}) => (
  <svg width={size} height={size} viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="11" fill={color} opacity={Math.min(1, p * 2)} />
    <path d="M7 12.5l3.2 3.2L17 9" fill="none" stroke="#fff" strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round" strokeDasharray={20} strokeDashoffset={20 * (1 - p)} />
  </svg>
);

/** Full-frame wrapper with the soft off-white stage. */
export const Stage: React.FC<{children: React.ReactNode; bg?: string; glow?: string}> = ({children, bg = C.bg, glow}) => (
  <div style={{position: 'absolute', inset: 0, background: bg, overflow: 'hidden'}}>
    {glow ? (
      <div style={{position: 'absolute', inset: 0, background: `radial-gradient(ellipse 60% 55% at 50% 40%, ${glow}, transparent 70%)`}} />
    ) : null}
    {children}
  </div>
);
