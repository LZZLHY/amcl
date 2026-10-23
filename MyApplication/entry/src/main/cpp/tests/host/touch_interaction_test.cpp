// 直接执行生产手势状态机：关注跨指角色、取消及单位，不把实现逐行复制到测试。
#include "../../platform/touch_interaction.h"
#include <cstdio>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)
#include <cmath>
#include <limits>
#include <vector>
using namespace amcl::input;
struct Recorded { MenuTouchAction action; double x, y; };
int main() {
    std::vector<Recorded> events;
    const MenuTouchEmitter emit = [&](MenuTouchAction a,double x,double y) { events.push_back({a,x,y}); };
    const auto count = [&](MenuTouchAction action) {
        int result=0; for (const auto& event:events) if(event.action==action) ++result; return result;
    };
    TouchInteractionConfig config;
    CHECK(ValidTouchInteractionConfig(config));
    CHECK(!config.touchpad && !config.menuScroll); // 缺省direct选择即时按住；双指候选必须显式开启。
    config.menuSensitivity=std::numeric_limits<double>::quiet_NaN();
    CHECK(!ValidTouchInteractionConfig(config)); config.menuSensitivity=1;
    MenuTouchInteraction menu;
    menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,100,200,1000000,emit);
    CHECK(count(MenuTouchAction::Down)==1); // 缺省直触立即开始原来的有序事务。
    menu.Event(TouchPhase::Move,0,150,250,2000000,emit);
    menu.Event(TouchPhase::Cancel,0,150,250,3000000,emit);
    CHECK(count(MenuTouchAction::Cancel)==1 && count(MenuTouchAction::Up)==0);

    // 即时direct不能等位移阈值或长按期限：落指就认领LEFT，UP新坐标先Position再Up。
    // 这里直接观察生产语义出口，后续bridge组合回归再验证真正的鼠标held区间。
    events.clear(); menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,10,20,10000000,emit);
    CHECK(count(MenuTouchAction::Down)==1 && menu.Deadline()==0);
    CHECK(events.back().action==MenuTouchAction::Down && events.back().x==10 && events.back().y==20);
    menu.Event(TouchPhase::Up,0,500,600,20000000,emit);
    CHECK(events.size()>=3 && events[events.size()-3].action==MenuTouchAction::Position);
    CHECK(events[events.size()-3].x==500 && events[events.size()-3].y==600);
    CHECK(events[events.size()-2].action==MenuTouchAction::Up && events[events.size()-2].x==500 && events[events.size()-2].y==600);
    CHECK(events.back().action==MenuTouchAction::End && events.back().x==0 && events.back().y==0);
    CHECK(count(MenuTouchAction::Down)==1 && count(MenuTouchAction::Up)==1 && !menu.Active());

    // 已认领的direct拖动不能被第二指改成滚动；主指抬起后的残留指直到全抬均不补点击。
    events.clear();
    menu.Event(TouchPhase::Down,0,100,200,30000000,emit);
    menu.Event(TouchPhase::Down,1,600,200,31000000,emit);
    menu.Event(TouchPhase::Move,1,600,50,32000000,emit);
    menu.Event(TouchPhase::Move,0,300,400,33000000,emit);
    menu.Event(TouchPhase::Up,0,300,400,34000000,emit);
    menu.Event(TouchPhase::Move,1,600,0,35000000,emit);
    menu.Event(TouchPhase::Up,1,600,0,36000000,emit);
    CHECK(count(MenuTouchAction::Down)==1 && count(MenuTouchAction::Up)==1);
    CHECK(count(MenuTouchAction::Scroll)==0 && count(MenuTouchAction::Cancel)==0 && !menu.Active());
    // direct+双指候选不能改变拖动源点：第一帧直接跨格，消费者仍先得到A处DOWN再收到B处MOVE。
    events.clear(); config.menuScroll=true;
    menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,100,200,100000000,emit);
    menu.Event(TouchPhase::Move,0,300,250,120000000,emit);
    CHECK(count(MenuTouchAction::Down)==1);
    for (const auto& event:events) if (event.action==MenuTouchAction::Down) {
        CHECK(event.x==100 && event.y==200);
    }
    CHECK(events.back().action==MenuTouchAction::Position && events.back().x==300);
    menu.Event(TouchPhase::Cancel,0,300,250,130000000,emit);
    // direct候选可能只收到DOWN/UP而无中间MOVE。UP远离源点时仍是完整拖动，
    // 先在原点认领，保持Position终点，最后Up；不能把因事件合并缺MOVE的操作吞掉。
    events.clear(); menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,100,200,150000000,emit);
    menu.Event(TouchPhase::Up,0,400,500,160000000,emit);
    CHECK(count(MenuTouchAction::Down)==1 && count(MenuTouchAction::Up)==1);
    size_t source=events.size(),target=events.size(),released=events.size();
    for(size_t i=0;i<events.size();++i){
        if(events[i].action==MenuTouchAction::Down){source=i;CHECK(events[i].x==100&&events[i].y==200);}
        if(events[i].action==MenuTouchAction::Position&&events[i].x==400&&events[i].y==500)target=i;
        if(events[i].action==MenuTouchAction::Up){released=i;CHECK(events[i].x==400&&events[i].y==500);}
    }
    CHECK(source<target && target<released && released+1==events.size()-1);
    CHECK(events.back().action==MenuTouchAction::End&&events.back().x==0&&events.back().y==0);
    events.clear(); config.touchpad=true; config.menuScroll=true;
    menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,1,200,300,1000000000,emit);
    const double old=menu.X();
    menu.Event(TouchPhase::Move,1,240,300,1020000000,emit);
    menu.Event(TouchPhase::Up,1,240,300,1030000000,emit);
    CHECK(std::abs(menu.X()-old-40)<.001 && count(MenuTouchAction::Down)==0 && count(MenuTouchAction::RelativeDown)==0);
    CHECK(count(MenuTouchAction::RelativeBegin)==1 && count(MenuTouchAction::RelativeEnd)==1);
    CHECK(events.size()==4 && events[1].action==MenuTouchAction::RelativePosition&&events[1].x==40&&events[1].y==0);
    CHECK(events[2].action==MenuTouchAction::RelativePosition&&events[2].x==0&&events[2].y==0);
    CHECK(events[3].action==MenuTouchAction::RelativeEnd&&events[3].x==0&&events[3].y==0);
    events.clear();
    menu.Event(TouchPhase::Down,1,100,100,2000000000,emit);
    menu.Event(TouchPhase::Down,2,300,100,2050000000,emit);
    menu.Event(TouchPhase::Move,1,100,52,2060000000,emit);
    menu.Event(TouchPhase::Move,2,300,52,2060000000,emit);
    CHECK(count(MenuTouchAction::Scroll)==2);
    for (const auto& event:events) if (event.action==MenuTouchAction::Scroll) CHECK(event.y==-2);
    menu.Event(TouchPhase::Up,2,300,52,2100000000,emit);
    menu.Event(TouchPhase::Move,1,100,0,2110000000,emit);
    menu.Event(TouchPhase::Up,1,100,0,2120000000,emit);
    CHECK(count(MenuTouchAction::Down)==0 && count(MenuTouchAction::Scroll)==2);
    events.clear();
    menu.Event(TouchPhase::Down,1,100,100,3000000000,emit);
    menu.Tick(3400000000,emit);
    menu.Event(TouchPhase::Down,2,300,100,3410000000,emit);
    menu.Event(TouchPhase::Move,2,300,0,3420000000,emit);
    menu.Event(TouchPhase::Up,1,100,100,3430000000,emit);
    menu.Event(TouchPhase::Up,2,300,0,3440000000,emit);
    CHECK(count(MenuTouchAction::RelativeDown)==1 && count(MenuTouchAction::RelativeUp)==1 && count(MenuTouchAction::Scroll)==0);
    for(const auto& event:events)if(event.action==MenuTouchAction::RelativeDown)CHECK(event.x==0&&event.y==0);
    events.clear();
    menu.Event(TouchPhase::Down,0,100,100,4000000000,emit);
    menu.Configure(800,600,2,config,emit);
    menu.Tick(5000000000,emit); // 配置退休不能让旧定时器复活按下。
    CHECK(count(MenuTouchAction::Down)==0);
    CHECK(count(MenuTouchAction::RelativeCancel)==1); // 未按键candidate也有可退休的pointer-only token。

    // 自然先后落指：250ms仍未提交长按，允许加入；向下滑发送正wheel，列表内容跟随手指。
    events.clear(); menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,100,100,5100000000,emit);
    menu.Event(TouchPhase::Down,1,200,100,5350000000,emit);
    menu.Event(TouchPhase::Move,0,100,124,5360000000,emit);
    menu.Event(TouchPhase::Move,1,200,124,5360000000,emit);
    CHECK(count(MenuTouchAction::Down)==0 && count(MenuTouchAction::Scroll)==2);
    for (const auto& event:events) if(event.action==MenuTouchAction::Scroll) CHECK(event.y==1);
    menu.Cancel(emit);

    // 相对模式先移动指针再加第二指，不因失去轻触资格而丢掉滚动资格。
    events.clear();
    menu.Event(TouchPhase::Down,0,100,100,5400000000,emit);
    menu.Event(TouchPhase::Move,0,116,100,5410000000,emit);
    menu.Event(TouchPhase::Down,1,220,100,5950000000,emit);
    menu.Event(TouchPhase::Move,0,116,76,5960000000,emit);
    CHECK(count(MenuTouchAction::Down)==0 && count(MenuTouchAction::Scroll)==1);
    menu.Event(TouchPhase::Up,1,220,100,5970000000,emit);
    menu.Event(TouchPhase::Down,2,240,100,5980000000,emit);
    menu.Event(TouchPhase::Move,2,240,0,5990000000,emit);
    CHECK(count(MenuTouchAction::Scroll)==1); // 残留/补指须全抬后再开新手势，不能补点击。
    menu.Cancel(emit);
    events.clear();

    // 两种菜单模式都直接执行同一生产解释器。末样只有UP时，原双指平均6vp/density
    // 仍采这次真实末段，随后残余指抑制；不能为缺MOVE补LEFT或重新认领旧触点。
    for (bool touchpad : {false,true}) {
        config.touchpad=touchpad;config.menuScroll=true;
        menu.Configure(1000,800,2,config,emit);events.clear();
        menu.Event(TouchPhase::Down,0,100,100,7000000000LL,emit);
        menu.Event(TouchPhase::Down,1,200,100,7010000000LL,emit);
        menu.Event(TouchPhase::Up,1,224,76,7020000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1);
        CHECK(events.back().action==MenuTouchAction::Scroll && events.back().x==1 && events.back().y==-1);
        menu.Event(TouchPhase::Move,0,500,-100,7030000000LL,emit);
        menu.Event(TouchPhase::Up,0,500,-100,7040000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1 && count(MenuTouchAction::Down)==0 && count(MenuTouchAction::RelativeDown)==0);
        CHECK(count(MenuTouchAction::End)+count(MenuTouchAction::RelativeEnd)==1 && !menu.Active());

        // MOVE已经采过的同坐标UP不重复；不能把终点总距离再次累加。
        menu.Configure(1000,800,2,config,emit);events.clear();
        menu.Event(TouchPhase::Down,0,100,100,7100000000LL,emit);
        menu.Event(TouchPhase::Down,1,200,100,7110000000LL,emit);
        menu.Event(TouchPhase::Move,1,224,76,7120000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1);
        menu.Event(TouchPhase::Up,1,224,76,7130000000LL,emit);
        menu.Event(TouchPhase::Up,0,100,100,7140000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1 && !menu.Active());

        // 原MOVE不足一格的余量可由正常UP末段凑成一格，density=2时每指24px一格。
        menu.Configure(1000,800,2,config,emit);events.clear();
        menu.Event(TouchPhase::Down,0,100,100,7200000000LL,emit);
        menu.Event(TouchPhase::Down,1,200,100,7210000000LL,emit);
        menu.Event(TouchPhase::Move,1,200,88,7220000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==0);
        menu.Event(TouchPhase::Up,1,200,76,7230000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1 && events.back().y==-1);
        menu.Event(TouchPhase::Up,0,100,100,7240000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==1 && !menu.Active());

        // 系统CANCEL的坐标没有正常末段语义：只退休原gesture，随后旧UP也不产生wheel。
        menu.Configure(1000,800,2,config,emit);events.clear();
        menu.Event(TouchPhase::Down,0,100,100,7300000000LL,emit);
        menu.Event(TouchPhase::Down,1,200,100,7310000000LL,emit);
        menu.Event(TouchPhase::Cancel,1,224,76,7320000000LL,emit);
        menu.Event(TouchPhase::Up,0,500,-100,7330000000LL,emit);
        CHECK(count(MenuTouchAction::Scroll)==0 && count(MenuTouchAction::Cancel)+count(MenuTouchAction::RelativeCancel)==1);
        CHECK(count(MenuTouchAction::Down)==0 && count(MenuTouchAction::RelativeDown)==0 && !menu.Active());
    }
    // 恢复后续原测试的相对菜单配置；新增场不改变原基线或删旧断言。
    config.touchpad=true;

    // 辅助右键已经按住时，另一根手指只有移动职责，不能因停留而合成左键。
    menu.SetExternalButtonsHeld(true);
    menu.AdoptCursor(700,500);
    menu.Event(TouchPhase::Down,0,100,100,6000000000,emit);
    menu.Tick(6500000000,emit);
    menu.Event(TouchPhase::Up,0,140,100,6510000000,emit);
    CHECK(count(MenuTouchAction::RelativeDown)==0 && count(MenuTouchAction::Down)==0 && std::abs(menu.X()-740)<.001);
    menu.SetExternalButtonsHeld(false);

    // 触摸板longhold用consumer当前点按下，Producer只传0；ACK反馈改变不能污染真实采样delta。
    events.clear();config.menuScroll=false;config.menuSensitivity=1.5;
    menu.Configure(1000,800,2,config,emit);menu.AdoptCursor(100,200);
    menu.Event(TouchPhase::Down,0,50,50,7000000000,emit);
    menu.Event(TouchPhase::Move,0,52,53,7010000000,emit);
    menu.AdoptConsumedCursor(500,600);
    menu.Tick(7400000000,emit);
    menu.Event(TouchPhase::Up,0,55,58,7410000000,emit);
    CHECK(count(MenuTouchAction::RelativeBegin)==1&&count(MenuTouchAction::RelativeDown)==1&&count(MenuTouchAction::RelativeUp)==1);
    size_t delta=events.size(),down=events.size(),up=events.size();
    for(size_t i=0;i<events.size();++i){
        if(events[i].action==MenuTouchAction::RelativePosition){delta=i;CHECK(events[i].x==3&&events[i].y==4.5);}
        if(events[i].action==MenuTouchAction::RelativeDown){down=i;CHECK(events[i].x==0&&events[i].y==0);}
        if(events[i].action==MenuTouchAction::RelativeUp){up=i;CHECK(events[i].x==4.5&&events[i].y==7.5);}
    }
    CHECK(delta<down&&down<up&&count(MenuTouchAction::Down)==0&&count(MenuTouchAction::Position)==0);
    CHECK(events.size()==5&&up==3&&events[4].action==MenuTouchAction::RelativeEnd&&events[4].x==0&&events[4].y==0);
    // 面板/relative在viewport边缘仍传完整delta；clamp是consumer职责，反馈缓存不吃掉后续量。
    events.clear();menu.Configure(100,80,1,config,emit);menu.AdoptCursor(99,79);
    CHECK(menu.MoveCursor(10,5,emit));CHECK(events.back().action==MenuTouchAction::RelativePosition);
    CHECK(events.back().x==15&&events.back().y==7.5&&menu.X()==99&&menu.Y()==79);
    menu.AdoptConsumedCursor(10,20);CHECK(menu.MoveCursor(1,2,emit));
    CHECK(events.back().x==1.5&&events.back().y==3);
    // direct活动指针仍归原手势，ACK不能改写它，也不能被面板relative挪动。
    config.touchpad=false;config.menuSensitivity=1;events.clear();menu.Configure(1000,800,2,config,emit);
    menu.Event(TouchPhase::Down,0,100,200,7500000000,emit);menu.AdoptConsumedCursor(700,600);
    CHECK(menu.X()==100&&menu.Y()==200&&!menu.MoveCursor(1,1,emit));menu.Cancel(emit);

    TouchJoystickInteraction joystick;
    config.floatingJoystick=true; config.sprint=true; config.autoWalk=true;
    joystick.Begin(120,140,100,100,200,200,config,.18);
    CHECK(joystick.X()==0 && joystick.Y()==0 && joystick.CenterX()==120);
    joystick.Move(120,50);
    CHECK(joystick.Sprint() && !joystick.Armed());
    joystick.End(false);
    CHECK(!joystick.Locked() && joystick.Y()==0);
    joystick.Begin(180,180,100,100,200,200,config,.18);
    CHECK(!joystick.Locked() && joystick.Y()==0);
    joystick.Move(180,30); joystick.End(true);
    CHECK(!joystick.Locked() && !joystick.Sprint() && joystick.Y()==0);
    config.floatingJoystick=false;
    joystick.Begin(200,200,100,100,200,200,config,.18);
    joystick.Move(260,200);
    CHECK(!joystick.Sprint() && !joystick.Armed());
    return 0;
}
