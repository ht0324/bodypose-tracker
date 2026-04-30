import AppKit
import BodyPoseTrackerCore

struct DebugFrame {
    let image: CGImage
    let imageSize: CGSize
    let face: FaceBox?
    let hands: [[String: Landmark]]
    let state: HairAlertState
    let config: DetectionConfig
    let appliedCameraFPS: Double?
    let appliedConnectionFPS: Double?
    let targetHandFPS: Double
    let observedProcessingFPS: Double
}

final class DebugPreviewView: NSView {
    private static let handEdges: [(String, String)] = [
        ("wrist", "thumb_cmc"),
        ("thumb_cmc", "thumb_mp"),
        ("thumb_mp", "thumb_ip"),
        ("thumb_ip", "thumb_tip"),
        ("wrist", "index_mcp"),
        ("index_mcp", "index_pip"),
        ("index_pip", "index_dip"),
        ("index_dip", "index_tip"),
        ("wrist", "middle_mcp"),
        ("middle_mcp", "middle_pip"),
        ("middle_pip", "middle_dip"),
        ("middle_dip", "middle_tip"),
        ("wrist", "ring_mcp"),
        ("ring_mcp", "ring_pip"),
        ("ring_pip", "ring_dip"),
        ("ring_dip", "ring_tip"),
        ("wrist", "little_mcp"),
        ("little_mcp", "little_pip"),
        ("little_pip", "little_dip"),
        ("little_dip", "little_tip")
    ]

    var frameData: DebugFrame? {
        didSet {
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let frameData else {
            drawCenteredMessage("Waiting for camera frames...")
            return
        }

        let imageRect = fittedImageRect(imageSize: frameData.imageSize)
        NSImage(cgImage: frameData.image, size: frameData.imageSize).draw(in: imageRect)

        drawFace(frameData.face, imageRect: imageRect)
        drawHeadZone(frameData.state.headZone, active: frameData.state.active, imageRect: imageRect)
        drawHands(frameData.hands, imageRect: imageRect)
        drawStatus(frameData, imageRect: imageRect)
    }

    private func drawCenteredMessage(_ message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let size = attributed.size()
        attributed.draw(
            at: CGPoint(
                x: bounds.midX - size.width * 0.5,
                y: bounds.midY - size.height * 0.5
            )
        )
    }

    private func fittedImageRect(imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width * 0.5,
            y: bounds.midY - height * 0.5,
            width: width,
            height: height
        )
    }

    private func projectTopLeftRect(_ rect: CGRect, into imageRect: CGRect) -> CGRect {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGRect(
            x: imageRect.minX + rect.origin.x * scale,
            y: imageRect.maxY - (rect.origin.y + rect.height) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    private func point(fromTopLeftImagePoint point: Landmark, imageRect: CGRect) -> CGPoint {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGPoint(
            x: imageRect.minX + point.x * scale,
            y: imageRect.maxY - point.y * scale
        )
    }

    private func drawFace(_ face: FaceBox?, imageRect: CGRect) {
        guard let face else { return }
        let rect = projectTopLeftRect(
            CGRect(x: face.x, y: face.y, width: face.width, height: face.height),
            into: imageRect
        )
        NSColor.systemGreen.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHeadZone(_ zone: HeadZone?, active: Bool, imageRect: CGRect) {
        guard let zone else { return }
        let boundary = HairPickingDetector.headZoneBoundaryPoints(for: zone)
        guard let first = boundary.first else { return }
        let color: NSColor = active ? .systemRed : (zone.stale ? .systemGray : .systemBlue)
        color.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath()
        path.move(to: point(fromTopLeftImagePoint: first, imageRect: imageRect))
        for point in boundary.dropFirst() {
            path.line(to: self.point(fromTopLeftImagePoint: point, imageRect: imageRect))
        }
        path.close()
        path.lineWidth = active ? 4 : 3
        path.stroke()
    }

    private func drawHands(_ hands: [[String: Landmark]], imageRect: CGRect) {
        for hand in hands {
            NSColor.systemCyan.withAlphaComponent(0.92).setStroke()
            for (start, end) in Self.handEdges {
                guard let a = hand[start], let b = hand[end] else { continue }
                let path = NSBezierPath()
                path.move(to: point(fromTopLeftImagePoint: a, imageRect: imageRect))
                path.line(to: point(fromTopLeftImagePoint: b, imageRect: imageRect))
                path.lineWidth = 2
                path.stroke()
            }

            NSColor.systemCyan.setFill()
            for landmark in hand.values {
                let center = point(fromTopLeftImagePoint: landmark, imageRect: imageRect)
                NSBezierPath(
                    ovalIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                ).fill()
            }
        }
    }

    private func drawStatus(_ frameData: DebugFrame, imageRect: CGRect) {
        let score = frameData.state.zoneScore.map { String(format: "%.2f", $0) } ?? "-"
        let cameraFPS = frameData.appliedCameraFPS.map { String(format: "%.0f", $0) } ?? "-"
        let connectionFPS = frameData.appliedConnectionFPS.map { String(format: "%.0f", $0) } ?? "-"
        let usableHands = frameData.hands.filter { !$0.isEmpty }.count
        let pointCount = frameData.hands.reduce(0) { $0 + $1.count }
        let line1 = String(
            format: "%@ | fps %.1f | cam %@/%@ | face %.0f | hand %.0f/%.0f | delay %.1fs",
            frameData.config.name,
            frameData.observedProcessingFPS,
            cameraFPS,
            connectionFPS,
            frameData.config.faceFPS,
            frameData.targetHandFPS,
            frameData.config.activeHandFPS,
            frameData.config.triggerSeconds
        )
        let line2 = String(
            format: "size %.0fx%.0f | face %@ | hands %d/%d pts %d | streak %d | score %@",
            frameData.imageSize.width,
            frameData.imageSize.height,
            frameData.face == nil ? "no" : "yes",
            usableHands,
            frameData.hands.count,
            pointCount,
            frameData.state.streak,
            score
        )
        let text = "\(line1)\n\(line2)"

        let barHeight: CGFloat = 48
        let barRect = CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: barHeight)
        NSColor.black.withAlphaComponent(0.78).setFill()
        barRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]
        NSAttributedString(string: text, attributes: attributes).draw(
            in: barRect.insetBy(dx: 10, dy: 6)
        )
    }
}

final class DebugPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView = DebugPreviewView(frame: CGRect(x: 0, y: 0, width: 960, height: 620))
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BodyPoseTracker Debug Preview"
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = previewView
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(frame: DebugFrame) {
        previewView.frameData = frame
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
