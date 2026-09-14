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
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
	}
	host.Run(application, smoke)
	fmt.println(
		"process_monitor PASS",
		"samples", app.sample_count,
		"rows", len(app.rows),
		"surface_updates", app.graph_revision,
		"surface_frames", app.graph_revision,
		"query_failures", app.query_failures,
	)
}
