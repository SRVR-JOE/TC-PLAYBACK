import Foundation
import Accelerate

/// Section boundaries and a repeat-structure guess (A / B / A…), from a beat-synchronous
/// self-similarity matrix of chroma + cepstrum features.
///
/// 1. Average the coarse features over each beat (0.5 s steps when there is no grid),
///    z-score each dimension, smooth over about a bar, and L2-normalise the chroma and
///    timbre halves separately so neither dominates.
/// 2. Self-similarity S = F·Fᵀ (cosine). Foote novelty: a Gaussian-tapered checkerboard kernel
///    four bars wide slid along the diagonal; its peaks are where the music changes.
/// 3. Peaks above `minNovelty`, at least three bars apart, moved onto the nearest bar line.
/// 4. Segments are grouped greedily by the cosine similarity of their mean feature vectors.
///    The most repeated group (louder wins a tie) is called Chorus, other repeated groups
///    Verse, one-off sections Intro / Outro at the edges and Bridge in between. These are
///    guesses and the UI says so.
enum SongSections {
    /// Groups at least this similar (average cosine of their segments' mean vectors) merge.
    static let joinSimilarity: Float = 0.5
    /// Songs rarely have more distinct kinds of section than this; past it, the closest merge anyway.
    static let maxGroups = 5
    /// Novelty peaks below this (of the track's highest) are not boundaries.
    static let minNovelty: Float = 0.2

    struct Segment: Equatable { var startUnit: Int; var endUnit: Int; var start: TimeInterval; var novelty: Float; var group = 0 }

    static func find(coarse c: SongAnalyzer.Coarse, grid: BeatGrid?, music: ClosedRange<TimeInterval>) -> [SongMoment] {
        // 1. Units: beats from the bar holding the music start, or 0.5 s steps.
        let bpb = max(1, grid?.beatsPerBar ?? 4)
        var starts: [TimeInterval] = []
        var unitLen: TimeInterval = 0.5
        if let g = grid, g.beatLength >= 0.2 {
            unitLen = g.beatLength
            let first = Int(floor(g.beatPosition(at: music.lowerBound) + 0.05))
            var n = Int(floor(Double(first) / Double(bpb))) * bpb
            while g.beatTime(n) < music.upperBound - unitLen * 0.5 { starts.append(g.beatTime(n)); n += 1 }
        } else {
            var t = music.lowerBound
            while t < music.upperBound - 0.25 { starts.append(t); t += 0.5 }
        }
        let U = starts.count, D = c.dims
        let K = 4 * bpb                                     // kernel half-width: four bars
        guard U >= 4 * K, c.count > 0 else { return [] }

        var F = [Float](repeating: 0, count: U * D)
        var unitLevel = [Float](repeating: 0, count: U)
        for u in 0..<U {
            var a = max(0, c.block(starts[u])), b = min(c.count, c.block(starts[u] + unitLen))
            if b <= a { a = min(c.count - 1, a); b = a + 1 }
            for i in a..<b {
                for d in 0..<D { F[u * D + d] += c.features[i * D + d] }
                unitLevel[u] += c.level[i]
            }
            let inv = 1 / Float(b - a)
            for d in 0..<D { F[u * D + d] *= inv }
            unitLevel[u] *= inv
        }
        // z-score, smooth over about a bar, normalise each half.
        for d in 0..<D {
            var col = (0..<U).map { F[$0 * D + d] }
            var mean: Float = 0, sd: Float = 0
            vDSP_normalize(col, 1, nil, 1, &mean, &sd, vDSP_Length(U))
            let s = sd > 1e-9 ? 1 / sd : 0
            col = col.map { ($0 - mean) * s }
            col = SongAnalyzer.movingAverage(col, radius: max(1, bpb / 2))
            for u in 0..<U { F[u * D + d] = col[u] }
        }
        let parts = [0..<SongAnalyzer.chromaDims, SongAnalyzer.chromaDims..<D]
        for u in 0..<U {
            for r in parts {
                var ss: Float = 0
                for d in r { ss += F[u * D + d] * F[u * D + d] }
                let inv = ss > 1e-12 ? 1 / (ss.squareRoot() * Float(2).squareRoot()) : 0
                for d in r { F[u * D + d] *= inv }
            }
        }

        // 2. Self-similarity and Foote novelty.
        var Ft = [Float](repeating: 0, count: U * D)
        vDSP_mtrans(F, 1, &Ft, 1, vDSP_Length(D), vDSP_Length(U))
        var S = [Float](repeating: 0, count: U * U)
        vDSP_mmul(F, 1, Ft, 1, &S, 1, vDSP_Length(U), vDSP_Length(U), vDSP_Length(D))
        let W = 2 * K
        var kern = [Float](repeating: 0, count: W * W)
        let sigma = Double(K) / 2
        for i in -K..<K {
            for j in -K..<K {
                let sign: Float = (i < 0) == (j < 0) ? 1 : -1
                let x = Double(i) + 0.5, y = Double(j) + 0.5
                kern[(i + K) * W + (j + K)] = sign * Float(exp(-(x * x + y * y) / (2 * sigma * sigma)))
            }
        }
        var novelty = [Float](repeating: 0, count: U)
        S.withUnsafeBufferPointer { sp in
            kern.withUnsafeBufferPointer { kp in
                for n in 0..<U {
                    var total: Float = 0
                    let jlo = max(-K, -n), jhi = min(K, U - n)
                    guard jhi > jlo else { continue }
                    for i in -K..<K {
                        let row = n + i
                        guard row >= 0, row < U else { continue }
                        var v: Float = 0
                        vDSP_dotpr(sp.baseAddress! + row * U + n + jlo, 1, kp.baseAddress! + (i + K) * W + (jlo + K), 1,
                                   &v, vDSP_Length(jhi - jlo))
                        total += v
                    }
                    novelty[n] = max(0, total)
                }
            }
        }
        let top = novelty.max() ?? 0
        guard top > 0 else { return [] }
        novelty = novelty.map { $0 / top }

        // 3. Peaks → boundaries on bar lines.
        let reach = max(bpb, (3 * K) / 4)
        var cuts: [(unit: Int, value: Float)] = []
        for n in (K / 2)..<(U - K / 2) where novelty[n] >= minNovelty {
            let lo = max(0, n - reach), hi = min(U - 1, n + reach)
            guard !(lo...hi).contains(where: { novelty[$0] > novelty[n] || (novelty[$0] == novelty[n] && $0 < n) }) else { continue }
            let snapped = grid != nil ? Int((Double(n) / Double(bpb)).rounded()) * bpb : n
            guard snapped >= bpb, snapped <= U - bpb, !cuts.contains(where: { abs($0.unit - snapped) < bpb * 2 }) else { continue }
            cuts.append((snapped, novelty[n]))
        }
        cuts.sort { $0.unit < $1.unit }
        let bounds = [0] + cuts.map(\.unit) + [U]
        var segs: [Segment] = []
        for s in 0..<(bounds.count - 1) {
            segs.append(Segment(startUnit: bounds[s], endUnit: bounds[s + 1], start: starts[bounds[s]],
                                novelty: s == 0 ? 1 : cuts[s - 1].value))
        }

        // 4. Group by mean feature vector.
        func meanVector(_ s: Segment) -> [Float] {
            var v = [Float](repeating: 0, count: D)
            for u in s.startUnit..<s.endUnit { for d in 0..<D { v[d] += F[u * D + d] } }
            var ss: Float = 0; vDSP_svesq(v, 1, &ss, vDSP_Length(D))
            let inv = ss > 1e-12 ? 1 / ss.squareRoot() : 0
            return v.map { $0 * inv }
        }
        let means = segs.map(meanVector)
        let groups = cluster(means, dims: D)
        for i in segs.indices { segs[i].group = groups[i] }
        // Neighbours in the same group are one section.
        var merged: [Segment] = []
        for sg in segs {
            if let last = merged.last, last.group == sg.group { merged[merged.count - 1].endUnit = sg.endUnit } else { merged.append(sg) }
        }
        segs = merged
        return label(segs, unitLevel: unitLevel)
    }

    /// Average-linkage clustering of unit vectors. Returns a group per item, numbered by first appearance.
    static func cluster(_ v: [[Float]], dims D: Int) -> [Int] {
        let n = v.count
        var sim = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in i..<n { var d: Float = 0; vDSP_dotpr(v[i], 1, v[j], 1, &d, vDSP_Length(D)); sim[i][j] = d; sim[j][i] = d } }
        var clusters = (0..<n).map { [$0] }
        while clusters.count > 1 {
            var best: (Int, Int, Float) = (0, 1, -2)
            for a in 0..<clusters.count {
                for b in (a + 1)..<clusters.count {
                    var t: Float = 0
                    for i in clusters[a] { for j in clusters[b] { t += sim[i][j] } }
                    let avg = t / Float(clusters[a].count * clusters[b].count)
                    if avg > best.2 { best = (a, b, avg) }
                }
            }
            let force = clusters.count > maxGroups && best.2 > 0.1
            guard best.2 >= joinSimilarity || force else { break }
            clusters[best.0] += clusters[best.1]
            clusters.remove(at: best.1)
        }
        var group = [Int](repeating: 0, count: n)
        for (g, c) in clusters.sorted(by: { $0.min()! < $1.min()! }).enumerated() { for i in c { group[i] = g } }
        return group
    }

    /// Names segments from their repeat groups (see the type's notes) and numbers song sections
    /// from 1 in time order.
    static func label(_ segs: [Segment], unitLevel: [Float]) -> [SongMoment] {
        guard !segs.isEmpty else { return [] }
        let groups = Set(segs.map(\.group))
        var count: [Int: Int] = [:], loud: [Int: Float] = [:]
        for s in segs {
            count[s.group, default: 0] += 1
            let lv = unitLevel[s.startUnit..<s.endUnit]
            loud[s.group, default: 0] += lv.reduce(0, +) / Float(max(1, lv.count))
        }
        let repeated = groups.filter { (count[$0] ?? 0) >= 2 }
        let chorus = groups.count >= 2 ? repeated.max { a, b in
            let ca = count[a]!, cb = count[b]!
            return ca != cb ? ca < cb : loud[a]! / Float(ca) < loud[b]! / Float(cb)
        } : nil
        var used: [String: Int] = [:]
        return segs.enumerated().map { i, s in
            let n = count[s.group] ?? 1
            let base: String
            if s.group == chorus { base = "Chorus" }
            else if n >= 2 { base = "Verse" }
            else if i == 0 { base = "Intro" }
            else if i == segs.count - 1 { base = "Outro" }
            else { base = "Bridge" }
            var name = base
            if CueLabelPresetStore.isSongSection(base) {
                used[base, default: 0] += 1
                name = "\(base) \(used[base]!)"
            }
            let letter = SongMoment.letter(s.group)
            let detail = n >= 2 ? "Sounds like the other \(letter) sections (\(n) in all). A guess from the audio."
                                : "Doesn't repeat elsewhere in the song. A guess from the audio."
            return SongMoment(time: max(0, s.start), kind: .section, strength: Double(0.25 + 0.75 * s.novelty), label: name,
                              cueTypeName: SongMoment.Kind.section.suggestedTypeName, group: s.group, detail: detail)
        }
    }
}
