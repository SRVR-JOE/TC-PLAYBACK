import Foundation
import os
import Synchronization
import TCKit

/// Drains the render thread's analysis ring (or the external-input ring) on its own thread,
/// runs one TCKit `TimecodeReader` per channel continuously — even for muted channels — and
/// keeps a scope history. Results are read by the main thread under an unfair lock (never
/// touched by the render thread).
final class TimecodeMonitor: @unchecked Sendable {
    struct Output {
        var left = TimecodeReader.Status()
        var right = TimecodeReader.Status()
        /// Samples fed to the readers so far (in the active input's domain).
        var decodedCount = 0
        var external = false
        var sampleRate: Double = 48_000
    }

    static let historyLength = 4096 // power of two ≥ scopeLength

    private let analysisRing: SPSCRingBuffer
    private let analysisRate: Double
    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`:
    private var output = Output()
    private var histL: UnsafeMutablePointer<Float>
    private var histR: UnsafeMutablePointer<Float>
    private var histWrite = 0
    private var pendingInput: (ring: SPSCRingBuffer, rate: Double)?
    private var inputChanged = false

    // Monitor-thread only:
    private var readerL: TimecodeReader
    private var readerR: TimecodeReader
    private var inputRing: SPSCRingBuffer?
    private var inputRate: Double = 48_000
    private var decoded = 0
    private var handledReset = 0
    private let resetGen = Atomic<Int>(0)
    private let stopFlag = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let chunk = 1024
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    init(analysisRing: SPSCRingBuffer, sampleRate: Double) {
        self.analysisRing = analysisRing
        analysisRate = sampleRate
        readerL = TimecodeReader(sampleRate: sampleRate)
        readerR = TimecodeReader(sampleRate: sampleRate)
        histL = .allocate(capacity: Self.historyLength); histL.initialize(repeating: 0, count: Self.historyLength)
        histR = .allocate(capacity: Self.historyLength); histR.initialize(repeating: 0, count: Self.historyLength)
        scratchL = .allocate(capacity: chunk); scratchL.initialize(repeating: 0, count: chunk)
        scratchR = .allocate(capacity: chunk); scratchR.initialize(repeating: 0, count: chunk)
        output.sampleRate = sampleRate
    }

    deinit {
        stop()
        histL.deallocate(); histR.deallocate(); scratchL.deallocate(); scratchR.deallocate()
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "TCPlayback.TimecodeMonitor"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .sequentiallyConsistent)
        _ = exited.wait(timeout: .now() + 1)
        thread = nil
    }

    /// Clear reader state (seek / load).
    func resetReaders() {
        resetGen.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    /// Switch the readers to an external-input ring (mono or stereo), or back to the file (nil).
    func setExternalInput(_ ring: SPSCRingBuffer?, sampleRate: Double) {
        lock.withLock {
            pendingInput = ring.map { ($0, sampleRate) }
            inputChanged = true
        }
    }

    func read() -> Output { lock.withLock { output } }

    /// Last `count` scope samples per channel, oldest first.
    func scope(count: Int) -> ([Float], [Float]) {
        let n = min(count, Self.historyLength)
        var l = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n)
        lock.withLock {
            let mask = Self.historyLength - 1
            let start = histWrite &- n
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    for i in 0..<n {
                        let idx = (start &+ i) & mask
                        lb[i] = histL[idx]; rb[i] = histR[idx]
                    }
                }
            }
        }
        return (l, r)
    }

    // MARK: Thread

    private func loop() {
        while !stopFlag.load(ordering: .sequentiallyConsistent) {
            var changed = false
            var newInput: (ring: SPSCRingBuffer, rate: Double)?
            lock.withLock {
                if inputChanged { changed = true; newInput = pendingInput; inputChanged = false }
            }
            if changed {
                inputRing = newInput?.ring
                inputRate = newInput?.rate ?? analysisRate
                let rate = newInput?.rate ?? analysisRate
                readerL = TimecodeReader(sampleRate: rate)
                readerR = TimecodeReader(sampleRate: rate)
                decoded = 0
            }
            let rg = resetGen.load(ordering: .sequentiallyConsistent)
            if rg != handledReset {
                handledReset = rg
                readerL.reset(); readerR.reset()
            }

            var didWork = false
            if let input = inputRing {
                // External: keep the file analysis ring drained, decode the input.
                while analysisRing.read(nil, nil, count: 8192) > 0 {}
                while true {
                    let n = input.read(scratchL, input.channels > 1 ? scratchR : nil, count: chunk)
                    if n == 0 { break }
                    if input.channels == 1 { scratchR.update(from: scratchL, count: n) }
                    process(n); didWork = true
                }
            } else {
                while true {
                    let n = analysisRing.read(scratchL, scratchR, count: chunk)
                    if n == 0 { break }
                    process(n); didWork = true
                }
            }
            let sL = readerL.status, sR = readerR.status
            let ext = inputRing != nil
            let rate = ext ? inputRate : analysisRate
            let d = decoded
            lock.withLock {
                output.left = sL; output.right = sR; output.decodedCount = d
                output.external = ext; output.sampleRate = rate
            }
            if !didWork { usleep(4_000) } else { usleep(1_000) }
        }
        exited.signal()
    }

    private func process(_ n: Int) {
        readerL.process(UnsafeBufferPointer(start: scratchL, count: n))
        readerR.process(UnsafeBufferPointer(start: scratchR, count: n))
        decoded += n
        lock.withLock {
            let mask = Self.historyLength - 1
            for i in 0..<n {
                let idx = (histWrite &+ i) & mask
                histL[idx] = scratchL[i]; histR[idx] = scratchR[i]
            }
            histWrite &+= n
        }
    }
}
