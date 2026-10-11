// crop.swift <in.png> <out.png> <x> <y> <w> <h>   (pixels, top-left origin)
import CoreGraphics
import Foundation
import ImageIO
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let r = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: min(Double(a[6])!, Double(img.height)))
let out = img.cropping(to: r)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, out, nil); CGImageDestinationFinalize(dst)
