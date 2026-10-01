// swiftc -O Sources/Portal/FrameImage.swift scripts/benchmark-frame-preparation.swift -o .build/benchmark-frame-preparation
// .build/benchmark-frame-preparation
// Measures real pixel conversion/drawing, not GPU execution or end-to-end latency.
import AppKit

@main struct Benchmark {
    static func main() {
        let width = 3440, height = 1440, frames = 60
        let space = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name:CGColorSpace.displayP3)!
        let target = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        var rawTime = 0.0, preparationTime = 0.0, preparedTime = 0.0
        for i in 0..<frames { autoreleasepool {
            let data = Data(repeating:UInt8(60+i),count:width*height*4)
            let raw = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let rect = CGRect(x:0,y:0,width:width,height:height)
            var start = CFAbsoluteTimeGetCurrent()
            target.draw(raw,in:rect)
            rawTime += CFAbsoluteTimeGetCurrent()-start
            start = CFAbsoluteTimeGetCurrent()
            let prepared = prepareFrameImage(data,width:width,height:height,colorSpace:space)!
            preparationTime += CFAbsoluteTimeGetCurrent()-start
            start = CFAbsoluteTimeGetCurrent()
            target.draw(prepared,in:rect)
            preparedTime += CFAbsoluteTimeGetCurrent()-start
        } }
        for (label, seconds) in [("Unprepared drawing",rawTime),("Background preparation",preparationTime),("Prepared drawing",preparedTime)] {
            print(String(format:"%@: %.2f ms/frame",label,seconds*1000/Double(frames)))
        }
    }
}
