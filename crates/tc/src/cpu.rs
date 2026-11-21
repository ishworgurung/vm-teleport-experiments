//! What CPU is this? Read from `/proc/cpuinfo`, whose fields differ per ISA.

use std::fs;

/// A one-line CPU description for the demo output and the capsule's hop log.
///
/// - x86-64 has a `model name` line (QEMU's CPU models fill it in, for example
///   "Intel Xeon Processor (Icelake)").
/// - arm64 has no model name; the kernel prints the MIDR (Main ID Register)
///   fields instead. Implementer 0x41 is Arm Ltd; parts 0xd0c, 0xd40 and 0xd4f
///   are Neoverse N1, V1 and V2 (from memory of Arm's part numbers; QEMU's
///   `-cpu neoverse-n1` reports 0xd0c, which is what these experiments rely on).
/// - riscv64 prints the ISA string and, when the platform has one, `uarch`.
pub(crate) fn model() -> String {
    let info = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let field = |key: &str| {
        info.lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                (k.trim() == key).then(|| v.trim().to_string())
            })
            .filter(|v| !v.is_empty())
    };
    if let Some(m) = field("model name") {
        return m;
    }
    if let (Some(imp), Some(part)) = (field("CPU implementer"), field("CPU part")) {
        let name = match (imp.as_str(), part.as_str()) {
            ("0x41", "0xd0c") => "Arm Neoverse-N1",
            ("0x41", "0xd40") => "Arm Neoverse-V1",
            ("0x41", "0xd4f") => "Arm Neoverse-V2",
            _ => "arm64",
        };
        return format!("{name} (implementer {imp}, part {part})");
    }
    if let Some(isa) = field("isa") {
        let uarch = field("uarch").unwrap_or_else(|| "no uarch".into());
        // The full ISA string lists every extension; the base and the first
        // few are enough to identify it in a log line.
        let short: String = isa.split('_').next().unwrap_or(&isa).to_string();
        return format!("{short} ({uarch})");
    }
    "unknown".into()
}

pub(crate) fn hostname() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname").map_or_else(|_| "unknown".into(), |s| s.trim().to_string())
}
