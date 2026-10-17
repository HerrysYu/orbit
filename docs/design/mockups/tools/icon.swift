// Compose placeholder app icons (1024², full-bleed, no baked corners) from the concept-sheet avatar cutouts.
// Usage: swift icon.swift <assetsDir> <outDir> <scale 0..1>
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let assets = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
let scale = Double(a[3]) ?? 0.66
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let S: CGFloat = 1024

func load(_ n: String) -> CIImage { CIImage(contentsOf: assets.appendingPathComponent("placeholder-\(n).png"))! }
func radial(_ inner: CIColor, _ outer: CIColor) -> CIImage {
  let g = CIFilter.radialGradient()
  g.center = CGPoint(x: S * 0.5, y: S * 0.62); g.radius0 = 0; g.radius1 = Float(S * 0.78)
  g.color0 = inner; g.color1 = outer
  return g.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}
func compose(_ char: CIImage, _ bg: CIImage) -> CIImage {
  // Character width = scale × icon; its flat bottom (cut by the original tile) bleeds off the bottom edge.
  let k = (S * scale) / char.extent.width
  let l = CIFilter.lanczosScaleTransform(); l.inputImage = char; l.scale = Float(k); l.aspectRatio = 1
  let c = l.outputImage!
  let moved = c.transformed(by: CGAffineTransform(translationX: (S - c.extent.width) / 2 - c.extent.minX, y: -c.extent.minY - 6))
  return moved.composited(over: bg).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}
func write(_ img: CIImage, _ name: String, gray: Bool = false) {
  var i = img
  if gray { let m = CIFilter.colorControls(); m.inputImage = img; m.saturation = 0; m.contrast = 1.08; i = m.outputImage! }
  let cg = ctx.createCGImage(i, from: CGRect(x: 0, y: 0, width: S, height: S), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
  let url = out.appendingPathComponent(name)
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
  print("wrote", url.path)
}
/// Floating, centred full-body pose with a soft contact shadow (variant B).
func composeFloating(_ char: CIImage, _ bg: CIImage, height: CGFloat, shadow: CGFloat) -> CIImage {
  let k = (S * height) / char.extent.height
  let l = CIFilter.lanczosScaleTransform(); l.inputImage = char; l.scale = Float(k); l.aspectRatio = 1
  let c = l.outputImage!
  let x = (S - c.extent.width) / 2 - c.extent.minX + S * 0.01, y = (S - c.extent.height) / 2 - c.extent.minY + S * 0.035
  let placed = c.transformed(by: CGAffineTransform(translationX: x, y: y))
  // contact shadow: blurred dark ellipse under the body
  let ell = CIFilter.radialGradient(); ell.center = CGPoint(x: S * 0.5, y: y - S * 0.005); ell.radius0 = 0; ell.radius1 = Float(S * 0.2)
  ell.color0 = CIColor(red: 0.2, green: 0.1, blue: 0.04, alpha: shadow); ell.color1 = CIColor(red: 0.2, green: 0.1, blue: 0.04, alpha: 0)
  let squash = ell.outputImage!.transformed(by: CGAffineTransform(translationX: -S * 0.5, y: -(y - S * 0.005)).concatenating(CGAffineTransform(scaleX: 1, y: 0.22)).concatenating(CGAffineTransform(translationX: S * 0.5, y: y + S * 0.012)))
  return placed.composited(over: squash.composited(over: bg)).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}
let apricot = radial(CIColor(red: 0.988, green: 0.792, blue: 0.604), CIColor(red: 0.949, green: 0.604, blue: 0.333))
let charcoal = radial(CIColor(red: 0.255, green: 0.231, blue: 0.212), CIColor(red: 0.137, green: 0.122, blue: 0.110))
let variant = a.count > 4 ? a[4] : "A"
if variant == "A" {
  write(compose(load("avatar-dark"), apricot), "AppIcon.png")
  let dark = compose(load("avatar-dark"), charcoal)
  write(dark, "AppIcon-Dark.png"); write(dark, "AppIcon-Tinted.png", gray: true)
} else {
  write(composeFloating(load("hero-wave"), apricot, height: scale, shadow: 0.22), "AppIcon.png")
  let dark = composeFloating(load("hero-wave"), charcoal, height: scale, shadow: 0.5)
  write(dark, "AppIcon-Dark.png"); write(dark, "AppIcon-Tinted.png", gray: true)
}
