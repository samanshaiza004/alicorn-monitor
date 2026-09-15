package main

import "core:fmt"
import "core:os"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

monitor_key_from_host :: proc(key: host.Application_Key) -> Monitor_Key {
	switch key {
	case .Up: return .Up
	case .Down: return .Down
	case .Page_Up: return .Page_Up
	case .Page_Down: return .Page_Down
	case .Command_1: return .Sort_CPU
	case .Command_2: return .Sort_Memory
	case .Command_3: return .Sort_Name
	case .Toggle: return .Toggle_Pause
	}
	return .Toggle_Pause
}

monitor_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^Process_Monitor)state
	return process_monitor_handle_key(app, monitor_key_from_host(key))
}

main :: proc() {
	app := process_monitor_new()
	defer process_monitor_destroy(&app)
	application := host.Application{
		state = rawptr(&app),
		title = "Alicorn Process Monitor",
		width = 960,
		height = 720,
		build = process_monitor_build,
		on_text_change = process_monitor_on_text_change,
		on_key = monitor_on_key,
		on_scroll = process_monitor_on_scroll,
		on_tick = process_monitor_on_tick,
	}
	smoke := false
	sample_check := false
	input_debug := false
	disable_sampler := false
	disable_surface := false
	self_test := false
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
		if argument == "--sample-check" { sample_check = true }
		if argument == "--input-debug" { input_debug = true }
		if argument == "--no-sampler" { disable_sampler = true }
		if argument == "--no-surface" { disable_surface = true }
		if argument == "--self-test" { self_test = true }
	}
	app.input_debug = input_debug
	app.disable_sampler = disable_sampler
	app.disable_surface = disable_surface
	if self_test {
		if !process_monitor_run_dogfood_tests() { os.exit(1) }
		return
	}
	when ODIN_OS == .Darwin {
		if sample_check {
			if !process_monitor_sampler_check() { os.exit(1) }
			return
		}
	}
	host.Run(application, smoke)
	fmt.println(
		"process_monitor PASS",
		"samples", app.sample_count,
		"rows", len(app.rows),
		"cpu_percent", fmt.tprintf("%.1f", app.cpu_percent),
		"memory_used", format_bytes(app.memory_used),
		"memory_total", format_bytes(app.memory_total),
		"identity_keys", len(app.previous_cpu),
		"surface_updates", app.graph_revision,
		"surface_frames", app.graph_revision,
		"query_failures", app.query_failures,
	)
}
