import Foundation

func formatBytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: Int64(b))
}

func formatRate(_ bps: UInt64) -> String {
    "\(formatBytes(bps))/s"
}

func formatETA(remaining: UInt64, bps: UInt64) -> String {
    guard bps > 0 else { return "—" }
    let seconds = remaining / bps
    if seconds < 60 { return "<1m" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let mins = minutes % 60
    if hours < 24 { return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m" }
    let days = hours / 24
    let hrs = hours % 24
    return hrs == 0 ? "\(days)d" : "\(days)d \(hrs)h"
}
