// Square face crop of the hero cutout for the avatar placeholder. Usage: swift avatar.swift <hero.png> <out.png>
import Foundation
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let crop = img.cropping(to: CGRect(x: 118, y: 48, width: 452, height: 452))!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, crop, nil); CGImageDestinationFinalize(d)
print("avatar", crop.width, crop.height)
