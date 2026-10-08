import SwiftUI
import CoreText

func registerPortalFonts() {
    // Older SwiftPM accessors never look in Contents/Resources and crash inside an app bundle.
    let bundle = Bundle.main.url(forResource:"Portal_Portal",withExtension:"bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
    for url in bundle.urls(forResourcesWithExtension:"ttf",subdirectory:"Fonts") ?? [] {
        CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
    }
}

extension Font {
    static func portal(size:CGFloat,weight:Font.Weight = .regular) -> Font {
        let face = weight == .semibold ? "SemiBold" : weight == .medium ? "Medium" : "Regular"
        return .custom("Inter-\(face)",fixedSize:size)
    }
    static func portalMono(size:CGFloat) -> Font { .custom("JetBrainsMono-Regular",fixedSize:size) }
}
