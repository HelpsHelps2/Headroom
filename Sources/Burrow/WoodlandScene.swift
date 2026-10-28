import SwiftUI

// Original vector illustration, drawn locally. No downloaded art or runtime assets.
struct WoodlandScene: View {
    var pressure: Double
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func ellipse(_ rect: CGRect, _ color: Color) { context.fill(Path(ellipseIn: rect), with: .color(color)) }
            func rounded(_ rect: CGRect, radius: CGFloat, color: Color) { context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color)) }
            let sky = pressure > 0.9 ? Color(red: 0.97, green: 0.89, blue: 0.78) : Color(red: 0.89, green: 0.93, blue: 0.83)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(sky))
            ellipse(CGRect(x: w * 0.70, y: -65, width: 360, height: 340), Color(red: 0.84, green: 0.89, blue: 0.76))
            ellipse(CGRect(x: w * 0.87, y: -22, width: 100, height: 100), Color(red: 0.99, green: 0.90, blue: 0.59))
            ellipse(CGRect(x: w * 0.46, y: h * 0.72, width: w * 0.70, height: 160), Color(red: 0.76, green: 0.83, blue: 0.65))
            ellipse(CGRect(x: w * 0.65, y: h * 0.83, width: w * 0.7, height: 110), Color(red: 0.64, green: 0.74, blue: 0.52))
            // The burrow and its rabbit keeper.
            let x = w * 0.74, ground = h * 0.84
            ellipse(CGRect(x: x - 72, y: ground - 26, width: 170, height: 42), Color(red: 0.53, green: 0.64, blue: 0.43).opacity(0.4))
            ellipse(CGRect(x: x + 21, y: ground - 89, width: 96, height: 95), Color(red: 0.59, green: 0.68, blue: 0.45))
            ellipse(CGRect(x: x + 44, y: ground - 69, width: 53, height: 73), Color(red: 0.29, green: 0.35, blue: 0.23))
            let fur = Color(red: 0.91, green: 0.76, blue: 0.57), light = Color(red: 0.98, green: 0.88, blue: 0.70)
            ellipse(CGRect(x: x - 39, y: ground - 139, width: 20, height: 67), fur)
            ellipse(CGRect(x: x - 9, y: ground - 147, width: 20, height: 73), fur)
            ellipse(CGRect(x: x - 34, y: ground - 130, width: 9, height: 42), Palette.peach.opacity(0.7))
            ellipse(CGRect(x: x - 4, y: ground - 138, width: 9, height: 46), Palette.peach.opacity(0.7))
            ellipse(CGRect(x: x - 57, y: ground - 86, width: 86, height: 87), fur)
            ellipse(CGRect(x: x - 46, y: ground - 105, width: 75, height: 63), light)
            ellipse(CGRect(x: x - 34, y: ground - 79, width: 5, height: pressure > 0.9 ? 8 : 5), Palette.ink)
            ellipse(CGRect(x: x + 4, y: ground - 79, width: 5, height: pressure > 0.9 ? 8 : 5), Palette.ink)
            ellipse(CGRect(x: x - 13, y: ground - 68, width: 7, height: 5), Color(red: 0.52, green: 0.35, blue: 0.29))
            ellipse(CGRect(x: x - 42, y: ground - 68, width: 14, height: 8), Palette.peach.opacity(0.5))
            ellipse(CGRect(x: x + 4, y: ground - 68, width: 14, height: 8), Palette.peach.opacity(0.5))
            rounded(CGRect(x: x - 40, y: ground - 41, width: 53, height: 39), radius: 12, color: Palette.green)
            ellipse(CGRect(x: x - 48, y: ground - 10, width: 32, height: 13), light)
            ellipse(CGRect(x: x - 7, y: ground - 10, width: 32, height: 13), light)
            // Cargo boxes become a small pile as the disk fills.
            for i in 0..<(pressure > 0.9 ? 5 : pressure > 0.75 ? 3 : 1) {
                let bx = x - 100 - CGFloat(i % 2) * 28, by = ground - 27 - CGFloat(i / 2) * 26
                rounded(CGRect(x: bx, y: by, width: 29, height: 27), radius: 3, color: Color(red: 0.73, green: 0.48, blue: 0.29))
                rounded(CGRect(x: bx + 12, y: by, width: 5, height: 16), radius: 1, color: Color(red: 0.89, green: 0.72, blue: 0.47))
            }
            // Woodland details.
            for (px, py, scale) in [(w * 0.56, h * 0.84, 1.0), (w * 0.93, h * 0.89, 0.7)] {
                rounded(CGRect(x: px, y: py - 15 * scale, width: 6 * scale, height: 21 * scale), radius: 2, color: light)
                ellipse(CGRect(x: px - 10 * scale, y: py - 24 * scale, width: 27 * scale, height: 15 * scale), Palette.peach)
                ellipse(CGRect(x: px - 3 * scale, y: py - 22 * scale, width: 4 * scale, height: 4 * scale), .white.opacity(0.75))
            }
        }
        .accessibilityLabel(pressure > 0.9 ? "A rabbit's woodland workshop is crowded with build boxes." : "A rabbit tends a cozy woodland workshop.")
    }
}
