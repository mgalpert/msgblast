import React from 'react';
import {AbsoluteFill, Audio, Img, interpolate, Sequence, Series, staticFile, useCurrentFrame, useVideoConfig, Easing} from 'remotion';
import {AgentIcon, AppIcon, C, Check, FONT, Headline, MacWindow, Phone, Reveal, Screenshot, Stage, Sub, TEXT_FONT, Toggle, useSpring, WordReveal} from './ui';

/**
 * 30 s vertical cut (1080 × 1920) timed to the ElevenLabs voice over.
 * VO starts at VO_START; scene lengths follow its word timings (see README).
 */
export const FPS = 30;
export const VO_START = 3; // frames (0.1 s): the voice starts right away
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

const Punch: React.FC<{children: React.ReactNode; fadeOut?: number; noIn?: boolean}> = ({children, fadeOut = 5, noIn}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const inP = noIn ? 1 : interpolate(frame, [0, 6], [0, 1], {...clamp, easing: Easing.out(Easing.cubic)});
  const outO = fadeOut ? interpolate(frame, [durationInFrames - fadeOut, durationInFrames], [1, 0], clamp) : 1;
  return <AbsoluteFill style={{opacity: Math.min(inP, outO), transform: `scale(${1.04 - 0.04 * inP})`}}>{children}</AbsoluteFill>;
};


/* Hook: frame 0 is already the full 0.11 feature list, so it stops the scroll. */
const IconTile: React.FC<{children: React.ReactNode; bg?: string}> = ({children, bg = '#fff'}) => (
  <div
    style={{
      width: 112,
      height: 112,
      borderRadius: 28,
      background: bg,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      overflow: 'hidden',
      boxShadow: '0 8px 20px rgba(0,0,0,0.10), 0 0 0 1px rgba(0,0,0,0.05)',
      flexShrink: 0,
    }}
  >
    {children}
  </div>
);

const HOOK_ROWS: {title: string; sub: string; icon: React.ReactNode}[] = [
  {
    title: 'msgblast on iPhone',
    sub: 'Every reply, every agent, anywhere',
    icon: (
      <IconTile bg="#1d1d1f">
        <div style={{width: 46, height: 80, borderRadius: 12, border: '5px solid #fff'}} />
      </IconTile>
    ),
  },
  {
    title: 'Outside agents control it with MCP',
    sub: 'Claude Code, Codex, Cursor and more',
    icon: (
      <IconTile bg="linear-gradient(135deg,#0a84ff,#5e5ce6 50%,#28cd41)">
        <div style={{fontFamily: FONT, fontWeight: 800, fontSize: 40, color: '#fff', letterSpacing: -1}}>MCP</div>
      </IconTile>
    ),
  },
  {
    title: 'Grok Bot over Tailscale',
    sub: 'Message any agent, on any device',
    icon: (
      <IconTile>
        <Img src={staticFile('img/grokbot.png')} style={{width: 124, height: 124}} />
      </IconTile>
    ),
  },
  {
    title: 'Shop Amazon with Alexa',
    sub: 'Product picks with photos and prices',
    icon: (
      <IconTile>
        <Img src={staticFile('img/alexa.png')} style={{width: 112, height: 112, objectFit: 'cover'}} />
      </IconTile>
    ),
  },
  {
    title: 'Pair from the sidebar',
    sub: 'One scan, encrypted',
    icon: (
      <IconTile>
        <AppIcon size={112} style={{filter: 'none'}} />
      </IconTile>
    ),
  },
  {
    title: 'Settings, redesigned',
    sub: 'Everything in one sidebar',
    icon: (
      <IconTile bg="#8e8e93">
        <svg width="64" height="64" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="3.2" fill="none" stroke="#fff" strokeWidth="2" />
          {Array.from({length: 8}).map((_, i) => (
            <rect key={i} x="11" y="1.5" width="2" height="4" rx="1" fill="#fff" transform={`rotate(${i * 45} 12 12)`} />
          ))}
          <circle cx="12" cy="12" r="7" fill="none" stroke="#fff" strokeWidth="2" />
        </svg>
      </IconTile>
    ),
  },
  {
    title: 'ChatGPT and Dots fixed',
    sub: 'Sends stay in the background',
    icon: (
      <IconTile>
        <Img src={staticFile('img/chatgpt.jpg')} style={{width: 112, height: 112, objectFit: 'cover'}} />
      </IconTile>
    ),
  },
];

const VHook: React.FC = () => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const zoom = interpolate(frame, [0, durationInFrames], [1, 1.05], clamp);
  const active = Math.floor(frame / 9) % HOOK_ROWS.length;
  return (
    <Stage glow="rgba(60,220,80,0.14)">
      <AbsoluteFill style={{transform: `scale(${zoom})`}}>
        <div style={{position: 'absolute', top: 150, left: 80, right: 80, display: 'flex', alignItems: 'center', gap: 30}}>
          <AppIcon size={130} />
          <div>
            <div style={{fontFamily: FONT, fontWeight: 800, fontSize: 96, letterSpacing: -3, color: C.ink, lineHeight: 1}}>
              msgblast <span style={{color: C.green}}>0.11</span>
            </div>
            <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 40, color: C.sub, marginTop: 8}}>Everything new.</div>
          </div>
        </div>
        <div style={{position: 'absolute', top: 400, left: 64, right: 64, display: 'flex', flexDirection: 'column', gap: 22}}>
          {HOOK_ROWS.map((r, i) => {
            const on = i === active;
            return (
              <div
                key={r.title}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 30,
                  padding: '22px 28px',
                  borderRadius: 36,
                  background: on ? '#fff' : 'rgba(255,255,255,0.55)',
                  boxShadow: on ? '0 20px 50px rgba(0,0,0,0.12), 0 0 0 3px ' + C.blue : '0 0 0 1px rgba(0,0,0,0.04)',
                  transform: `scale(${on ? 1.03 : 1})`,
                }}
              >
                {r.icon}
                <div>
                  <div style={{fontFamily: FONT, fontWeight: 700, fontSize: 48, letterSpacing: -1, color: C.ink, lineHeight: 1.1}}>{r.title}</div>
                  <div style={{fontFamily: TEXT_FONT, fontSize: 32, color: C.sub, marginTop: 6}}>{r.sub}</div>
                </div>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Stage>
  );
};

/* Intro: icon and version */
const VIntro: React.FC = () => {
  const s = useSpring(0, 12, 30);
  return (
    <Stage glow="rgba(60,220,80,0.16)">
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{transform: `scale(${0.5 + 0.5 * s}) rotate(${(1 - s) * -12}deg)`, opacity: s}}>
          <AppIcon size={340} />
        </div>
        <div style={{height: 70}} />
        <Reveal delay={6}>
          <Headline size={150} style={{textAlign: 'center'}}>
            msgblast <span style={{color: C.faint, fontWeight: 600}}>0.11</span>
          </Headline>
        </Reveal>
      </AbsoluteFill>
    </Stage>
  );
};

/* iPhone */
const VIPhone: React.FC = () => {
  const frame = useCurrentFrame();
  const ph = useSpring(4, 16, 30);
  const push = interpolate(frame, [70, 84], [0, 1], {...clamp, easing: Easing.inOut(Easing.cubic)});
  const drift = interpolate(frame, [0, 162], [0, -40]);
  return (
    <Stage glow="rgba(10,132,255,0.08)">
      <div style={{position: 'absolute', top: 170, width: '100%'}}>
        <WordReveal text="Now on iPhone." size={140} stagger={4} />
        <Reveal delay={40}>
          <Sub size={48} style={{textAlign: 'center', marginTop: 26}}>
            Read every reply. Message every agent.
          </Sub>
        </Reveal>
      </div>
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: 560,
          transform: `translateX(-50%) translateY(${(1 - ph) * 900 + drift}px)`,
        }}
      >
        <Phone height={1260}>
          <div style={{position: 'absolute', inset: 0, transform: `translateX(${-30 * push}%)`}}>
            <Screenshot src="phone-inbox.png" />
          </div>
          <div style={{position: 'absolute', inset: 0, transform: `translateX(${100 - 100 * push}%)`, boxShadow: '-10px 0 30px rgba(0,0,0,0.12)'}}>
            <Screenshot src="phone-conversation.png" />
          </div>
        </Phone>
      </div>
    </Stage>
  );
};

/* MCP in big letters, then who can connect, the approval and the Stop banner */
const Pill: React.FC<{at: number; children: React.ReactNode}> = ({at, children}) => {
  const s = useSpring(at, 12, 20);
  return (
    <div
      style={{
        transform: `scale(${0.6 + 0.4 * s})`,
        opacity: s,
        fontFamily: TEXT_FONT,
        fontWeight: 600,
        fontSize: 44,
        color: C.ink,
        background: '#fff',
        borderRadius: 999,
        padding: '22px 40px',
        boxShadow: '0 10px 30px rgba(0,0,0,0.08), 0 0 0 1px rgba(0,0,0,0.05)',
      }}
    >
      {children}
    </div>
  );
};

const Spinner: React.FC<{size: number}> = ({size}) => {
  const frame = useCurrentFrame();
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{transform: `rotate(${frame * 12}deg)`}}>
      {Array.from({length: 8}).map((_, i) => (
        <rect key={i} x="11" y="2" width="2" height="6" rx="1" fill="#6e6e73" opacity={0.2 + (i / 8) * 0.8} transform={`rotate(${i * 45} 12 12)`} />
      ))}
    </svg>
  );
};

const VMCP: React.FC = () => {
  const lead = useSpring(0, 14, 20);
  const slam = useSpring(118, 9, 16); // lands on the spoken "MCP"
  const banner = useSpring(136, 14, 20);
  return (
    <Stage glow="rgba(94,92,230,0.07)">
      <div style={{position: 'absolute', top: 300, left: 70, right: 70, textAlign: 'center', opacity: lead, transform: `translateY(${(1 - lead) * 40}px)`}}>
        <Headline size={92}>
          Have outside agents
          <br />
          control msgblast with
        </Headline>
      </div>
      <div
        style={{
          position: 'absolute',
          width: '100%',
          top: 580,
          textAlign: 'center',
          transform: `scale(${1.25 - 0.25 * slam})`,
          opacity: slam,
        }}
      >
        <div
          style={{
            display: 'inline-block',
            fontFamily: FONT,
            fontWeight: 800,
            fontSize: 420,
            letterSpacing: -14,
            lineHeight: 1,
            padding: '0 30px',
            background: 'linear-gradient(135deg,#0a84ff 0%,#5e5ce6 45%,#28cd41 100%)',
            WebkitBackgroundClip: 'text',
            backgroundClip: 'text',
            color: 'transparent',
          }}
        >
          MCP
        </div>
      </div>
      <div style={{position: 'absolute', top: 1110, width: '100%', display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 22, padding: '0 60px'}}>
        <Pill at={36}>Claude Code</Pill>
        <Pill at={54}>Codex</Pill>
        <Pill at={68}>Cursor</Pill>
        <Pill at={82}>And more</Pill>
      </div>
      <div
        style={{
          position: 'absolute',
          left: 60,
          right: 60,
          top: 1480,
          borderRadius: 30,
          background: '#fff',
          boxShadow: '0 20px 60px rgba(0,0,0,0.12), 0 0 0 1px rgba(0,0,0,0.05)',
          padding: '30px 36px',
          display: 'flex',
          alignItems: 'center',
          gap: 22,
          fontFamily: TEXT_FONT,
          opacity: banner,
          transform: `translateY(${(1 - banner) * 80}px)`,
        }}
      >
        <Spinner size={44} />
        <div style={{flex: 1, fontSize: 34, color: C.ink, lineHeight: 1.25}}>
          <b>Claude Code</b> started a blast · 3 agents
        </div>
        <div style={{color: C.blue, fontWeight: 700, fontSize: 34}}>Stop</div>
      </div>
    </Stage>
  );
};

/* Grok Bot + Tailscale + msgblast = Message Any Agent */
const TailscaleMark: React.FC<{size: number}> = ({size}) => {
  // 3 × 3 dots: middle row and bottom middle dark, the rest light (Tailscale's mark).
  const on = [0, 0, 0, 1, 1, 1, 0, 1, 0];
  const cell = size / 3;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      {on.map((o, i) => (
        <circle key={i} cx={cell * (i % 3) + cell / 2} cy={cell * Math.floor(i / 3) + cell / 2} r={cell * 0.36} fill={o ? '#1f1f1f' : 'rgba(31,31,31,0.2)'} />
      ))}
    </svg>
  );
};

const Tile: React.FC<{at: number; label: string; children: React.ReactNode}> = ({at, label, children}) => {
  const s = useSpring(at, 11, 22);
  return (
    <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 22, opacity: s, transform: `translateY(${(1 - s) * 60}px) scale(${0.5 + 0.5 * s})`}}>
      {children}
      <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 40, color: C.ink, letterSpacing: -0.5}}>{label}</div>
    </div>
  );
};

const Op: React.FC<{at: number; children: React.ReactNode}> = ({at, children}) => {
  const s = useSpring(at, 14, 16);
  return (
    <div style={{fontFamily: FONT, fontWeight: 300, fontSize: 90, color: C.faint, opacity: s, transform: `scale(${s})`, marginTop: -70}}>{children}</div>
  );
};

const VEquation: React.FC = () => {
  const frame = useCurrentFrame();
  const res = useSpring(96, 13, 26);
  const T = 220;
  const glow = interpolate(frame, [96, 132], [0, 1], clamp);
  return (
    <Stage glow={`rgba(10,132,255,${0.08 * glow})`}>
      <div style={{position: 'absolute', top: 470, width: '100%', display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 26}}>
        <Tile at={2} label="Grok Bot">
          <Img src={staticFile('img/grokbot.png')} style={{width: T, height: T, filter: 'drop-shadow(0 14px 24px rgba(0,0,0,0.18))'}} />
        </Tile>
        <Op at={26}>+</Op>
        <Tile at={30} label="Tailscale">
          <div
            style={{
              width: T * 0.86,
              height: T * 0.86,
              margin: T * 0.07,
              borderRadius: T * 0.2,
              background: '#fff',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              boxShadow: '0 14px 30px rgba(0,0,0,0.14), 0 0 0 1px rgba(0,0,0,0.05)',
            }}
          >
            <TailscaleMark size={T * 0.5} />
          </div>
        </Tile>
        <Op at={54}>+</Op>
        <Tile at={58} label="msgblast">
          <AppIcon size={T} />
        </Tile>
      </div>
      <div style={{position: 'absolute', top: 960, width: '100%', textAlign: 'center'}}>
        <div style={{fontFamily: FONT, fontWeight: 300, fontSize: 110, color: C.faint, opacity: res, transform: `scale(${res})`}}>=</div>
        <div style={{opacity: res, transform: `translateY(${(1 - res) * 60}px)`, filter: `blur(${(1 - res) * 10}px)`}}>
          <Headline size={160} style={{textAlign: 'center', marginTop: 20}}>
            Message
            <br />
            Any Agent.
          </Headline>
        </div>
      </div>
    </Stage>
  );
};

/* Quick montage: Alexa, Settings, and more */
const Bottle: React.FC<{hue: number; cap: string}> = ({hue, cap}) => (
  <svg width="100%" height="100%" viewBox="0 0 200 140">
    <rect width="200" height="140" fill={`hsl(${hue},40%,95%)`} />
    <rect x="82" y="16" width="36" height="16" rx="5" fill={cap} />
    <rect x="70" y="30" width="60" height="98" rx="18" fill={`hsl(${hue},55%,62%)`} />
    <rect x="80" y="44" width="10" height="70" rx="5" fill="rgba(255,255,255,0.45)" />
  </svg>
);

const VAlexa: React.FC = () => {
  const frame = useCurrentFrame();
  const ph = useSpring(0, 14, 16);
  const scroll = interpolate(frame, [6, 100], [0, -300], clamp);
  const products = [
    {name: '32 oz Wide Mouth Bottle', price: '$16.25 · 4.8★', hue: 200, cap: '#1d1d1f'},
    {name: 'Insulated Steel Bottle', price: '$29.95 · 4.7★', hue: 150, cap: '#8e8e93'},
    {name: 'Everyday Straw Bottle', price: '$19.99 · 4.6★', hue: 20, cap: '#fff'},
  ];
  return (
    <Stage glow="rgba(0,168,225,0.08)">
      <div style={{position: 'absolute', top: 170, width: '100%', textAlign: 'center'}}>
        <Headline size={104}>
          Shop Amazon with
          <br />
          Alexa Shopping Agent.
        </Headline>
      </div>
      <div style={{position: 'absolute', left: '50%', top: 560, transform: `translateX(-50%) translateY(${(1 - ph) * 500}px)`}}>
        <Phone height={1300}>
          <div style={{position: 'absolute', inset: 0, background: '#fff', fontFamily: TEXT_FONT}}>
            <div style={{position: 'absolute', top: 0, left: 0, right: 0, height: 260, background: 'rgba(255,255,255,0.97)', zIndex: 2, textAlign: 'center', paddingTop: 90}}>
              <Img src={staticFile('img/alexa.png')} style={{width: 92, height: 92, borderRadius: 99, boxShadow: '0 2px 8px rgba(0,0,0,0.1)'}} />
              <div style={{marginTop: 8, fontSize: 22, color: '#000'}}>Alexa Shopping Web ›</div>
            </div>
            <div style={{position: 'absolute', top: 270, left: 0, right: 0, transform: `translateY(${scroll}px)`}}>
              {products.map((p) => (
                <div key={p.name} style={{width: '80%', marginLeft: 20, marginTop: 20}}>
                  <div style={{borderRadius: 28, overflow: 'hidden', height: 220}}>
                    <Bottle hue={p.hue} cap={p.cap} />
                  </div>
                  <div style={{background: '#e9e9eb', borderRadius: 28, padding: '16px 22px', marginTop: 8, fontSize: 25, color: '#000'}}>
                    <b>{p.name}</b>
                    <div style={{color: '#3c3c43'}}>{p.price}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </Phone>
      </div>
    </Stage>
  );
};

const SETTINGS = ['General', 'Mac apps', 'Websites', 'CLI tools', 'Webhooks', 'Outside agents', 'Remote', 'Permissions', 'Sharing', 'Updates'];
const COLORS = ['#8e8e93', '#0a84ff', '#30b0c7', '#1d1d1f', '#5e5ce6', '#28cd41', '#ff9f0a', '#ff375f', '#64d2ff', '#8e8e93'];

const VSettings: React.FC = () => {
  const frame = useCurrentFrame();
  const idx = Math.min(SETTINGS.length - 1, Math.floor(frame / 4));
  const win = useSpring(0, 14, 16);
  return (
    <Stage>
      <div style={{position: 'absolute', top: 170, width: '100%', textAlign: 'center'}}>
        <Headline size={120}>
          Settings,
          <br />
          redesigned.
        </Headline>
      </div>
      <div style={{position: 'absolute', left: 60, top: 640, opacity: win, transform: `translateY(${(1 - win) * 200}px)`}}>
        <MacWindow
          width={960}
          height={980}
          sidebarWidth={400}
          sidebar={
            <div>
              {SETTINGS.map((s, i) => (
                <div
                  key={s}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 18,
                    padding: '16px 18px',
                    borderRadius: 14,
                    marginBottom: 4,
                    background: i === idx ? C.blue : 'transparent',
                    color: i === idx ? '#fff' : C.ink,
                    fontSize: 32,
                    fontWeight: 500,
                  }}
                >
                  <div style={{width: 34, height: 34, borderRadius: 9, background: COLORS[i], boxShadow: i === idx ? '0 0 0 2px #fff' : 'none'}} />
                  {s}
                </div>
              ))}
            </div>
          }
        >
          <div style={{padding: '10px 36px'}}>
            <div style={{fontFamily: FONT, fontWeight: 700, fontSize: 44, color: C.ink}}>{SETTINGS[idx]}</div>
            <div style={{background: '#f5f5f7', borderRadius: 20, marginTop: 26, padding: '0 24px'}}>
              {[0, 1, 2].map((r) => (
                <div key={r} style={{display: 'flex', justifyContent: 'flex-end', padding: '30px 0', borderBottom: r < 2 ? `1px solid ${C.line}` : 'none'}}>
                  <Toggle on={r === 1 ? 0 : 1} />
                </div>
              ))}
            </div>
          </div>
        </MacWindow>
      </div>
    </Stage>
  );
};

const MORE = [
  'ChatGPT and Dots work again',
  'Sends stay in the background',
  'Pair from the sidebar',
  'Open in Messages finds the chat',
  'First conversation on iPhone just works',
];

const VMore: React.FC = () => (
  <Stage>
    <div style={{position: 'absolute', top: 260, width: '100%'}}>
      <WordReveal text="And a lot more." size={130} stagger={3} />
    </div>
    <div style={{position: 'absolute', top: 700, left: 110, right: 80, display: 'flex', flexDirection: 'column', gap: 50}}>
      {MORE.map((t, i) => (
        <Reveal key={t} delay={4 + i * 4} rise={30}>
          <div style={{display: 'flex', alignItems: 'center', gap: 30}}>
            <Check size={64} p={1} />
            <div style={{fontFamily: FONT, fontSize: 48, fontWeight: 600, letterSpacing: -0.8, color: C.ink}}>{t}</div>
          </div>
        </Reveal>
      ))}
    </div>
  </Stage>
);

/* Outro: "Available now for Mac and iPhone" whooshes in */
const Whoosh: React.FC<{at: number; from: number; children: React.ReactNode}> = ({at, from, children}) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [at, at + 9], [0, 1], {...clamp, easing: Easing.out(Easing.exp)});
  const settle = interpolate(frame, [at + 9, at + 18], [1, 0], clamp);
  const x = (1 - p) * from;
  const v = Math.abs(from) * (1 - p);
  return (
    <div
      style={{
        opacity: p > 0 ? 1 : 0,
        transform: `translateX(${x}px) skewX(${(-Math.sign(from) * v) / 90}deg) scaleX(${1 + v / 4000 + settle * 0.02})`,
        filter: `blur(${Math.min(18, v / 60)}px)`,
      }}
    >
      {children}
    </div>
  );
};

const VOutro: React.FC = () => {
  const frame = useCurrentFrame();
  const s = useSpring(0, 12, 26);
  const badge = useSpring(48, 9, 20);
  const shine = interpolate(frame, [44, 74], [-120, 220], clamp);
  return (
    <Stage glow="rgba(60,220,80,0.14)">
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', transform: `scale(${interpolate(frame, [40, 141], [1, 1.06], clamp)})`}}>
        <div style={{transform: `scale(${0.7 + 0.3 * s})`, opacity: s, position: 'relative'}}>
          <AppIcon size={320} />
          <div
            style={{
              position: 'absolute',
              top: -24,
              right: -60,
              transform: `scale(${badge}) rotate(${(1 - badge) * 30 + 8}deg)`,
              background: C.blue,
              color: '#fff',
              fontFamily: FONT,
              fontWeight: 700,
              fontSize: 40,
              padding: '12px 26px',
              borderRadius: 999,
              boxShadow: '0 10px 30px rgba(10,132,255,0.4)',
            }}
          >
            New
          </div>
        </div>
        <div style={{height: 60}} />
        <Reveal delay={2}>
          <Headline size={140} style={{textAlign: 'center'}}>
            msgblast <span style={{color: C.faint, fontWeight: 600}}>0.11</span>
          </Headline>
        </Reveal>
        <div style={{height: 60}} />
        <Whoosh at={34} from={1300}>
          <div style={{position: 'relative', overflow: 'hidden'}}>
            <Headline size={96} style={{textAlign: 'center'}}>
              Available now
            </Headline>
            <div
              style={{
                position: 'absolute',
                top: 0,
                bottom: 0,
                left: `${shine}%`,
                width: '35%',
                background: 'linear-gradient(100deg, transparent, rgba(255,255,255,0.85), transparent)',
              }}
            />
          </div>
        </Whoosh>
        <Whoosh at={40} from={-1300}>
          <Headline size={96} color={C.blue} style={{textAlign: 'center', marginTop: 8}}>
            for Mac and iPhone.
          </Headline>
        </Whoosh>
        <div style={{height: 70}} />
        <Reveal delay={58} rise={30}>
          <div
            style={{
              fontFamily: FONT,
              fontWeight: 700,
              fontSize: 64,
              letterSpacing: -1,
              color: '#fff',
              background: C.ink,
              borderRadius: 999,
              padding: '26px 64px',
              boxShadow: '0 20px 50px rgba(0,0,0,0.25)',
            }}
          >
            msgblast.app
          </div>
        </Reveal>
      </AbsoluteFill>
    </Stage>
  );
};

/* Timeline. Scene lengths come from each voice's word timings (ElevenLabs transcript), VO starts at 0.1 s. */
type Voice = 'female' | 'male';
// Script v3 (msg, 2026-11-14 20:15Z). Cuts land on sentence starts: "Now on iPhone", "Local coding agents",
// "Connecting your Grok Bot", "That includes", "We have lots more", "like a redesigned Settings", "Message Blast. Download now".
export const VERTICAL_FRAMES = 960; // 32 s: the script is ~30 s of speech, plus a hold on msgblast.app
const FRAMES: Record<Voice, number[]> = {
  // hook, iphone, mcp, grok-tailscale, alexa, more, settings, outro
  female: [101, 130, 162, 184, 121, 47, 56, 159],
  male: [99, 130, 163, 194, 127, 46, 55, 146],
};
const VO_FILE: Record<Voice, string> = {female: 'audio/vo.wav', male: 'audio/vo-male.wav'};
const VO_SECONDS: Record<Voice, number> = {female: 29.92, male: 30.64};
const ELEMENTS = [<VHook />, <VIPhone />, <VMCP />, <VEquation />, <VAlexa />, <VMore />, <VSettings />, <VOutro />];
const IDS = ['hook', 'iphone', 'mcp', 'grok-tailscale', 'alexa', 'more', 'settings', 'outro'];

/** Music sits back while the voice speaks and comes up around it. */
const musicVolume = (voice: Voice) => (f: number) => {
  const voFrom = VO_START;
  const voTo = VO_START + Math.round(VO_SECONDS[voice] * FPS);
  const ducked = 0.13;
  const open = 0.45;
  return interpolate(f, [voFrom - 6, voFrom, voTo, voTo + 15], [open, ducked, ducked, open], clamp);
};

export const Vertical: React.FC<{withAudio?: boolean; voice?: Voice}> = ({withAudio = true, voice = 'female'}) => (
  <AbsoluteFill style={{background: C.bg}}>
    <Series>
      {FRAMES[voice].map((frames, i) => (
        <Series.Sequence key={IDS[i]} durationInFrames={frames} name={IDS[i]}>
          <Punch noIn={i === 0} fadeOut={i === IDS.length - 1 ? 18 : 4}>{ELEMENTS[i]}</Punch>
        </Series.Sequence>
      ))}
    </Series>
    {withAudio ? (
      <>
        <Audio src={staticFile('audio/music.wav')} volume={musicVolume(voice)} />
        <Sequence from={VO_START}>
          <Audio src={staticFile(VO_FILE[voice])} volume={1} />
        </Sequence>
        <Sequence from={VERTICAL_FRAMES - FRAMES[voice][7] + 34 - 22}>
          <Audio src={staticFile('audio/whoosh.mp3')} volume={0.7} />
        </Sequence>
      </>
    ) : null}
  </AbsoluteFill>
);
