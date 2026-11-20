// Renders the app icon (original artwork: a TV screen with a remote control in front of it, on a deep
// cobalt blue that evokes Samsung TVs without using any Samsung logo or wordmark) as 1024x1024 PNGs
// for the light, dark and tinted appearances into the AppIcon asset catalog.
// Usage: swift scripts/render-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("App/FreeRemote/Resources/Assets.xcassets/AppIcon.appiconset")

struct Palette {
    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    var body: CGColor
    var bodyShade: CGColor
    var ring: CGColor
    var centre: CGColor
    var power: CGColor
    var buttons: CGColor
    var tvFrame: CGColor
    var tvScreenTop: CGColor
    var tvScreenBottom: CGColor
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gray(_ white: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: white, green: white, blue: white, alpha: alpha)
}

let palettes: [(file: String, palette: Palette)] = [
    ("AppIcon-Light.png", Palette(
        backgroundTop: rgb(0x2341C8), backgroundBottom: rgb(0x0E1B70),
        body: rgb(0xFFFFFF), bodyShade: rgb(0xE4E9F5),
        ring: rgb(0x1428A0), centre: rgb(0x2F55E8), power: rgb(0xFF4B3E), buttons: rgb(0x9AA6C4),
        tvFrame: rgb(0x0A1250), tvScreenTop: rgb(0x5C82FF), tvScreenBottom: rgb(0x2341C8)
    )),
    ("AppIcon-Dark.png", Palette(
        backgroundTop: rgb(0x1C1F2A), backgroundBottom: rgb(0x07080C),
        body: rgb(0x2C3142), bodyShade: rgb(0x232736),
        ring: rgb(0x6F95FF), centre: rgb(0x4C7DFF), power: rgb(0xFF5A4E), buttons: rgb(0x59617A),
        tvFrame: rgb(0x000000), tvScreenTop: rgb(0x2341C8), tvScreenBottom: rgb(0x0E1B70)
    )),
    ("AppIcon-Tinted.png", Palette(
        backgroundTop: gray(0), backgroundBottom: gray(0),
        body: gray(0.92), bodyShade: gray(0.80),
        ring: gray(0.30), centre: gray(0.55), power: gray(0.45), buttons: gray(0.55),
        tvFrame: gray(0.20), tvScreenTop: gray(0.62), tvScreenBottom: gray(0.40)
    )),
]

func render(_ palette: Palette) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let s = CGFloat(size)

    // Background: full-bleed vertical gradient (the system applies the corner mask).
    let gradient = CGGradient(
        colorsSpace: space, colors: [palette.backgroundTop, palette.backgroundBottom] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // TV: a wide screen with a thin bezel and a small stand, upper left, behind the remote.
    // Core Graphics origin is bottom-left; y values below are measured from the bottom.
    let tv = CGRect(x: 110, y: 430, width: 640, height: 400)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: gray(0, alpha: 0.35))
    context.addPath(CGPath(roundedRect: tv, cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.setFillColor(palette.tvFrame)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    let screen = tv.insetBy(dx: 26, dy: 26)
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.clip()
    let screenGradient = CGGradient(
        colorsSpace: space, colors: [palette.tvScreenTop, palette.tvScreenBottom] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(screenGradient, start: CGPoint(x: screen.minX, y: screen.maxY),
                               end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    context.restoreGState()
    context.setFillColor(palette.tvFrame)
    context.fill(CGRect(x: tv.midX - 18, y: tv.minY - 70, width: 36, height: 70))
    context.addPath(CGPath(roundedRect: CGRect(x: tv.midX - 130, y: tv.minY - 92, width: 260, height: 30),
                           cornerWidth: 15, cornerHeight: 15, transform: nil))
    context.fillPath()

    // Remote body: a tall rounded rectangle, slightly tilted for character, in front of the TV.
    context.saveGState()
    context.translateBy(x: s * 0.66, y: s * 0.40)
    context.scaleBy(x: 0.72, y: 0.72)
    context.rotate(by: -12 * .pi / 180)
    let bodyWidth: CGFloat = 360, bodyHeight: CGFloat = 760
    let body = CGRect(x: -bodyWidth / 2, y: -bodyHeight / 2, width: bodyWidth, height: bodyHeight)
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: gray(0, alpha: 0.35))
    context.addPath(CGPath(roundedRect: body, cornerWidth: 150, cornerHeight: 150, transform: nil))
    context.setFillColor(palette.body)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // Subtle lower shade band to give the body some depth.
    context.saveGState()
    context.addPath(CGPath(roundedRect: body, cornerWidth: 150, cornerHeight: 150, transform: nil))
    context.clip()
    context.setFillColor(palette.bodyShade)
    context.fill(CGRect(x: body.minX, y: body.minY, width: bodyWidth, height: 230))
    context.restoreGState()

    // Power dot near the top.
    let power = CGRect(x: -34, y: 270, width: 68, height: 68)
    context.setFillColor(palette.power)
    context.fillEllipse(in: power)

    // Circular D-pad: a ring with a centre OK button.
    let ringRadius: CGFloat = 120, ringWidth: CGFloat = 44, ringCentreY: CGFloat = 60
    context.setStrokeColor(palette.ring)
    context.setLineWidth(ringWidth)
    context.strokeEllipse(in: CGRect(
        x: -ringRadius, y: ringCentreY - ringRadius, width: ringRadius * 2, height: ringRadius * 2
    ))
    context.setFillColor(palette.centre)
    context.fillEllipse(in: CGRect(x: -52, y: ringCentreY - 52, width: 104, height: 104))

    // Two pill buttons below the D-pad.
    context.setFillColor(palette.buttons)
    for x in [CGFloat(-110), 30] {
        context.addPath(CGPath(
            roundedRect: CGRect(x: x, y: -200, width: 80, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil
        ))
        context.fillPath()
    }
    context.restoreGState()

    return context.makeImage()!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (file, palette) in palettes {
    let url = outputDirectory.appendingPathComponent(file)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, render(palette), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
    print("wrote \(url.path)")
}
