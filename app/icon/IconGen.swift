#!/usr/bin/env swift
// Procedurally render the Jnobs app icon into an .iconset directory of PNGs.
//
// Usage:   swift icon/IconGen.swift <output-iconset-dir>
//
// The icon is a stylized hardware knob shot from above:
//   * Rounded-square charcoal panel with subtle mint-tinted vignette.
//   * Concentric knob body with a 3D radial shaded cap.
//   * Bold mint-green indicator pointing at ~10 o'clock (a covert J).
//   * Three mint LED "fan" dots arcing across the top.
//
// We render each .iconset size natively (rather than downscaling one master) so
// thin strokes stay crisp at 16x16.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Brand palette

struct Brand {
    static let mint        = CGColor(red: 0/255,   green: 220/255, blue:  90/255, alpha: 1)
    static let mintGlow    = CGColor(red: 64/255,  green: 240/255, blue: 140/255, alpha: 1)
    static let mintDim     = CGColor(red: 0/255,   green: 110/255, blue:  55/255, alpha: 1)
    static let panelTop    = CGColor(red: 28/255,  green:  31/255, blue:  36/255, alpha: 1)
    static let panelBot    = CGColor(red: 12/255,  green:  14/255, blue:  18/255, alpha: 1)
    static let knobOuter   = CGColor(red: 40/255,  green:  44/255, blue:  50/255, alpha: 1)
    static let knobMid     = CGColor(red: 70/255,  green:  76/255, blue:  84/255, alpha: 1)
    static let knobInner   = CGColor(red: 22/255,  green:  25/255, blue:  30/255, alpha: 1)
    static let highlight   = CGColor(red: 1,       green: 1,       blue: 1,       alpha: 0.18)
    static let bezel       = CGColor(red: 0,       green: 0,       blue: 0,       alpha: 0.55)
}

// MARK: - Drawing

func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // 1. Rounded-square panel with vertical gradient.
    let corner = size * 0.225  // macOS 26 squircle-ish
    let panel = CGPath(roundedRect: rect.insetBy(dx: size * 0.012, dy: size * 0.012),
                       cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(panel)
    ctx.clip()

    let gradient = CGGradient(colorsSpace: nil,
                              colors: [Brand.panelTop, Brand.panelBot] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end:   CGPoint(x: 0, y: 0),
                           options: [])

    // Mint vignette behind the knob.
    let vignette = CGGradient(colorsSpace: nil,
                              colors: [Brand.mintDim.copy(alpha: 0.35)!,
                                       Brand.panelBot.copy(alpha: 0)!] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(vignette,
                           startCenter: CGPoint(x: size/2, y: size * 0.45), startRadius: 0,
                           endCenter:   CGPoint(x: size/2, y: size * 0.45), endRadius: size * 0.45,
                           options: [])

    // Subtle inner highlight along the top edge.
    if size >= 64 {
        ctx.setStrokeColor(Brand.highlight)
        ctx.setLineWidth(size * 0.006)
        ctx.addPath(panel)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // 2. Knob body — three concentric rings + radial shaded cap.
    let center = CGPoint(x: size/2, y: size * 0.46)
    let bodyR  = size * 0.30
    let midR   = size * 0.265
    let capR   = size * 0.225

    // Outer ring (matte body).
    ctx.setFillColor(Brand.knobOuter)
    ctx.addArc(center: center, radius: bodyR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Bezel shadow under the outer ring.
    if size >= 32 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.025,
                      color: Brand.bezel)
        ctx.setFillColor(Brand.knobOuter)
        ctx.addArc(center: center, radius: bodyR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Middle ring (the rotatable surface — slightly lighter).
    ctx.setFillColor(Brand.knobMid)
    ctx.addArc(center: center, radius: midR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Cap with radial gradient (from top-left highlight to bottom shadow).
    ctx.saveGState()
    ctx.addArc(center: center, radius: capR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    let capGrad = CGGradient(colorsSpace: nil,
                             colors: [Brand.knobMid, Brand.knobInner] as CFArray,
                             locations: [0, 1])!
    ctx.drawRadialGradient(capGrad,
                           startCenter: CGPoint(x: center.x - capR*0.35, y: center.y + capR*0.4),
                           startRadius: 0,
                           endCenter: center, endRadius: capR * 1.2,
                           options: [])
    ctx.restoreGState()

    // Cap rim highlight (very subtle inner ring).
    if size >= 64 {
        ctx.setStrokeColor(Brand.highlight)
        ctx.setLineWidth(size * 0.004)
        ctx.addArc(center: center, radius: capR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
    }

    // 3. Mint indicator pointing at ~11 o'clock.
    // CG bitmap is +y up; angle 0 is along +x. Upper-left ≈ 2pi/3.
    let angle = CGFloat.pi * (2.0/3.0)
    let indicatorOuter = capR * 0.92
    let indicatorInner = capR * 0.42
    let pStart = CGPoint(x: center.x + cos(angle) * indicatorInner,
                         y: center.y + sin(angle) * indicatorInner)
    let pEnd   = CGPoint(x: center.x + cos(angle) * indicatorOuter,
                         y: center.y + sin(angle) * indicatorOuter)
    ctx.setLineCap(.round)
    ctx.setLineWidth(size * 0.038)
    ctx.setStrokeColor(Brand.mint)
    ctx.move(to: pStart); ctx.addLine(to: pEnd)
    ctx.strokePath()

    // Indicator glow.
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.04, color: Brand.mintGlow)
        ctx.setLineWidth(size * 0.022)
        ctx.setStrokeColor(Brand.mintGlow.copy(alpha: 0.9)!)
        ctx.move(to: pStart); ctx.addLine(to: pEnd)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. Three LED "fan" dots arcing across the top of the knob.
    // CG bitmap is +y up — upper arc spans pi/4..3pi/4 (45° / 90° / 135°).
    let ledR    = size * 0.022
    let ledRing = bodyR + size * 0.06
    let angles: [CGFloat] = [.pi * 0.75, .pi * 0.50, .pi * 0.25]
    for a in angles {
        let p = CGPoint(x: center.x + cos(a) * ledRing,
                        y: center.y + sin(a) * ledRing)
        if size >= 32 {
            // Glow halo.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: size * 0.05, color: Brand.mintGlow)
            ctx.setFillColor(Brand.mintGlow.copy(alpha: 0.9)!)
            ctx.addArc(center: p, radius: ledR * 1.1, startAngle: 0, endAngle: .pi*2, clockwise: false)
            ctx.fillPath()
            ctx.restoreGState()
        }
        // Bright core.
        ctx.setFillColor(Brand.mintGlow)
        ctx.addArc(center: p, radius: ledR, startAngle: 0, endAngle: .pi*2, clockwise: false)
        ctx.fillPath()
    }
}

// MARK: - PNG writing

func writePNG(_ ctx: CGContext, to url: URL) throws {
    guard let image = ctx.makeImage() else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "destination failed"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "finalize failed"])
    }
}

func makeContext(size: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: size, height: size,
                     bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: IconGen.swift <iconset-output-dir>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Spec { let name: String; let pixels: Int }
let specs: [Spec] = [
    .init(name: "icon_16x16.png",       pixels: 16),
    .init(name: "icon_16x16@2x.png",    pixels: 32),
    .init(name: "icon_32x32.png",       pixels: 32),
    .init(name: "icon_32x32@2x.png",    pixels: 64),
    .init(name: "icon_128x128.png",     pixels: 128),
    .init(name: "icon_128x128@2x.png",  pixels: 256),
    .init(name: "icon_256x256.png",     pixels: 256),
    .init(name: "icon_256x256@2x.png",  pixels: 512),
    .init(name: "icon_512x512.png",     pixels: 512),
    .init(name: "icon_512x512@2x.png",  pixels: 1024),
]

for spec in specs {
    let ctx = makeContext(size: spec.pixels)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    drawAppIcon(ctx, size: CGFloat(spec.pixels))
    let url = outDir.appendingPathComponent(spec.name)
    try writePNG(ctx, to: url)
    print("  \(spec.name) (\(spec.pixels)px)")
}

print("OK Rendered \(specs.count) PNGs into \(outDir.path)")
