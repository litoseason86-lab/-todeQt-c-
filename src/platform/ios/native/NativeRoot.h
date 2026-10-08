#pragma once

// 启动与生命周期钩子只用于 iOS 装配，不向 Swift 暴露 Qt 或 UIKit 类型。
bool shouldUseNativeRoot();
void installNativeRoot();
void flushNativeEdits();
