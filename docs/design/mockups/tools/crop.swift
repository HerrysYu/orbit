// Plain crops from the concept sheet (app icon concept tiles). Usage: swift crop.swift <sheet.png> <outDir>
import Foundation
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil)!
for (name, r) in [("icon-dark", CGRect(x: 1041, y: 714, width: 206, height: 206)),
                  ("icon-apricot", CGRect(x: 1263, y: 714, width: 206, height: 206))] {
  let url = URL(fileURLWithPath: a[2]).appendingPathComponent("placeholder-\(name).png")
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, sheet.cropping(to: r)!, nil)
  CGImageDestinationFinalize(d)
  print("wrote", url.lastPathComponent)
}
