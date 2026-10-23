import Foundation

/// The next instant at which existing data can change the UI. There is no
/// per-second redraw loop, and a closed menu has no countdown timer.
func nextDisplayChange(_ states: [ProviderState], now: Double, menuOpen: Bool) -> Double? {
    var dates: [Double] = []
    for state in states {
        guard let reading = state.reading, reading.fetchedAt.isFinite else { continue }
        let staleAt = reading.fetchedAt + 2 * Cfg.refreshInterval + 60
        if !state.restored, state.error == nil, staleAt > now { dates.append(staleAt) }
        if menuOpen {
            let age = max(0, now - reading.fetchedAt)
            let unit = age < 3600 ? 60.0 : (age < 86400 ? 3600.0 : 86400.0)
            dates.append(reading.fetchedAt + (floor(age / unit) + 1) * unit)
        }
        for window in reading.windows {
            guard let reset = sanitizeEpoch(window.resetsAt), reset > now else { continue }
            dates.append(reset)
            let remaining = reset - now
            if menuOpen, remaining >= 60 {
                // countdown() floors minutes; beyond a day it only shows hours.
                let unit = remaining >= 86400 ? 3600.0 : 60.0
                dates.append(reset - floor(remaining / unit) * unit)
            }
        }
    }
    return dates.filter { $0.isFinite && $0 >= now }.min().map { max(now + 0.05, $0 + 0.01) }
}
