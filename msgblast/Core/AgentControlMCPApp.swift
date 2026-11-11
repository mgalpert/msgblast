import Foundation

/// The comparison view hosts render beside a tool result (MCP Apps). Read only: the HTML never sends.
public enum AgentControlMCPApp {
    public static let viewURI = "ui://msgblast/comparison"
    public static let mimeType = "text/html;profile=mcp-app"
    public static let extensionID = "io.modelcontextprotocol/ui"

    /// Advertised under `capabilities.extensions` and, on `initialize`, `capabilities.experimental`.
    static func extensionCapability() -> [String: Any] {
        [extensionID: ["mimeTypes": [mimeType]]]
    }

    /// `_meta` on the UI resource in both `resources/list` and `resources/read`. No domain or CSP:
    /// the view makes no network requests, and domain is only for remote servers in Claude.
    static func resourceMeta() -> [String: Any] {
        ["ui": ["prefersBorder": true], "openai/ui": ["availableDisplayModes": ["inline", "fullscreen"]]]
    }

    /// Extra `_meta` for tools that open the view. The list tool is the global entry point and accepts `{}`.
    static func toolMeta(_ name: String) -> [String: Any]? {
        switch name {
        case "msgblast_comparison_read", "msgblast_blast_wait":
            ["ui": ["resourceUri": viewURI]]
        case "msgblast_comparisons_list":
            ["ui": ["resourceUri": viewURI], "openai/ui": ["entrypoints": [["type": "global"]]]]
        default: nil
        }
    }

    static func listing() -> [String: Any] {
        ["uri": viewURI, "name": "msgblast comparison",
         "description": "Side-by-side comparison of replies. Read only.",
         "mimeType": mimeType, "_meta": resourceMeta()]
    }

    static func contents() -> [String: Any] {
        ["contents": [["uri": viewURI, "mimeType": mimeType, "text": AgentControlMCPAppHTML.html, "_meta": resourceMeta()]]]
    }
}
