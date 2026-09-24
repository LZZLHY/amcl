#include "terrain_upload_core.h"

#include <cstdlib>
#include <iostream>

namespace {

void Require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "mg_terrain_upload_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

} // namespace

int main() {
    using namespace mg::terrain_upload;
    Require(IsRenderPearlTerrainStore(Store32MiB), "32 MiB terrain store not recognized");
    Require(IsRenderPearlTerrainStore(Store128MiB), "128 MiB terrain store not recognized");
    Require(!IsRenderPearlTerrainStore(64U * 1024U * 1024U),
            "unrelated store size was recognized as terrain storage");

    std::cout << "mg_terrain_upload_core_test: PASS\n";
    return 0;
}
