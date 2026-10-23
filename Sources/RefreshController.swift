import Foundation

/// Fetches each provider on a background queue — at most one request per
/// provider at a time, so a slow endpoint never holds up the other — and
/// reports every result on the main thread. A provider that answers HTTP 429 is
/// left alone for 5, 10, 20, then 30 minutes; the usage endpoints rate-limit hard.
final class RefreshController {
    struct Source {
        let provider: Provider
        let fetch: () throws -> Reading
    }

    private let sources: [Source]
    private var inFlight = Set<Provider>()
    private var pausedUntil: [Provider: Double] = [:]
    private var rateLimitStreak: [Provider: Int] = [:]
    private var lastRun: [Provider: Double] = [:]
    private let clock: () -> Double
    private var timer: Timer?
    private(set) var interval: TimeInterval = 0
    var isEnabled: (Provider) -> Bool = { _ in true }
    var onResult: (Provider, Result<Reading, Error>) -> Void = { _, _ in }

    init(sources: [Source] = [Source(provider: .codex, fetch: fetchCodexReading),
                              Source(provider: .claude, fetch: fetchClaudeReading)],
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.sources = sources
        self.clock = clock
    }

    /// Refresh now, then every `interval` seconds. The timer also fires while the menu is open.
    func start(every interval: TimeInterval, refreshImmediately: Bool = true) {
        stop()
        let interval = interval.isFinite && interval > 0 ? interval : 300
        self.interval = interval
        guard sources.contains(where: { isEnabled($0.provider) }) else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if refreshImmediately { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// `minimumGap` skips the refresh if one started less than that many seconds ago.
    func refresh(minimumGap: TimeInterval = 0, providers: Set<Provider>? = nil) {
        let now = clock()
        for source in sources where isEnabled(source.provider) && !inFlight.contains(source.provider)
            && (providers?.contains(source.provider) ?? true)
            && now - lastRun[source.provider, default: -.infinity] >= minimumGap
            && now >= pausedUntil[source.provider, default: 0] {
            lastRun[source.provider] = now
            inFlight.insert(source.provider)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try source.fetch() }
                RunLoop.main.perform(inModes: [.common]) {
                    guard let self = self else { return }
                    self.inFlight.remove(source.provider)
                    self.backOffIfRateLimited(source.provider, result)
                    self.onResult(source.provider, result)
                }
            }
        }
    }

    private func backOffIfRateLimited(_ provider: Provider, _ result: Result<Reading, Error>) {
        switch result {
        case .success:
            rateLimitStreak[provider] = nil
            pausedUntil[provider] = nil
        case .failure(let error):
            guard (error as? UsageError)?.rateLimited == true else { return }
            let streak = min(4, rateLimitStreak[provider, default: 0] + 1)
            rateLimitStreak[provider] = streak
            pausedUntil[provider] = clock() + min(1800, 300 * pow(2, Double(streak - 1)))
        }
    }
    deinit { timer?.invalidate() }
}
