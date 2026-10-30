// The app's icon, drawn rather than exported: roko's Eclipse, the same mark
// as the iPhone app's default icon (Scripts/make_alternate_icons.swift in the
// iOS repository), so it stays a crisp vector at every size. The icon puts it
// on a plate: a Dock icon has to be an opaque square.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")

/// A dev build (build.sh) puts the mark on a yellow plate rather than the dark
/// one, as Chrome Canary does, so the build from a worktree and the installed
/// app are told apart at a glance: in the Dock, in ⌘Tab, at 16 points.
let dev = ProcessInfo.processInfo.environment["SEARCH_DEV"] == "1"
/// The iPhone icon's colours: the light ink (Theme.ink) on the dark canvas
/// (Theme.canvas). A dev build turns it round: dark mark on yellow.
let inkDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0F / 255.0, alpha: 1)
let inkLight = NSColor(srgbRed: 0xE7 / 255.0, green: 0xE7 / 255.0, blue: 0xE4 / 255.0, alpha: 1)
let plateColor = dev ? NSColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 1) : inkDark
let markColor = dev ? inkDark : inkLight
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The Eclipse on its own 600 × 600 canvas: a disc of radius 300, with a hole
/// of radius 150 moved 94 to the right of its centre. The same shape is
/// Design.swift's `Logomark`.
let canvas = 600.0
/// On the iPhone the mark is 600 of a 1024 tile; on a Mac plate (824 of 1024)
/// it keeps that share of the plate.
let fraction: CGFloat = 600.0 / 1024
let markPathData = "M0 300A300 300 0 1 0 600 300A300 300 0 1 0 0 300ZM244 300A150 150 0 1 0 544 300A150 150 0 1 0 244 300Z"

func markPath(in plate: NSRect) -> NSBezierPath {
    let scale = plate.width * fraction / canvas
    let side = canvas * scale
    let origin = NSPoint(x: plate.midX - side / 2, y: plate.midY - side / 2)
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    path.appendOval(in: NSRect(x: origin.x, y: origin.y, width: side, height: side))
    let hole = 150 * scale
    path.appendOval(in: NSRect(x: origin.x + 244 * scale, y: origin.y + side / 2 - hole, width: hole * 2, height: hole * 2))
    return path
}

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // The Dock's own shadow, cast downward from above, tight.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 14 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    plateColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    markColor.setFill()
    markPath(in: plate).fill()
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    // The bitmap is asked for at the pixel size, whatever the screen thinks.
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")

// The same icon as an Icon Composer document, when a second path is given,
// so macOS 26 can show it Dark, Clear or Tinted: the plate and the mark are
// separate layers. The icon is already dark, so Dark keeps it; Tinted gets a
// light mark whose brightness the system tints. build.sh compiles it with
// actool; the images above stay the .icns.
if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    // An Icon Composer canvas is the plate, 1024 points across; the mark
    // takes the same share of it as it does of the plate drawn above.
    let side = 1024 * fraction
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(side)" height="\(side)" viewBox="0 0 600 600">\
    <path fill-rule="evenodd" fill="#E7E7E4" d="\(markPathData)"/></svg>
    """
    try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

    let light = #"{ "solid" : "srgb:0.90588,0.90588,0.89412,1.00000" }"#
    let dark = #"{ "solid" : "srgb:0.05490,0.05490,0.05882,1.00000" }"#
    let yellow = #"{ "solid" : "srgb:1.00000,0.80000,0.20000,1.00000" }"#
    let white = #"{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }"#
    // A dev build keeps its yellow in Dark too: the mark yellow on the dark plate.
    let plate = dev ? yellow : dark
    let mark = dev ? dark : light
    let json = """
    {
      "fill" : \(plate),
      "fill-specializations" : [
        { "value" : \(plate) },
        { "appearance" : "dark", "value" : \(dark) }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "name" : "mark",
              "image-name" : "mark.svg",
              "glass" : false,
              "fill-specializations" : [
                { "value" : \(mark) },
                { "appearance" : "dark", "value" : \(dev ? yellow : light) },
                { "appearance" : "tinted", "value" : \(white) }
              ]
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
