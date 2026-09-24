#include "../../glfw/size_notification_state.h"
#include <cstdlib>
#include <iostream>
#include <vector>
#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL " << __LINE__ << ": " << #x << '\n'; std::abort(); } } while (0)
struct Window {
    amcl::glfw::SizeNotificationState sizeNotifications{};
    void (*windowSizeCb)(Window*, int, int) = nullptr;
    void (*framebufferSizeCb)(Window*, int, int) = nullptr;
};
static Window* active;
static std::vector<int> delivered;
static bool current(Window* window, uint64_t lifetime) {
    return active == window && window->sizeNotifications.lifetime == lifetime && !window->sizeNotifications.closed;
}
static bool pump() { return amcl::glfw::DispatchSizeNotifications(active, current); }
static void record(Window*, int w, int) { delivered.push_back(w); }
int main() {
    Window window;
    active = &window;
    window.sizeNotifications.Prime(1, 3120, 2010);
    window.framebufferSizeCb = record;
    window.windowSizeCb = record;
    pump(); CHECK(delivered.empty());
    window.sizeNotifications.Observe(2500, 1600);
    window.sizeNotifications.Observe(2090, 1324);
    CHECK(delivered.empty()); // MakeCurrent/surface publication cannot enter Java.
    pump(); CHECK((delivered == std::vector<int>{2090, 2090}));
    CHECK(window.sizeNotifications.framebufferDispatched == 2);
    pump(); CHECK(delivered.size() == 2);
    window.sizeNotifications.Observe(0, 0); pump();
    window.sizeNotifications.Observe(2090, 1324); pump();
    CHECK(delivered.size() == 6 && delivered[2] == 0 && delivered[4] == 2090);
    window.framebufferSizeCb = [](Window* w, int x, int) {
        delivered.push_back(x);
        w->sizeNotifications.Observe(1800, 1100);
        CHECK(!pump()); // Also stop the nested event pump before it dispatches input.
    };
    window.sizeNotifications.Observe(1900, 1200); pump();
    CHECK(delivered[6] == 1900 && delivered[7] == 1900);
    CHECK(window.sizeNotifications.observed > window.sizeNotifications.framebufferDispatched);
    window.framebufferSizeCb = record; pump();
    CHECK(delivered[8] == 1800 && delivered[9] == 1800);
    window.framebufferSizeCb = nullptr; window.windowSizeCb = nullptr;
    window.sizeNotifications.Observe(1700, 1000); pump();
    window.framebufferSizeCb = record; pump(); CHECK(delivered.back() == 1700);
    window.sizeNotifications.Cancel();
    window.sizeNotifications.Observe(1600, 900); pump(); CHECK(delivered.back() == 1700);
    Window* dying = new Window(); active = dying;
    dying->sizeNotifications.Prime(2, 10, 10);
    dying->framebufferSizeCb = [](Window* w, int, int) { delete w; active = nullptr; };
    dying->windowSizeCb = [](Window*, int, int) { CHECK(false); };
    dying->sizeNotifications.Observe(20, 20); CHECK(!pump()); CHECK(!active);
    Window reused; active = &reused;
    reused.sizeNotifications.Prime(3, 10, 10);
    reused.framebufferSizeCb = [](Window* w, int, int) { w->sizeNotifications.Prime(4, 20, 20); };
    reused.windowSizeCb = [](Window*, int, int) { CHECK(false); };
    reused.sizeNotifications.Observe(20, 20); CHECK(!pump()); CHECK(reused.sizeNotifications.lifetime == 4);
    std::cout << "GLFW size notification lifecycle PASS\n";
}
