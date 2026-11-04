import Foundation

// MARK: - Per-model usage from Claude Code's own history
//
// Claude Code writes every assistant message — with the model and the tokens
// it used — to ~/.claude/projects/**/*.jsonl on this Mac. Those tokens, priced
// at the published API rates, are compared with the percentage the provider
// reports, which calibrates "how much of the limit one dollar of work uses".
// Nothing here leaves the Mac, and none of it changes a reported number.

/// The three Claude families the advice chooses between, at their current generation.
enum ModelFamily: String, CaseIterable {
    case haiku = "Haiku", sonnet = "Sonnet", opus = "Opus"

    static let generation = "5.5"
    var title: String { "\(rawValue) \(Self.generation)" }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The published API price of this family's current generation. Haiku 5.5
    /// costs five times as much once a prompt passes 100K tokens.
    func price(longPrompt: Bool) -> ModelPrice {
        switch self {
        case .haiku: return longPrompt ? ModelPrice(input: 0.50, output: 2.50) : ModelPrice(input: 0.10, output: 0.50)
        case .sonnet: return ModelPrice(input: 2, output: 10, cacheRead: 0.20)
        case .opus: return ModelPrice(input: 4, output: 20, cacheRead: 0.20)
        }
    }
}

/// Dollars per million tokens.
struct ModelPrice: Equatable {
    var input: Double, output: Double, cacheRead: Double, write5m: Double, write1h: Double

    /// Cache reads default to 0.1x the input price, writes to 1.25x (5 minutes) and 2x (1 hour).
    init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        write5m = input * 1.25
        write1h = input * 2
    }

    func cost(_ t: TokenCounts) -> Double {
        (Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * cacheRead
            + Double(t.write5m) * write5m + Double(t.write1h) * write1h) / 1e6
    }
}

/// What a model id seen in the history costs per token; nil for one whose price isn't known.
func priceOf(modelID: String, longPrompt: Bool) -> ModelPrice? {
    switch modelID.hasPrefix("claude-") ? String(modelID.dropFirst(7)) : modelID {
    case "haiku-5-5": return ModelFamily.haiku.price(longPrompt: longPrompt)
    case "sonnet-5-5", "sonnet-5": return ModelFamily.sonnet.price(longPrompt: false)
    case "opus-5-5": return ModelFamily.opus.price(longPrompt: false)
    case "opus-5", "opus-4-8", "opus-4-7", "opus-4-6": return ModelPrice(input: 5, output: 25)
    case "fable-5-1": return ModelPrice(input: 10, output: 50, cacheRead: 0.25)
    case "fable-5": return ModelPrice(input: 10, output: 50)
    case "sonnet-4-6": return ModelPrice(input: 3, output: 15)
    case "haiku-4-5": return ModelPrice(input: 1, output: 5)
    default: return nil
    }
}

func familyOf(modelID: String) -> ModelFamily? {
    ModelFamily.allCases.first { modelID.contains($0.rawValue.lowercased()) }
}

struct TokenCounts: Codable, Equatable {
    var input = 0, output = 0, cacheRead = 0, write5m = 0, write1h = 0
    var promptTokens: Int { input + cacheRead + write5m + write1h }
    mutating func add(_ other: TokenCounts) {
        input += other.input; output += other.output; cacheRead += other.cacheRead
        write5m += other.write5m; write1h += other.write1h
    }
}

// MARK: - Ledger

struct LedgerSlice: Equatable {
    var actualCost = 0.0                              // what the work cost on the models that did it
    var actualByFamily: [ModelFamily: Double] = [:]
    var repriced: [ModelFamily: Double] = [:]         // the same tokens, priced as if one family did it all
    var activeHours = 0                               // hours in which anything was sent
}

/// Tokens by 15-minute bucket and model, read from Claude Code's history.
struct UsageLedger: Codable, Equatable {
    static let bucketSeconds = 900.0
    static let longPrompt = 100_000

    struct Cursor: Codable, Equatable {
        var offset: Int
        var recent: [String]    // the last few message ids, since one message is written once per content block
    }

    /// bucket index → "model|L" (prompt over 100K tokens) or "model|S" → tokens
    var buckets: [Int: [String: TokenCounts]] = [:]
    var files: [String: Cursor] = [:]

    var isEmpty: Bool { buckets.isEmpty }

    /// Returns false when the model's price isn't known: it is left out, never guessed.
    @discardableResult
    mutating func add(at t: Double, model: String, tokens: TokenCounts) -> Bool {
        guard priceOf(modelID: model, longPrompt: false) != nil else { return false }
        let long = tokens.promptTokens > Self.longPrompt
        buckets[Int((t / Self.bucketSeconds).rounded(.down)), default: [:]]["\(model)|\(long ? "L" : "S")", default: TokenCounts()].add(tokens)
        return true
    }

    func slice(from: Double, to: Double) -> LedgerSlice {
        guard from.isFinite, to.isFinite, to > from else { return LedgerSlice() }
        let low = Int((from / Self.bucketSeconds).rounded(.up)), high = Int((to / Self.bucketSeconds).rounded(.down))
        var result = LedgerSlice()
        var hours = Set<Int>()
        for (index, models) in buckets where index >= low && index <= high {
            hours.insert(index / 4)
            for (key, tokens) in models {
                guard let bar = key.lastIndex(of: "|") else { continue }
                let id = String(key[..<bar]), long = key[key.index(after: bar)...] == "L"
                guard let price = priceOf(modelID: id, longPrompt: long) else { continue }
                let cost = price.cost(tokens)
                result.actualCost += cost
                if let family = familyOf(modelID: id) { result.actualByFamily[family, default: 0] += cost }
                for family in ModelFamily.allCases {
                    result.repriced[family, default: 0] += family.price(longPrompt: long).cost(tokens)
                }
            }
        }
        result.activeHours = hours.count
        return result
    }

    // MARK: Reading the history

    /// Nothing older than a week is kept: the longest window forecast is a weekly one.
    static let horizon = 7 * 86400.0

    /// Adds what Claude Code has written under `root` since the last scan. Only
    /// the bytes after each file's saved offset are read, and only files touched
    /// in the last week. Returns whether anything changed.
    @discardableResult
    mutating func scan(root: String, now: Double, horizon: Double = UsageLedger.horizon) -> Bool {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return false }
        var changed = false
        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            // One scan can read gigabytes: release Foundation's temporary objects per file, not per scan.
            autoreleasepool {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate?.timeIntervalSince1970, modified >= now - horizon,
                      let size = values.fileSize else { return }
                seen.insert(url.path)
                var cursor = files[url.path] ?? Cursor(offset: 0, recent: [])
                if cursor.offset > size { cursor = Cursor(offset: 0, recent: []) }   // rewritten: start over
                if cursor.offset < size, consume(url, &cursor, now: now, horizon: horizon) { changed = true }
                if files[url.path] != cursor { files[url.path] = cursor; changed = true }
            }
        }
        let known = files.count, count = buckets.count
        files = files.filter { seen.contains($0.key) }                        // gone, or untouched for a week
        let oldest = Int(((now - horizon) / Self.bucketSeconds).rounded(.down))
        buckets = buckets.filter { $0.key >= oldest }                          // and nothing older than a week
        return changed || files.count != known || buckets.count != count
    }

    private mutating func consume(_ url: URL, _ cursor: inout Cursor, now: Double, horizon: Double) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(cursor.offset))) != nil else { return false }
        var pending = Data()
        var position = cursor.offset
        var added = false
        var finished = false
        while !finished {
            // Each chunk is a Foundation object that would otherwise live until the whole file is read.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { finished = true; return }
                pending.append(chunk)
                let used: Int = pending.withUnsafeBytes { bytes in
                    var start = 0
                    while start < bytes.count, let found = memchr(bytes.baseAddress! + start, 0x0A, bytes.count - start) {
                        let end = bytes.baseAddress!.distance(to: UnsafeRawPointer(found))
                        let line = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                        autoreleasepool { if record(line, &cursor, now: now, horizon: horizon) { added = true } }
                        start = end + 1
                    }
                    return start
                }
                position += used
                // Copy the unfinished tail out: removeFirst would keep the whole front of the file alive.
                pending = pending.subdata(in: used..<pending.count)
            }
        }
        cursor.offset = position   // a line still being written stays unread until it is complete
        return added
    }

    private static let usageNeedle = Array("\"usage\"".utf8), assistantNeedle = Array("\"type\":\"assistant\"".utf8)
    private static let messageNeedle = Array("\"message\":{\"model\":\"".utf8), idNeedle = Array("\",\"id\":\"".utf8)

    private static func find(_ needle: [UInt8], in bytes: UnsafeRawBufferPointer) -> Int? {
        guard let base = bytes.baseAddress, bytes.count >= needle.count,
              let hit = memmem(base, bytes.count, needle, needle.count) else { return nil }
        return base.distance(to: UnsafeRawPointer(hit))
    }

    /// The message id read straight from the bytes (Claude Code writes `"message":{"model":"…","id":"…"`),
    /// so a message written once per content block is recognized without parsing it again.
    private static func messageID(_ line: UnsafeRawBufferPointer) -> String? {
        guard let at = find(messageNeedle, in: line) else { return nil }
        let rest = UnsafeRawBufferPointer(rebasing: line[(at + messageNeedle.count)...].prefix(160))
        guard let id = find(idNeedle, in: rest) else { return nil }
        let tail = UnsafeRawBufferPointer(rebasing: rest[(id + idNeedle.count)...])
        guard let quote = tail.firstIndex(of: 0x22), quote > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: tail[..<quote]), as: UTF8.self)
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private mutating func record(_ line: UnsafeRawBufferPointer, _ cursor: inout Cursor, now: Double, horizon: Double) -> Bool {
        guard line.count > 100, Self.find(Self.assistantNeedle, in: line) != nil, Self.find(Self.usageNeedle, in: line) != nil else { return false }
        if let id = Self.messageID(line), cursor.recent.contains(id) { return false }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, let stamp = object["timestamp"] as? String,
              let time = (Self.timestamp.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp))?.timeIntervalSince1970,
              time >= now - horizon, time <= now + 300 else { return false }
        if let id = (message["id"] as? String) ?? (object["uuid"] as? String), !id.isEmpty {
            if cursor.recent.contains(id) { return false }
            cursor.recent.append(id)
            if cursor.recent.count > 8 { cursor.recent.removeFirst() }
        }
        func count(_ source: [String: Any]?, _ key: String) -> Int? { (source?[key] as? NSNumber)?.intValue }
        let creation = usage["cache_creation"] as? [String: Any]
        let tokens = TokenCounts(input: count(usage, "input_tokens") ?? 0, output: count(usage, "output_tokens") ?? 0,
                                 cacheRead: count(usage, "cache_read_input_tokens") ?? 0,
                                 write5m: count(creation, "ephemeral_5m_input_tokens") ?? count(usage, "cache_creation_input_tokens") ?? 0,
                                 write1h: count(creation, "ephemeral_1h_input_tokens") ?? 0)
        return add(at: time, model: model, tokens: tokens)
    }
}

// MARK: - Keeping it up to date

/// Scans Claude Code's history in the background (at most every couple of
/// minutes) and keeps the result on disk so a restart doesn't rescan a week.
final class LedgerStore {
    private let queue = DispatchQueue(label: "com.sueun.aicreditsbar.ledger", qos: .utility)
    private let root: String
    private let file: URL?
    private var running = false
    private var lastRun = -Double.infinity
    private(set) var snapshot: UsageLedger

    /// Tests set AICB_DEFAULTS_SUITE; they never touch the real saved history.
    static var defaultFile: URL? {
        if ProcessInfo.processInfo.environment["AICB_DEFAULTS_SUITE"] != nil { return nil }
        let directory = ProcessInfo.processInfo.environment["AICB_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AICreditsBar")
        return directory?.appendingPathComponent("usage-ledger.json")
    }

    init(root: String = (claudeConfigDir as NSString).appendingPathComponent("projects"), file: URL? = LedgerStore.defaultFile) {
        self.root = root
        self.file = file
        snapshot = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(UsageLedger.self, from: $0) } ?? UsageLedger()
    }

    /// Call on the main thread; `completion` runs there too, only when a scan ran.
    func refresh(minimumGap: TimeInterval = 120, completion: @escaping () -> Void = {}) {
        let now = nowEpoch()
        guard !running, now - lastRun >= minimumGap else { return }
        running = true
        lastRun = now
        var work = snapshot
        let root = self.root, file = self.file
        queue.async { [weak self] in
            let changed = work.scan(root: root, now: now)
            if changed, let file = file, let data = try? JSONEncoder().encode(work) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snapshot = work
                self.running = false
                completion()
            }
        }
    }

    /// Forget everything that was read, in memory and on disk.
    func clear() {
        snapshot = UsageLedger()
        lastRun = -.infinity
        if let file = file { try? FileManager.default.removeItem(at: file) }
    }
}
