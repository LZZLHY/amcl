#include "../../platform/desktop_command_queue.h"
#include <iostream>
#include <cstdlib>
#define CHECK(expression) do { if (!(expression)) { std::cerr << "failed line " << __LINE__ << ": " << #expression << '\n'; std::exit(1); } } while (false)
using amcl::desktop::Command;
using amcl::desktop::CommandQueue;
int main() {
    CommandQueue queue;
    Command resize; resize.kind = AMCL_DESKTOP_RESIZE; resize.a = 1280; resize.b = 720;
    CHECK(queue.submit(resize) == 0);
    const auto first = queue.attach();
    const auto sequence = queue.submit(resize);
    CHECK(sequence > 0);
    Command taken;
    CHECK(queue.take(taken)); CHECK(taken.a == 1280 && taken.b == 720);
    CHECK(!queue.take(taken));
    CHECK(!queue.complete(first, sequence + 1, 0));
    CHECK(!queue.complete(first + 1, sequence, 0));
    CHECK(queue.complete(first, sequence, 1300002));
    CHECK(queue.failed() == 1 && queue.lastError() == 1300002);
    CHECK(!queue.complete(first, sequence, 0));
    for (int i = 0; i < 128; ++i) CHECK(queue.submit(resize) > 0);
    CHECK(queue.submit(resize) == 0);
    CHECK(queue.take(taken));
    const auto beforeDetach = queue.failed();
    queue.detach(); CHECK(queue.failed() == beforeDetach + 128);
    CHECK(!queue.complete(first, taken.sequence, 0)); CHECK(!queue.take(taken));
    const auto next = queue.attach(); CHECK(next > first);
    const auto nextSequence = queue.submit(resize); CHECK(nextSequence > sequence);
    CHECK(queue.take(taken)); CHECK(queue.complete(next, nextSequence, 0));
    CHECK(queue.lastError() == 0);
    Command invalid; invalid.kind = 999; CHECK(queue.submit(invalid) == 0);
    invalid.kind = AMCL_DESKTOP_TITLE; invalid.text.assign(65537, 'x'); CHECK(queue.submit(invalid) == 0);
    std::cout << "desktop command queue: stale leases, ordering, overflow, teardown and errors PASS\n";
}
