import AppKit
import AVFoundation
import SwiftUI

/// Toggle-first A/B player (ADR-8), production port of the S5 spike with its
/// four gotcha fixes: KVO-gated preroll, future-dated host-time anchor,
/// CATransaction-disabled opacity flips, frame-boundary snap before stepping.
struct ABPlayerView: NSViewRepresentable {
    let clipA: URL
    let clipB: URL
    let fpsNum: Int
    let fpsDen: Int

    func makeNSView(context: Context) -> ABPlayerNSView {
        ABPlayerNSView(clipA: clipA, clipB: clipB,
                       frameDuration: CMTime(value: CMTimeValue(fpsDen), timescale: CMTimeScale(fpsNum)))
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
        CATransaction.commit()
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
                updateLabel()
            }
        case 123, 124: // arrows — frame-step both when paused
            guard paused else { return }
            let delta = event.keyCode == 124 ? frameDuration
                                             : CMTimeMultiply(frameDuration, multiplier: -1)
            seekBoth(to: nearestFrame(CMTimeAdd(playerA.currentTime(), delta)))
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

    private func updateLabel() {
        label.stringValue = (showingB ? " B — filtered " : " A — source ")
                          + (paused ? "[paused — ⇦⇨ steps] " : "")
        needsLayout = true
    }
}
