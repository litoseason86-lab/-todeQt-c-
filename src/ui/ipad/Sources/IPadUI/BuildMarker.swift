import IPadCore

// 两个 Swift 模块分开编译：界面模块只能经桥接访问业务服务。
public enum IPadUIBuildMarker {
    public static let initialPage = PageID.dashboard
}
