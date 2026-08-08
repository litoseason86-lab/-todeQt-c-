#ifndef MACSTATUSBARCONTROLLER_H
#define MACSTATUSBARCONTROLLER_H

#include "../../services/TrayController.h"

// NSStatusItem 菜单栏实现。头文件纯 C++（ObjC 对象藏在 void* 后），main.cpp 可直接包含。
// 只在构造时创建一次状态项与菜单，之后仅更新文本与启用态，绝不重建对象。
class MacStatusBarController : public TrayView
{
public:
    explicit MacStatusBarController(TrayController* controller);
    ~MacStatusBarController() override;
    MacStatusBarController(const MacStatusBarController&) = delete;
    MacStatusBarController& operator=(const MacStatusBarController&) = delete;
    MacStatusBarController(MacStatusBarController&&) = delete;
    MacStatusBarController& operator=(MacStatusBarController&&) = delete;

    void updateDisplay(const TrayDisplay& display) override;

    // 断开对 TrayController 的裸指针引用。菜单项的点击回调直接调用控制器，
    // 而 ObjC 宿主只持有一个 assign（弱）指针——控制器先销毁的话，
    // 那五个回调里的 `if (self.controller)` 挡不住悬垂指针（非空但已失效）。
    //
    // 宿主必须在控制器销毁前调用一次。目前 main.cpp 的栈声明顺序恰好保证了
    // 正确的析构次序，但那是隐式的、代码里没有任何地方说明；显式解绑之后，
    // 正确性不再依赖声明顺序。
    void detachController();

private:
    void* m_impl = nullptr; // PTStatusBarController*（ObjC）
};

#endif // MACSTATUSBARCONTROLLER_H
