import Foundation
import TandemSpeech

/// The mix from a frame to the end of the timeline, played faster or slower
/// through a `SpeechStretcher`. The synchronizer plays it at 1×: its frames
/// count on from `start` at the output's own pace, while the picture runs at
/// `rate`, so frame `start + n` here is timeline frame `start + n × rate`.
final class StretchedSound: ViewerSound {
    private let source: ViewerSound
    private var stretcher: SpeechStretcher
    private var nextFrame: Int
    private var ended = false

    init(_ source: ViewerSound, rate: Double, from start: Int) {
        self.source = source
        stretcher = SpeechStretcher(rate: rate)
        nextFrame = start
    }

    func next() -> (frame: Int, samples: [Float])? {
        while !ended {
            let out: [Float]
            if let chunk = source.next() {
                out = stretcher.process(chunk.samples)
            } else {
                ended = true
                out = stretcher.flush()
            }
            guard !out.isEmpty else { continue }
            defer { nextFrame += out.count / AudioBuffers.channels }
            return (nextFrame, out)
        }
        return nil
    }

    func cancel() {
        source.cancel()
    }
}
