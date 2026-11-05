// SPDX-License-Identifier: Apache-2.0
// Optional checked-presence adapter for generated typed settings.
import config;
namespace config;

fn has_value(store: Store&, key: const u8[:], expected: Kind) -> bool, u8[>..] {
    if !store.initialized { return false, problem("store is not initialized", key); }
    let id = locate(store, key);
    if id < 0 { return false, problem("unknown key", key); }
    // Check kind even for an absent optional value.
    if store.fields[id].kind != expected { return false, problem("wrong getter type", key); }
    return store.values[id].present, [];
}
