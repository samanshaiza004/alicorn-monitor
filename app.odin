package main

import "core:fmt"
import "core:strings"
import "core:time"
import alicorn "vendor/alicorn/runtime"

// Process_Key deliberately includes the creation timestamp. Windows may
// recycle a PID; PID alone is not a safe retained identity.
Process_Key :: struct {
	pid:            u32,
	creation_time:  u64,
}

Process_Record :: struct {
	key:            Process_Key,
	identity:       string,
	name:           string,
	cpu_percent:    f32,
	working_set_bytes: u64,
	private_bytes:     u64,
	cpu_time_100ns: u64,
}

Process_Sort :: enum {
	CPU,
	Memory,
	Name,
}

Monitor_Key :: enum {
	Up,
	Down,
	Page_Up,
	Page_Down,
	Sort_CPU,
	Sort_Memory,
	Sort_Name,
	Toggle_Pause,
}

// Shared table geometry keeps the header and rows aligned even as values
// change. The process-name column is the only flexible column.
TABLE_MARKER_WIDTH :: 28
TABLE_PID_WIDTH    :: 72
TABLE_CPU_WIDTH    :: 82
TABLE_MEMORY_WIDTH :: 110

SUMMARY_CPU_WIDTH       :: 150
SUMMARY_MEMORY_WIDTH    :: 300
SUMMARY_PROCESSES_WIDTH :: 170

Process_Monitor :: struct {
	filter:            string,
	rows:              [dynamic]Process_Record,
	visible:           [dynamic]int,
	previous_cpu:      map[Process_Key]u64,
	cpu_history:       [dynamic]f32,
	cpu_percent:       f32,
	memory_used:       u64,
	memory_total:      u64,
	system_times_valid: bool,
	last_system_idle:   u64,
	last_system_kernel: u64,
	last_system_user:   u64,
	process_revision:  u64,
	graph_revision:    u64,
	scroll_y:          f32,
	sort:              Process_Sort,
	sort_descending:   bool,
	selected:          Process_Key,
	has_selected:      bool,
	paused:            bool,
	sample_count:      u64,
	query_failures:    int,
	qpc_frequency:     u64,
	last_qpc:          u64,
	tick_count:        u64,
	last_tick_time:    time.Time,
	tick_time_valid:   bool,
	tick_hz:           f32,
	filter_node:       alicorn.Node_ID,
	surface_node:      alicorn.Node_ID,
}

Monitor_Nodes :: struct {
	filter:  alicorn.Node_ID,
	surface: alicorn.Node_ID,
}

process_monitor_new :: proc() -> Process_Monitor {
	app := Process_Monitor{}
	app.rows = make([dynamic]Process_Record, 0, 256)
	app.visible = make([dynamic]int, 0, 256)
	app.previous_cpu = make(map[Process_Key]u64)
	app.cpu_history = make([dynamic]f32, 0, 512)
	for i := 0; i < 512; i += 1 { append(&app.cpu_history, 0) }
	app.sort = .CPU
	app.sort_descending = true
	return app
}

process_monitor_destroy :: proc(app: ^Process_Monitor) {
	if len(app.filter) > 0 { delete(app.filter) }
	for row in app.rows {
		if len(row.identity) > 0 { delete(row.identity) }
		if len(row.name) > 0 { delete(row.name) }
	}
	delete(app.rows)
	delete(app.visible)
	delete(app.previous_cpu)
	delete(app.cpu_history)
	app^ = {}
}

// Graph history advances only when a fresh process sample is available. The
// host may tick at display cadence, but the monitor should not manufacture
// repeated points or GPU submissions between samples.
process_monitor_graph_tick :: proc(app: ^Process_Monitor) {
	if len(app.cpu_history) == 0 {
		for i := 0; i < 512; i += 1 { append(&app.cpu_history, 0) }
	}
	if app.sample_count <= 1 {
		value := app.cpu_percent / 100
		for &sample in app.cpu_history { sample = value }
		app.graph_revision += 1
		return
	}
	for i := 1; i < len(app.cpu_history); i += 1 { app.cpu_history[i-1] = app.cpu_history[i] }
	if len(app.cpu_history) > 0 { app.cpu_history[len(app.cpu_history)-1] = app.cpu_percent / 100 }
	app.graph_revision += 1
}

process_key_equal :: proc(a, b: Process_Key) -> bool {
	return a.pid == b.pid && a.creation_time == b.creation_time
}

process_identity_string :: proc(key: Process_Key) -> string {
	return fmt.tprintf("pid=%d;created=%d", key.pid, key.creation_time)
}

ascii_fold :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value + ('a' - 'A') }
	return value
}

contains_insensitive :: proc(value, query: string) -> bool {
	if len(query) == 0 { return true }
	if len(query) > len(value) { return false }
	for start := 0; start <= len(value)-len(query); start += 1 {
		matched := true
		for i := 0; i < len(query); i += 1 {
			if ascii_fold(u8(value[start+i])) != ascii_fold(u8(query[i])) {
				matched = false
				break
			}
		}
		if matched { return true }
	}
	return false
}

process_before :: proc(app: ^Process_Monitor, left, right: Process_Record) -> bool {
	less := false
	switch app.sort {
	case .CPU:
		if left.cpu_percent != right.cpu_percent { less = left.cpu_percent < right.cpu_percent }
		else { less = left.key.pid < right.key.pid }
	case .Memory:
		if left.working_set_bytes != right.working_set_bytes { less = left.working_set_bytes < right.working_set_bytes }
		else { less = left.key.pid < right.key.pid }
	case .Name:
		comparison := strings.compare(left.name, right.name)
		if comparison != 0 { less = comparison < 0 }
		else { less = left.key.pid < right.key.pid }
	}
	return app.sort_descending ? !less && left.key.pid != right.key.pid : less
}

process_monitor_prepare_visible :: proc(app: ^Process_Monitor, filter: string) {
	clear(&app.visible)
	for row, index in app.rows {
		if contains_insensitive(row.name, filter) || contains_insensitive(row.identity, filter) {
			append(&app.visible, index)
		}
	}
	// Process counts are normally a few hundred. A stable insertion sort keeps
	// this first dogfood app dependency-free and preserves deterministic ties.
	for i := 1; i < len(app.visible); i += 1 {
		item := app.visible[i]
		j := i
		for j > 0 && process_before(app, app.rows[item], app.rows[app.visible[j-1]]) {
			app.visible[j] = app.visible[j-1]
			j -= 1
		}
		app.visible[j] = item
	}
}

format_bytes :: proc(value: u64) -> string {
	if value >= 1024*1024*1024 { return fmt.tprintf("%.1f GB", f64(value)/(1024*1024*1024)) }
	if value >= 1024*1024 { return fmt.tprintf("%.1f MB", f64(value)/(1024*1024)) }
	if value >= 1024 { return fmt.tprintf("%.1f KB", f64(value)/1024) }
	return fmt.tprintf("%d B", value)
}

process_monitor_render :: proc(rt: ^alicorn.Runtime, app: ^Process_Monitor, logical_width, logical_height: f32, dpi_scale: f32) -> Monitor_Nodes {
	ui, build := alicorn.begin_frame(rt)
	if !build { return Monitor_Nodes{} }
	process_monitor_prepare_visible(app, app.filter)
	root_style := alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 0, 12, 6, .Stretch, true}
	alicorn.container_begin(&ui, .Root, label="Process Monitor", style=root_style, color=alicorn.Color{0.035, 0.045, 0.065, 1})
	alicorn.text(&ui, "Process Monitor / Alicorn dogfood")
	header_style := alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 8, .Stretch, false}
	alicorn.container_begin(&ui, .Container, label="system-summary", style=header_style, color=alicorn.Color{0.08, 0.14, 0.24, 1})
	alicorn.text(&ui, fmt.tprintf("CPU %.1f%%", app.cpu_percent), style=alicorn.Layout_Style{.Row, SUMMARY_CPU_WIDTH, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, fmt.tprintf("System memory %s / %s", format_bytes(app.memory_used), format_bytes(app.memory_total)), style=alicorn.Layout_Style{.Row, SUMMARY_MEMORY_WIDTH, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, fmt.tprintf("Processes %d", len(app.rows)), style=alicorn.Layout_Style{.Row, SUMMARY_PROCESSES_WIDTH, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, fmt.tprintf("Host ticks %.1f Hz", app.tick_hz), style=alicorn.Layout_Style{.Row, 170, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_end(&ui)

	graph_width := logical_width - 24
	if graph_width < 260 { graph_width = 260 }
	if graph_width > 1000 { graph_width = 1000 }
	graph_color := alicorn.Color{0.055, 0.08, 0.13, 1}
	graph_header_color := alicorn.Color{0.07, 0.11, 0.18, 1}
	alicorn.container_begin(&ui, .Container, label="cpu-graph", style=alicorn.Layout_Style{.Column, graph_width, 190, 0, -1, 0, -1, 0, 6, 6, .Stretch, false}, color=graph_color)
	// These containers are layout-only, but the current public container API
	// paints when no color is supplied. Use the intended graph colors so the
	// default light fill cannot leak into the chart area.
	alicorn.container_begin(&ui, .Container, label="cpu-graph-header", style=alicorn.Layout_Style{.Row, -1, 24, 0, -1, 0, -1, 0, 0, 8, .Stretch, false}, color=graph_header_color)
	alicorn.text(&ui, "CPU history / GPU surface", style=alicorn.Layout_Style{.Row, 260, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, fmt.tprintf("Current CPU %.1f%%", app.cpu_percent), style=alicorn.Layout_Style{.Row, 180, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_end(&ui)
	alicorn.container_begin(&ui, .Container, label="cpu-graph-body", style=alicorn.Layout_Style{.Row, -1, 150, 0, -1, 0, -1, 0, 0, 4, .Stretch, false}, color=graph_color)
	alicorn.container_begin(&ui, .Container, label="cpu-graph-axis", style=alicorn.Layout_Style{.Column, 42, 150, 0, -1, 0, -1, 0, 0, 0, .Stretch, false}, color=graph_color)
	alicorn.text(&ui, "100%", style=alicorn.Layout_Style{.Column, 42, 50, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "50%", style=alicorn.Layout_Style{.Column, 42, 50, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "0%", style=alicorn.Layout_Style{.Column, 42, 50, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_end(&ui)
	surface_width := graph_width - 58
	if surface_width < 160 { surface_width = 160 }
	surface := alicorn.gpu_surface(&ui, "cpu-history", app.graph_revision, alicorn.Rect{0, 0, surface_width, 150}, int(surface_width*dpi_scale), int(150*dpi_scale), dpi_scale)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.text(&ui, fmt.tprintf("Filter (%d matching)", len(app.visible)))
	filter_id := alicorn.text_field(&ui, app.filter, style=alicorn.Layout_Style{.Column, -1, 30, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})

	alicorn.container_begin(&ui, .Container, label="sort-controls", style=alicorn.Layout_Style{.Row, -1, 32, 0, -1, 0, -1, 0, 6, 6, .Stretch, false}, color=alicorn.Color{0.06, 0.09, 0.14, 1})
	clicked_cpu := alicorn.button(&ui, "Sort CPU", key=alicorn.key_string("sort-cpu"), state=alicorn.Button_State{selected=app.sort == .CPU}, style=alicorn.Layout_Style{.Row, 110, 28, 0, -1, 0, -1, 0, 0, 4, .Stretch, false})
	clicked_memory := alicorn.button(&ui, "Sort Memory", key=alicorn.key_string("sort-memory"), state=alicorn.Button_State{selected=app.sort == .Memory}, style=alicorn.Layout_Style{.Row, 125, 28, 0, -1, 0, -1, 0, 0, 4, .Stretch, false})
	clicked_name := alicorn.button(&ui, "Sort Name", key=alicorn.key_string("sort-name"), state=alicorn.Button_State{selected=app.sort == .Name}, style=alicorn.Layout_Style{.Row, 110, 28, 0, -1, 0, -1, 0, 0, 4, .Stretch, false})
	clicked_pause := alicorn.button(&ui, "Pause / Resume", key=alicorn.key_string("pause"), state=alicorn.Button_State{selected=app.paused}, style=alicorn.Layout_Style{.Row, 145, 28, 0, -1, 0, -1, 0, 0, 4, .Stretch, false})
	controls_changed := clicked_cpu || clicked_memory || clicked_name || clicked_pause
	if clicked_cpu { app.sort = .CPU; app.sort_descending = !app.sort_descending }
	if clicked_memory { app.sort = .Memory; app.sort_descending = !app.sort_descending }
	if clicked_name { app.sort = .Name; app.sort_descending = !app.sort_descending }
	if clicked_pause { app.paused = !app.paused }
	alicorn.container_end(&ui)

	alicorn.container_begin(&ui, .Container, label="process-table-header", style=alicorn.Layout_Style{.Row, -1, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false}, color=alicorn.Color{0.08, 0.11, 0.16, 1})
	alicorn.text(&ui, "", style=alicorn.Layout_Style{.Row, TABLE_MARKER_WIDTH, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "PID", style=alicorn.Layout_Style{.Row, TABLE_PID_WIDTH, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "PROCESS", style=alicorn.Layout_Style{.Row, -1, 24, 0, -1, 0, -1, 1, 0, 0, .Stretch, false})
	alicorn.text(&ui, "CPU", style=alicorn.Layout_Style{.Row, TABLE_CPU_WIDTH, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "WS", style=alicorn.Layout_Style{.Row, TABLE_MEMORY_WIDTH, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.text(&ui, "PRIVATE", style=alicorn.Layout_Style{.Row, TABLE_MEMORY_WIDTH, 24, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_end(&ui)
	row_height: f32 = 24
	list_height := logical_height - 340
	if list_height < row_height { list_height = row_height }
	first := int(app.scroll_y / row_height)
	if first < 0 { first = 0 }
	if first >= len(app.visible) && len(app.visible) > 0 { first = len(app.visible)-1 }
	last := int((app.scroll_y + list_height) / row_height) + 1
	if last > len(app.visible) { last = len(app.visible) }
	alicorn.container_begin(&ui, .Virtual_List, label="process-list", style=alicorn.Layout_Style{.Column, -1, list_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true})
	for position := first; position < last; position += 1 {
		row := app.rows[app.visible[position]]
		if !alicorn.component_begin(&ui, alicorn.key_pair(u64(row.key.pid), row.key.creation_time)) { continue }
		row_style := alicorn.Layout_Style{.Row, -1, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true}
		alicorn.container_begin(&ui, .Container, label="process-row", style=row_style)
		selected := app.has_selected && process_key_equal(app.selected, row.key)
		marker := selected ? ">" : ""
		clicked_marker := alicorn.button(&ui, marker, key=alicorn.key_string("marker"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, TABLE_MARKER_WIDTH, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		clicked_pid := alicorn.button(&ui, fmt.tprintf("%d", row.key.pid), key=alicorn.key_string("pid"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, TABLE_PID_WIDTH, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		clicked_row_name := alicorn.button(&ui, row.name, key=alicorn.key_string("name"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, -1, row_height, 0, -1, 0, -1, 1, 0, 0, .Stretch, true})
		clicked_cpu := alicorn.button(&ui, fmt.tprintf("%.1f%%", row.cpu_percent), key=alicorn.key_string("cpu"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, TABLE_CPU_WIDTH, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		clicked_ws := alicorn.button(&ui, format_bytes(row.working_set_bytes), key=alicorn.key_string("working-set"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, TABLE_MEMORY_WIDTH, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		clicked_private := alicorn.button(&ui, format_bytes(row.private_bytes), key=alicorn.key_string("private"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, TABLE_MEMORY_WIDTH, row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		if clicked_marker || clicked_pid || clicked_row_name || clicked_cpu || clicked_ws || clicked_private {
			app.selected = row.key
			app.has_selected = true
		}
		alicorn.container_end(&ui)
		alicorn.component_end(&ui)
	}
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	if controls_changed { alicorn.invalidate_root(rt, "process monitor control changed") }
	app.filter_node = filter_id
	app.surface_node = surface
	return Monitor_Nodes{filter_id, surface}
}

// The callbacks below form the entire application/host seam. A host borrows
// the application's state pointer only while invoking them; the runtime keeps
// only Node_IDs and copied runtime products.
process_monitor_build :: proc(state: rawptr, rt: ^alicorn.Runtime, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID {
	app := cast(^Process_Monitor)state
	first_build := app.filter_node == 0
	nodes := process_monitor_render(rt, app, f32(logical_width), f32(logical_height), dpi_scale)
	if first_build && nodes.filter != 0 { alicorn.focus(rt, nodes.filter) }
	return nodes.surface
}

process_monitor_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^Process_Monitor)state
	if change.changed {
		if len(app.filter) > 0 { delete(app.filter) }
		app.filter = change.text
		alicorn.invalidate_root(rt, "process monitor filter changed")
	} else if len(change.text) > 0 {
		delete(change.text)
	}
}

process_monitor_on_scroll :: proc(state: rawptr, rt: ^alicorn.Runtime, delta_y: f32) {
	app := cast(^Process_Monitor)state
	process_monitor_scroll(app, delta_y)
	alicorn.invalidate_root(rt, "process monitor scroll")
}

process_monitor_on_tick :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Process_Monitor)state
	app.tick_count += 1
	now := time.now()
	if app.tick_time_valid {
		delta_ns := time.duration_nanoseconds(time.diff(app.last_tick_time, now))
		if delta_ns > 0 {
			instant_hz := f32(1e9 / f64(delta_ns))
			if app.tick_hz == 0 {
				app.tick_hz = instant_hz
			} else {
				app.tick_hz = app.tick_hz*0.9 + instant_hz*0.1
			}
		}
	}
	app.last_tick_time = now
	app.tick_time_valid = true
	if app.paused { return }
	// The host ticks at display cadence, but process data and graph history only
	// change when a new sample is available. This keeps the monitor's GPU work
	// proportional to information changes rather than repainting duplicates.
	if app.sample_count == 0 || app.tick_count % 15 == 0 {
		if process_monitor_sample(app) {
			process_monitor_graph_tick(app)
			if app.surface_node != 0 {
				_ = alicorn.gpu_surface_update(rt, app.surface_node, app.graph_revision, app.cpu_history[:])
			}
			alicorn.invalidate_root(rt, "process monitor sample")
		}
	}
}

process_monitor_handle_key :: proc(app: ^Process_Monitor, key: Monitor_Key) -> bool {
	switch key {
	case .Sort_CPU:
		if app.sort == .CPU { app.sort_descending = !app.sort_descending } else { app.sort = .CPU; app.sort_descending = true }
	case .Sort_Memory:
		if app.sort == .Memory { app.sort_descending = !app.sort_descending } else { app.sort = .Memory; app.sort_descending = true }
	case .Sort_Name:
		if app.sort == .Name { app.sort_descending = !app.sort_descending } else { app.sort = .Name; app.sort_descending = false }
	case .Toggle_Pause:
		app.paused = !app.paused
	case .Up, .Down, .Page_Up, .Page_Down:
		if len(app.visible) == 0 { return false }
		selected_position := -1
		for position, row_index in app.visible {
			if app.has_selected && process_key_equal(app.selected, app.rows[row_index].key) { selected_position = position; break }
		}
		if selected_position < 0 { selected_position = 0 }
		delta := 1
		if key == .Up { delta = -1 }
		if key == .Page_Up { delta = -8 }
		if key == .Page_Down { delta = 8 }
		next := selected_position + delta
		if next < 0 { next = 0 }
		if next >= len(app.visible) { next = len(app.visible)-1 }
		app.selected = app.rows[app.visible[next]].key
		app.has_selected = true
		app.scroll_y = f32(next/8) * 24
	case:
		return false
	}
	return true
}

process_monitor_scroll :: proc(app: ^Process_Monitor, delta_y: f32) {
	app.scroll_y -= delta_y * 3
	if app.scroll_y < 0 { app.scroll_y = 0 }
	max_scroll := f32(max(len(app.visible)*24-240, 0))
	if app.scroll_y > max_scroll { app.scroll_y = max_scroll }
}
