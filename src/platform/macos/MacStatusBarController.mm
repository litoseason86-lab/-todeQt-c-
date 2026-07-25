#import "MacStatusBarController.h"

#import "../../services/TrayController.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 菜单栏的 ObjC 宿主：持有 NSStatusItem 与菜单项，把点击转发回平台无关的 TrayController。
@interface PTStatusBarController : NSObject
@property (nonatomic, assign) TrayController* controller;
@property (nonatomic, strong) NSStatusItem* statusItem;
@property (nonatomic, strong) NSMenuItem* taskItem;
@property (nonatomic, strong) NSMenuItem* stateItem;
@property (nonatomic, strong) NSMenuItem* timeItem;
@property (nonatomic, strong) NSMenuItem* pauseItem;
@property (nonatomic, strong) NSMenuItem* resumeItem;
@property (nonatomic, strong) NSMenuItem* stopItem;
- (instancetype)initWithController:(TrayController*)controller;
- (void)applyDisplay:(const TrayDisplay&)display;
@end

@implementation PTStatusBarController

- (instancetype)initWithController:(TrayController*)controller
{
    self = [super init];
    if (!self) {
        return nil;
    }
    self.controller = controller;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🍅";

    NSMenu* menu = [[NSMenu alloc] init];
    // 自行管理启用态，避免 AppKit 因缺 action 自动禁用只读信息项。
    menu.autoenablesItems = NO;

    self.taskItem = [menu addItemWithTitle:@"未在专注" action:nil keyEquivalent:@""];
    self.taskItem.enabled = NO;
    self.stateItem = [menu addItemWithTitle:@"状态：空闲" action:nil keyEquivalent:@""];
    self.stateItem.enabled = NO;
    self.timeItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    self.timeItem.enabled = NO;
    self.timeItem.hidden = YES;

    [menu addItem:[NSMenuItem separatorItem]];

    self.pauseItem = [menu addItemWithTitle:@"暂停" action:@selector(pauseClicked) keyEquivalent:@""];
    self.pauseItem.target = self;
    self.resumeItem = [menu addItemWithTitle:@"继续" action:@selector(resumeClicked) keyEquivalent:@""];
    self.resumeItem.target = self;
    self.stopItem = [menu addItemWithTitle:@"停止专注" action:@selector(stopClicked) keyEquivalent:@""];
    self.stopItem.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* showItem = [menu addItemWithTitle:@"显示主窗口" action:@selector(showClicked) keyEquivalent:@""];
    showItem.target = self;
    NSMenuItem* quitItem = [menu addItemWithTitle:@"退出" action:@selector(quitClicked) keyEquivalent:@"q"];
    quitItem.target = self;

    self.statusItem.menu = menu;
    return self;
}

- (void)applyDisplay:(const TrayDisplay&)display
{
    // 空闲（无标题）时菜单栏退回番茄图标，不清空成看不见的空状态项。
    self.statusItem.button.title = display.title.isEmpty() ? @"🍅" : display.title.toNSString();

    self.taskItem.title = display.taskLine.toNSString();
    self.stateItem.title = display.stateLine.toNSString();

    self.timeItem.title = display.timeLine.toNSString();
    self.timeItem.hidden = display.timeLine.isEmpty();

    // 暂停/继续互斥显示；停止按可用态启用。
    self.pauseItem.hidden = !display.canPause;
    self.resumeItem.hidden = !display.canResume;
    self.stopItem.enabled = display.canStop;
    self.stopItem.hidden = !display.canStop;
}

- (void)pauseClicked { if (self.controller) self.controller->requestPause(); }
- (void)resumeClicked { if (self.controller) self.controller->requestResume(); }
- (void)stopClicked { if (self.controller) self.controller->requestStop(); }
- (void)showClicked { if (self.controller) self.controller->requestShowWindow(); }
- (void)quitClicked { if (self.controller) self.controller->requestQuit(); }

@end

MacStatusBarController::MacStatusBarController(TrayController* controller)
{
    PTStatusBarController* impl = [[PTStatusBarController alloc] initWithController:controller];
    // 跨越 void* 边界持有强引用（ARC）。
    m_impl = (void*)CFBridgingRetain(impl);
}

MacStatusBarController::~MacStatusBarController()
{
    if (m_impl) {
        CFBridgingRelease(m_impl);
        m_impl = nullptr;
    }
}

void MacStatusBarController::updateDisplay(const TrayDisplay& display)
{
    if (!m_impl) {
        return;
    }
    PTStatusBarController* impl = (__bridge PTStatusBarController*)m_impl;
    [impl applyDisplay:display];
}
