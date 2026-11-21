import AppKit
import SwiftUI

/// Three stacked teal stones on an indigo rounded square, small gold dot above.
/// Drawn in code until there's a real asset catalog (when the app is bundled).
struct CairnIconView: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.27, blue: 0.72), Color(red: 0.18, green: 0.15, blue: 0.50)],
                                         startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(Color(red: 0.98, green: 0.78, blue: 0.30))
                    .frame(width: s * 0.09)
                    .offset(y: -s * 0.31)
                stone(s, width: 0.26, height: 0.13, y: -0.16, shade: 0.80)
                stone(s, width: 0.40, height: 0.16, y: 0.0, shade: 0.68)
                stone(s, width: 0.56, height: 0.19, y: 0.19, shade: 0.56)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func stone(_ s: CGFloat, width: CGFloat, height: CGFloat, y: CGFloat, shade: Double) -> some View {
        Ellipse()
            .fill(Color(red: 0.16, green: shade, blue: shade * 0.9))
            .frame(width: s * width, height: s * height)
            .offset(y: s * y)
    }
}

enum CairnIcon {
    @MainActor
    static func image(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: CairnIconView().frame(width: size, height: size).padding(size * 0.05))
        renderer.scale = 2
        return renderer.nsImage
    }
}
