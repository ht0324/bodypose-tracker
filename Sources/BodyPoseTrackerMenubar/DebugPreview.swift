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
    private static let statusBarHeight: CGFloat = 116
    private static let sliderStripHeight: CGFloat = 30
    private static let handFaceLimitRange: ClosedRange<Double> = 0.60...1.80

    var frameData: DebugFrame? {
        didSet {
            if let frameData {
                syncHandFaceControls(to: frameData.config.maxHandFaceRatio)
                handFaceValueLabel.isHidden = false
                handFaceLimitSlider.isHidden = false
            } else {
                handFaceValueLabel.isHidden = true
                handFaceLimitSlider.isHidden = true
            }
            needsLayout = true
            needsDisplay = true
        }
    }
    var onHandFaceLimitChanged: ((Double) -> Void)?

    var placeholderMessage = "Waiting for camera frames..." {
        didSet {
            guard placeholderMessage != oldValue, frameData == nil else { return }
            needsDisplay = true
        }
    }

    private let handFaceValueLabel = NSTextField(labelWithString: "")
    private lazy var handFaceLimitSlider: NSSlider = {
        let slider = NSSlider(
            value: DetectionConfig.production.maxHandFaceRatio,
            minValue: Self.handFaceLimitRange.lowerBound,
            maxValue: Self.handFaceLimitRange.upperBound,
            target: self,
            action: #selector(handFaceLimitSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .small
        slider.focusRingType = .none
        slider.toolTip = "Adjust hand/face size limit"
        return slider
    }()
    private var pendingHandFaceLimit: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHandFaceControls()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHandFaceControls()
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    override func layout() {
        super.layout()
        layoutHandFaceControls()
    }

    private func configureHandFaceControls() {
        handFaceValueLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        handFaceValueLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        handFaceValueLabel.alignment = .left
        handFaceValueLabel.isHidden = true
        handFaceValueLabel.toolTip = "Current hand/face size limit"
        updateHandFaceValueLabel(DetectionConfig.production.maxHandFaceRatio)

        handFaceLimitSlider.isHidden = true
        addSubview(handFaceValueLabel)
        addSubview(handFaceLimitSlider)
    }

    private func layoutHandFaceControls() {
        guard let frameData else {
            handFaceValueLabel.isHidden = true
            handFaceLimitSlider.isHidden = true
            return
        }

        let imageRect = fittedImageRect(imageSize: frameData.imageSize)
        let barRect = statusBarRect(imageRect: imageRect)
        let controlRect = handFaceControlRect(in: barRect)
        let labelWidth: CGFloat = 112
        let sliderGap: CGFloat = 8
        let sliderWidth = max(80, controlRect.width - labelWidth - sliderGap)

        handFaceValueLabel.frame = CGRect(
            x: controlRect.minX,
            y: controlRect.minY + 3,
            width: labelWidth,
            height: 18
        )
        handFaceLimitSlider.frame = CGRect(
            x: controlRect.minX + labelWidth + sliderGap,
            y: controlRect.minY,
            width: sliderWidth,
            height: controlRect.height
        )
    }

    private func syncHandFaceControls(to limit: Double) {
        let roundedLimit = roundedHandFaceLimit(limit)
        if let pendingHandFaceLimit, abs(roundedLimit - pendingHandFaceLimit) > 0.005 {
            return
        }

        pendingHandFaceLimit = nil
        handFaceLimitSlider.doubleValue = roundedLimit
        updateHandFaceValueLabel(roundedLimit)
    }

    private func updateHandFaceValueLabel(_ limit: Double) {
        handFaceValueLabel.stringValue = String(format: "hand/face %.2f", limit)
    }

    private func roundedHandFaceLimit(_ limit: Double) -> Double {
        let clamped = min(max(limit, Self.handFaceLimitRange.lowerBound), Self.handFaceLimitRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    @objc private func handFaceLimitSliderChanged(_ sender: NSSlider) {
        let limit = roundedHandFaceLimit(sender.doubleValue)
        sender.doubleValue = limit
        pendingHandFaceLimit = limit
        updateHandFaceValueLabel(limit)
        onHandFaceLimitChanged?(limit)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let frameData else {
            drawCenteredMessage(placeholderMessage)
            return
        }

        let imageRect = fittedImageRect(imageSize: frameData.imageSize)
        drawMirroredImage(frameData.image, size: frameData.imageSize, in: imageRect)

        drawFace(frameData.face, imageRect: imageRect)
        drawHeadZone(frameData.state.headZone, active: frameData.state.active, imageRect: imageRect)
        drawHandSizeBoxes(frameData, imageRect: imageRect)
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

    private func drawMirroredImage(_ image: CGImage, size: CGSize, in imageRect: CGRect) {
        let previewImage = NSImage(cgImage: image, size: size)
        guard let context = NSGraphicsContext.current?.cgContext else {
            previewImage.draw(in: imageRect)
            return
        }

        context.saveGState()
        context.translateBy(x: imageRect.maxX, y: imageRect.minY)
        context.scaleBy(x: -1, y: 1)
        previewImage.draw(in: CGRect(x: 0, y: 0, width: imageRect.width, height: imageRect.height))
        context.restoreGState()
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

    private func statusBarRect(imageRect: CGRect) -> CGRect {
        let barHeight = min(Self.statusBarHeight, max(0, imageRect.height))
        return CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: barHeight)
    }

    private func handFaceControlRect(in barRect: CGRect) -> CGRect {
        let controlWidth = min(300, max(220, barRect.width - 20))
        return CGRect(
            x: barRect.minX + 10,
            y: barRect.minY + 4,
            width: controlWidth,
            height: 24
        )
    }

    private func projectTopLeftRect(_ rect: CGRect, into imageRect: CGRect) -> CGRect {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGRect(
            x: imageRect.maxX - (rect.origin.x + rect.width) * scale,
            y: imageRect.maxY - (rect.origin.y + rect.height) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    private func point(fromTopLeftImagePoint point: Landmark, imageRect: CGRect) -> CGPoint {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGPoint(
            x: imageRect.maxX - point.x * scale,
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

    private func drawHandSizeBoxes(_ frameData: DebugFrame, imageRect: CGRect) {
        guard let face = frameData.state.headZone?.faceBox else { return }

        for hand in frameData.hands {
            guard let metrics = handSizeMetrics(hand: hand, face: face, threshold: frameData.config.maxHandFaceRatio) else {
                continue
            }

            let projectedSquare = projectTopLeftRect(metrics.squareRect, into: imageRect)
            let color: NSColor = metrics.accepted ? .systemOrange : .systemRed
            color.withAlphaComponent(0.98).setStroke()
            let path = NSBezierPath(rect: projectedSquare)
            path.lineWidth = 2
            path.stroke()

            drawHandSizeLabel(metrics, color: color, near: projectedSquare, imageRect: imageRect)
        }
    }

    private func drawHandSizeLabel(
        _ metrics: HandSizeMetrics,
        color: NSColor,
        near square: CGRect,
        imageRect: CGRect
    ) {
        let text = String(
            format: "hand %.0f / face %.0f = %.2fx",
            metrics.handSide,
            metrics.faceSide,
            metrics.ratio
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding = CGSize(width: 6, height: 4)
        let labelWidth = textSize.width + padding.width * 2
        let labelHeight = textSize.height + padding.height * 2
        let labelX = min(
            max(imageRect.minX + 4, square.minX),
            imageRect.maxX - labelWidth - 4
        )
        let preferredY = square.minY - labelHeight - 4
        let labelY = preferredY >= imageRect.minY + 4
            ? preferredY
            : min(square.maxY + 4, imageRect.maxY - labelHeight - 4)
        let labelRect = CGRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        color.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()
        attributed.draw(at: CGPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height))
    }

    private func drawStatus(_ frameData: DebugFrame, imageRect: CGRect) {
        let score = frameData.state.zoneScore.map { String(format: "%.2f", $0) } ?? "-"
        let sizeMetrics = strongestHandSizeMetrics(frameData)
        let handFaceRatio = sizeMetrics.map { String(format: "%.2f", $0.ratio) } ?? "-"
        let handSizeStatus = sizeMetrics == nil
            ? "-"
            : (sizeMetrics?.accepted == true ? "ok" : "no")
        let handSide = sizeMetrics.map { String(format: "%.0f", $0.handSide) } ?? "-"
        let faceSide = sizeMetrics.map { String(format: "%.0f", $0.faceSide) } ?? "-"
        let sideDiff = sizeMetrics.map { String(format: "%+.0f", $0.handSide - $0.faceSide) } ?? "-"
        let handFaceLimit = String(format: "%.2f", frameData.config.maxHandFaceRatio)
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
        let line3 = String(
            format: "hand %@px | face %@px | diff %@px | hand/face %@ <= %@ | size %@",
            handSide,
            faceSide,
            sideDiff,
            handFaceRatio,
            handFaceLimit,
            handSizeStatus
        )
        let line4 = String(
            format: "params head x%.2f min %.0fpx | faceHold %.1fs | maxHands %d | hand/face limit %@",
            frameData.config.headScale,
            frameData.config.minHeadRadius,
            frameData.config.faceHoldSeconds,
            frameData.config.maxHands,
            handFaceLimit
        )
        let text = "\(line1)\n\(line2)\n\(line3)\n\(line4)"

        let barRect = statusBarRect(imageRect: imageRect)
        NSColor.black.withAlphaComponent(0.78).setFill()
        barRect.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let textRect = CGRect(
            x: barRect.minX + 10,
            y: barRect.minY + Self.sliderStripHeight + 4,
            width: barRect.width - 20,
            height: barRect.height - Self.sliderStripHeight - 10
        )
        NSAttributedString(string: text, attributes: attributes).draw(in: textRect)

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: barRect.minX + 10, y: barRect.minY + Self.sliderStripHeight))
        divider.line(to: CGPoint(x: barRect.maxX - 10, y: barRect.minY + Self.sliderStripHeight))
        divider.lineWidth = 1
        divider.stroke()
    }

    private func strongestHandSizeMetrics(_ frameData: DebugFrame) -> HandSizeMetrics? {
        guard let face = frameData.state.headZone?.faceBox else { return nil }

        return frameData.hands
            .compactMap { handSizeMetrics(hand: $0, face: face, threshold: frameData.config.maxHandFaceRatio) }
            .max { $0.ratio < $1.ratio }
    }

    private func handSizeMetrics(
        hand: [String: Landmark],
        face: FaceBox,
        threshold: Double
    ) -> HandSizeMetrics? {
        guard let square = HairPickingDetector.handBoundingSquare(hand: hand) else { return nil }

        let faceSide = HairPickingDetector.faceSquareSide(face: face)
        guard faceSide > 0 else { return nil }

        let ratio = square.side / faceSide
        return HandSizeMetrics(
            squareRect: CGRect(x: square.x, y: square.y, width: square.side, height: square.side),
            handSide: square.side,
            faceSide: faceSide,
            ratio: ratio,
            accepted: ratio <= threshold
        )
    }

    private struct HandSizeMetrics {
        let squareRect: CGRect
        let handSide: Double
        let faceSide: Double
        let ratio: Double
        let accepted: Bool
    }
}

final class DebugPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView = DebugPreviewView(frame: CGRect(x: 0, y: 0, width: 960, height: 620))
    var onClose: (() -> Void)?
    var onHandFaceLimitChanged: ((Double) -> Void)? {
        didSet {
            previewView.onHandFaceLimitChanged = onHandFaceLimitChanged
        }
    }

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

    func updateStatus(_ status: String) {
        previewView.placeholderMessage = "Waiting for camera frames... (\(status))"
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
