#ifndef APPLEUBIQUITOUSITEM_H
#define APPLEUBIQUITOUSITEM_H

#include <QString>

// iCloud 云盘里单个文件的同步状态（macOS 与 iOS 是同一套 Foundation 接口）。
// 头文件保持纯 C++，平台层的 C++ 代码可以直接包含；ObjC 细节在 .mm 里。
namespace AppleUbiquitousItem {

// 这个文件往 iCloud 上传时出的错（例如 iCloud 空间已满），用系统给的说明文字。
// 上传正常、还在排队、查不到或者文件不在 iCloud 里，都返回空：只在确实出错时提醒，不猜。
QString uploadProblem(const QString& absolutePath);

} // namespace AppleUbiquitousItem

#endif // APPLEUBIQUITOUSITEM_H
