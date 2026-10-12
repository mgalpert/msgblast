import Foundation
import WebKit

public enum WebPerformanceSignal {
    case request(WebSendAttempt)
    case status(WebSendAttempt)
    case cancellationRequested(WebSendAttempt)
    case canceled(WebSendAttempt)
    case snapshot(comparisonID: UUID, documentID: String, snapshot: WebPageSnapshot)
    case gap(comparisonID: UUID, reason: String)
}

// Serialize visible conversation text without applying receipt normalization.
// Block boundaries are semantic line breaks; pre/code content retains its bytes.
enum WebPerformanceText {
    static let script = #"""
    const performanceText = root => {
      let result='',trailingBoundary=0;
      const append = text => {if(text){result+=text;trailingBoundary=0;}};
      const boundary = count => {
        if (!result) return;
        const existing=(result.match(/\n*$/)||[''])[0].length;
        if(existing<count) {const extra=count-existing;result+='\n'.repeat(extra);trailingBoundary+=extra;}
      };
      const block=/^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DIV|DL|DT|DD|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|SECTION|TABLE|TR|UL)$/;
      const walk = (node,isRoot=false,preserve=false) => {
        if(node.nodeType===Node.TEXT_NODE) {
          const text=node.nodeValue||'';
          if(!preserve && !text.trim() && text.includes('\n')) return;
          append(text); return;
        }
        if(node.nodeType!==Node.ELEMENT_NODE) return;
        if(node.tagName==='BR') {append('\n');return;}
        if(node.tagName==='PRE') {boundary(2);append(node.textContent||'');boundary(2);return;}
        preserve=node.__msgblastPreformatted ?? preserve;
        const isBlock=block.test(node.tagName)&&!isRoot;
        if(isBlock)boundary(1);
        for(const child of node.childNodes)walk(child,false,preserve);
        if(isBlock)boundary(node.tagName==='P'?2:1);
      };
      walk(root,true);
      return trailingBoundary?result.slice(0,-trailingBoundary):result;
    };
    """#
}

/// Notifies native code of conversation mutations only. Extracted content still
/// goes through the existing provider adapter and page-generation ownership checks.
@MainActor
final class WebPerformanceObserver: NSObject, WKScriptMessageHandler {
    weak var session: WebAgentSession?
    init(session: WebAgentSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "msgblastPerformance", let view = message.webView,
              let body = message.body as? [String: String], body["signal"] == "conversation-changed" else { return }
        session?.performanceMutation(in: view)
    }
    static let install = #"""
    if (!globalThis.__msgblastPerformanceObserver) {
      const root = document.querySelector('[aria-label="Chat messages"],#hatch-chat-scroll,[data-testid="conversation-turns"],main');
      if (root) {
        let pending;
        const notify = () => { clearTimeout(pending); pending=setTimeout(()=>window.webkit.messageHandlers.msgblastPerformance.postMessage({signal:'conversation-changed'}),100); };
        const observer = new MutationObserver(notify);
        observer.observe(root,{subtree:true,childList:true,characterData:true});
        globalThis.__msgblastPerformanceObserver={observer,stop:()=>{observer.disconnect();clearTimeout(pending);}};
      }
    }
    """#
    static let remove = "globalThis.__msgblastPerformanceObserver?.stop(); delete globalThis.__msgblastPerformanceObserver;"
}
