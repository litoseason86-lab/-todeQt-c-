import Foundation

public enum DashboardFormat {
    public static func greeting(for hour: Int) -> String {
        if hour < 5 { return "夜深了" }
        if hour < 11 { return "早上好" }
        if hour < 13 { return "中午好" }
        if hour < 18 { return "下午好" }
        if hour < 23 { return "晚上好" }
        return "夜深了"
    }

    public static func totalHoursText(seconds: Int) -> String {
        let hours = Double(max(0, seconds)) / 3600
        if hours >= 100 { return String(Int(hours.rounded())) }
        return String(format: "%.1f", hours.rounded(toPlaces: 1))
    }

    public static func equivalentDaysText(seconds: Int) -> String {
        let days = Double(max(0, seconds)) / 86400
        return String(format: "%.1f", days.rounded(toPlaces: 1))
    }

    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
