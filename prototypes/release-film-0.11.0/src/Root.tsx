import React from 'react';
import {AbsoluteFill, Composition, Series} from 'remotion';
import {C} from './ui';
import {AgentsTitle, Alexa, AndMore, Intro, IPhoneShowcase, IPhoneTitle, MCPFlow, OtherDevices, Outro, Pairing, SceneFade, SettingsScene} from './scenes';

/**
 * Feature list for msgblast 0.11.0.
 * `pr` names the pull request each scene depends on; `pending: true` marks PRs that were
 * still open when this was made (2026-11-14 07:30Z, main 51fedbe). The "merged only" cut drops them.
 */
type Props = {includePending: boolean};

const MORE: {text: string; pr: string; pending?: boolean}[] = [
  {text: 'ChatGPT and Dots work with the latest ChatGPT app.', pr: '#123'},
  {text: 'Sends to ChatGPT stay in the background.', pr: '#123'},
  {text: 'Long Dots chats load in full.', pr: '#123'},
  {text: 'A clear stop when an app prompt covers the message box.', pr: '#123'},
  {text: 'Open in Messages opens the right chat.', pr: '#126'},
  {text: 'msgblast comes forward after you grant access.', pr: '#143'},
  {text: 'Your first new conversation on iPhone just works.', pr: '#136', pending: true},
];

type Scene = {id: string; frames: number; el: (p: Props) => React.ReactNode; pending?: boolean};

const SCENES: Scene[] = [
  {id: 'intro', frames: 120, el: () => <Intro />},
  {id: 'iphone-title', frames: 80, el: () => <IPhoneTitle />},
  {id: 'iphone', frames: 270, el: () => <IPhoneShowcase />}, // #94
  {id: 'pairing', frames: 210, el: () => <Pairing />}, // #126
  {id: 'agents-title', frames: 95, el: () => <AgentsTitle />},
  {id: 'mcp', frames: 330, el: () => <MCPFlow />}, // #107, #97, #124
  {id: 'other-devices', frames: 210, el: () => <OtherDevices />}, // #139
  {id: 'alexa', frames: 210, el: () => <Alexa />, pending: true}, // #125, #135
  {id: 'settings', frames: 175, el: () => <SettingsScene />}, // #97
  {
    id: 'more',
    frames: 250,
    el: (p) => <AndMore items={MORE.filter((m) => p.includePending || !m.pending).map((m) => m.text)} />,
  },
  {id: 'outro', frames: 180, el: () => <Outro />},
];

const scenesFor = (p: Props) => SCENES.filter((s) => p.includePending || !s.pending);
const total = (p: Props) => scenesFor(p).reduce((n, s) => n + s.frames, 0);

const Film: React.FC<Props> = (p) => (
  <AbsoluteFill style={{background: C.bg}}>
  <Series>
    {scenesFor(p).map((s, i, arr) => (
      <Series.Sequence key={s.id} durationInFrames={s.frames} name={s.id}>
        <SceneFade fadeIn={i === 0 ? 0 : 10} fadeOut={i === arr.length - 1 ? 20 : 10}>
          {s.el(p)}
        </SceneFade>
      </Series.Sequence>
    ))}
  </Series>
  </AbsoluteFill>
);

export const Root: React.FC = () => (
  <>
    <Composition
      id="Film"
      component={Film}
      durationInFrames={total({includePending: true})}
      fps={30}
      width={1920}
      height={1080}
      defaultProps={{includePending: true}}
    />
    <Composition
      id="FilmMergedOnly"
      component={Film}
      durationInFrames={total({includePending: false})}
      fps={30}
      width={1920}
      height={1080}
      defaultProps={{includePending: false}}
    />
  </>
);
