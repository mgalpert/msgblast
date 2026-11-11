import AppKit

func rgba(_ path: String) -> (width: Int, height: Int, bytes: [UInt8]) {
    let image = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!.cgImage!
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, bytes)
}

let before = rgba(CommandLine.arguments[1]), after = rgba(CommandLine.arguments[2])
guard before.width == after.width, before.height == after.height else {
    print("size differs: \(before.width)x\(before.height) vs \(after.width)x\(after.height)")
    exit(0)
}
var differing: [(Int, Int)] = []
var diff = after.bytes
for pixel in 0..<(before.width * before.height) {
    let i = pixel * 4
    if before.bytes[i..<i + 4] != after.bytes[i..<i + 4] {
        differing.append((pixel % before.width, pixel / before.width))
        diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0; diff[i + 3] = 255
    } else {
        let gray = UInt8(200 + (Int(after.bytes[i]) + Int(after.bytes[i + 1]) + Int(after.bytes[i + 2])) / 3 / 5)
        diff[i] = gray; diff[i + 1] = gray; diff[i + 2] = gray; diff[i + 3] = 255
    }
}
print("\(before.width)x\(before.height): \(differing.count) differing pixels")
print("first differing (x, y): \(differing.prefix(20).map { "(\($0.0), \($0.1))" }.joined(separator: " "))")
diff.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: before.width, height: before.height, bitsPerComponent: 8, bytesPerRow: before.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
