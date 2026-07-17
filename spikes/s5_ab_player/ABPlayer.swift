// S5 spike — toggle A/B player prototype (throwaway; see docs/ADR.md ADR-8).
// Build: swiftc -o spikes/s5_ab_player/abplayer spikes/s5_ab_player/ABPlayer.swift \
//        -framework AVFoundation -framework AppKit
// Keys: SPACE = flip A/B, P = pause/resume, LEFT/RIGHT = frame-step (paused).

import AppKit
import AVFoundation

let frameDuration = CMTime(value: 1001, timescale: 24000)

func resolve(_ rel: String) -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(rel)
    if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
    return URL(fileURLWithPath: "/Users/4Site/Documents/GitHub/mac-35mm-restoration")
        .appendingPathComponent(rel)
}

final class PlayerView: NSView {
    let layerA = AVPlayerLayer()
    let layerB = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [layerA, layerB] {
            l.videoGravity = .resizeAspect
            layer!.addSublayer(l)
        }
        layerB.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerA.frame = bounds
        layerB.frame = bounds
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let playerA = AVPlayer(url: resolve("spikes/s5_ab_player/source60_preview.mp4"))
    let playerB = AVPlayer(url: resolve("spikes/s3_pipeline/out60_preview.mp4"))
    var showingB = false
    var paused = false
    var observations: [NSKeyValueObservation] = []
    var playerView: PlayerView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 960, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        playerView = PlayerView(frame: rect)
        window.contentView = playerView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateTitle()

        for p in [playerA, playerB] {
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = false
        }
        playerView.layerA.player = playerA
        playerView.layerB.player = playerB

        var ready = 0
        for p in [playerA, playerB] {
            observations.append(p.currentItem!.observe(\.status, options: [.new, .initial]) {
                [weak self] item, _ in
                guard item.status == .readyToPlay else {
                    if item.status == .failed { print("item failed:", item.error ?? "?"); NSApp.terminate(nil) }
                    return
                }
                ready += 1
                if ready == 2 { self?.prerollAndStart() }
            })
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleKey(ev) == true ? nil : ev
        }
    }

    func prerollAndStart() {
        var done = 0
        for p in [playerA, playerB] {
            p.preroll(atRate: 1.0) { [weak self] ok in
                DispatchQueue.main.async {
                    if !ok { print("preroll failed") }
                    done += 1
                    if done == 2 { self?.anchor(from: .zero) }
                }
            }
        }
    }

    /// Start both players in lockstep from `time` at the same host time (slightly in the future).
    func anchor(from time: CMTime) {
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                             CMTime(value: 1, timescale: 10)) // +100 ms
        playerA.setRate(1.0, time: time, atHostTime: host)
        playerB.setRate(1.0, time: time, atHostTime: host)
        paused = false
        updateTitle()
    }

    func handleKey(_ ev: NSEvent) -> Bool {
        switch ev.keyCode {
        case 49: // space — flip opacity, nothing else
            showingB.toggle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerView.layerA.opacity = showingB ? 0 : 1
            playerView.layerB.opacity = showingB ? 1 : 0
            CATransaction.commit()
            updateTitle()
            return true
        case 35: // p — pause / resume (resume re-anchors to keep lockstep)
            if paused {
                anchor(from: playerA.currentTime())
            } else {
                playerA.pause(); playerB.pause()
                paused = true
                seekBoth(to: nearestFrame(playerA.currentTime())) // snap to frame boundary
                updateTitle()
            }
            return true
        case 123, 124: // left / right — frame-step both when paused
            guard paused else { return true }
            let delta = ev.keyCode == 124 ? frameDuration : CMTimeMultiply(frameDuration, multiplier: -1)
            seekBoth(to: nearestFrame(CMTimeAdd(playerA.currentTime(), delta)))
            return true
        default:
            return false
        }
    }

    func nearestFrame(_ t: CMTime) -> CMTime {
        let n = (t.seconds * 24000.0 / 1001.0).rounded()
        return CMTime(value: CMTimeValue(max(0, n) * 1001), timescale: 24000)
    }

    func seekBoth(to t: CMTime) {
        for p in [playerA, playerB] {
            p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func updateTitle() {
        window.title = (showingB ? "B (restored)" : "A (source)") + (paused ? "  [paused]" : "")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
