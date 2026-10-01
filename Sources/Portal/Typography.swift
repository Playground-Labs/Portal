import SwiftUI
import CoreText

func registerPortalFonts() {
    for url in Bundle.module.urls(forResourcesWithExtension:"ttf",subdirectory:"Fonts") ?? [] {
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
