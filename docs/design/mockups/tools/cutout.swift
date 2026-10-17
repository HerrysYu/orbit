// Temporary mascot placeholders for the design mockups: crop poses from the concept sheet and lift the
// subject with Vision (transparent PNG). NOT production assets — see docs/design/orbit-app-design.md §7.3.
// Usage: swift cutout.swift <concept.png> <outDir>
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: cutout <concept.png> <outDir>") }
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let outDir = URL(fileURLWithPath: args[2])
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

// name: (x, y, w, h) in sheet pixels, origin top-left
let crops: [(String, CGRect)] = [
  ("hero-wave",   CGRect(x: 110, y: 130, width: 640, height: 680)),
  ("side",        CGRect(x: 820, y: 70, width: 245, height: 275)),
  ("rear",        CGRect(x: 1170, y: 80, width: 290, height: 270)),
  ("attentive",   CGRect(x: 765, y: 395, width: 240, height: 245)),
  ("thinking",    CGRect(x: 1020, y: 395, width: 215, height: 245)),
  ("focused",     CGRect(x: 1255, y: 390, width: 220, height: 236)),
  ("happy",       CGRect(x: 730, y: 660, width: 280, height: 270)),
  ("avatar-tile", CGRect(x: 1268, y: 718, width: 196, height: 196)),
  ("avatar-dark", CGRect(x: 1046, y: 718, width: 196, height: 196)),
]

func writePNG(_ image: CGImage, _ name: String) {
  let url = outDir.appendingPathComponent("placeholder-\(name).png")
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  print("wrote \(url.lastPathComponent) \(image.width)x\(image.height)")
}

for (name, rect) in crops {
  guard let crop = sheet.cropping(to: rect) else { print("crop failed \(name)"); continue }
  let handler = VNImageRequestHandler(cgImage: crop)
  let req = VNGenerateForegroundInstanceMaskRequest()
  do {
    try handler.perform([req])
    guard let obs = req.results?.first else { print("no subject \(name)"); continue }
    let buf = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
    let ci = CIImage(cvPixelBuffer: buf)
    let cg = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    writePNG(cg, name)
  } catch {
    print("vision failed \(name): \(error)")
  }
}
