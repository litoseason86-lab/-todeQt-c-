#ifndef IOSBACKGROUNDTASK_H
#define IOSBACKGROUNDTASK_H

#include <QString>

#include <functional>

// 向系统要一点后台时间，把手头的事做完（切到后台时写出攒下的同步改动）。
// 返回的函数在做完时调用，把时间还给系统；可以调用多次，只有第一次生效。
// 系统给的时间用完了还没调用，也会自动结束：不结束的话，系统会直接终止应用。
std::function<void()> beginIosBackgroundTask(const QString& name);

#endif // IOSBACKGROUNDTASK_H
