import React from 'react';
import {Audio} from '@remotion/media';
import {AbsoluteFill, Composition, Easing, Img, interpolate, registerRoot, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import icons from './inventory.json';
import {IPhonePromo, PROMO_FPS, PROMO_FRAMES} from './promo/IPhonePromo';
const clamp={extrapolateLeft:'clamp',extrapolateRight:'clamp'} as const;
const mix=(t:number,a:number,b:number)=>a+(b-a)*t;
const Scene: React.FC<{background?:boolean; withAudio?:boolean}> = ({background=false, withAudio=false})=>{
 const frame=useCurrentFrame(); const {fps}=useVideoConfig(); const t=background?8:frame/fps;
 const appReveal=interpolate(t,[1.9,2.2],[0,1],clamp);
 const folderReveal=interpolate(t,[5.15,5.65],[0,1],clamp);
 const reveal=interpolate(t,[5.7,6.15],[0,1],clamp);
 const settle=interpolate(t,[4.65,5.35],[0,1],{...clamp,easing:Easing.inOut(Easing.cubic)});
 const appX=mix(settle,960,580),appY=mix(settle,820,680);
 const pulse=t<2.2?0:t<4.3?.025*Math.sin((t-2.2)*12):.02*Math.sin((t-4.3)*14)*Math.exp(-(t-4.3)*6);
 return <AbsoluteFill style={{background:'#ffffff',fontFamily:'-apple-system, BlinkMacSystemFont, sans-serif',color:'#202124',overflow:'hidden'}}>
  {withAudio && !background && <Audio src={staticFile('audio/onboarding.mp3')} />}
  <div style={{position:'absolute',top:152,width:'100%',textAlign:'center',opacity:interpolate(t,[5.2,5.8],[0,1],clamp),transform:`translateY(${(1-reveal)*16}px)`}}><div style={{fontSize:54,fontWeight:600,letterSpacing:-2}}>Welcome to msgblast.</div><div style={{fontSize:24,color:'#74787a',marginTop:18}}>your next agent message starts here</div></div>
  {!background && icons.map((icon,i)=>{
   // Uniform tiles and spacing: quantity overwhelms, choreography stays orderly.
   const col=i%13,row=Math.floor(i/13),base=col*154+(row%2)*77;
   const tail=(time:number)=>25*(1-Math.exp(-Math.max(0,time-2)/.25));
   const wallX=(time:number)=>time<=2?((base+time*100)%2156)-118:((base+200)%2156)-118+tail(time);
   const sourceY=75+row*150;
   const distance=Math.hypot(wallX(4)-960,sourceY-820);
   // Distance determines cascade order: nearest marks enter before farther marks.
   const start=2.2+distance/1350*.92;
   const sourceX=wallX(Math.min(t,start));
   const intake=interpolate(t,[start,start+.88+distance*.00017],[0,1],{...clamp,easing:Easing.in(Easing.cubic)});
   const x=mix(intake,sourceX,960),y=mix(intake,sourceY,820);
   const scale=1-intake*.96;
   const fade=interpolate(intake,[.97,1],[1,0],clamp);
   return <div key={icon.file} style={{position:'absolute',left:x-70,top:y-70,width:140,height:140,zIndex:1,opacity:fade,transform:`scale(${scale})`,borderRadius:31,background:'#ffffff',border:'1px solid #e9e9e9',overflow:'hidden'}}><Img src={staticFile(`assets/${icon.file}`)} style={{width:'100%',height:'100%',objectFit:'contain'}}/></div>
  })}
  <div style={{position:'absolute',left:appX-150,top:appY+105,width:300,height:45,borderRadius:'50%',background:'#000',filter:'blur(25px)',opacity:(background?.025:.04)*appReveal}}/>
  {!background && <div style={{position:'absolute',left:appX-130,top:appY-130,width:260,height:260,zIndex:199,opacity:appReveal,borderRadius:75,background:'#ffffff',boxShadow:'0 0 35px 18px #ffffff'}}/>}
  {!background && <Img src={staticFile('assets/msgblast.png')} style={{position:'absolute',left:appX-105,top:appY-105,zIndex:200,opacity:appReveal,width:210,height:210,transform:`scale(${1+pulse})`,filter:'drop-shadow(0 3px 4px #0000000a)'}}/>}
  <div style={{position:'absolute',left:1190,top:785,width:300,height:45,borderRadius:'50%',background:'#000',filter:'blur(25px)',opacity:folderReveal*.04}}/>
  {!background && <Img src={staticFile('assets/applications.png')} style={{position:'absolute',left:1235,top:575,width:210,height:210,opacity:folderReveal,transform:`translateY(${(1-folderReveal)*28}px)`,filter:'drop-shadow(0 3px 4px #0000000a)'}}/>}
  <svg width="1920" height="1200" style={{position:'absolute',opacity:reveal}}><path d="M 765 680 C 875 635, 1040 635, 1150 680" fill="none" stroke="#8d9690" strokeWidth="4" strokeDasharray="2 15" strokeLinecap="round"/><path d="m 1129 654 24 28 -34 7" fill="none" stroke="#8d9690" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round"/></svg>
  <div style={{position:'absolute',top:827,left:420,width:320,textAlign:'center',fontSize:25,opacity:background?0:reveal}}>msgblast</div>
  <div style={{position:'absolute',top:827,left:1180,width:320,textAlign:'center',fontSize:25,opacity:background?0:reveal}}>Applications</div>
  <div style={{position:'absolute',top:950,width:'100%',textAlign:'center',opacity:reveal}}><div style={{fontSize:38,fontWeight:500,letterSpacing:-.7}}>Drag to Applications</div><div style={{fontSize:21,color:'#74787a',marginTop:14}}>Then open msgblast from your Applications folder.</div></div>
 </AbsoluteFill>;
};
const Root=()=> <><Composition id="Onboarding" component={Scene} defaultProps={{withAudio:true}} width={1920} height={1200} fps={30} durationInFrames={240}/><Composition id="OnboardingSilent" component={Scene} width={1920} height={1200} fps={30} durationInFrames={240}/><Composition id="FinderBackground" component={()=> <Scene background/>} width={1920} height={1200} fps={30} durationInFrames={1}/><Composition id="IPhonePromo" component={IPhonePromo} width={1080} height={1920} fps={PROMO_FPS} durationInFrames={PROMO_FRAMES}/></>;
registerRoot(Root);
