// Draws the selected pad-plus-Abe's-bezel-engraving app-icon artwork. The generated PNGs can be used
// to populate an iconset; this script only writes to the requested output path.
//
//   swift scripts/genicon.swift <output.iconset>
//
// Emits the ten PNGs `iconutil -c icns` expects.

import AppKit
import CoreText

let canvas: CGFloat = 1024

func rgb(_ packed: Int) -> NSColor {
    NSColor(
        srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
        green: CGFloat((packed >> 8) & 0xFF) / 255,
        blue: CGFloat(packed & 0xFF) / 255,
        alpha: 1
    )
}

func cgColor(_ packed: Int, alpha: CGFloat = 1) -> CGColor {
    rgb(packed).withAlphaComponent(alpha).cgColor
}

enum Cell {
    case key(Int)
    case dial
    case joystick
    case caseMark
    case empty
}

// The actual Creator Micro 2 surface, viewed from above. The bottom-left
// circular case mark is not a key; the dial and joystick flank the top keys.
let surface: [[Cell]] = [
    [.dial, .key(1), .key(0), .joystick],
    [.key(2), .key(3), .key(4), .key(5)],
    [.key(6), .key(7), .key(8), .key(9)],
    [.caseMark, .key(10), .key(11), .key(12)],
]

func roundedRect(_ frame: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(
    _ path: CGPath,
    in bounds: CGRect,
    top: Int,
    bottom: Int,
    ctx: CGContext
) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(top).cgColor, rgb(bottom).cgColor] as CFArray,
        locations: [0, 1]
    )!

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: []
    )
    ctx.restoreGState()
}

func keyColors(_ key: Int) -> (top: Int, bottom: Int) {
    switch key {
    case 0, 4: return (0x54DCA5, 0x1E9E7C)
    case 1: return (0xF5D77A, 0xE98B2F)
    case 2, 5: return (0x68B9F2, 0x315FAD)
    case 3: return (0xF7857F, 0xD94B51)
    case 6: return (0xB99AF4, 0x7253C0)
    case 7: return (0x63D2C2, 0x218579)
    default: return (0x71839A, 0x40516A)
    }
}

func drawKey(_ key: Int, in frame: CGRect, ctx: CGContext) {
    let colors = keyColors(key)
    let radius = frame.width * 0.17
    let path = roundedRect(frame, radius: radius)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -frame.height * 0.035),
        blur: frame.height * 0.065,
        color: cgColor(0x050914, alpha: 0.48)
    )
    ctx.addPath(path)
    ctx.setFillColor(cgColor(colors.bottom))
    ctx.fillPath()
    ctx.restoreGState()

    fillGradient(path, in: frame, top: colors.top, bottom: colors.bottom, ctx: ctx)

    ctx.addPath(path)
    ctx.setStrokeColor(cgColor(0xFFFFFF, alpha: key < 6 ? 0.42 : 0.27))
    ctx.setLineWidth(max(2, frame.width * 0.035))
    ctx.strokePath()

    let highlight = CGRect(
        x: frame.minX + frame.width * 0.20,
        y: frame.maxY - frame.height * 0.14,
        width: frame.width * 0.42,
        height: max(2, frame.height * 0.028)
    )
    ctx.addPath(roundedRect(highlight, radius: highlight.height / 2))
    ctx.setFillColor(cgColor(0xFFFFFF, alpha: key < 6 ? 0.34 : 0.23))
    ctx.fillPath()
}

func drawDial(in frame: CGRect, ctx: CGContext) {
    let dial = frame.insetBy(dx: frame.width * 0.11, dy: frame.height * 0.11)
    let path = CGPath(ellipseIn: dial, transform: nil)
    fillGradient(path, in: dial, top: 0x46536A, bottom: 0x242F42, ctx: ctx)
    ctx.addPath(path)
    ctx.setStrokeColor(cgColor(0x8B99AD, alpha: 0.63))
    ctx.setLineWidth(max(2, frame.width * 0.035))
    ctx.strokePath()

    let indicator = CGRect(
        x: dial.midX - dial.width * 0.045,
        y: dial.maxY - dial.height * 0.31,
        width: dial.width * 0.09,
        height: dial.height * 0.23
    )
    ctx.addPath(roundedRect(indicator, radius: indicator.width / 2))
    ctx.setFillColor(cgColor(0xD4DCE8, alpha: 0.92))
    ctx.fillPath()
}

func drawJoystick(in frame: CGRect, ctx: CGContext) {
    let joystick = frame.insetBy(dx: frame.width * 0.11, dy: frame.height * 0.11)
    let path = CGPath(ellipseIn: joystick, transform: nil)
    fillGradient(path, in: joystick, top: 0x46536A, bottom: 0x242F42, ctx: ctx)
    ctx.addPath(path)
    ctx.setStrokeColor(cgColor(0x8B99AD, alpha: 0.63))
    ctx.setLineWidth(max(2, frame.width * 0.035))
    ctx.strokePath()

    let arm = joystick.width * 0.22
    ctx.setStrokeColor(cgColor(0xD4DCE8, alpha: 0.84))
    ctx.setLineWidth(max(2, frame.width * 0.05))
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: joystick.midX - arm, y: joystick.midY - arm))
    ctx.addLine(to: CGPoint(x: joystick.midX + arm, y: joystick.midY + arm))
    ctx.move(to: CGPoint(x: joystick.midX - arm, y: joystick.midY + arm))
    ctx.addLine(to: CGPoint(x: joystick.midX + arm, y: joystick.midY - arm))
    ctx.strokePath()
}

func drawCaseMark(in frame: CGRect, ctx: CGContext) {
    let mark = frame.insetBy(dx: frame.width * 0.30, dy: frame.height * 0.30)
    let path = CGPath(ellipseIn: mark, transform: nil)
    fillGradient(path, in: mark, top: 0x344155, bottom: 0x1C2637, ctx: ctx)
    ctx.addPath(path)
    ctx.setStrokeColor(cgColor(0x91A0B4, alpha: 0.47))
    ctx.setLineWidth(max(2, frame.width * 0.03))
    ctx.strokePath()
}

func drawBezelEngraving(in pad: CGRect, inset: CGFloat, ctx: CGContext) {
    let fontSize = pad.width * 0.033
    let font = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(0xC5CEDA, alpha: 0.68),
        NSAttributedString.Key(kCTKernAttributeName as String): fontSize * 0.13,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ABE'S", attributes: attributes))
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    let bandCenterY = pad.maxY - inset * 0.50
    let baseline = bandCenterY - (ascent - descent) / 2

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: cgColor(0x07101D, alpha: 0.8))
    ctx.textPosition = CGPoint(x: pad.midX - textWidth / 2, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func draw(in ctx: CGContext) {
    // The rounded deep-blue/navy icon field is separate from the physical pad.
    let background = CGRect(x: 96, y: 96, width: 832, height: 832)
    let backgroundPath = roundedRect(background, radius: 186)
    fillGradient(backgroundPath, in: background, top: 0x26344F, bottom: 0x101827, ctx: ctx)
    ctx.addPath(backgroundPath)
    ctx.setStrokeColor(cgColor(0x60708B, alpha: 0.72))
    ctx.setLineWidth(3)
    ctx.strokePath()

    let padSide = background.width * 0.88
    let pad = CGRect(
        x: background.midX - padSide / 2,
        y: background.midY - padSide / 2,
        width: padSide,
        height: padSide
    )
    let padPath = roundedRect(pad, radius: padSide * 0.12)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -padSide * 0.012),
        blur: padSide * 0.035,
        color: cgColor(0x030711, alpha: 0.38)
    )
    ctx.addPath(padPath)
    ctx.setFillColor(cgColor(0x202B3D))
    ctx.fillPath()
    ctx.restoreGState()

    fillGradient(padPath, in: pad, top: 0x35445D, bottom: 0x1B2536, ctx: ctx)
    ctx.addPath(padPath)
    ctx.setStrokeColor(cgColor(0x8795AA, alpha: 0.43))
    ctx.setLineWidth(4)
    ctx.strokePath()

    let gap = padSide * 0.035
    let inset = padSide * 0.095
    let cellSide = (padSide - inset * 2 - gap * 3) / 4

    for (rowIndex, row) in surface.enumerated() {
        let y = pad.maxY - inset - cellSide - CGFloat(rowIndex) * (cellSide + gap)
        for (column, cell) in row.enumerated() {
            let x = pad.minX + inset + CGFloat(column) * (cellSide + gap)
            let frame = CGRect(x: x, y: y, width: cellSide, height: cellSide)

            switch cell {
            case .key(let key):
                drawKey(key, in: frame, ctx: ctx)
            case .dial:
                drawDial(in: frame, ctx: ctx)
            case .joystick:
                drawJoystick(in: frame, ctx: ctx)
            case .caseMark:
                drawCaseMark(in: frame, ctx: ctx)
            case .empty:
                break
            }
        }
    }

    // Fine, low-contrast engraving on the physical top bezel, away from keys.
    drawBezelEngraving(in: pad, inset: inset, ctx: ctx)
}

func writePNG(size: Int, scale: Int, to url: URL) {
    let pixels = size * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not make bitmap \(pixels)px") }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: genicon.swift <output.iconset>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    writePNG(size: size, scale: 1, to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(size: size, scale: 2, to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
