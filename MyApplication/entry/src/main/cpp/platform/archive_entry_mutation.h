#pragma once
#include <string>

namespace amcl::archive {
// 传入已打开的原父目录和原条目。新名称为空表示删除，返回空串表示已提交。
std::string MutateConfirmedEntry(int parent, int entry, const std::string &name, const std::string &newName);
}
