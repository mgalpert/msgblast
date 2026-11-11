import CoreGraphics
import Foundation

func area(_ window: [String: Any]) -> CGFloat {
    guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return 0 }
    return rect.width * rect.height
}

let pid = Int32(CommandLine.arguments[1])!
for _ in 0..<60 {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    if let best = mine.max(by: { area($0) < area($1) }), let id = best[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
    Thread.sleep(forTimeInterval: 1)
}
FileHandle.standardError.write("no window for pid \(pid)\n".data(using: .utf8)!)
exit(1)
