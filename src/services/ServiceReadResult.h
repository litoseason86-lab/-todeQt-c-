#pragma once
#include <QString>

// 只读调用通过返回值区分空结果、目标不存在与数据库失败，不向无关页面发送失败信号。
enum class ServiceReadError { None, InvalidArgument, NotFound, Database, LimitExceeded };
template<typename T> struct ServiceReadResult
{
    T value {};
    ServiceReadError error = ServiceReadError::None;
    bool ok() const { return error == ServiceReadError::None; }
};
