import Foundation

/// Derives a human-readable project name from the EXIF DateTimeOriginal
/// values of the photos in a shoot. Full month names always; literal
/// day or month-bracketed ranges — no "dominant month" collapsing.
/// When no dates are available, falls back to the folder name so the
/// user still sees something sensible while EXIF is loading.
enum ProjectNameDeriver {

    /// `dates` may be a subset of the shoot's photos (EXIF loads in
    /// batches); the deriver picks the min and max regardless of how
    /// many points it has. `folderName` is the last path component of
    /// the shoot folder and is returned verbatim when `dates` is
    /// empty.
    static func derive(from dates: [Date],
                       folderName: String,
                       calendar: Calendar = .current,
                       locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            return folderName
        }
        var cal = calendar
        cal.locale = locale
        let minC = cal.dateComponents([.year, .month, .day], from: minDate)
        let maxC = cal.dateComponents([.year, .month, .day], from: maxDate)
        guard let minY = minC.year, let minM = minC.month, let minD = minC.day,
              let maxY = maxC.year, let maxM = maxC.month, let maxD = maxC.day else {
            return folderName
        }

        // Single day → "2026-March-14"
        if minY == maxY && minM == maxM && minD == maxD {
            return "\(minY)-\(monthName(minM, locale: locale))-\(twoDigit(minD))"
        }

        // Same month/year → "2026-March-14_to_18"
        if minY == maxY && minM == maxM {
            return "\(minY)-\(monthName(minM, locale: locale))-\(twoDigit(minD))_to_\(twoDigit(maxD))"
        }

        // Same year, different months → "2026-March-14_to_April-02"
        if minY == maxY {
            return "\(minY)-\(monthName(minM, locale: locale))-\(twoDigit(minD))_to_\(monthName(maxM, locale: locale))-\(twoDigit(maxD))"
        }

        // Different years → "2026-December-30_to_2027-January-02"
        return "\(minY)-\(monthName(minM, locale: locale))-\(twoDigit(minD))_to_\(maxY)-\(monthName(maxM, locale: locale))-\(twoDigit(maxD))"
    }

    /// Full English month name for the 1-based month number.
    private static func monthName(_ month: Int, locale: Locale) -> String {
        let symbols = monthSymbols(locale: locale)
        let idx = month - 1
        guard symbols.indices.contains(idx) else { return "\(month)" }
        return symbols[idx]
    }

    private static func monthSymbols(locale: Locale) -> [String] {
        // Cache one DateFormatter — instantiation is non-trivial and
        // the deriver may be called many times as EXIF batches flush.
        if let cached = cachedSymbols, cachedLocale?.identifier == locale.identifier {
            return cached
        }
        let f = DateFormatter()
        f.locale = locale
        let syms = f.standaloneMonthSymbols ?? f.monthSymbols ?? []
        cachedSymbols = syms
        cachedLocale = locale
        return syms
    }

    nonisolated(unsafe) private static var cachedSymbols: [String]?
    nonisolated(unsafe) private static var cachedLocale: Locale?

    private static func twoDigit(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
