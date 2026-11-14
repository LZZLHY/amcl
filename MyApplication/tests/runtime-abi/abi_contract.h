#pragma once
#include <stdexcept>

/** 跨 DSO 测试类型：虚继承和有状态异常用于触发真实 RTTI/展开路径。 */
struct AbiBase {
    virtual ~AbiBase() = default;
    virtual int value() const = 0;
};
struct AbiDerived : virtual AbiBase {
    int value() const override { return 73; }
};
struct AbiError : std::runtime_error {
    explicit AbiError(int code) : std::runtime_error("cross-dso"), code(code) {}
    int code;
};

/** subject 库拥有初始化状态；runner 通过这些边界观察发布、重试和线程析构。 */
extern "C" {
int abi_static_value();
int abi_static_constructions();
int abi_retry_value();
int abi_retry_attempts();
void abi_throw(int code);
AbiBase* abi_create();
void abi_touch_tls();
int abi_tls_destructors();
}
