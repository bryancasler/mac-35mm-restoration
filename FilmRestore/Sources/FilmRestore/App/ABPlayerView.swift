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

/// Bridge between the SwiftUI window (buttons, overlays) and the AppKit player.
@MainActor
final class ABPlayerController: ObservableObject {
    @Published var isPaused = false
    @Published var showingB = false
    @Published var currentAbsFrame = 0
    @Published var markCount = 0
    weak var view: ABPlayerNSView?

    func togglePlay() { view?.togglePauseResume() }
    func flip() { view?.flipAB() }
    func step(_ delta: Int) { view?.stepFrame(delta) }
    func undoMark() { view?.undoLastMark() }
    func copyReport() { view?.copyReportNow() }
}

struct ABPlayerView: NSViewRepresentable {
    let clipA: URL
    let clipB: URL
    let fpsNum: Int
    let fpsDen: Int
    var clipStartFrame: Int = 0
    var videoWidth: Int = 1440
    var videoHeight: Int = 1080
    var renderID = UUID()
    var controller: ABPlayerController? = nil
    var onCopyReport: (([DefectMark]) -> Void)? = nil

    func makeNSView(context: Context) -> ABPlayerNSView {
        let v = ABPlayerNSView(clipA: clipA, clipB: clipB,
                               frameDuration: CMTime(value: CMTimeValue(fpsDen), timescale: CMTimeScale(fpsNum)))
        v.clipStartFrame = clipStartFrame
        v.videoSize = CGSize(width: videoWidth, height: videoHeight)
        v.onCopyReport = onCopyReport
        v.controller = controller
        controller?.view = v
        context.coordinator.renderID = renderID
        return v
    }

    func updateNSView(_ view: ABPlayerNSView, context: Context) {
        view.controller = controller
        controller?.view = view
        // a new render reuses the same filenames — reload or the players keep
        // showing the old (deleted) files ("player seems broken" bug)
        if context.coordinator.renderID != renderID {
            context.coordinator.renderID = renderID
            view.clipStartFrame = clipStartFrame
            view.reload(clipA: clipA, clipB: clipB)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderID = UUID() }
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
    weak var controller: ABPlayerController?
    private var marks: [DefectMark] = []
    private let markLayer = CALayer()
    private var timeObserver: Any?

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

        // live frame readout for the SwiftUI overlay (no baking into pixels)
        let interval = CMTime(value: frameDuration.value, timescale: frameDuration.timescale)
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.pushState()
        }

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

    deinit {
        if let timeObserver { playerA.removeTimeObserver(timeObserver) }
    }

    private func pushState() {
        guard let c = controller else { return }
        c.isPaused = paused
        c.showingB = showingB
        c.currentAbsFrame = currentAbsFrame
        c.markCount = marks.count
    }

    // MARK: public controls (click buttons + keyboard share these)

    func togglePauseResume() {
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
        pushState()
    }

    func flipAB() {
        showingB.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerA.opacity = showingB ? 0 : 1
        layerB.opacity = showingB ? 1 : 0
        CATransaction.commit()
        updateLabel()
        pushState()
    }

    func stepFrame(_ delta: Int) {
        guard paused else { return }
        let d = CMTimeMultiply(frameDuration, multiplier: Int32(delta))
        seekBoth(to: nearestFrame(CMTimeAdd(playerA.currentTime(), d)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.redrawMarks(); self?.updateLabel(); self?.pushState()
        }
    }

    func undoLastMark() {
        if !marks.isEmpty { marks.removeLast(); redrawMarks(); updateLabel(); pushState() }
    }

    func copyReportNow() {
        if !marks.isEmpty { onCopyReport?(marks) }
    }

    /// Swap in freshly-rendered clips (same filenames, new contents).
    func reload(clipA: URL, clipB: URL) {
        playerA.replaceCurrentItem(with: AVPlayerItem(url: clipA))
        playerB.replaceCurrentItem(with: AVPlayerItem(url: clipB))
        marks.removeAll()
        paused = false
        var ready = 0
        observations.removeAll()
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
        redrawMarks()
        updateLabel()
        pushState()
    }

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
        pushState()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: flipAB()                       // space
        case 35: togglePauseResume()            // p
        case 123: stepFrame(-1)                 // left
        case 124: stepFrame(1)                  // right
        case 32: undoLastMark()                 // u
        case 8: copyReportNow()                 // c
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
        pushState()
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
