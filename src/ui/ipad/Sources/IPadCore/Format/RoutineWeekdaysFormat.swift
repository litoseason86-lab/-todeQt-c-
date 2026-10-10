import Foundation
public enum RoutineWeekdaysFormat {
    public static let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    // 仅重写 QML 星期短标签与选择状态，合法性仍交给 RoutineManager。
    public static func text(_ mask: Int) -> String {
        guard mask > 0 else { return "未设置" }
        if mask == 127 { return "每天" }
        if mask == 31 { return "工作日" }
        if mask == 96 { return "周末" }
        let on = (0..<7).filter { mask & (1 << $0) != 0 }
        guard !on.isEmpty else { return "未设置" }
        let off = (0..<7).filter { mask & (1 << $0) == 0 }
        if off.count == 1 { return "除" + names[off[0]] }
        return "周" + on.map { String(names[$0].dropFirst()) }.joined()
    }
    public static func normalize(_ mask: Int) -> Int { mask > 0 && mask <= 127 ? mask : 127 }
    public static func toggle(_ mask: Int, bit: Int) -> Int { mask & bit != 0 ? mask & ~bit : mask | bit }
}
