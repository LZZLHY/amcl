#include "buffer_contract_core.h"

#include <cstdlib>
#include <iostream>

namespace {

void Require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "mg_buffer_contract_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

} // namespace

int main() {
    using namespace mg::buffer_contract;

    const StorageState dynamic_only = ImmutableStorage(DynamicStorage, true);
    Require(dynamic_only.requested_flags == DynamicStorage, "dynamic requested flags changed");
    Require(dynamic_only.effective_flags == DynamicStorage,
            "BC-02: exact DYNAMIC_STORAGE was promoted to a mapping store");
    Require(!dynamic_only.coherent_substitution, "dynamic store was marked coherent-substituted");
    Require(!ApplicationMappingAllowed(dynamic_only, MapWrite),
            "backend-only write permission leaked into the application contract");
    Require(ApplicationMappingAllowed(dynamic_only, 0x0004U),
            "range invalidation modifier was mistaken for a storage permission");
    Require(ApplicationMappingAllowed(MutableStorage(), MapRead | MapWrite),
            "mutable storage unexpectedly rejected an application mapping");

    const Flags persistent_write = MapWrite | MapPersistent;
    const StorageState disabled = ImmutableStorage(persistent_write, false);
    Require(disabled.effective_flags == persistent_write && !disabled.coherent_substitution,
            "disabled coherent substitution changed storage");

    const StorageState promoted = ImmutableStorage(persistent_write, true);
    Require(promoted.requested_flags == persistent_write, "requested storage contract was overwritten");
    Require(promoted.effective_flags == (persistent_write | MapCoherent) && promoted.coherent_substitution,
            "BC-03: persistent-write store was not coherently strengthened");
    Require(ApplicationMappingAllowed(promoted, MapWrite | MapPersistent),
            "an application-authorized persistent write mapping was rejected");
    Require(!ApplicationMappingAllowed(promoted, MapRead),
            "an unrequested read mapping permission was accepted");

    const Flags explicit_mapping = MapWrite | MapPersistent | MapFlushExplicit;
    const MappingDecision coherent_map = DecideMapping(promoted, explicit_mapping);
    Require(coherent_map.requested_access == explicit_mapping,
            "requested mapping access was overwritten");
    Require(coherent_map.effective_access == (MapWrite | MapPersistent | MapCoherent) &&
                coherent_map.coherent_substitution,
            "BC-04: coherent store was not paired with a coherent mapping");

    const MappingDecision original_map = DecideMapping(disabled, explicit_mapping);
    Require(original_map.effective_access == explicit_mapping && !original_map.coherent_substitution,
            "mapping was rewritten without an effective coherent store");

    // BC-06 fallback uses the original decision after a rewritten driver call
    // fails. Its successful state must therefore forward explicit flushes.
    const MappingState fallback_state = SuccessfulMapping(64, 256, original_map);
    Require(DecideFlush(fallback_state, 0, 16) == FlushDisposition::Forward,
            "fallback mapping incorrectly swallowed explicit flush");

    const MappingState coherent_state = SuccessfulMapping(64, 256, coherent_map);
    Require(DecideFlush(coherent_state, 0, 16) == FlushDisposition::Suppress,
            "valid coherent-substitution flush was not suppressed");
    Require(DecideFlush(coherent_state, 240, 16) == FlushDisposition::Suppress,
            "flush ending at mapping boundary was rejected");
    Require(DecideFlush(coherent_state, -1, 16) == FlushDisposition::InvalidValue,
            "negative flush offset was accepted");
    Require(DecideFlush(coherent_state, 250, 16) == FlushDisposition::InvalidValue,
            "flush past mapping boundary was accepted");

    const StorageState already_coherent =
        ImmutableStorage(MapWrite | MapPersistent | MapCoherent, true);
    const MappingDecision app_coherent =
        DecideMapping(already_coherent, MapWrite | MapPersistent | MapCoherent);
    Require(!app_coherent.coherent_substitution,
            "application-requested coherent mapping was mislabeled as an MG substitution");
    Require(DecideFlush(SuccessfulMapping(0, 64, app_coherent), 0, 4) == FlushDisposition::Forward,
            "illegal application flush was hidden from the provider");

    std::cout << "mg_buffer_contract_core_test: PASS\n";
    return 0;
}
