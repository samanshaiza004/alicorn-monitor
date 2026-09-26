#+build darwin

package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"
import "core:sys/unix"
import "core:time"

// The Mach host calls are public system interfaces. The process calls used by
// Odin's core:sys/darwin package are libproc interfaces; Apple's SDK marks
// libproc.h as private and subject to change. Keep every use of that boundary
// in this file so the application and its public host API never depend on
// libproc types.
foreign import system "system:System"

foreign system {
	mach_host_self :: proc() -> c.uint ---
	host_statistics :: proc(host: c.uint, flavor: c.int, info: rawptr, count: ^c.uint) -> c.int ---
	host_statistics64 :: proc(host: c.uint, flavor: c.int, info: rawptr, count: ^c.uint) -> c.int ---
	host_page_size :: proc(host: c.uint, page_size: ^uintptr) -> c.int ---
}

DARWIN_HOST_CPU_LOAD_INFO :: 3
DARWIN_HOST_VM_INFO64 :: 4
DARWIN_CPU_STATE_USER :: 0
DARWIN_CPU_STATE_SYSTEM :: 1
DARWIN_CPU_STATE_IDLE :: 2
DARWIN_CPU_STATE_NICE :: 3

Darwin_Host_CPU_Load_Info :: struct {
	cpu_ticks: [4]c.uint,
}

// This mirrors vm_statistics64_data_t from the SDK used to build this
// checkout. host_statistics64 writes the complete structure for the current
// HOST_VM_INFO64 count, so the FFI buffer matches the installed SDK ABI.
Darwin_VM_Statistics64 :: struct {
	free_count:                             c.uint,
	active_count:                           c.uint,
	inactive_count:                         c.uint,
	wire_count:                             c.uint,
	zero_fill_count:                        u64,
	reactivations:                          u64,
	pageins:                                u64,
	pageouts:                               u64,
	faults:                                 u64,
	cow_faults:                             u64,
	lookups:                                u64,
	hits:                                   u64,
	purges:                                 u64,
	purgeable_count:                        c.uint,
	speculative_count:                      c.uint,
	decompressions:                         u64,
	compressions:                           u64,
	swapins:                                u64,
	swapouts:                               u64,
	compressor_page_count:                  c.uint,
	throttled_count:                        c.uint,
	external_page_count:                    c.uint,
	internal_page_count:                    c.uint,
	total_uncompressed_pages_in_compressor: u64,
	swapped_count:                          u64,
	total_tag_storage_pages:                u64,
	nontag_pageable_tag_storage_pages:      u64,
	nontag_wired_tag_storage_pages:         u64,
	free_tag_storage_pages:                 u64,
	tag_storing_tag_storage_pages:          u64,
	total_tagged_pages:                     u64,
	resident_tagged_pages:                  u64,
	compressed_tagged_pages:                u64,
	tagged_compressions:                    u64,
	tagged_decompressions:                  u64,
	compressed_tag_storage_bytes:           u64,
}

darwin_process_list :: proc() -> (pids: []i32, ok: bool) {
	// proc_listallpids returns the count of valid PID entries, not a sentinel
	// terminated list. The core wrapper follows the documented two-call form.
	count := darwin.proc_listallpids(nil, 0)
	if count <= 0 { return }

	pids = make([]i32, count, context.temp_allocator)
	filled := darwin.proc_listallpids(raw_data(pids), count*size_of(i32))
	if filled <= 0 {
		delete(pids, context.temp_allocator)
		pids = nil
		return
	}
	if int(filled) < len(pids) { pids = pids[:int(filled)] }
	ok = true
	return
}

darwin_process_name :: proc(pid: i32) -> string {
	info: darwin.proc_bsdinfo
	ret := darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, size_of(info))
	if ret != size_of(info) { return "" }
	// The SDK buffer is stack-local. Clone before returning; returning a string
	// view into `info` makes names turn into stack garbage at the call site.
	// pbi_comm is the short (MAXCOMLEN) kernel command name. pbi_name is the
	// longer registered process name and is what Activity Monitor-like views
	// expect when it is available.
	raw_name := string(cstring(raw_data(info.pbi_name[:])))
	if len(raw_name) == 0 {
		raw_name = string(cstring(raw_data(info.pbi_comm[:])))
	}
	name, err := strings.clone(raw_name)
	if err != nil { return "" }
	return name
}

process_monitor_system_cpu :: proc(app: ^Process_Monitor) -> (percent: f32, ok: bool) {
	info: Darwin_Host_CPU_Load_Info
	count := c.uint(size_of(info) / size_of(c.int))
	if host_statistics(mach_host_self(), DARWIN_HOST_CPU_LOAD_INFO, rawptr(&info), &count) != 0 {
		return
	}

	now_user := u64(info.cpu_ticks[DARWIN_CPU_STATE_USER])
	now_system := u64(info.cpu_ticks[DARWIN_CPU_STATE_SYSTEM])
	now_idle := u64(info.cpu_ticks[DARWIN_CPU_STATE_IDLE])
	now_nice := u64(info.cpu_ticks[DARWIN_CPU_STATE_NICE])
	if app.system_times_valid {
		if now_user >= app.last_system_user && now_system >= app.last_system_kernel && now_idle >= app.last_system_idle && now_nice >= app.last_system_nice {
			user_delta := now_user - app.last_system_user
			system_delta := now_system - app.last_system_kernel
			idle_delta := now_idle - app.last_system_idle
			nice_delta := now_nice - app.last_system_nice
			total_delta := user_delta + system_delta + idle_delta + nice_delta
			if total_delta > 0 {
				percent = f32(100.0 * f64(total_delta-idle_delta) / f64(total_delta))
				if percent < 0 { percent = 0 }
				if percent > 100 { percent = 100 }
				ok = true
			}
		}
	}
	app.last_system_user = now_user
	app.last_system_kernel = now_system
	app.last_system_idle = now_idle
	app.last_system_nice = now_nice
	app.system_times_valid = true
	return
}

process_monitor_system_memory :: proc(app: ^Process_Monitor) -> bool {
	total: u64
	if !unix.sysctlbyname("hw.memsize", &total) { return false }

	page_size: uintptr
	if host_page_size(mach_host_self(), &page_size) != 0 || page_size == 0 { return false }

	stats: Darwin_VM_Statistics64
	count := c.uint(size_of(stats) / size_of(c.int))
	if host_statistics64(mach_host_self(), DARWIN_HOST_VM_INFO64, rawptr(&stats), &count) != 0 { return false }

	free_bytes := u64(stats.free_count) * u64(page_size)
	if free_bytes > total { free_bytes = total }
	// This is deliberately labelled "non-free" in the UI. It includes
	// reclaimable/cache pages and is not Activity Monitor's private-memory
	// formula.
	app.memory_total = total
	app.memory_used = total - free_bytes
	return true
}

process_monitor_sample_system :: proc(app: ^Process_Monitor) -> bool {
	sampled := false
	if system_cpu, system_ok := process_monitor_system_cpu(app); system_ok {
		app.cpu_percent = system_cpu
		sampled = true
	} else if !app.system_times_valid {
		app.cpu_percent = 0
	}
	if process_monitor_system_memory(app) { sampled = true }
	return sampled || app.sample_count == 0
}

process_monitor_sample_processes :: proc(app: ^Process_Monitor) -> bool {
	elapsed := time.tick_lap_time(&app.process_sample_tick)
	app.queried_this_sample = 0
	app.unavailable_this_sample = 0
	// The list is a point-in-time snapshot; process churn between enumeration
	// and querying is handled as normal.
	pids, list_ok := darwin_process_list()
	if !list_ok {
		return false
	}
	defer delete(pids, context.temp_allocator)

	for row in app.rows {
		if len(row.identity) > 0 { delete(row.identity) }
		if len(row.name) > 0 { delete(row.name) }
	}
	clear(&app.rows)
	next_cpu := make(map[Process_Key]u64)
	logical_processors := os.get_processor_core_count()
	if logical_processors <= 0 { logical_processors = 1 }
	elapsed_ns := i64(elapsed)

	for pid in pids {
		if pid <= 0 { continue }
		rusage: darwin.rusage_info_v0
		if darwin.proc_pid_rusage(posix.pid_t(pid), .V0, &rusage) != 0 {
			// Processes can exit or become inaccessible between enumeration and
			// querying. That is expected sampling churn, not a fatal error.
			app.query_failures += 1
			app.unavailable_this_sample += 1
			continue
		}

		key := Process_Key{u32(pid), rusage.ri_proc_start_abstime}
		cpu_time := (rusage.ri_user_time + rusage.ri_system_time) / 100
		identity, identity_err := strings.clone(process_identity_string(key))
		if identity_err != nil { identity = "" }
		row := Process_Record{key=key, cpu_time_100ns=cpu_time, identity=identity}
		name := darwin_process_name(pid)
		if len(name) == 0 {
			name = fmt.tprintf("pid %d", pid)
			row.name, _ = strings.clone(name)
		} else {
			row.name = name
		}
		if previous, found := app.previous_cpu[key]; found && elapsed_ns > 0 && cpu_time >= previous {
			elapsed_seconds := f64(elapsed_ns) / 1e9
			process_seconds := f64(cpu_time-previous) / 10_000_000.0
			row.cpu_percent = f32(100.0 * process_seconds / elapsed_seconds / f64(logical_processors))
			if row.cpu_percent < 0 { row.cpu_percent = 0 }
			if row.cpu_percent > 100 { row.cpu_percent = 100 }
		}
		row.working_set_bytes = rusage.ri_resident_size
		row.private_bytes = rusage.ri_phys_footprint
		append(&app.rows, row)
		app.queried_this_sample += 1
		next_cpu[key] = cpu_time
	}

	delete(app.previous_cpu)
	app.previous_cpu = next_cpu
	app.process_revision += 1
	return true
}

process_monitor_sample :: proc(app: ^Process_Monitor) -> bool {
	system_sampled := process_monitor_sample_system(app)
	process_sampled := process_monitor_sample_processes(app)
	return system_sampled || process_sampled
}

process_monitor_sampler_check :: proc() -> bool {
	app := process_monitor_new()
	defer process_monitor_destroy(&app)
	if !process_monitor_sample(&app) {
		fmt.println("sampler_check FAIL sampler did not produce a snapshot")
		return false
	}
	if len(app.rows) == 0 {
		fmt.println("sampler_check FAIL sampler returned zero rows")
		return false
	}
	for row, index in app.rows {
		if index >= 8 { break }
		fmt.println("sampler_check row", row.key.pid, "name_len", len(row.name), "name", row.name)
	}
	for row in app.rows {
		for i in 0..<len(row.name) {
			byte := u8(row.name[i])
			if byte < 0x20 || byte == 0x7f {
				fmt.println("sampler_check FAIL non-printable process-name byte", byte)
				return false
			}
		}
	}
	fmt.println("sampler_check PASS rows", len(app.rows), "identity_keys", len(app.previous_cpu), "queried_this_sample", app.queried_this_sample, "unavailable_this_sample", app.unavailable_this_sample, "query_failures", app.query_failures)
	return true
}
