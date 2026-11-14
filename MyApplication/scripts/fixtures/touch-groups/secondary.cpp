/** 执行生产状态机，覆盖二级组的mask快照、当前入口、资格退休、呈现屏障及结构重装。 */
#include "touch_group_state.h"
#include <cassert>
#include <iostream>
using namespace amcl::input;

int main() {
    TouchGroupSchema schema;schema.profile="secondary-test";
    schema.groups={{"base",true},{"fkeys",false,true,false},{"keyboard",false,true,true},{"previously-hidden",false}};
    schema.controls.resize(7);
    for(int i=0;i<7;++i){schema.controls[i].group=0;schema.controls[i].rank=i;}
    schema.controls[1].group=1;schema.controls[3].group=2;schema.controls[4].group=-1;schema.controls[5].group=3;
    const auto bind=[&](int control,int group,bool returning){auto& c=schema.controls[control];c.phases=true;c.secondaryTarget=group;c.secondaryReturn=returning;
        c.bindings[0].actions={{static_cast<uint32_t>(group),returning?TouchGroupOperation::CloseSecondary:TouchGroupOperation::ToggleSecondary}};};
    bind(0,1,false);bind(2,2,false);bind(3,2,true);
    assert(ValidTouchGroupSchema(schema,7));
    TouchGroupState state;state.Install(schema);uint64_t sequence=0;
    const auto invoke=[&](int control){TouchGroupCommand cmd{1,++sequence,control,state.Epoch(control),schema.controls[control].bindings[0].actions};
        assert(state.Accept(cmd));state.Advance();assert(state.PendingPresentation());return cmd;};
    const auto initial=state.Mask();const auto primaryEpoch=state.Epoch(6);
    auto first=invoke(0);assert(state.Visible(0)&&state.Visible(1)&&state.Visible(2)&&state.Visible(4)&&state.Visible(6));
    assert(!state.Visible(3)&&!state.Visible(5));assert(state.Epoch(6)==primaryEpoch);
    assert(state.Rank(0)>state.Rank(1));assert(state.Confirm(state.Revision()));
    invoke(0);assert(!state.Visible(1)&&state.Mask()==initial);assert(state.Confirm(state.Revision()));
    invoke(0);assert(state.Confirm(state.Revision()));
    invoke(2);assert(!state.Visible(0)&&!state.Visible(1)&&state.Visible(2)&&state.Visible(3));
    assert(!state.Visible(4)&&!state.Visible(6)&&state.HasHiddenControls());
    assert(!state.CarriedGroupVisible("base")&&state.CarriedGroupVisible("keyboard"));
    assert(state.Epoch(6)!=primaryEpoch&&state.Rank(2)>state.Rank(3));
    std::vector<AmclCtrlEntry> rects(7);for(int i=0;i<7;++i){rects[i].x=float(i*70);rects[i].w=60;rects[i].h=60;}
    assert(state.BlocksControl(4,rects)&&state.BlocksPoint(4*70+5,5,rects));
    assert(state.Confirm(state.Revision()));
    const auto epoch=state.Epoch(2);state.RetireTransactions();assert(state.Visible(2)&&!state.Visible(6)&&state.Epoch(2)!=epoch);
    state.Install(schema);assert((state.Visible(2)&&state.Visible(3)&&!state.Visible(6))&&"valid secondary layer must survive structural publication");
    invoke(3);assert(state.Mask()==initial&&!state.Visible(1)&&!state.Visible(3)&&!state.Visible(5)&&state.Visible(4));
    assert(state.Confirm(state.Revision()));
    // 无返回键也可再次点击展开键收起，保护入口不依赖额外自动生成的按钮。
    auto noReturn=schema;noReturn.controls[3].secondaryTarget=-1;noReturn.controls[3].secondaryReturn=false;noReturn.controls[3].phases=false;noReturn.controls[3].bindings={};
    assert(ValidTouchGroupSchema(noReturn,7));state.Install(noReturn);
    invoke(2);assert(state.Visible(2)&&!state.Visible(0));assert(state.Confirm(state.Revision()));
    invoke(2);assert(state.Mask()==initial);assert(state.Confirm(state.Revision()));
    invoke(2);assert(state.Confirm(state.Revision()));
    auto changed=noReturn;changed.controls[2].secondaryTarget=-1;changed.controls[2].phases=false;changed.controls[2].bindings={};
    state.Install(changed);assert((state.Mask()==initial&&state.Visible(4)&&state.Visible(6))&&"removed opener must restore primary snapshot");
    auto invalid=schema;invalid.controls[0].bindings[0].keys={69};assert(!ValidTouchGroupSchema(invalid,7));
    invalid=schema;invalid.controls[6]=invalid.controls[0];assert(!ValidTouchGroupSchema(invalid,7));
    invalid=schema;invalid.groups[1].initialVisible=true;assert(!ValidTouchGroupSchema(invalid,7));
    std::cout<<"PASS native secondary groups: optional return, toggling, snapshot restore, hidden primary retirement, shared rank, lifecycle and schema validation\n";
}
