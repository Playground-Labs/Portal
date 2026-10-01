// Run with: swift scripts/benchmark-rendering.swift
// Measures CPU drawing/submission only; excludes decoding, network and GPU execution.
import AppKit
import QuartzCore
let width = 3440, height = 1440, frames = 120
let data = Data(repeating:127,count:width*height*4)
let provider = CGDataProvider(data:data as CFData)!
let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
let source = CGRect(x:0,y:0,width:width,height:height)
let target = CGRect(x:0,y:0,width:1720,height:720)
let context = CGContext(data:nil,width:1720,height:720,bitsPerComponent:8,bytesPerRow:1720*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
func time(_ label:String,_ body:()->Void) {
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<frames { autoreleasepool { body() } }
    print("\(label): \((CFAbsoluteTimeGetCurrent()-start)*1000/Double(frames)) ms/frame")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
time("Legacy crop/scale/draw") {
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage:image.cropping(to:source)!,size:source.size).draw(in:target,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
}
NSGraphicsContext.restoreGraphicsState()
let layer = CALayer()
time("Layer submission (GPU work excluded)") {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.frame = target; layer.contents = image
    layer.contentsRect = CGRect(x:0,y:0,width:1,height:1)
    CATransaction.commit()
}
