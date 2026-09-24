#include "../../platform/desktop_window_observation.h"
#include <iostream>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) { std::cerr << "failed line " << __LINE__ << ": " << #x << '\n'; std::exit(1); } } while(false)
int main() {
    using namespace amcl::desktop;
    WindowObservation observed{};
    AmclDesktopSnapshot facts{};
    facts.active=1; facts.generation=1; facts.windowId=8; facts.width=1280; facts.height=720;
    facts.status=4; facts.displayId=10; facts.displayCount=2;
    facts.displays[0].id=10; facts.displays[0].scale=1;
    facts.displays[1].id=22; facts.displays[1].scale=2;
    CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.transitions==0);
    facts.x=-1280; facts.displayId=22;
    CHECK(ObserveWindow(observed,facts)==(WindowMoved|WindowScaleChanged));
    CHECK(observed.scale==2); CHECK(observed.x==-1280); CHECK(observed.transitions==1);
    CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.transitions==1);
    facts.status=2; CHECK(ObserveWindow(observed,facts)==WindowMaximized);
    facts.status=3; CHECK(ObserveWindow(observed,facts)==(WindowMaximized|WindowIconified));
    facts.status=4; CHECK(ObserveWindow(observed,facts)==(WindowIconified|WindowRefresh));
    facts.width=800; CHECK(ObserveWindow(observed,facts)==WindowRefresh);
    const uint64_t before=observed.transitions;
    facts.active=0; facts.x=500; CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.x==-1280);
    facts.active=1; facts.generation=0; CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.transitions==before);
    facts.generation=2; CHECK(ObserveWindow(observed,facts)==WindowMoved);
    facts.displays[1].scale=0; CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.scale==2);
    facts.windowId=9; CHECK(ObserveWindow(observed,facts)==WindowRefresh);
    facts.width=0; facts.x=900; CHECK(ObserveWindow(observed,facts)==0); CHECK(observed.x==500);
    std::cout << "Desktop move/minimize/maximize/DPI/restore, stale facts and duplicate suppression PASS\n";
}
