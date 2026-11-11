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
var differing = 0
var diff = after.bytes
for pixel in 0..<(before.width * before.height) {
    let i = pixel * 4
    if before.bytes[i..<i + 4] != after.bytes[i..<i + 4] {
        differing += 1
        diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0; diff[i + 3] = 255
    } else {
        diff[i + 3] = 60
    }
}
print("\(before.width)x\(before.height): \(differing) differing pixels")
diff.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: before.width, height: before.height, bitsPerComponent: 8, bytesPerRow: before.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
