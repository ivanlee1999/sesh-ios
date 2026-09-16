import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/**
 Touch feedback.

 The web app calls `navigator.vibrate`, which iOS Safari ignores entirely — so
 one of the small pleasures of the installed app was simply missing. Here it
 works, and the taps are deliberately quiet: a tab switch is the lightest thing
 available, and only finishing a session is allowed to be felt properly.
 */
enum Haptics {
    static func light() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

/**
 The chime at the end of a session.

 Synthesised rather than shipped as a file, for the same reason the web app
 generates it: it is one sine wave with a decay, and a bundled asset would be a
 larger, less adjustable way of saying the same thing. 880Hz ends focus, 660Hz
 ends a break — the same two notes, so the two apps sound alike.

 Played on the ambient category so it ducks politely under music rather than
 stopping it.
 */
actor Chime {
    static let shared = Chime()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func play(focus: Bool, enabled: Bool) {
        guard enabled else { return }
        let frequency = focus ? 880.0 : 660.0

        do {
            #if canImport(UIKit)
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif

            let engine = self.engine ?? AVAudioEngine()
            let player = self.player ?? AVAudioPlayerNode()
            if self.engine == nil {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: nil)
                self.engine = engine
                self.player = player
            }
            guard let buffer = Self.tone(frequency: frequency, seconds: 0.7) else { return }
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            player.play()
        } catch {
            // A chime that cannot play is not worth interrupting anyone over.
        }
    }

    /// One sine wave, faded out exponentially so it rings rather than clicks.
    private static func tone(frequency: Double, seconds: Double) -> AVAudioPCMBuffer? {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        guard let samples = buffer.floatChannelData?[0] else { return nil }
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            let envelope = pow(0.001 / 0.25, t / seconds) * 0.25
            samples[frame] = Float(sin(2 * .pi * frequency * t) * envelope)
        }
        return buffer
    }
}
