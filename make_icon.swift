import Cocoa

// Draws the app icon: an open two-page spread on a dark tile.
enum IconError: LocalizedError {
    case bitmapCreationFailed(Int)
    case graphicsContextFailed(Int)
    case pngEncodingFailed(Int)
    case iconutilFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed(let px):
            return "Failed to allocate \(px)x\(px) bitmap image rep."
        case .graphicsContextFailed(let px):
            return "Failed to create graphics context for \(px)x\(px) icon."
        case .pngEncodingFailed(let px):
            return "Failed to encode \(px)x\(px) icon as PNG."
        case .iconutilFailed(let status, let stderr):
            return "iconutil failed with exit code \(status)\(stderr.isEmpty ? "" : ": \(stderr)")."
        }
    }
}

func renderIconPNG(pixels px: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconError.bitmapCreationFailed(px)
    }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw IconError.graphicsContextFailed(px)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high
    let scale = CGFloat(px) / 1024.0
    ctx.cgContext.scaleBy(x: scale, y: scale)

    NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

    let paper = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)
    let ink = NSColor(calibratedRed: 0.55, green: 0.52, blue: 0.46, alpha: 1)
    for x in [222.0, 522.0] {
        paper.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 250, width: 280, height: 524), xRadius: 14, yRadius: 14).fill()
        ink.setFill()
        var y = 690.0
        while y > 300 {
            let w = (y < 340 && x > 500) ? 120.0 : 216.0
            NSBezierPath(roundedRect: NSRect(x: x + 32, y: y, width: w, height: 14), xRadius: 7, yRadius: 7).fill()
            y -= 38
        }
    }

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncodingFailed(px)
    }
    return pngData
}

func buildICNS(at outputURL: URL) throws {
    let fm = FileManager.default
    let iconsetURL = fm.temporaryDirectory
        .appendingPathComponent("TwoUp-\(ProcessInfo.processInfo.globallyUniqueString).iconset", isDirectory: true)
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconsetURL) }

    let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for entry in sizes {
        let data = try renderIconPNG(pixels: entry.pixels)
        try data.write(to: iconsetURL.appendingPathComponent(entry.name), options: .atomic)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    try process.run()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let message = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw IconError.iconutilFailed(process.terminationStatus, message)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make_icon.swift <output.icns|output.png>\n", stderr)
    exit(1)
}

let outputArg = CommandLine.arguments[1]
if outputArg.isEmpty || outputArg == "-h" || outputArg == "--help" {
    fputs("Usage: swift make_icon.swift <output.icns|output.png>\n", stderr)
    exit(outputArg == "-h" || outputArg == "--help" ? 0 : 1)
}

let outputURL = URL(fileURLWithPath: outputArg)
do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if outputURL.pathExtension.lowercased() == "png" {
        let data = try renderIconPNG(pixels: 1024)
        try data.write(to: outputURL, options: .atomic)
    } else {
        try buildICNS(at: outputURL)
    }
} catch {
    fputs("make_icon.swift: \(error.localizedDescription)\n", stderr)
    exit(1)
}
