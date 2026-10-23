/** 直接执行生产组事务：队列、幂等、局部门控、未变资格与试用恢复；不复制期望算法。 */
#include "touch_group_state.h"
#include <cassert>
#include <cstring>
#include <iostream>
using namespace amcl::input;

int main() {
    TouchGroupSchema schema; schema.profile = "profile-a";
    schema.groups = {{"base",true},{"tools",false},{"extra",false}};
    schema.controls.resize(3);
    for (int i=0;i<3;++i) { schema.controls[i].group=i; schema.controls[i].rank=i; }
    assert(ValidTouchGroupSchema(schema,3));
    TouchGroupState state; state.Install(schema);
    const auto baseEpoch = state.Epoch(0), originalRevision = state.Revision();
    TouchGroupCommand first{1,1,0,baseEpoch,{{1,TouchGroupOperation::Toggle}}};
    assert(state.Accept(first));
    assert(state.Advance().empty());
    assert(state.PendingPresentation() && state.Visible(1));
    const auto firstRevision = state.Revision();
    assert(firstRevision > originalRevision && state.Epoch(0)==baseEpoch);
    assert(!state.Accept(first));
    assert(state.Query(first).status==TouchGroupCommandStatus::Committed);
    auto changedPayload=first;changedPayload.actions[0].target=2;
    assert(state.Query(changedPayload).status==TouchGroupCommandStatus::Rejected);
    TouchGroupCommand second{1,2,0,baseEpoch,{{1,TouchGroupOperation::Toggle}}};
    assert(state.Accept(second));
    assert(state.Advance().empty() && state.Visible(1));
    assert(!state.Confirm(firstRevision-1));
    assert(state.Confirm(firstRevision));
    const auto hidden=state.Advance();assert(hidden.count(1)==1 && !state.Visible(1));
    assert(!state.Confirm(firstRevision));
    assert(state.Confirm(state.Revision()));
    assert(state.Query(first).status==TouchGroupCommandStatus::Presented);

    // 多目标原子提交及重复 toggle；无变化直接 Presented，不等待不存在的几何变化。
    TouchGroupCommand unchanged{1,3,0,baseEpoch,{{1,TouchGroupOperation::Toggle},{1,TouchGroupOperation::Toggle}}};
    assert(state.Accept(unchanged));state.Advance();
    assert(!state.PendingPresentation() && !state.Visible(1));
    assert(state.Query(unchanged).status==TouchGroupCommandStatus::Presented);
    TouchGroupCommand both{1,4,0,baseEpoch,{{1,TouchGroupOperation::Show},{2,TouchGroupOperation::Show}}};
    assert(state.Accept(both));state.Advance();assert(state.Visible(1)&&state.Visible(2));
    std::vector<AmclCtrlEntry> rectangles(3);
    for(int i=0;i<3;++i){rectangles[i].x=static_cast<float>(i*100);rectangles[i].w=50;rectangles[i].h=50;rectangles[i].hitSlop=8;}
    assert(!state.BlocksPoint(10,10,rectangles));
    assert(state.BlocksPoint(95,10,rectangles));
    assert(!state.BlocksControl(0,rectangles));
    rectangles[0].x=90;assert(state.BlocksControl(0,rectangles));
    assert(state.Epoch(0)==baseEpoch);
    assert(state.Confirm(state.Revision()));

    // 已接受 B 在 A 隐藏其来源后仍按原序执行；新的同源命令则因资格失效拒绝。
    TouchGroupCommand hideTools{1,5,0,baseEpoch,{{1,TouchGroupOperation::Hide}}};
    TouchGroupCommand acceptedFromTools{2,1,1,state.Epoch(1),{{2,TouchGroupOperation::Hide}}};
    assert(state.Accept(hideTools)&&state.Accept(acceptedFromTools));state.Advance();
    assert(!state.Visible(1));assert(!state.CanAccept({2,2,1,acceptedFromTools.eligibility,{{0,TouchGroupOperation::Hide}}}));
    assert(state.Confirm(state.Revision()));state.Advance();assert(!state.Visible(2));
    assert(state.Query(acceptedFromTools).status==TouchGroupCommandStatus::Committed);
    assert(state.Confirm(state.Revision()));

    // 队列满只拒绝新项；淘汰旧结果后水位防止盲重试再次执行。
    for(uint64_t i=6;i<70;++i)assert(state.Accept({1,i,0,baseEpoch,{{2,TouchGroupOperation::Toggle}}}));
    assert(!state.Accept({1,70,0,baseEpoch,{{2,TouchGroupOperation::Toggle}}}));
    for(int i=0;i<64;++i){state.Advance();assert(state.PendingPresentation());assert(state.Confirm(state.Revision()));}
    assert(state.Query(first).status==TouchGroupCommandStatus::Expired);
    assert(!state.Accept(first));

    // 同一方案的结构重发保留稳定组ID对应的运行显隐；真正换方案采用初始态。
    TouchGroupCommand show{1,70,0,baseEpoch,{{1,TouchGroupOperation::Show}}};
    assert(state.Accept(show));state.Advance();assert(state.Confirm(state.Revision()));
    state.Install(schema);
    if(!state.Visible(1)){std::cerr<<"same-profile publication lost group mask\n";return 91;}
    auto another=schema;another.profile="profile-b";state.Install(another);assert(!state.Visible(1));
    state.Install(schema);assert(!state.Visible(1));
    TouchGroupSchema legacy;assert(ValidTouchGroupSchema(legacy,7));
    legacy.profile="invalid-empty-groups";assert(!ValidTouchGroupSchema(legacy,7));
    // 恢复初始态等无成员命令没有成员epoch；退休后仍须保留生产者水位防止未知结果重试重放。
    TouchGroupCommand restore{3,1,-1,0,{{1,TouchGroupOperation::Show}}};
    assert(state.Accept(restore));state.Advance();assert(state.Confirm(state.Revision()));
    const auto epoch=state.Epoch(0), retirementRevision=state.Revision();
    const auto retirementMask=state.Mask();
    state.RetireTransactions();
    assert(state.Epoch(0)!=epoch && state.Revision()>retirementRevision);
    assert(state.Mask()==retirementMask && !state.PendingPresentation());
    // 同一可见成员恢复后必须使用新资格；旧 UI 不能因 mask 未变化而沿用旧见证。
    assert(!state.CanAccept({4,1,0,epoch,{{1,TouchGroupOperation::Show}}}));
    assert(state.CanAccept({4,1,0,state.Epoch(0),{{1,TouchGroupOperation::Show}}}));
    assert(!state.CanAccept(restore) && state.Query(restore).status==TouchGroupCommandStatus::Expired);
    auto invalid=schema;invalid.controls[0].group=99;assert(!ValidTouchGroupSchema(invalid,3));
    invalid=schema;invalid.groups.push_back(invalid.groups[0]);assert(!ValidTouchGroupSchema(invalid,3));
    std::cout << "PASS production touch group transactions\n";
}
