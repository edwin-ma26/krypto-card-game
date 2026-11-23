import SwiftUI
import Charts

/// Profile › Stats. One mode at a time (Solo / Daily / Ranked): headline
/// tiles, then a solve-time chart with a smoothed trend, then either a rating
/// chart (rated modes) or a four-week streak grid (daily).
struct StatsPage: View {
    @ObservedObject private var log = StatsLog.shared

    /// Straight off the profile doc, loaded by the hub.
    var elo: Int?
    var rankedTier: Int?
    var streak: Int?
    var longestStreak: Int?

    // Solo lifetime counters predate the per-solve log, so the tiles use them
    // and only the charts depend on the log.
    @AppStorage("gamesWon") private var gamesWon = 0
    @AppStorage("bestTime") private var bestTime = 0
    @AppStorage("totalSolveTime") private var totalSolveTime = 0
    @AppStorage("soloRating") private var soloRating = SoloRating.initial
    @AppStorage("soloTier") private var soloTier = -1
    @AppStorage("soloPuzzlesCompleted") private var soloPuzzlesCompleted = 0
    @StateObject private var remote = Remote.shared

    @State private var mode: SolveRecord.Kind = .solo
    @State private var range: HistoryRange = .thirty

    enum HistoryRange: String, CaseIterable, Identifiable {
        case ten = "10", thirty = "30", all = "All"
        var id: String { rawValue }
        var count: Int? { self == .all ? nil : Int(rawValue) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modePicker
                tiles
                solveTimeCard
                if mode == .daily { streakGridCard } else { ratingCard }
                if log.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing history…")
                    }
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.easeInOut(duration: 0.2), value: range)
    }

    // MARK: Data

    private var modeRecords: [SolveRecord] { log.records(of: mode) }

    /// Solved puzzles in this mode, oldest first, trimmed to the range.
    private var solvedInRange: [SolveRecord] {
        trimmed(modeRecords.filter(\.solved))
    }

    private func trimmed(_ records: [SolveRecord]) -> [SolveRecord] {
        guard let count = range.count, records.count > count else { return records }
        return Array(records.suffix(count))
    }

    private var averageInRange: Int? {
        let times = solvedInRange.compactMap(\.seconds)
        return times.isEmpty ? nil : times.reduce(0, +) / times.count
    }

    private var bestInRange: SolveRecord? {
        solvedInRange.min { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            segment(.solo, "Solo")
            segment(.daily, "Daily")
            segment(.ranked, "Ranked")
        }
        .padding(4)
        .background(.white, in: Capsule())
    }

    private func segment(_ kind: SolveRecord.Kind, _ title: String) -> some View {
        let selected = mode == kind
        return Button {
            mode = kind
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(selected ? .white : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Theme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tiles

    private var tiles: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            switch mode {
            case .solo:
                let standing = soloPuzzlesCompleted >= remote.tiers.unrankedUntil
                    ? remote.tiers.standing(rating: soloRating, held: soloTier >= 0 ? soloTier : nil) : nil
                StatTile(icon: "seal.fill", value: standing?.label ?? "Unranked",
                         label: "Rating · \(String(soloRating))", tint: standing?.color)
                StatTile(icon: "checkmark.seal.fill", value: "\(gamesWon)", label: "Solved")
                StatTile(icon: "bolt.fill", value: bestTime > 0 ? clock(bestTime) : "—", label: "Best time")
                StatTile(icon: "timer", value: gamesWon > 0 ? clock(totalSolveTime / gamesWon) : "—", label: "Average")
            case .daily:
                let dailySolved = modeRecords.filter(\.solved)
                let best = dailySolved.compactMap(\.seconds).min()
                let avg = dailySolved.isEmpty ? nil : dailySolved.compactMap(\.seconds).reduce(0, +) / dailySolved.count
                StatTile(icon: "flame.fill", value: streak.map(String.init) ?? "—", label: "Day streak")
                StatTile(icon: "crown.fill", value: longestStreak.map(String.init) ?? "—", label: "Longest streak")
                StatTile(icon: "bolt.fill", value: best.map(clock) ?? "—", label: "Best time")
                StatTile(icon: "timer", value: avg.map(clock) ?? "—", label: "Average")
            case .ranked:
                let wins = modeRecords.filter { $0.won == true }.count
                let losses = modeRecords.filter { $0.won == false }.count
                let played = wins + losses
                let rating = elo ?? modeRecords.last?.ratingAfter
                let peak = modeRecords.compactMap(\.ratingAfter).max()
                // Tier only once placed (a held tier is stored); the rating
                // itself is still shown in the label.
                let placed = rankedTier != nil
                let standing = placed ? rating.map { remote.tiers.standing(rating: $0, held: rankedTier) } : nil
                let peakStanding = placed ? peak.map { remote.tiers.standing(rating: $0, held: nil) } : nil
                StatTile(icon: "seal.fill", value: standing?.label ?? (rating != nil ? "Unranked" : "—"),
                         label: rating.map { "Rating · \(String($0))" } ?? "Rating", tint: standing?.color)
                StatTile(icon: "flag.checkered", value: played > 0 ? "\(wins)–\(losses)" : "—", label: "Record")
                StatTile(icon: "percent", value: played > 0 ? "\(Int((Double(wins) / Double(played) * 100).rounded()))%" : "—", label: "Win rate")
                StatTile(icon: "chart.line.uptrend.xyaxis", value: peakStanding?.label ?? "—",
                         label: peak.map { "Peak · \(String($0))" } ?? "Peak", tint: peakStanding?.color)
            }
        }
    }

    // MARK: Solve time chart

    private struct TimePoint: Identifiable {
        let id: Int
        let seconds: Int
        let trend: Double
        let at: Date
    }

    private var timePoints: [TimePoint] {
        let records = solvedInRange
        let times = records.compactMap(\.seconds)
        // Trailing five-solve mean, so one slow puzzle reads as a blip on a
        // trend rather than a cliff in the line.
        let window = 5
        return records.enumerated().map { index, record in
            let start = max(0, index - window + 1)
            let slice = times[start...index]
            return TimePoint(
                id: index + 1, seconds: record.seconds ?? 0,
                trend: Double(slice.reduce(0, +)) / Double(slice.count), at: record.at
            )
        }
    }

    private var solveTimeCard: some View {
        StatsCard(title: "SOLVE TIME", trailing: rangePills) {
            let points = timePoints
            if points.count < 2 {
                emptyState(
                    icon: "clock",
                    text: mode == .ranked
                        ? "Win a couple of ranked matches and your solve times show up here."
                        : "Solve a couple of puzzles and your times show up here."
                )
            } else {
                HStack(spacing: 14) {
                    if let averageInRange {
                        legend(color: Theme.inkMuted, text: "Avg \(clock(averageInRange))", dashed: true)
                    }
                    if let best = bestInRange?.seconds {
                        legend(color: Theme.accent, text: "Best \(clock(best))", dashed: false)
                    }
                    Spacer()
                }
                solveTimeChart(points)
                    .frame(height: 190)
                Text("Last \(points.count) \(mode == .ranked ? "wins" : "solves"), oldest first")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func solveTimeChart(_ points: [TimePoint]) -> some View {
        let maxSeconds = Double(points.map(\.seconds).max() ?? 60)
        let smooth = points.count >= 6
        let bestID = bestInRange.flatMap { best in points.first { $0.at == best.at && $0.seconds == best.seconds }?.id }
        return Chart {
            ForEach(points) { p in
                if smooth {
                    AreaMark(x: .value("Solve", p.id), y: .value("Trend", p.trend))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    LineMark(x: .value("Solve", p.id), y: .value("Trend", p.trend))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    PointMark(x: .value("Solve", p.id), y: .value("Seconds", p.seconds))
                        .foregroundStyle(p.id == bestID ? Theme.accent : Theme.inkMuted.opacity(0.45))
                        .symbolSize(p.id == bestID ? 110 : 34)
                } else {
                    LineMark(x: .value("Solve", p.id), y: .value("Seconds", p.seconds))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    PointMark(x: .value("Solve", p.id), y: .value("Seconds", p.seconds))
                        .foregroundStyle(p.id == bestID ? Theme.accent : .white)
                        .symbolSize(p.id == bestID ? 110 : 60)
                    PointMark(x: .value("Solve", p.id), y: .value("Seconds", p.seconds))
                        .foregroundStyle(Theme.accent)
                        .symbolSize(p.id == bestID ? 110 : 26)
                }
            }
            if let averageInRange {
                RuleMark(y: .value("Average", averageInRange))
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0.5...(Double(points.count) + 0.5))
        .chartYScale(domain: 0...(maxSeconds * 1.15 + 5))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.inkMuted.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(clock(Int(v)))
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    // MARK: Rating chart

    private struct RatingPoint: Identifiable {
        let id: String
        let at: Date
        let rating: Int
    }

    private var ratingPoints: [RatingPoint] {
        let rated = trimmed(modeRecords.filter { $0.ratingAfter != nil })
        return rated.map { RatingPoint(id: $0.id, at: $0.at, rating: $0.ratingAfter ?? 0) }
    }

    private var ratingCard: some View {
        StatsCard(title: "RATING", trailing: EmptyView()) {
            let points = ratingPoints
            if points.count < 2 {
                emptyState(
                    icon: "chart.line.uptrend.xyaxis",
                    text: mode == .ranked
                        ? "Your rating after each ranked match will chart here."
                        : "Your rating after each solo puzzle will chart here."
                )
            } else {
                let current = points.last!.rating
                let first = points.first!.rating
                let change = current - first
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(current))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.inkDark)
                        .monospacedDigit()
                    Text(change >= 0 ? "+\(change)" : "\(change)")
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                        .foregroundStyle(change >= 0 ? Color.green.opacity(0.85) : Color.red.opacity(0.8))
                        .monospacedDigit()
                    Text(range == .all ? "all time" : "over last \(points.count)")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                }
                ratingChart(points)
                    .frame(height: 170)
            }
        }
    }

    private func ratingChart(_ points: [RatingPoint]) -> some View {
        let ratings = points.map(\.rating)
        let low = Double(ratings.min() ?? 1200), high = Double(ratings.max() ?? 1200)
        let pad = max(15, (high - low) * 0.2)
        let sameDay = points.count >= 2 && Calendar.current.isDate(points.first!.at, inSameDayAs: points.last!.at)
        let floor = Int((low - pad).rounded(.down))
        let last = points.last
        let fill = LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0)],
                                  startPoint: .top, endPoint: .bottom)
        // Split into helpers: the marks inline in one `Chart` closure blew
        // the type-checker's budget.
        return Chart {
            ratingArea(points, floor: Double(floor), fill: fill)
            ratingLine(points)
            if let last { ratingEndpoint(last) }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.inkMuted.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: sameDay ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.inkMuted.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(String(v))
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func ratingArea(_ points: [RatingPoint], floor: Double, fill: LinearGradient) -> some ChartContent {
        ForEach(points) { p in
            AreaMark(x: .value("When", p.at), yStart: .value("Floor", floor), yEnd: .value("Rating", Double(p.rating)))
                .interpolationMethod(.monotone)
                .foregroundStyle(fill)
        }
    }

    @ChartContentBuilder
    private func ratingLine(_ points: [RatingPoint]) -> some ChartContent {
        ForEach(points) { p in
            LineMark(x: .value("When", p.at), y: .value("Rating", p.rating))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    @ChartContentBuilder
    private func ratingEndpoint(_ last: RatingPoint) -> some ChartContent {
        PointMark(x: .value("When", last.at), y: .value("Rating", last.rating))
            .foregroundStyle(.white)
            .symbolSize(90)
        PointMark(x: .value("When", last.at), y: .value("Rating", last.rating))
            .foregroundStyle(Theme.accent)
            .symbolSize(40)
    }

    // MARK: Daily streak grid

    private var streakGridCard: some View {
        let days = lastDays(28)
        let solvedKeys = Set(modeRecords.filter(\.solved).map { $0.id.replacingOccurrences(of: "daily-", with: "") })
        let solvedCount = days.filter { solvedKeys.contains($0) }.count
        return StatsCard(title: "LAST 4 WEEKS", trailing: EmptyView()) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(days, id: \.self) { key in
                    let solved = solvedKeys.contains(key)
                    let isToday = key == days.last
                    RoundedRectangle(cornerRadius: 8)
                        .fill(solved ? Theme.accent : Theme.pill)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if isToday {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.inkDark.opacity(0.5), lineWidth: 2)
                            }
                        }
                        .accessibilityLabel("\(key), \(solved ? "solved" : "not solved")")
                }
            }
            Text("\(solvedCount) of 28 days solved")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    /// UTC day keys ending today, matching how the daily puzzle keys days.
    private func lastDays(_ count: Int) -> [String] {
        (0..<count).reversed().map { offset in
            DailyPuzzleService.todayKeyUTC(Date().addingTimeInterval(-Double(offset) * 86_400))
        }
    }

    // MARK: Pieces

    private var rangePills: some View {
        HStack(spacing: 4) {
            ForEach(HistoryRange.allCases) { option in
                let selected = range == option
                Button { range = option } label: {
                    Text(option.rawValue)
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(selected ? .white : Theme.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selected ? Theme.accent : Theme.pill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func legend(color: Color, text: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            if dashed {
                Rectangle().fill(color).frame(width: 14, height: 2)
                    .mask(HStack(spacing: 3) { Rectangle(); Rectangle(); Rectangle() })
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkDark)
                .monospacedDigit()
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text(text)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

// MARK: - Shared

private struct StatTile: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint ?? Theme.accent)
            Text(value)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white).shadow(color: .black.opacity(0.05), radius: 8, y: 3))
    }
}

private struct StatsCard<Trailing: View, Content: View>: View {
    let title: String
    let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }
}
