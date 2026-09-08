import AppKit

// Main-run-loop state; each provider has its own worker and at most one pending
// forced refresh. A slow endpoint cannot hold up another provider's display.
final class RefreshController {
    struct Reader {
        let key: String
        let fetch: (Bool) -> ProviderStatus
    }
    private let readers: [Reader]
    private var running = Set<String>()
    private var pending = Set<String>()
    private var timer: Timer?
    var onUpdate: (ProviderStatus) -> Void = { _ in }
    var onActivity: (Bool) -> Void = { _ in }

    init(readers: [Reader] = [
        Reader(key: "Cx", fetch: { readCodex(force: $0) }),
        Reader(key: "Cl", fetch: { readClaude(force: $0) }),
        Reader(key: "Gm", fetch: { _ in readGemini() })
    ]) { self.readers = readers }

    func start(interval: TimeInterval) {
        stop()
        let cadence = interval.isFinite ? max(0.05, interval) : 15
        let timer = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = min(1, cadence * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    func refresh(force: Bool = false) {
        for reader in readers { request(reader, force: force) }
    }

    private func request(_ reader: Reader, force: Bool) {
        guard !running.contains(reader.key) else {
            if force { pending.insert(reader.key) }
            return
        }
        running.insert(reader.key); onActivity(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = reader.fetch(force)
            // Common modes also deliver results while an NSMenu is tracking.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self = self else { return }
                self.running.remove(reader.key)
                if self.pending.remove(reader.key) != nil {
                    // Settings/login may have changed during the request. Discard
                    // its obsolete result and fetch once with the latest settings.
                    self.request(reader, force: true)
                } else {
                    self.onUpdate(result)
                }
                self.onActivity(!self.running.isEmpty)
            }
        }
    }
}
