import CoreGraphics
import Foundation

// Convert into display-native pixels on the frame worker, before Core Animation sees them.
func prepareFrameImage(_ data: Data, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
    guard width > 0, height > 0, width <= 16384, height <= 16384,
          width * height <= 33554432, data.count == width * height * 4,
          let provider = CGDataProvider(data:data as CFData),
          let source = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
          let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    context.setBlendMode(.copy)
    context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
    return context.makeImage()
}
