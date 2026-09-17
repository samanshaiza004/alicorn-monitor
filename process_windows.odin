#+build windows

package main

import "core:os"
import "core:strings"
import "core:sys/windows"

foreign import psapi "system:Psapi.lib"
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign psapi {
	GetProcessMemoryInfo :: proc(process: windows.HANDLE, counters: rawptr, cb: windows.DWORD) -> windows.BOOL ---
}

@(default_calling_convention="system")
foreign kernel32 {
	GetSystemTimes :: proc(idle_time, kernel_time, user_time: ^windows.FILETIME) -> windows.BOOL ---
}

PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb:                       windows.DWORD,
	PageFaultCount:           windows.DWORD,
	PeakWorkingSetSize:       windows.SIZE_T,
	WorkingSetSize:           windows.SIZE_T,
	QuotaPeakPagedPoolUsage:  windows.SIZE_T,
	QuotaPagedPoolUsage:      windows.SIZE_T,
	QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
	QuotaNonPagedPoolUsage:   windows.SIZE_T,
	PagefileUsage:            windows.SIZE_T,
	PeakPagefileUsage:        windows.SIZE_T,
	PrivateUsage:             windows.SIZE_T,
}

filetime_value :: proc(value: windows.FILETIME) -> u64 {
	return u64(value.dwLowDateTime) | (u64(value.dwHighDateTime) << 32)
}

process_monitor_system_cpu :: proc(app: ^Process_Monitor) -> (percent: f32, ok: bool) {
	idle, kernel, user: windows.FILETIME
	if !GetSystemTimes(&idle, &kernel, &user) { return }
	now_idle := filetime_value(idle)
	now_kernel := filetime_value(kernel)
	now_user := filetime_value(user)
	if app.system_times_valid {
		if now_idle >= app.last_system_idle && now_kernel >= app.last_system_kernel && now_user >= app.last_system_user {
			idle_delta := now_idle - app.last_system_idle
			total_now := now_kernel + now_user
			total_before := app.last_system_kernel + app.last_system_user
			if total_now >= total_before {
				total_delta := total_now - total_before
				if total_delta > 0 && total_delta >= idle_delta {
					percent = f32(100.0 * f64(total_delta-idle_delta) / f64(total_delta))
					if percent < 0 { percent = 0 }
					if percent > 100 { percent = 100 }
					ok = true
				}
			}
		}
	}
	app.last_system_idle = now_idle
	app.last_system_kernel = now_kernel
	app.last_system_user = now_user
	app.system_times_valid = true
	return
}

qpc_value :: proc() -> u64 {
	value: windows.LARGE_INTEGER
	if !windows.QueryPerformanceCounter(&value) { return 0 }
	return u64(i64(value))
}

process_monitor_sample :: proc(app: ^Process_Monitor) -> bool {
	if app.qpc_frequency == 0 {
		frequency: windows.LARGE_INTEGER
		if !windows.QueryPerformanceFrequency(&frequency) { return false }
		app.qpc_frequency = u64(i64(frequency))
	}
	now := qpc_value()
	if now == 0 { return false }
	elapsed_qpc := u64(0)
	if app.last_qpc != 0 && now > app.last_qpc { elapsed_qpc = now - app.last_qpc }
	app.last_qpc = now
	app.queried_this_sample = 0
	app.unavailable_this_sample = 0

	for row in app.rows {
		if len(row.identity) > 0 { delete(row.identity, app.persistent_allocator) }
		if len(row.name) > 0 { delete(row.name, app.persistent_allocator) }
	}
	clear(&app.rows)
	next_cpu := make(map[Process_Key]u64, allocator=app.persistent_allocator)
	snapshot := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if snapshot == windows.INVALID_HANDLE_VALUE {
		delete(next_cpu)
		return false
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.PROCESSENTRY32W{dwSize=size_of(windows.PROCESSENTRY32W)}
	status := windows.Process32FirstW(snapshot, &entry)
	logical_processors := os.get_processor_core_count()
	if logical_processors <= 0 { logical_processors = 1 }
	total_cpu: f32 = 0
	for status {
		pid := entry.th32ProcessID
		handle := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
		if handle != nil {
			creation, exit_time, kernel, user: windows.FILETIME
			if windows.GetProcessTimes(handle, &creation, &exit_time, &kernel, &user) {
				key := Process_Key{pid, filetime_value(creation)}
				cpu_time := filetime_value(kernel) + filetime_value(user)
				identity_temp := process_identity_string(key)
				identity, identity_err := strings.clone(identity_temp, app.persistent_allocator)
				if identity_err != nil { identity = "" }
				row := Process_Record{key=key, cpu_time_100ns=cpu_time, identity=identity}
				name, name_err := windows.wstring_to_utf8_alloc(cstring16(raw_data(entry.szExeFile[:])), -1, context.temp_allocator)
				if name_err == nil { row.name, _ = strings.clone(name, app.persistent_allocator) } else { row.name, _ = strings.clone("unknown", app.persistent_allocator) }
				if previous, found := app.previous_cpu[key]; found && elapsed_qpc > 0 && cpu_time >= previous {
					elapsed_seconds := f64(elapsed_qpc) / f64(app.qpc_frequency)
					process_seconds := f64(cpu_time-previous) / 10_000_000.0
					row.cpu_percent = f32(100.0 * process_seconds / elapsed_seconds / f64(logical_processors))
					if row.cpu_percent < 0 { row.cpu_percent = 0 }
					if row.cpu_percent > 100 { row.cpu_percent = 100 }
				}
				counters := PROCESS_MEMORY_COUNTERS_EX{cb=windows.DWORD(size_of(PROCESS_MEMORY_COUNTERS_EX))}
				if GetProcessMemoryInfo(handle, &counters, windows.DWORD(size_of(counters))) {
					row.working_set_bytes = u64(counters.WorkingSetSize)
					row.private_bytes = u64(counters.PrivateUsage)
				}
				append(&app.rows, row)
				app.queried_this_sample += 1
				next_cpu[key] = cpu_time
				total_cpu += row.cpu_percent
			} else {
				app.query_failures += 1
				app.unavailable_this_sample += 1
			}
			windows.CloseHandle(handle)
		} else {
			app.query_failures += 1
			app.unavailable_this_sample += 1
		}
		status = windows.Process32NextW(snapshot, &entry)
	}
	delete(app.previous_cpu)
	app.previous_cpu = next_cpu
	app.process_revision += 1
	app.sample_count += 1
	if system_cpu, system_ok := process_monitor_system_cpu(app); system_ok {
		app.cpu_percent = system_cpu
	} else {
		app.cpu_percent = total_cpu
	}
	if app.cpu_percent > 100 { app.cpu_percent = 100 }
	memory := windows.MEMORYSTATUSEX{dwLength=size_of(windows.MEMORYSTATUSEX)}
	if windows.GlobalMemoryStatusEx(&memory) {
		app.memory_total = u64(memory.ullTotalPhys)
		app.memory_used = app.memory_total - u64(memory.ullAvailPhys)
	}
	return true
}
