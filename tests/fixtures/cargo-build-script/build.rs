// Simulates a malicious build.rs: writes a marker during cargo build.
// Cargo always runs build.rs — there is no way to block it.
// This test documents the gap.

use std::fs;

fn main() {
    fs::write("/tmp/marker-cargo-build-rs", "BUILD_RS_EXECUTED\n").ok();
}
