import AppKit
import AVFoundation
import SwiftUI

/// Toggle-first A/B player (ADR-8), production port of the S5 spike with its
/// four gotcha fixes: KVO-gated preroll, future-dated host-time anchor,
/// CATransaction-disabled opacity flips, frame-boundary snap before stepping.
/// One user-identified defect: absolute source frame + source-pixel coords.
struct DefectMark: Equatable {
    let frame: Int
    let x: Int
    let y: Int
}

struct ABPlayerView: NSViewRepresentable {
    let clipA: URL
    let clipB: URL
    let fpsNum: Int
    let fpsDen: Int
    var clipStartFrame: Int = 0
    var videoWidth: Int = 1440
    var videoHeight: Int = 1080
    var onCopyReport: (([DefectMark]) -> Void)? = nil

    func makeNSView(context: Context) -> ABPlayerNSView {
        let v = ABPlayerNSView(clipA: clipA, clipB: clipB,
                               frameDuration: CMTime(value: CMTimeValue(fpsDen), timescale: CMTimeScale(fpsNum)))
        v.clipStartFrame = clipStartFrame
        v.videoSize = CGSize(width: videoWidth, height: videoHeight)
        v.onCopyReport = onCopyReport
        return v
    }

    func updateNSView(_ view: ABPlayerNSView, context: Context) {}
}

final class ABPlayerNSView: NSView {
    private let playerA: AVPlayer
    private let playerB: AVPlayer
    private let layerA = AVPlayerLayer()
    private let layerB = AVPlayerLayer()
    private let frameDuration: CMTime
    private let label = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var showingB = false
    private var paused = false

    // --- defect annotation (click while paused; C copies the report)
    var clipStartFrame = 0
    var videoSize = CGSize(width: 1440, height: 1080)
    var onCopyReport: (([DefectMark]) -> Void)?
    private var marks: [DefectMark] = []
    private let markLayer = CALayer()

    init(clipA: URL, clipB: URL, frameDuration: CMTime) {
        playerA = AVPlayer(url: clipA)
        playerB = AVPlayer(url: clipB)
        self.frameDuration = frameDuration
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor

        for (p, l) in [(playerA, layerA), (playerB, layerB)] {
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = false
            l.player = p
            l.videoGravity = .resizeAspect
            layer!.addSublayer(l)
        }
        layerB.opacity = 0

        layer!.addSublayer(markLayer)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        label.drawsBackground = true
        addSubview(label)
        updateLabel()

        // Gotcha 1: preroll only once both items are .readyToPlay
        var ready = 0
        for p in [playerA, playerB] {
            guard let item = p.currentItem else { continue }
            observations.append(item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    ready += 1
                    if ready == 2 { self?.prerollAndStart() }
                }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        // Gotcha 3: no implicit CA animations on layer geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerA.frame = bounds
        layerB.frame = bounds
        markLayer.frame = bounds
        CATransaction.commit()
        redrawMarks()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 12, y: bounds.height - label.frame.height - 12)
    }

    private func prerollAndStart() {
        var done = 0
        for p in [playerA, playerB] {
            p.preroll(atRate: 1.0) { _ in
                DispatchQueue.main.async { [weak self] in
                    done += 1
                    if done == 2 { self?.anchor(from: .zero) }
                }
            }
        }
    }

    /// Gotcha 2: anchor both players at the same host time, ~100 ms in the future.
    private func anchor(from time: CMTime) {
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                             CMTime(value: 1, timescale: 10))
        playerA.setRate(1.0, time: time, atHostTime: host)
        playerB.setRate(1.0, time: time, atHostTime: host)
        paused = false
        updateLabel()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space — flip opacity only
            showingB.toggle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layerA.opacity = showingB ? 0 : 1
            layerB.opacity = showingB ? 1 : 0
            CATransaction.commit()
            updateLabel()
        case 35: // p — pause/resume; resume re-anchors, pause snaps to frame (gotcha 4)
            if paused {
                anchor(from: playerA.currentTime())
            } else {
                playerA.pause(); playerB.pause()
                paused = true
                seekBoth(to: nearestFrame(playerA.currentTime()))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.redrawMarks(); self?.updateLabel()
                }
                updateLabel()
            }
        case 123, 124: // arrows — frame-step both when paused
            guard paused else { return }
            let delta = event.keyCode == 124 ? frameDuration
                                             : CMTimeMultiply(frameDuration, multiplier: -1)
            seekBoth(to: nearestFrame(CMTimeAdd(playerA.currentTime(), delta)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.redrawMarks(); self?.updateLabel()
            }
        case 32: // U — undo last mark
            if !marks.isEmpty { marks.removeLast(); redrawMarks(); updateLabel() }
        case 8: // C — copy defect report
            if !marks.isEmpty { onCopyReport?(marks) }
        default:
            super.keyDown(with: event)
        }
    }

    private func nearestFrame(_ t: CMTime) -> CMTime {
        let fps = Double(frameDuration.timescale) / Double(frameDuration.value)
        let n = max(0, (t.seconds * fps).rounded())
        return CMTime(value: CMTimeValue(n) * CMTimeValue(frameDuration.value),
                      timescale: frameDuration.timescale)
    }

    private func seekBoth(to t: CMTime) {
        for p in [playerA, playerB] {
            p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Where the video actually sits inside the view (resizeAspect letterbox).
    private var videoRect: CGRect {
        let vw = videoSize.width, vh = videoSize.height
        guard vw > 0, vh > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / vw, bounds.height / vh)
        let w = vw * scale, h = vh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private var currentAbsFrame: Int {
        let fps = Double(frameDuration.timescale) / Double(frameDuration.value)
        return clipStartFrame + Int((playerA.currentTime().seconds * fps).rounded())
    }

    override func mouseDown(with event: NSEvent) {
        guard paused else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.contains(p) else { return }
        // view coords are bottom-left origin; video pixels are top-left
        let px = Int(((p.x - r.minX) / r.width * videoSize.width).rounded())
        let py = Int(((r.maxY - p.y) / r.height * videoSize.height).rounded())
        marks.append(DefectMark(frame: currentAbsFrame, x: px, y: py))
        redrawMarks()
        updateLabel()
    }

    private func redrawMarks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let r = videoRect
        let cur = currentAbsFrame
        for m in marks where m.frame == cur {
            let ring = CAShapeLayer()
            let cx = r.minX + CGFloat(m.x) / videoSize.width * r.width
            let cy = r.maxY - CGFloat(m.y) / videoSize.height * r.height
            let radius: CGFloat = 26
            ring.path = CGPath(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                                 width: radius * 2, height: radius * 2),
                               transform: nil)
            ring.strokeColor = NSColor.systemRed.cgColor
            ring.fillColor = nil
            ring.lineWidth = 3
            markLayer.addSublayer(ring)
        }
        CATransaction.commit()
    }

    private func updateLabel() {
        var text = (showingB ? " B — filtered " : " A — source ")
        if paused { text += "[paused · frame \(currentAbsFrame) · click = mark] " }
        if !marks.isEmpty { text += "· \(marks.count) marked (U undo, C copy report) " }
        label.stringValue = text
        needsLayout = true
    }
}
