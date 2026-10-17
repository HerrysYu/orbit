// Render app-icon background options around the same floating waving mascot, plus a side-by-side contact sheet.
// Usage: swift icon-options.swift <assetsDir> <outDir>
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let assets = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let S: CGFloat = 1024

func load(_ n: String) -> CIImage { CIImage(contentsOf: assets.appendingPathComponent("placeholder-\(n).png"))! }
func hex(_ v: UInt32) -> CIColor {
  CIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255)
}
func radial(_ inner: CIColor, _ outer: CIColor) -> CIImage {
  let g = CIFilter.radialGradient()
  g.center = CGPoint(x: S * 0.5, y: S * 0.62); g.radius0 = 0; g.radius1 = Float(S * 0.78)
  g.color0 = inner; g.color1 = outer
  return g.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}
/// Same floating, centred full-body pose with a soft contact shadow as tools/icon.swift variant B.
func composeFloating(_ char: CIImage, _ bg: CIImage, height: CGFloat, shadow: CGFloat) -> CIImage {
  let k = (S * height) / char.extent.height
  let l = CIFilter.lanczosScaleTransform(); l.inputImage = char; l.scale = Float(k); l.aspectRatio = 1
  let c = l.outputImage!
  let x = (S - c.extent.width) / 2 - c.extent.minX + S * 0.01, y = (S - c.extent.height) / 2 - c.extent.minY + S * 0.035
  let placed = c.transformed(by: CGAffineTransform(translationX: x, y: y))
  let ell = CIFilter.radialGradient(); ell.center = CGPoint(x: S * 0.5, y: y - S * 0.005); ell.radius0 = 0; ell.radius1 = Float(S * 0.2)
  ell.color0 = CIColor(red: 0.2, green: 0.1, blue: 0.04, alpha: shadow); ell.color1 = CIColor(red: 0.2, green: 0.1, blue: 0.04, alpha: 0)
  let squash = ell.outputImage!.transformed(by: CGAffineTransform(translationX: -S * 0.5, y: -(y - S * 0.005))
    .concatenating(CGAffineTransform(scaleX: 1, y: 0.22)).concatenating(CGAffineTransform(translationX: S * 0.5, y: y + S * 0.012)))
  return placed.composited(over: squash.composited(over: bg)).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}
func write(_ img: CIImage, _ name: String, _ rect: CGRect) {
  let cg = ctx.createCGImage(img, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
  let url = out.appendingPathComponent(name)
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
  print("wrote", url.path)
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let options: [(name: String, inner: UInt32, outer: UInt32, shadow: CGFloat)] = [
  ("1-warm-white", 0xFFFFFF, 0xEDE9E4, 0.18),
  ("2-cream", 0xFCF7EF, 0xE9DDCB, 0.20),
  ("3-mist-blue", 0xF1F6FC, 0xD2E0F0, 0.20),
  ("4-charcoal", 0x433D38, 0x211E1B, 0.50),
]
var icons: [CIImage] = []
for o in options {
  let img = composeFloating(load("hero-wave"), radial(hex(o.inner), hex(o.outer)), height: 0.8, shadow: o.shadow)
  write(img, "icon-\(o.name).png", CGRect(x: 0, y: 0, width: S, height: S))
  icons.append(img)
}

// Contact sheet: the options left to right, masked to the iOS icon corner radius, on a neutral grey.
let size: CGFloat = 360, gap: CGFloat = 64
let W = gap + CGFloat(icons.count) * (size + gap), H = size + gap * 2
var sheet = CIImage(color: hex(0xE6E6E8)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
let mask = CIFilter.roundedRectangleGenerator()
mask.extent = CGRect(x: 0, y: 0, width: size, height: size); mask.radius = Float(size * 0.2237); mask.color = .white
for (i, icon) in icons.enumerated() {
  let scaled = icon.transformed(by: CGAffineTransform(scaleX: size / S, y: size / S))
  let blend = CIFilter.blendWithMask()
  blend.inputImage = scaled; blend.backgroundImage = CIImage.empty(); blend.maskImage = mask.outputImage!
  sheet = blend.outputImage!.transformed(by: CGAffineTransform(translationX: gap + CGFloat(i) * (size + gap), y: gap)).composited(over: sheet)
}
write(sheet, "icon-options-sheet.png", CGRect(x: 0, y: 0, width: W, height: H))
