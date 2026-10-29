// Loopback-only fixture around the actual handler. No production service or R2.
import http from 'node:http';
import {handleFeedback} from '../../feedback/worker.mjs';
const objects = new Map();
const requests = [];
let releaseHeldResponse;
const env = {FEEDBACK_RATE_LIMIT:{limit:async()=>({success:true})},FEEDBACK_BUCKET:{
 head:async key=>objects.get(key),
 put:async(key,value,options)=>{
  if(objects.has(key))return null;
  const saved={value,customMetadata:options.customMetadata};objects.set(key,saved);return saved;
 }
}};
const server = http.createServer(async(req,res)=>{
 if(req.url==='/fixture-status') {
  res.setHeader('content-type','application/json');res.end(JSON.stringify({requests,stored:objects.size,held:!!releaseHeldResponse}));return;
 }
 if(req.url==='/fixture-release') {releaseHeldResponse?.();releaseHeldResponse=undefined;res.end('released');return;}
 if(req.url!='/api/feedback'||req.method!=='POST'){res.writeHead(404);res.end();return;}
 const chunks=[];let size=0;
 for await(const chunk of req){size+=chunk.length;if(size>65536){res.writeHead(413);res.end();return;}chunks.push(chunk);}
 const bytes=Buffer.concat(chunks);
 const body=JSON.parse(bytes);requests.push({id:body.id,note:body.note});
 const response=await handleFeedback(new Request('http://127.0.0.1/api/feedback',{method:'POST',headers:{'content-type':'application/json'},body:bytes}),env);
 if(body.note==='Synthetic close while sending') await new Promise(resolve=>{releaseHeldResponse=resolve;});
 // Model an uncertain acknowledgement after a successful durable write.
 const status=requests.length===1&&response.status===201?503:response.status;
 res.writeHead(status,Object.fromEntries(response.headers));res.end(status===503?'{}':await response.text());
});
server.listen(Number(process.argv[2]||8128),'127.0.0.1',()=>console.log('Crash intake fixture listening on loopback'));
