use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Storage::FileSystem::{GetDiskFreeSpaceExW, GetLogicalDriveStringsW};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::ProcessStatus::{K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_INFORMATION, PROCESS_VM_READ};

pub const MEMORY_REFRESH_INTERVAL: Duration = Duration::from_secs(2);
pub const DRIVE_REFRESH_INTERVAL: Duration = Duration::from_secs(30);
const BYTES_PER_GIB: f64 = 1024.0 * 1024.0 * 1024.0;

#[derive(Clone, Debug, Default)]
pub struct MemoryMetrics {
    pub available: bool,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub free_bytes: u64,
    pub top_processes: Vec<ProcessMemoryMetrics>,
}

impl MemoryMetrics {
    pub fn used_percent(&self) -> f64 {
        percentage(self.used_bytes, self.total_bytes)
    }

    pub fn free_percent(&self) -> f64 {
        percentage(self.free_bytes, self.total_bytes)
    }

    pub fn total_gib(&self) -> f64 {
        gibibytes(self.total_bytes)
    }

    pub fn used_gib(&self) -> f64 {
        gibibytes(self.used_bytes)
    }

    pub fn free_gib(&self) -> f64 {
        gibibytes(self.free_bytes)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProcessMemoryMetrics {
    pub name: String,
    pub memory_bytes: u64,
}

impl ProcessMemoryMetrics {
    pub fn memory_mib(&self) -> f64 {
        self.memory_bytes as f64 / (1024.0 * 1024.0)
    }

    pub fn memory_gib(&self) -> f64 {
        gibibytes(self.memory_bytes)
    }

    pub fn display_memory(&self) -> String {
        if self.memory_bytes >= 1024 * 1024 * 1024 {
            format!("{:.1}GB", self.memory_gib())
        } else {
            format!("{:.0}MB", self.memory_mib())
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct DriveMetrics {
    pub key: String,
    pub label: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub free_bytes: u64,
}

impl DriveMetrics {
    pub fn used_percent(&self) -> f64 {
        percentage(self.used_bytes, self.total_bytes)
    }

    pub fn free_percent(&self) -> f64 {
        percentage(self.free_bytes, self.total_bytes)
    }

    pub fn total_gib(&self) -> f64 {
        gibibytes(self.total_bytes)
    }

    pub fn used_gib(&self) -> f64 {
        gibibytes(self.used_bytes)
    }

    pub fn free_gib(&self) -> f64 {
        gibibytes(self.free_bytes)
    }
}

#[derive(Clone, Debug, Default)]
pub struct SystemMetrics {
    pub memory: MemoryMetrics,
    pub drives: Vec<DriveMetrics>,
}

#[derive(Debug, Default)]
struct MetricsCache {
    snapshot: SystemMetrics,
    memory_refreshed_at: Option<Instant>,
    drives_refreshed_at: Option<Instant>,
}

impl MetricsCache {
    fn snapshot(&mut self, now: Instant) -> SystemMetrics {
        if refresh_due(self.memory_refreshed_at, now, MEMORY_REFRESH_INTERVAL) {
            if let Some(memory) = read_memory() {
                self.snapshot.memory = memory;
            }
            self.memory_refreshed_at = Some(now);
        }
        if refresh_due(self.drives_refreshed_at, now, DRIVE_REFRESH_INTERVAL) {
            if let Some(drives) = read_drives() {
                self.snapshot.drives = drives;
            }
            self.drives_refreshed_at = Some(now);
        }
        self.snapshot.clone()
    }
}

pub fn snapshot() -> SystemMetrics {
    static CACHE: OnceLock<Mutex<MetricsCache>> = OnceLock::new();
    CACHE
        .get_or_init(|| Mutex::new(MetricsCache::default()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .snapshot(Instant::now())
}

fn refresh_due(last: Option<Instant>, now: Instant, interval: Duration) -> bool {
    last.is_none_or(|last| now.saturating_duration_since(last) >= interval)
}

fn read_memory() -> Option<MemoryMetrics> {
    let mut status = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        ..Default::default()
    };
    unsafe { GlobalMemoryStatusEx(&mut status) }.ok()?;
    let total_bytes = status.ullTotalPhys;
    let free_bytes = status.ullAvailPhys.min(total_bytes);
    Some(MemoryMetrics {
        available: total_bytes > 0,
        total_bytes,
        used_bytes: total_bytes.saturating_sub(free_bytes),
        free_bytes,
        top_processes: read_top_memory_processes(),
    })
}

fn read_top_memory_processes() -> Vec<ProcessMemoryMetrics> {
    let Ok(snapshot) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }) else {
        return Vec::new();
    };
    let snapshot = OwnedHandle(snapshot);
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    if unsafe { Process32FirstW(snapshot.0, &mut entry) }.is_err() {
        return Vec::new();
    }

    let mut usage_by_name = HashMap::<String, u64>::new();
    loop {
        let name = process_name(&entry.szExeFile);
        if !name.is_empty() {
            if let Some(memory_bytes) = process_working_set(entry.th32ProcessID) {
                let total = usage_by_name.entry(name).or_default();
                *total = total.saturating_add(memory_bytes);
            }
        }
        if unsafe { Process32NextW(snapshot.0, &mut entry) }.is_err() {
            break;
        }
    }
    rank_process_memory(usage_by_name)
}

fn process_working_set(process_id: u32) -> Option<u64> {
    let handle = unsafe {
        OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            false,
            process_id,
        )
    }
    .ok()?;
    let handle = OwnedHandle(handle);
    let mut counters = PROCESS_MEMORY_COUNTERS {
        cb: std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        ..Default::default()
    };
    unsafe {
        K32GetProcessMemoryInfo(
            handle.0,
            &mut counters,
            std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        )
    }
    .as_bool()
    .then_some(counters.WorkingSetSize as u64)
}

fn process_name(buffer: &[u16]) -> String {
    let end = buffer
        .iter()
        .position(|value| *value == 0)
        .unwrap_or(buffer.len());
    let mut name = String::from_utf16_lossy(&buffer[..end]);
    if name.to_ascii_lowercase().ends_with(".exe") {
        name.truncate(name.len().saturating_sub(4));
    }
    name
}

fn rank_process_memory(usage_by_name: HashMap<String, u64>) -> Vec<ProcessMemoryMetrics> {
    let mut processes = usage_by_name
        .into_iter()
        .filter(|(name, bytes)| {
            !name.trim().is_empty() && *bytes > 0 && !is_hidden_process_name(name)
        })
        .map(|(name, memory_bytes)| ProcessMemoryMetrics { name, memory_bytes })
        .collect::<Vec<_>>();
    processes.sort_by(|left, right| {
        right.memory_bytes.cmp(&left.memory_bytes).then_with(|| {
            left.name
                .to_ascii_lowercase()
                .cmp(&right.name.to_ascii_lowercase())
        })
    });
    processes.truncate(5);
    processes
}

fn is_hidden_process_name(name: &str) -> bool {
    name.eq_ignore_ascii_case("node")
}

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.0) };
    }
}

fn read_drives() -> Option<Vec<DriveMetrics>> {
    let required = unsafe { GetLogicalDriveStringsW(None) };
    if required == 0 {
        return None;
    }
    let mut buffer = vec![0u16; required as usize + 1];
    let copied = unsafe { GetLogicalDriveStringsW(Some(&mut buffer)) };
    if copied == 0 || copied as usize >= buffer.len() {
        return None;
    }

    let mut drives = Vec::new();
    let mut start = 0usize;
    for end in 0..=copied as usize {
        if buffer.get(end).copied().unwrap_or_default() != 0 {
            continue;
        }
        if end == start {
            break;
        }
        let root = &buffer[start..=end];
        let mut free_to_caller = 0u64;
        let mut total_bytes = 0u64;
        let mut free_bytes = 0u64;
        if unsafe {
            GetDiskFreeSpaceExW(
                PCWSTR::from_raw(root.as_ptr()),
                Some(&mut free_to_caller),
                Some(&mut total_bytes),
                Some(&mut free_bytes),
            )
        }
        .is_ok()
            && total_bytes > 0
        {
            let letter = char::from_u32(u32::from(root[0]))?;
            if letter.is_ascii_alphabetic() {
                drives.push(DriveMetrics {
                    key: letter.to_ascii_lowercase().to_string(),
                    label: format!("{}:", letter.to_ascii_uppercase()),
                    total_bytes,
                    used_bytes: total_bytes.saturating_sub(free_bytes.min(total_bytes)),
                    free_bytes: free_bytes.min(total_bytes),
                });
            }
        }
        start = end + 1;
    }
    drives.sort_by(|left, right| left.key.cmp(&right.key));
    Some(drives)
}

pub(crate) fn percentage(part: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        (part as f64 / total as f64 * 100.0).clamp(0.0, 100.0)
    }
}

fn gibibytes(bytes: u64) -> f64 {
    bytes as f64 / BYTES_PER_GIB
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentages_are_bounded_and_zero_safe() {
        assert_eq!(percentage(1, 0), 0.0);
        assert_eq!(percentage(25, 100), 25.0);
        assert_eq!(percentage(125, 100), 100.0);
    }

    #[test]
    fn live_snapshot_contains_physical_memory_and_fixed_storage() {
        let metrics = snapshot();
        assert!(metrics.memory.available);
        assert!(metrics.memory.total_bytes > 0);
        assert!(metrics.memory.used_bytes <= metrics.memory.total_bytes);
        assert!(!metrics.memory.top_processes.is_empty());
        assert!(metrics.memory.top_processes.len() <= 5);
        assert!(metrics.drives.iter().any(|drive| drive.key == "c"));
    }

    #[test]
    fn process_ranking_aggregates_and_keeps_the_largest_five() {
        let ranked = rank_process_memory(HashMap::from([
            ("one".into(), 1),
            ("two".into(), 2),
            ("three".into(), 3),
            ("four".into(), 4),
            ("five".into(), 5),
            ("six".into(), 6),
        ]));
        assert_eq!(ranked.len(), 5);
        assert_eq!(ranked[0].name, "six");
        assert_eq!(ranked[4].name, "two");
    }

    #[test]
    fn generic_node_runtimes_do_not_mask_real_applications() {
        let ranked = rank_process_memory(HashMap::from([
            ("node".into(), 10_000),
            ("NODE".into(), 9_000),
            ("chrome".into(), 1_000),
        ]));
        assert_eq!(
            ranked,
            vec![ProcessMemoryMetrics {
                name: "chrome".into(),
                memory_bytes: 1_000,
            }]
        );
    }
}
