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

private:
    void* m_impl = nullptr; // PTStatusBarController*（ObjC）
};

#endif // MACSTATUSBARCONTROLLER_H
