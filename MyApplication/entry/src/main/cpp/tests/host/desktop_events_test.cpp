#include "../../platform/desktop_event_signal.h"
#include "../../platform/desktop_drop_packet.h"
#include <thread>
#include <iostream>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) { std::cerr << "failed " << __LINE__ << '\n'; std::exit(1); } } while(false)
int main() {
    amcl::desktop::EventSignal signal;
    const auto first=signal.epoch();
    CHECK(!signal.wait(first,0));
    signal.wake(); CHECK(signal.wait(first,0));
    const auto second=signal.epoch();
    std::thread producer([&]{std::this_thread::sleep_for(std::chrono::milliseconds(10));signal.wake();});
    CHECK(signal.wait(second,1000000000)); producer.join();
    CHECK(signal.epoch()>second);
    const auto current=signal.epoch(); CHECK(!signal.wait(current,1000000));
    const char packet[]="/tmp/one.zip\0/tmp/two.txt";
    const char* paths[2]; CHECK(amclDecodeDesktopDrop(packet,sizeof(packet),paths,2)==2);
    CHECK(std::string(paths[0])=="/tmp/one.zip" && std::string(paths[1])=="/tmp/two.txt");
    CHECK(amclDecodeDesktopDrop(packet,sizeof(packet)-1,paths,2)==-1);
    CHECK(amclDecodeDesktopDrop(packet,sizeof(packet),paths,1)==-1);
    CHECK(amclDecodeDesktopDrop("relative",9,paths,2)==-1);
    std::cout << "Event wake-before-wait, asynchronous wake, timeout and bounded drop protocol PASS\n";
}
