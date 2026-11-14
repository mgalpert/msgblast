import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig, Img, staticFile} from 'remotion';
import {
  AgentIcon,
  AppIcon,
  C,
  Check,
  FONT,
  Headline,
  MacWindow,
  MONO,
  Phone,
  PseudoQR,
  Reveal,
  Screenshot,
  Stage,
  Sub,
  TEXT_FONT,
  Toggle,
  useProgress,
  useSpring,
  WordReveal,
} from './ui';

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/** Cross-dissolve every scene through the stage colour. */
export const SceneFade: React.FC<{children: React.ReactNode; fadeIn?: number; fadeOut?: number}> = ({children, fadeIn = 10, fadeOut = 10}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const o = Math.min(
    fadeIn ? interpolate(frame, [0, fadeIn], [0, 1], clamp) : 1,
    fadeOut ? interpolate(frame, [durationInFrames - fadeOut, durationInFrames], [1, 0], clamp) : 1,
  );
  return <AbsoluteFill style={{opacity: o}}>{children}</AbsoluteFill>;
};

const Eyebrow: React.FC<{children: React.ReactNode; color?: string}> = ({children, color = C.green}) => (
  <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 30, color, letterSpacing: -0.2, marginBottom: 18}}>{children}</div>
);

/* 1 ─ Intro */
export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const s = useSpring(4, 14, 50);
  const glow = interpolate(frame, [0, 60], [0, 1], clamp);
  const lift = interpolate(useProgress(70, 30), [0, 1], [0, -40]);
  return (
    <Stage glow={`rgba(60,220,80,${0.16 * glow})`}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', transform: `translateY(${lift}px)`}}>
        <div style={{transform: `scale(${0.7 + 0.3 * s})`, opacity: s}}>
          <AppIcon size={260} />
        </div>
        <div style={{height: 56}} />
        <Reveal delay={30}>
          <Headline size={110} style={{textAlign: 'center'}}>
            msgblast <span style={{color: C.faint, fontWeight: 600}}>0.11</span>
          </Headline>
        </Reveal>
        <Reveal delay={52}>
          <Sub size={40} style={{marginTop: 22, textAlign: 'center'}}>
            Every agent. Now everywhere.
          </Sub>
        </Reveal>
      </AbsoluteFill>
    </Stage>
  );
};

/* 2 ─ "Now on iPhone." */
export const IPhoneTitle: React.FC = () => (
  <Stage>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <WordReveal text="Now on iPhone." size={170} stagger={6} />
    </AbsoluteFill>
  </Stage>
);

/* 3 ─ iPhone showcase: inbox, then a conversation */
export const IPhoneShowcase: React.FC = () => {
  const frame = useCurrentFrame();
  const enter = useSpring(0, 18, 45);
  const push = useProgress(118, 22);
  const tilt = interpolate(frame, [0, 270], [-10, 4]);
  return (
    <Stage glow="rgba(10,132,255,0.07)">
      <div style={{position: 'absolute', left: 150, top: 300, width: 760}}>
        <Reveal delay={10}>
          <Eyebrow color={C.blue}>msgblast for iPhone</Eyebrow>
        </Reveal>
        <Reveal delay={16}>
          <Headline size={92}>
            Every reply.
            <br />
            In your pocket.
          </Headline>
        </Reveal>
        <Reveal delay={30}>
          <Sub style={{marginTop: 34, maxWidth: 680}}>
            Read every agent's answer and send to all of them, at home or anywhere over Tailscale.
          </Sub>
        </Reveal>
        <div style={{display: 'flex', gap: 14, marginTop: 44, flexWrap: 'wrap', maxWidth: 720}}>
          {['Your Mac does the sending', 'Its own paired key', 'Keep Mac Awake'].map((t, i) => (
            <Reveal key={t} delay={140 + i * 8} rise={12}>
              <div
                style={{
                  fontFamily: TEXT_FONT,
                  fontSize: 24,
                  fontWeight: 500,
                  color: C.ink,
                  background: '#fff',
                  border: `1px solid ${C.line}`,
                  borderRadius: 999,
                  padding: '12px 22px',
                }}
              >
                {t}
              </div>
            </Reveal>
          ))}
        </div>
      </div>
      <div
        style={{
          position: 'absolute',
          left: 1180,
          top: 70,
          perspective: 2000,
          transform: `translateY(${(1 - enter) * 500}px)`,
          opacity: enter,
        }}
      >
        <div style={{transform: `rotateY(${tilt}deg) rotateX(2deg)`}}>
          <Phone height={900}>
            <div style={{position: 'absolute', inset: 0, transform: `translateX(${-30 * push}%)`, filter: `brightness(${1 - 0.1 * push})`}}>
              <Screenshot src="phone-inbox.png" />
            </div>
            <div style={{position: 'absolute', inset: 0, transform: `translateX(${100 - 100 * push}%)`, boxShadow: '-10px 0 30px rgba(0,0,0,0.12)'}}>
              <Screenshot src="phone-conversation.png" />
            </div>
          </Phone>
        </div>
      </div>
    </Stage>
  );
};

/* 4 ─ Pair from the sidebar */
const AGENTS = [
  {src: 'chatgpt.jpg', name: 'ChatGPT'},
  {src: 'claude.jpg', name: 'Claude'},
  {src: 'grok.png', name: 'Grok'},
  {src: 'hermes.png', name: 'Hermes'},
  {src: 'openclaw.png', name: 'OpenClaw'},
  {src: 'poke.png', name: 'Poke'},
];

const SidebarItem: React.FC<{label: string; active?: boolean; color?: string}> = ({label, active, color = C.blue}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '9px 12px',
      borderRadius: 9,
      background: active ? 'rgba(0,0,0,0.07)' : 'transparent',
      fontSize: 16,
      fontWeight: 600,
      color: C.ink,
    }}
  >
    <div style={{width: 18, height: 18, borderRadius: 5, background: color, opacity: 0.85}} />
    {label}
  </div>
);

export const Pairing: React.FC = () => {
  const frame = useCurrentFrame();
  const win = useSpring(0, 20, 40);
  const ph = useSpring(18, 20, 40);
  const remoteOn = interpolate(frame, [40, 48], [0, 1], clamp);
  const qr = useProgress(50, 16);
  const scan = interpolate(frame, [95, 135], [0, 1], clamp);
  const paired = useProgress(140, 14);
  const check = useProgress(146, 20);
  return (
    <Stage>
      <div style={{position: 'absolute', top: 70, width: '100%', textAlign: 'center'}}>
        <Reveal delay={4}>
          <Headline size={80}>Pair in one scan.</Headline>
        </Reveal>
        <Reveal delay={14}>
          <Sub style={{marginTop: 16}}>From the new Phone section in the Mac sidebar. Encrypted, device to device.</Sub>
        </Reveal>
      </div>
      <div style={{position: 'absolute', left: 170, top: 300, opacity: win, transform: `translateY(${(1 - win) * 60}px)`}}>
        <MacWindow
          width={1120}
          height={680}
          sidebarWidth={290}
          sidebar={
            <div style={{display: 'flex', flexDirection: 'column', height: '100%'}}>
              <SidebarItem label="Agents" active />
              <SidebarItem label="Discover" color="#5e5ce6" />
              <div style={{fontSize: 13, fontWeight: 600, color: C.faint, margin: '18px 12px 6px'}}>Comparisons</div>
              <div style={{fontSize: 15, color: C.faint, margin: '0 12px'}}>No comparisons</div>
              <div style={{flex: 1}} />
              <div style={{background: '#fff', borderRadius: 14, padding: 16, boxShadow: '0 1px 2px rgba(0,0,0,0.06)'}}>
                <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
                  <div style={{width: 16, height: 26, borderRadius: 4, border: `2px solid ${C.blue}`}} />
                  <div>
                    <div style={{fontWeight: 700, fontSize: 16}}>Phone</div>
                    <div style={{fontSize: 13, color: C.sub}}>{paired > 0.5 ? 'Paired' : 'Scan to pair your iPhone'}</div>
                  </div>
                </div>
                <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 14, fontSize: 15}}>
                  Remote <Toggle on={remoteOn} />
                </div>
                <div
                  style={{
                    height: 210 * qr,
                    overflow: 'hidden',
                    marginTop: 12,
                    display: 'flex',
                    justifyContent: 'center',
                    position: 'relative',
                  }}
                >
                  <div style={{padding: 10, background: '#fff', borderRadius: 10, opacity: 1 - paired * 0.7, position: 'relative'}}>
                    <PseudoQR size={180} />
                    {scan > 0 && scan < 1 ? (
                      <div
                        style={{
                          position: 'absolute',
                          left: 4,
                          right: 4,
                          top: 10 + 180 * scan,
                          height: 3,
                          borderRadius: 3,
                          background: C.green,
                          boxShadow: `0 0 16px 4px rgba(40,205,65,0.5)`,
                        }}
                      />
                    ) : null}
                  </div>
                  <div style={{position: 'absolute', top: 70, left: '50%', marginLeft: -36, transform: `scale(${check})`}}>
                    <Check size={72} p={check} />
                  </div>
                </div>
                <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 12, fontSize: 15}}>
                  Keep Mac awake <Toggle on={1} />
                </div>
              </div>
            </div>
          }
        >
          <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', rowGap: 50, padding: '40px 40px'}}>
            {AGENTS.map((a) => (
              <div key={a.name} style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12}}>
                <AgentIcon src={a.src} size={104} />
                <div style={{fontSize: 17, color: C.sub, fontWeight: 500}}>{a.name}</div>
              </div>
            ))}
          </div>
        </MacWindow>
      </div>
      <div style={{position: 'absolute', left: 1380, top: 300, opacity: ph, transform: `translateY(${(1 - ph) * 120}px) rotate(${(1 - ph) * 4}deg)`}}>
        <Phone height={700}>
          <Screenshot src="phone-pairing.png" />
          <div style={{position: 'absolute', inset: 0, opacity: paired}}>
            <Screenshot src="phone-inbox.png" />
          </div>
        </Phone>
      </div>
    </Stage>
  );
};

/* 5 ─ "Your agents can use msgblast." */
export const AgentsTitle: React.FC = () => (
  <Stage>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column'}}>
      <Reveal delay={0}>
        <Eyebrow color={C.blue}>Model Context Protocol</Eyebrow>
      </Reveal>
      <WordReveal text="Now your agents" size={140} stagger={5} delay={4} />
      <WordReveal text="can use it, too." size={140} stagger={5} delay={18} style={{marginTop: 4}} />
    </AbsoluteFill>
  </Stage>
);

/* 6 ─ MCP flow: an agent lists, asks for access, starts a blast */
const TermLine: React.FC<{at: number; children: React.ReactNode; color?: string; indent?: boolean}> = ({at, children, color = '#e5e5ea', indent}) => {
  const frame = useCurrentFrame();
  const o = interpolate(frame, [at, at + 8], [0, 1], clamp);
  return <div style={{opacity: o, color, paddingLeft: indent ? 26 : 0, marginTop: 10, transform: `translateY(${(1 - o) * 8}px)`}}>{children}</div>;
};

const Typed: React.FC<{text: string; start: number; cps?: number}> = ({text, start, cps = 2}) => {
  const frame = useCurrentFrame();
  const n = Math.max(0, Math.min(text.length, Math.floor((frame - start) * cps)));
  const caret = n < text.length || Math.floor(frame / 15) % 2 === 0;
  return (
    <span>
      {text.slice(0, n)}
      <span style={{opacity: caret ? 1 : 0, color: '#8e8e93'}}>▍</span>
    </span>
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

export const MCPFlow: React.FC = () => {
  const frame = useCurrentFrame();
  const term = useSpring(0, 20, 40);
  const mac = useSpring(10, 20, 40);
  const dialog = useSpring(128, 16, 30);
  const dialogOut = interpolate(frame, [196, 208], [1, 0], clamp);
  const seg = interpolate(frame, [160, 170], [0, 1], clamp);
  const press = frame > 186 && frame < 194 ? 0.96 : 1;
  const banner = useSpring(214, 18, 30);
  const replies = interpolate(frame, [262, 300], [0, 3], clamp);
  const caption = frame < 128 ? 0 : frame < 214 ? 1 : 2;
  const captions = [
    'Claude Code, Codex, Cursor and any MCP app can connect.',
    'Read only, or Full access. You choose, once per agent.',
    'Agent sends show up on your Mac. Stop them anytime.',
  ];
  return (
    <Stage>
      {/* terminal */}
      <div
        style={{
          position: 'absolute',
          left: 110,
          top: 170,
          width: 800,
          height: 560,
          borderRadius: 18,
          background: '#1c1c1e',
          boxShadow: '0 40px 90px -20px rgba(0,0,0,0.35)',
          opacity: term,
          transform: `translateY(${(1 - term) * 60}px)`,
          overflow: 'hidden',
        }}
      >
        <div style={{height: 44, display: 'flex', alignItems: 'center', gap: 8, paddingLeft: 18, background: '#2c2c2e'}}>
          {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
            <div key={c} style={{width: 12, height: 12, borderRadius: 99, background: c}} />
          ))}
          <div style={{flex: 1, textAlign: 'center', marginRight: 70, fontFamily: TEXT_FONT, fontSize: 14, color: '#98989d', fontWeight: 600}}>Claude Code</div>
        </div>
        <div style={{padding: '26px 30px', fontFamily: MONO, fontSize: 21, lineHeight: 1.45, color: '#f2f2f7'}}>
          <div>
            <span style={{color: '#ff9f0a'}}>&gt; </span>
            <Typed text="Ask my agents which pasta goes best with pesto, then wait for their replies." start={14} cps={1.6} />
          </div>
          <TermLine at={78} color="#30d158">● msgblast_agents_list</TermLine>
          <TermLine at={90} indent color="#98989d">
            ChatGPT · Claude · Grok
          </TermLine>
          <TermLine at={108} color="#30d158">● msgblast_blast_start</TermLine>
          <TermLine at={118} indent color="#ff9f0a">
            {frame < 200 ? 'Waiting for your approval in msgblast…' : 'Approved: Full access'}
          </TermLine>
          <TermLine at={222} indent color="#98989d">
            Started a blast · 3 agents
          </TermLine>
          <TermLine at={250} color="#30d158">● msgblast_blast_wait</TermLine>
          <TermLine at={262} indent color="#98989d">
            {Math.floor(replies)} of 3 replies{replies >= 3 ? ' ✓' : '…'}
          </TermLine>
        </div>
      </div>

      {/* mac window */}
      <div style={{position: 'absolute', left: 980, top: 170, opacity: mac, transform: `translateY(${(1 - mac) * 60}px)`}}>
        <MacWindow width={830} height={560} sidebarWidth={200} sidebar={<><SidebarItem label="Agents" active /><SidebarItem label="Discover" color="#5e5ce6" /></>}>
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: 0,
              height: 64 * banner,
              overflow: 'hidden',
              background: '#f5f5f7',
              borderBottom: banner > 0.05 ? `1px solid ${C.line}` : 'none',
              display: 'flex',
              alignItems: 'center',
              padding: '0 18px',
              gap: 12,
              fontSize: 16,
              color: C.ink,
            }}
          >
            <Spinner size={20} />
            <div style={{flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}}>
              Sending for an outside agent: <b>Claude Code</b> · Started a blast · 3 agents
            </div>
            <div style={{color: C.blue, fontWeight: 600, whiteSpace: 'nowrap'}}>Stop Agent Sends</div>
          </div>
          <div style={{display: 'flex', justifyContent: 'center', gap: 56, paddingTop: 110 + 30 * banner}}>
            {AGENTS.slice(0, 3).map((a, i) => {
              const done = replies > i + 1 - 0.01 + 0;
              return (
                <div key={a.name} style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, position: 'relative'}}>
                  <AgentIcon src={a.src} size={110} />
                  <div style={{position: 'absolute', top: 84, right: -8}}>
                    {frame > 214 ? done ? <Check size={32} p={1} color={C.blue} /> : <Spinner size={30} /> : null}
                  </div>
                  <div style={{fontSize: 17, color: C.sub, fontWeight: 500}}>{a.name}</div>
                </div>
              );
            })}
          </div>
        </MacWindow>

        {/* approval dialog */}
        <div
          style={{
            position: 'absolute',
            left: 215,
            top: 110,
            width: 400,
            borderRadius: 22,
            background: 'rgba(255,255,255,0.97)',
            boxShadow: '0 30px 80px rgba(0,0,0,0.3), 0 0 0 1px rgba(0,0,0,0.06)',
            padding: 28,
            fontFamily: TEXT_FONT,
            opacity: dialog * dialogOut,
            transform: `scale(${1.25 * (0.9 + 0.1 * dialog) * (frame > 196 ? 0.97 + 0.03 * dialogOut : 1)})`,
          }}
        >
          <AppIcon size={64} style={{filter: 'none'}} />
          <div style={{fontWeight: 700, fontSize: 19, marginTop: 14, color: C.ink}}>Claude Code wants to use msgblast</div>
          <div style={{fontSize: 15, color: C.sub, marginTop: 8, lineHeight: 1.4}}>
            Choose what it may do. You can change this anytime in Settings › Outside agents.
          </div>
          <div style={{display: 'flex', background: '#ececf0', borderRadius: 10, padding: 3, marginTop: 18, position: 'relative'}}>
            <div
              style={{
                position: 'absolute',
                top: 3,
                bottom: 3,
                width: 'calc(50% - 3px)',
                left: `calc(3px + ${seg * 50}% - ${seg * 3}px)`,
                background: '#fff',
                borderRadius: 8,
                boxShadow: '0 1px 4px rgba(0,0,0,0.15)',
              }}
            />
            {['Read only', 'Full access'].map((t) => (
              <div key={t} style={{flex: 1, textAlign: 'center', padding: '9px 0', fontSize: 15, fontWeight: 600, position: 'relative', color: C.ink}}>
                {t}
              </div>
            ))}
          </div>
          <div style={{display: 'flex', gap: 10, marginTop: 18}}>
            <div style={{flex: 1, textAlign: 'center', padding: '10px 0', borderRadius: 10, background: '#ececf0', fontWeight: 600, fontSize: 15}}>Don't Allow</div>
            <div
              style={{
                flex: 1,
                textAlign: 'center',
                padding: '10px 0',
                borderRadius: 10,
                background: C.blue,
                color: '#fff',
                fontWeight: 600,
                fontSize: 15,
                transform: `scale(${press})`,
              }}
            >
              Allow
            </div>
          </div>
        </div>
      </div>

      <div style={{position: 'absolute', top: 810, width: '100%', textAlign: 'center'}}>
        {captions.map((c, i) => {
          const starts = [6, 128, 214];
          const ends = [120, 206, 9999];
          return (
            <div key={i} style={{position: 'absolute', width: '100%'}}>
              {caption === i ? (
                <Reveal delay={starts[i]} out={ends[i]}>
                  <Sub size={36} style={{color: C.ink, fontWeight: 600}}>
                    {c}
                  </Sub>
                </Reveal>
              ) : null}
            </div>
          );
        })}
      </div>
    </Stage>
  );
};

/* 7 ─ Agents on other devices (Grok Bot over Tailscale) */
const Row: React.FC<{k: string; v: React.ReactNode; at: number; mono?: boolean; last?: boolean}> = ({k, v, at, mono, last}) => (
  <Reveal delay={at} rise={10} blur={false}>
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        padding: '15px 0',
        borderBottom: last ? 'none' : `1px solid ${C.line}`,
        fontSize: 19,
      }}
    >
      <span style={{color: C.ink}}>{k}</span>
      <span style={{color: C.sub, fontFamily: mono ? MONO : TEXT_FONT, fontSize: mono ? 17 : 19}}>{v}</span>
    </div>
  </Reveal>
);

export const OtherDevices: React.FC = () => {
  const frame = useCurrentFrame();
  const card = useSpring(6, 20, 40);
  const allowed = useProgress(130, 18);
  return (
    <Stage glow="rgba(0,0,0,0.03)">
      <div style={{position: 'absolute', left: 150, top: 330, width: 760}}>
        <Reveal delay={4}>
          <Eyebrow color={C.blue}>Outside agents</Eyebrow>
        </Reveal>
        <Reveal delay={10}>
          <Headline size={88}>
            Agents on your
            <br />
            other devices, too.
          </Headline>
        </Reveal>
        <Reveal delay={24}>
          <Sub style={{marginTop: 32, maxWidth: 660}}>
            Grok Bot connects over Tailscale with its own key. Claude Code and Codex set up with one click.
          </Sub>
        </Reveal>
      </div>
      <div
        style={{
          position: 'absolute',
          left: 1060,
          top: 170,
          width: 700,
          opacity: card,
          transform: `translateY(${(1 - card) * 80}px)`,
        }}
      >
        <MacWindow width={700} height={740} title="Set Up Grok Bot">
          <div style={{padding: '6px 34px', fontFamily: TEXT_FONT}}>
            <div style={{display: 'flex', alignItems: 'center', gap: 16, margin: '6px 0 18px'}}>
              <AgentIcon src="grok.png" size={58} />
              <div style={{fontSize: 30, color: C.faint}}>⇄</div>
              <AppIcon size={58} style={{filter: 'none'}} />
            </div>
            <Reveal delay={20} rise={10} blur={false}>
              <div style={{fontWeight: 700, fontSize: 18, marginBottom: 8}}>1. In Grok Bot, connect Tailscale</div>
            </Reveal>
            <div style={{background: '#f5f5f7', borderRadius: 14, padding: '0 20px'}}>
              <Row k="Connect apps → Tailscale" v={<span style={{color: C.green, fontWeight: 600}}>Connected</span>} at={26} last />
            </div>
            <Reveal delay={36} rise={10} blur={false}>
              <div style={{fontWeight: 700, fontSize: 18, margin: '22px 0 8px'}}>2. Add a custom connector</div>
            </Reveal>
            <div style={{background: '#f5f5f7', borderRadius: 14, padding: '0 20px'}}>
              <Row k="Name" v="msgblast" mono at={42} />
              <Row k="Type" v="Remote HTTPS" at={50} />
              <Row k="Server URL" v="https://your-mac.your-tailnet.ts.net/mcp" mono at={58} />
              <Row k="Key" v="Authorization" mono at={66} />
              <Row k="Value" v="(key hidden)" at={74} last />
            </div>
            <Reveal delay={90} rise={10} blur={false}>
              <div style={{fontWeight: 700, fontSize: 18, margin: '22px 0 8px'}}>3. Send this to Grok Bot</div>
            </Reveal>
            <div style={{background: '#f5f5f7', borderRadius: 14, padding: '14px 20px'}}>
              <Reveal delay={96} rise={10} blur={false}>
                <div style={{fontFamily: MONO, fontSize: 17, color: C.sub}}>Use msgblast to check its status and list my agents.</div>
              </Reveal>
              <div style={{display: 'flex', alignItems: 'center', gap: 10, marginTop: 14, opacity: allowed, height: 30}}>
                <Check size={26} p={allowed} />
                <span style={{color: C.green, fontWeight: 600, fontSize: 19}}>Allowed</span>
              </div>
            </div>
          </div>
        </MacWindow>
      </div>
      {frame < 0 ? null : null}
    </Stage>
  );
};

/* 8 ─ Alexa Shopping (ships with #125 / #135) */
const Bottle: React.FC<{hue: number; cap: string}> = ({hue, cap}) => (
  <svg width="100%" height="100%" viewBox="0 0 200 140">
    <rect width="200" height="140" fill={`hsl(${hue},40%,95%)`} />
    <rect x="82" y="16" width="36" height="16" rx="5" fill={cap} />
    <rect x="70" y="30" width="60" height="98" rx="18" fill={`hsl(${hue},55%,62%)`} />
    <rect x="80" y="44" width="10" height="70" rx="5" fill="rgba(255,255,255,0.45)" />
  </svg>
);

const Product: React.FC<{at: number; name: string; price: string; rating: string; hue: number; cap: string}> = ({at, ...p}) => (
  <Reveal delay={at} rise={30} blur={false}>
    <div style={{width: '78%', marginLeft: 14, marginTop: 14}}>
      <div style={{borderRadius: 20, overflow: 'hidden', height: 150}}>
        <Bottle hue={p.hue} cap={p.cap} />
      </div>
      <div style={{background: '#e9e9eb', borderRadius: 20, padding: '12px 16px', marginTop: 6, fontSize: 17, lineHeight: 1.35, color: '#000'}}>
        <b>{p.name}</b>
        <div style={{color: '#3c3c43', marginTop: 2}}>
          {p.price} · {p.rating}
        </div>
      </div>
    </div>
  </Reveal>
);

export const Alexa: React.FC = () => {
  const frame = useCurrentFrame();
  const ph = useSpring(0, 18, 40);
  const scroll = interpolate(frame, [70, 190], [0, -300], {...clamp});
  return (
    <Stage glow="rgba(0,160,220,0.07)">
      <div style={{position: 'absolute', left: 260, top: 70, opacity: ph, transform: `translateY(${(1 - ph) * 200}px)`}}>
        <Phone height={900}>
          <div style={{position: 'absolute', inset: 0, background: '#fff', fontFamily: TEXT_FONT}}>
            <div style={{position: 'absolute', top: 0, left: 0, right: 0, height: 200, background: 'rgba(255,255,255,0.96)', zIndex: 2, textAlign: 'center', paddingTop: 66}}>
              <Img src={staticFile('img/alexa.png')} style={{width: 64, height: 64, borderRadius: 99, boxShadow: '0 2px 8px rgba(0,0,0,0.1)'}} />
              <div style={{display: 'inline-block', marginTop: 6, fontSize: 15, padding: '4px 12px', borderRadius: 99, border: '1px solid #d1d1d6', color: '#000'}}>
                Alexa Shopping Web ›
              </div>
            </div>
            <div style={{position: 'absolute', top: 200, left: 0, right: 0, transform: `translateY(${scroll}px)`}}>
              <div style={{display: 'flex', justifyContent: 'flex-end', padding: '8px 14px'}}>
                <div style={{background: C.blue, color: '#fff', borderRadius: 20, padding: '10px 16px', fontSize: 17}}>Find me a good water bottle</div>
              </div>
              <Product at={20} name="32 oz Wide Mouth Bottle" price="$16.25" rating="4.8★" hue={200} cap="#1d1d1f" />
              <Product at={34} name="Insulated Steel Bottle, 24 oz" price="$29.95" rating="4.7★" hue={150} cap="#8e8e93" />
              <Product at={48} name="Everyday Straw Bottle" price="$19.99" rating="4.6★" hue={20} cap="#ffffff" />
            </div>
          </div>
        </Phone>
      </div>
      <div style={{position: 'absolute', left: 900, top: 340, width: 860}}>
        <Reveal delay={8}>
          <Eyebrow color="#00a8e1">New agent</Eyebrow>
        </Reveal>
        <Reveal delay={14}>
          <Headline size={96}>Alexa Shopping.</Headline>
        </Reveal>
        <Reveal delay={28}>
          <Sub style={{marginTop: 30, maxWidth: 760}}>
            Compare its picks with your other agents. On iPhone, products show up with photos, prices and ratings.
          </Sub>
        </Reveal>
      </div>
    </Stage>
  );
};

/* 9 ─ Settings, redesigned */
const SETTINGS = [
  {label: 'General', color: '#8e8e93', group: ''},
  {label: 'Mac apps', color: '#0a84ff', group: 'Connections'},
  {label: 'Websites', color: '#30b0c7', group: ''},
  {label: 'CLI tools', color: '#1d1d1f', group: ''},
  {label: 'Webhooks', color: '#5e5ce6', group: ''},
  {label: 'Outside agents', color: '#28cd41', group: ''},
  {label: 'Remote', color: '#ff9f0a', group: ''},
  {label: 'Permissions', color: '#ff375f', group: ''},
  {label: 'Sharing', color: '#64d2ff', group: ''},
  {label: 'Updates', color: '#8e8e93', group: ''},
];

const PANE_ROWS: Record<string, string[]> = {
  General: ['Launch at login', 'Show in menu bar', 'Sounds'],
  'Mac apps': ['ChatGPT', 'Claude', 'Grok Bot'],
  Websites: ['Alexa Shopping Web', 'Claude on the web', 'Grok'],
  'CLI tools': ['Claude Code', 'Codex'],
  Webhooks: ['Grok Bot webhook'],
  'Outside agents': ['Let agents use msgblast', 'Claude Code', 'Codex', 'Tailscale'],
  Remote: ['Remote', 'Keep Mac awake', 'Network'],
  Permissions: ['Accessibility', 'Full Disk Access', 'Screen Recording'],
  Sharing: ['Usage stats'],
  Updates: ['Check automatically'],
};

export const SettingsScene: React.FC = () => {
  const frame = useCurrentFrame();
  const win = useSpring(10, 20, 40);
  const idx = Math.min(SETTINGS.length - 1, Math.max(0, Math.floor((frame - 40) / 11)));
  const page = SETTINGS[idx].label;
  const rows = PANE_ROWS[page];
  return (
    <Stage>
      <div style={{position: 'absolute', top: 70, width: '100%', textAlign: 'center'}}>
        <Reveal delay={0}>
          <Headline size={80}>Settings, redesigned.</Headline>
        </Reveal>
        <Reveal delay={10}>
          <Sub style={{marginTop: 16}}>Everything in one sidebar. Your settings carry over.</Sub>
        </Reveal>
      </div>
      <div style={{position: 'absolute', left: 360, top: 300, opacity: win, transform: `translateY(${(1 - win) * 60}px) scale(${0.96 + 0.04 * win})`}}>
        <MacWindow
          width={1200}
          height={660}
          sidebarWidth={290}
          sidebar={
            <div>
              {SETTINGS.map((s, i) => (
                <React.Fragment key={s.label}>
                  {s.group ? <div style={{fontSize: 13, fontWeight: 600, color: C.faint, margin: '14px 12px 4px'}}>{s.group}</div> : null}
                  <div
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 12,
                      padding: '8px 12px',
                      borderRadius: 9,
                      background: i === idx ? C.blue : 'transparent',
                      color: i === idx ? '#fff' : C.ink,
                      fontSize: 16,
                      fontWeight: 500,
                    }}
                  >
                    <div style={{width: 22, height: 22, borderRadius: 6, background: s.color, boxShadow: i === idx ? '0 0 0 1.5px #fff' : 'none'}} />
                    {s.label}
                  </div>
                </React.Fragment>
              ))}
            </div>
          }
        >
          <div style={{padding: '0 44px'}}>
            <div style={{fontFamily: FONT, fontWeight: 700, fontSize: 34, letterSpacing: -0.6, color: C.ink}}>{page}</div>
            <div style={{background: '#f5f5f7', borderRadius: 14, marginTop: 22, padding: '0 22px'}}>
              {rows.map((r, i) => (
                <div
                  key={page + r}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    padding: '17px 0',
                    borderBottom: i === rows.length - 1 ? 'none' : `1px solid ${C.line}`,
                    fontSize: 18,
                    color: C.ink,
                  }}
                >
                  {r}
                  <Toggle on={i === 2 ? 0 : 1} />
                </div>
              ))}
            </div>
          </div>
        </MacWindow>
      </div>
    </Stage>
  );
};

/* 10 ─ And more */
export const AndMore: React.FC<{items: string[]}> = ({items}) => (
  <Stage>
    <div style={{position: 'absolute', top: 150, width: '100%', textAlign: 'center'}}>
      <WordReveal text="And a lot more." size={110} stagger={5} />
    </div>
    <div
      style={{
        position: 'absolute',
        top: 400,
        left: 230,
        right: 230,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        columnGap: 90,
        rowGap: 44,
      }}
    >
      {items.map((t, i) => (
        <Reveal key={t} delay={26 + i * 9} rise={18}>
          <div style={{display: 'flex', gap: 20, alignItems: 'flex-start'}}>
            <div style={{marginTop: 4}}>
              <Check size={34} p={1} />
            </div>
            <div style={{fontFamily: FONT, fontSize: 34, fontWeight: 600, letterSpacing: -0.5, lineHeight: 1.25, color: C.ink}}>{t}</div>
          </div>
        </Reveal>
      ))}
    </div>
  </Stage>
);

/* 11 ─ Outro */
export const Outro: React.FC = () => {
  const s = useSpring(0, 14, 45);
  return (
    <Stage glow="rgba(60,220,80,0.12)">
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{transform: `scale(${0.8 + 0.2 * s})`, opacity: s}}>
          <AppIcon size={220} />
        </div>
        <div style={{height: 50}} />
        <Reveal delay={14}>
          <Headline size={100} style={{textAlign: 'center'}}>
            msgblast <span style={{color: C.faint, fontWeight: 600}}>0.11</span>
          </Headline>
        </Reveal>
        <Reveal delay={30}>
          <Sub size={38} style={{marginTop: 22, textAlign: 'center', color: C.ink}}>
            Available now for Mac.
          </Sub>
        </Reveal>
        <Reveal delay={44}>
          <Sub size={24} style={{marginTop: 14, textAlign: 'center', color: C.faint}}>
            The iPhone app builds from source and needs msgblast 0.11 on your Mac.
          </Sub>
        </Reveal>
      </AbsoluteFill>
    </Stage>
  );
};
