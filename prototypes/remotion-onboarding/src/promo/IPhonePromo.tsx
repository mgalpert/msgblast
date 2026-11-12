import React from 'react';
import {AbsoluteFill, Easing, Img, Sequence, interpolate, staticFile, useCurrentFrame} from 'remotion';

// 1080 × 1920, 30 fps, 48 s. Script and sources: ../../PROMO.md.
// Phone screens are the simulator fixture captures from the iPhone promo
// captures workflow (#130), fetched into public/promo/ (ignored by Git).

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const ease = Easing.out(Easing.cubic);
const GREEN = '#1fbf2a';
const font = '-apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif';

export const PROMO_FPS = 30;

type PhoneScene = {kind: 'phone'; dur: number; shot: string; title: string; sub: string; dark?: boolean};
type Scene = PhoneScene | {kind: 'hook' | 'mac' | 'end'; dur: number};

export const SCENES: Scene[] = [
  {kind: 'hook', dur: 90},
  {kind: 'phone', dur: 150, shot: '01-inbox', title: 'Your Mac’s AI chats.\nIn your pocket.', sub: 'Every conversation on your Mac, on your iPhone.'},
  {kind: 'phone', dur: 180, shot: '02-conversation', title: 'One prompt.\nEvery answer.', sub: 'Claude, ChatGPT and Muse reply side by side.'},
  {kind: 'phone', dur: 150, shot: '03-conversation-details', title: 'Pick who answers.', sub: 'Websites and Mac apps, in one thread.'},
  {kind: 'phone', dur: 150, shot: '07-pairing', title: 'Pair in seconds.', sub: 'Scan the code in the new Phone section of the Mac sidebar.'},
  {kind: 'phone', dur: 150, shot: '11-conversation-dark', title: 'Read it here.\nRead on your Mac.', sub: 'Catching up on the phone clears iMessage unread on the Mac.', dark: true},
  {kind: 'mac', dur: 300},
  {kind: 'phone', dur: 150, shot: '09-settings', title: 'Private by design.', sub: 'Encrypted device to device. Interrupted sends are never resent.'},
  {kind: 'end', dur: 120},
];

export const PROMO_FRAMES = SCENES.reduce((sum, s) => sum + s.dur, 0);

// Mac-side changes in this release, one line each (PR numbers in PROMO.md).
const MAC_FEATURES: [string, string][] = [
  ['Messages-style conversations', 'A redesigned Mac conversation window'],
  ['Phone in the sidebar', 'Pairing QR code and phone settings, always visible'],
  ['Voice control', 'Drive msgblast by voice with your own OpenAI key'],
  ['Agents that can send', 'Full-access outside agents, with a Stop banner'],
  ['ChatGPT and Dots in the background', 'Sends no longer steal the foreground'],
  ['Alexa Shopping', 'New optional agent in onboarding'],
  ['Muse connects quietly', 'And says why when a connect fails'],
  ['Clear “needs you” stops', 'When an app prompt covers the composer'],
  ['Long Dots DMs', 'Read all the way to the composer'],
  ['Ended chats scroll again', 'Link cards open in your browser'],
  ['A new Settings sidebar', 'Every page one click away'],
  ['Sturdier phone sends', 'Upload and queue caps, late confirmations matched'],
];

const Background: React.FC<{dark?: boolean}> = ({dark}) => (
  <AbsoluteFill style={{background: dark
    ? 'radial-gradient(120% 80% at 50% 0%, #1d3a20 0%, #0b0d0c 60%)'
    : 'radial-gradient(120% 80% at 50% 0%, #e6fbe4 0%, #ffffff 60%)'}}/>
);

const Caption: React.FC<{title: string; sub: string; dark?: boolean}> = ({title, sub, dark}) => {
  const f = useCurrentFrame();
  const a = interpolate(f, [4, 18], [0, 1], {...clamp, easing: ease});
  const b = interpolate(f, [12, 26], [0, 1], {...clamp, easing: ease});
  return <div style={{position: 'absolute', top: 96, left: 60, right: 60, textAlign: 'center', fontFamily: font}}>
    <div style={{fontSize: 72, fontWeight: 700, letterSpacing: -2, lineHeight: 1.05, whiteSpace: 'pre-line',
      color: dark ? '#fff' : '#111', opacity: a, transform: `translateY(${(1 - a) * 24}px)`}}>{title}</div>
    <div style={{fontSize: 34, marginTop: 20, color: dark ? '#b8c2bb' : '#5d6460', opacity: b,
      transform: `translateY(${(1 - b) * 16}px)`}}>{sub}</div>
  </div>;
};

const Phone: React.FC<{shot: string; dur: number}> = ({shot, dur}) => {
  const f = useCurrentFrame();
  const enter = interpolate(f, [0, 20], [0, 1], {...clamp, easing: ease});
  const zoom = interpolate(f, [0, dur], [1, 1.035], clamp);
  const w = 620, h = Math.round(w * 2622 / 1206), bezel = 18;
  return <div style={{position: 'absolute', left: (1080 - w) / 2 - bezel, top: 440 + (1 - enter) * 160, opacity: enter,
    width: w + bezel * 2, height: h + bezel * 2, borderRadius: 112, background: '#111',
    boxShadow: '0 40px 90px #0003, inset 0 0 0 3px #3a3a3a', transform: `scale(${zoom})`, transformOrigin: '50% 0%'}}>
    <div style={{position: 'absolute', left: bezel, top: bezel, width: w, height: h, borderRadius: 96, overflow: 'hidden', background: '#fff'}}>
      <Img src={staticFile(`promo/${shot}.png`)} style={{width: '100%', height: '100%'}}/>
    </div>
  </div>;
};

const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const icon = interpolate(f, [0, 18], [0, 1], {...clamp, easing: Easing.out(Easing.back(1.6))});
  const text = interpolate(f, [14, 32], [0, 1], {...clamp, easing: ease});
  return <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', fontFamily: font}}>
    <Img src={staticFile('assets/msgblast.png')} style={{width: 300, height: 300, transform: `scale(${icon})`}}/>
    <div style={{fontSize: 84, fontWeight: 700, letterSpacing: -2.5, textAlign: 'center', marginTop: 50, lineHeight: 1.05,
      opacity: text, transform: `translateY(${(1 - text) * 24}px)`}}>Ask every AI.<br/>From your iPhone.</div>
  </AbsoluteFill>;
};

const MacRelease: React.FC = () => {
  const f = useCurrentFrame();
  const head = interpolate(f, [0, 16], [0, 1], {...clamp, easing: ease});
  return <AbsoluteFill style={{fontFamily: font}}>
    <div style={{position: 'absolute', top: 110, width: '100%', textAlign: 'center', opacity: head}}>
      <div style={{fontSize: 30, fontWeight: 600, color: GREEN, letterSpacing: 2}}>ALSO NEW ON THE MAC</div>
      <div style={{fontSize: 72, fontWeight: 700, letterSpacing: -2, marginTop: 10}}>This release</div>
    </div>
    {MAC_FEATURES.map(([title, sub], i) => {
      const t = interpolate(f, [18 + i * 12, 34 + i * 12], [0, 1], {...clamp, easing: ease});
      return <div key={title} style={{position: 'absolute', left: 70, right: 70, top: 340 + i * 124, height: 108,
        display: 'flex', alignItems: 'center', gap: 28, padding: '0 34px', borderRadius: 30, background: '#fff',
        boxShadow: '0 6px 24px #0000000f', border: '1px solid #ececec', opacity: t, transform: `translateX(${(1 - t) * 80}px)`}}>
        <div style={{width: 18, height: 18, borderRadius: 9, background: GREEN, flex: 'none'}}/>
        <div>
          <div style={{fontSize: 36, fontWeight: 600, letterSpacing: -.6, color: '#111'}}>{title}</div>
          <div style={{fontSize: 26, color: '#6b716d', marginTop: 4}}>{sub}</div>
        </div>
      </div>;
    })}
  </AbsoluteFill>;
};

const End: React.FC = () => {
  const f = useCurrentFrame();
  const a = interpolate(f, [0, 20], [0, 1], {...clamp, easing: ease});
  return <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', fontFamily: font, opacity: a}}>
    <Img src={staticFile('assets/msgblast.png')} style={{width: 260, height: 260}}/>
    <div style={{fontSize: 96, fontWeight: 700, letterSpacing: -3, marginTop: 36}}>msgblast</div>
    <div style={{fontSize: 38, color: '#5d6460', marginTop: 12}}>Every AI answer, side by side.</div>
    <div style={{fontSize: 40, fontWeight: 600, color: GREEN, marginTop: 56}}>msgblast.app</div>
  </AbsoluteFill>;
};

const FadeOut: React.FC<{dur: number; children: React.ReactNode}> = ({dur, children}) => {
  const f = useCurrentFrame();
  return <AbsoluteFill style={{opacity: interpolate(f, [dur - 10, dur], [1, 0], clamp)}}>{children}</AbsoluteFill>;
};

export const IPhonePromo: React.FC = () => {
  let from = 0;
  return <AbsoluteFill style={{background: '#fff'}}>
    {SCENES.map((s, i) => {
      const start = from; from += s.dur;
      const last = i === SCENES.length - 1;
      const body = s.kind === 'phone'
        ? <><Background dark={s.dark}/><Phone shot={s.shot} dur={s.dur}/><Caption title={s.title} sub={s.sub} dark={s.dark}/></>
        : <><Background/>{s.kind === 'hook' ? <Hook/> : s.kind === 'mac' ? <MacRelease/> : <End/>}</>;
      return <Sequence key={i} from={start} durationInFrames={s.dur}>
        {last ? <AbsoluteFill>{body}</AbsoluteFill> : <FadeOut dur={s.dur}>{body}</FadeOut>}
      </Sequence>;
    })}
  </AbsoluteFill>;
};
