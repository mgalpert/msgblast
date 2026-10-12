import Foundation

// Compile against stream A's actual PerformanceModels/Store/Recorder, never a copied event model.
// Synthetic calls exercise the portable envelope, not a live provider DOM or native cloud UI.
@main struct NativeContractFixture {
 static func main() throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let recorder=try PerformanceRecorder(directory: directory, fixture: true);recorder.enabled=true
  let comparison="native-contract-comparison"
  let agent=PerformanceAgent(id:"native-configured-agent",name:"Renamed synthetic agent",connection:.website,model:"synthetic-model")
  var time:Int64=1000
  func stamp()->PerformanceStamp {time+=250;return .init(clockID:"native-fixture-clock",monotonicMS:time,wallMS:1791760000000)}
  let turn=try recorder.beginTurn(comparisonID:comparison,agent:agent,text:"Explain a reversible choice.",scope:.shared,at:stamp())!
  _=try recorder.record(.observationState,comparisonID:comparison,agent:agent,method:"structured conversation messages; earlier history omitted",reason:"document-start",at:stamp())
  _=try recorder.record(.dispatched,comparisonID:comparison,agent:agent,turnID:turn,method:"native dispatch",at:stamp())
  _=try recorder.record(.submitted,comparisonID:comparison,agent:agent,turnID:turn,method:"submission receipt; not delivery",at:stamp())
  _=try recorder.record(.observationState,comparisonID:comparison,agent:agent,reason:"generating",at:stamp())
  try recorder.reply(comparisonID:comparison,agent:agent,messageID:"document:reply-1",text:"I will explain it.",turnID:turn,sourceMS:1791760000000,method:"scoped DOM observer with 1 s polling fallback; native receipt; not tokens",at:stamp())
  try recorder.reply(comparisonID:comparison,agent:agent,messageID:"document:reply-2",text:"Try a small reversible change first.",turnID:turn,method:"scoped DOM observer with 1 s polling fallback; native receipt; not tokens",at:stamp())
  _=try recorder.record(.observationState,comparisonID:comparison,agent:agent,reason:"idle",at:stamp())
  _=try recorder.record(.completed,comparisonID:comparison,agent:agent,turnID:turn,method:"observed running-to-idle in same document; answer completion only",at:stamp())
  try recorder.setFeedback(comparisonID:comparison,agentID:agent.id,messageID:"document:reply-2",selection:.favorite)
  _=try recorder.record(.gap,comparisonID:comparison,agent:agent,reason:"synthetic sleep gap",at:stamp())
  _=try recorder.record(.outcome,comparisonID:comparison,agent:agent,turnID:turn,reason:"unsupported",at:stamp())
  try recorder.stop(reason:"disabled")
  let chunk=PerformanceUploadChunk(id:"native-contract-chunk",sessionID:comparison,sequenceStart:1,events:recorder.events)
  let bytes=try PerformanceCanonical.bytes(chunk)
  try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  try (PerformanceCanonical.hash(bytes)+"\n").write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
 }
}
