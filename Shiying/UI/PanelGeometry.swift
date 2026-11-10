import Foundation

enum PanelGeometry {
    static let inset: CGFloat = 16
    static func frame(in visible: CGRect, scale: CGFloat = 1, details: Bool = false, origin: CGPoint? = nil) -> CGRect {
        let scale = min(1.3, max(1, scale))
        let width = min(384 * min(scale, 1.15), max(1, visible.width - inset * 2))
        let height = min(408 * scale + (details ? 116 : 0), max(1, visible.height - inset * 2))
        var frame = CGRect(x: visible.maxX - inset - width, y: visible.minY + inset, width: width, height: height)
        if let origin, origin.x.isFinite, origin.y.isFinite {
            frame.origin = CGPoint(x: min(max(origin.x, visible.minX + inset), visible.maxX - inset - width),
                                   y: min(max(origin.y, visible.minY + inset), visible.maxY - inset - height))
        }
        return frame
    }
}
