package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

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
SUMMARY_PROCESSES_WIDTH :: 220

// The root is a vertical flow with fixed-height controls and one growing
// table body. Keep the two text labels explicit-height so the pre-layout
// virtual-list calculation uses the same vertical contract as the retained
// layout pass.
MONITOR_ROOT_PADDING       :: 12
MONITOR_ROOT_GAP           :: 6
MONITOR_ROOT_CHILD_GAPS    :: 7
MONITOR_TITLE_HEIGHT       :: 20
MONITOR_SUMMARY_HEIGHT     :: 28
MONITOR_GRAPH_HEIGHT       :: 190
MONITOR_FILTER_LABEL_HEIGHT :: 20
MONITOR_FILTER_HEIGHT      :: 30
MONITOR_SORT_HEIGHT        :: 32
MONITOR_TABLE_HEADER_HEIGHT :: 24
MONITOR_TABLE_BODY_PADDING :: 6

Process_Monitor :: struct {
	// Application-owned persistent storage and per-callback scratch storage
	// are captured together so monitor callbacks do not depend on whichever
	// ambient allocator happens to be active at a later host event.
	persistent_allocator: mem.Allocator,
	scratch_arena:        ^mem.Dynamic_Arena,
	scratch_allocator:    mem.Allocator,
	filter:            string,
	scheduler:         host.Application_Scheduler,
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
	last_system_nice:   u64,
	process_revision:  u64,
	graph_revision:    u64,
	visible_filter:    string,
	visible_revision:  u64,
	visible_sort:      Process_Sort,
	visible_descending: bool,
	visible_valid:     bool,
	projection_rebuilds: u64,
	sort:              Process_Sort,
	sort_descending:   bool,
	selected:          Process_Key,
	has_selected:      bool,
	paused:            bool,
	// Temporary diagnostics for isolating the reported macOS interaction stall.
	disable_sampler:   bool,
	disable_surface:   bool,
	sample_count:      u64,
	process_sample_count: u64,
	query_failures:    int,
	queried_this_sample: int,
	unavailable_this_sample: int,
	input_debug:       bool,
	last_pointer_events: u64,
	qpc_frequency:     u64,
	last_qpc:          u64,
	process_sample_tick: time.Tick,
	filter_node:       alicorn.Node_ID,
	scroll_node:       alicorn.Node_ID,
	surface_node:      alicorn.Node_ID,
}

Monitor_Nodes :: struct {
	filter:  alicorn.Node_ID,
	surface: alicorn.Node_ID,
}

process_monitor_new :: proc() -> Process_Monitor {
	app := Process_Monitor{persistent_allocator = context.allocator}
	app.scratch_arena = new(mem.Dynamic_Arena, allocator=app.persistent_allocator)
	mem.dynamic_arena_init(app.scratch_arena, block_allocator=app.persistent_allocator, array_allocator=app.persistent_allocator)
	app.scratch_allocator = mem.dynamic_arena_allocator(app.scratch_arena)
	app.rows = make([dynamic]Process_Record, 0, 256, app.persistent_allocator)
	app.visible = make([dynamic]int, 0, 256, app.persistent_allocator)
	app.previous_cpu = make(map[Process_Key]u64, app.persistent_allocator)
	app.cpu_history = make([dynamic]f32, 0, 512, app.persistent_allocator)
	for i := 0; i < 512; i += 1 { append(&app.cpu_history, 0) }
	app.sort = .CPU
	app.sort_descending = true
	return app
}

process_monitor_destroy :: proc(app: ^Process_Monitor) {
	if len(app.filter) > 0 { delete(app.filter, app.persistent_allocator) }
	for row in app.rows {
		if len(row.identity) > 0 { delete(row.identity, app.persistent_allocator) }
		if len(row.name) > 0 { delete(row.name, app.persistent_allocator) }
	}
	delete(app.rows)
	delete(app.visible)
	if len(app.visible_filter) > 0 { delete(app.visible_filter) }
	delete(app.previous_cpu)
	delete(app.cpu_history)
	if app.scratch_arena != nil {
		mem.dynamic_arena_destroy(app.scratch_arena)
		free(app.scratch_arena, allocator=app.persistent_allocator)
	}
	app^ = {}
}

process_monitor_scratch_reset :: proc(app: ^Process_Monitor) {
	if app.scratch_arena != nil { mem.dynamic_arena_reset(app.scratch_arena) }
}

// Graph history advances only when a fresh frequent system sample is available;
// the monitor does not manufacture repeated points between scheduled samples.
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

process_monitor_reconcile_selection :: proc(app: ^Process_Monitor) {
	if !app.has_selected { return }
	for row in app.rows {
		if process_key_equal(app.selected, row.key) { return }
	}
	// Filtering and sorting preserve the snapshot row, so they preserve
	// selection. A missing key means the process exited or became unavailable;
	// clear the selection instead of leaving an invisible selected row behind.
	app.selected = Process_Key{}
	app.has_selected = false
}

process_monitor_process_summary :: proc(app: ^Process_Monitor) -> string {
	if app.unavailable_this_sample > 0 {
		return fmt.tprintf("Processes %d · %d unavailable", len(app.rows), app.unavailable_this_sample)
	}
	return fmt.tprintf("Processes %d", len(app.rows))
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

process_monitor_prepare_visible :: proc(app: ^Process_Monitor) {
	process_monitor_reconcile_selection(app)
	if app.visible_valid && app.visible_revision == app.process_revision &&
		app.visible_filter == app.filter && app.visible_sort == app.sort &&
		app.visible_descending == app.sort_descending {
		return
	}
	clear(&app.visible)
	for row, index in app.rows {
		if contains_insensitive(row.name, app.filter) || contains_insensitive(row.identity, app.filter) {
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
	if len(app.visible_filter) > 0 { delete(app.visible_filter) }
	filter_copy, err := strings.clone(app.filter)
	if err != nil {
		app.visible_valid = false
		return
	}
	app.visible_filter = filter_copy
	app.visible_revision = app.process_revision
	app.visible_sort = app.sort
	app.visible_descending = app.sort_descending
	app.visible_valid = true
	app.projection_rebuilds += 1
}

process_monitor_graph_range :: proc(app: ^Process_Monitor) -> (latest, minimum, maximum: f32) {
	if len(app.cpu_history) == 0 { return }
	minimum = app.cpu_history[0]
	maximum = app.cpu_history[0]
	for sample in app.cpu_history {
		if sample < minimum { minimum = sample }
		if sample > maximum { maximum = sample }
	}
	latest = app.cpu_history[len(app.cpu_history)-1]
	return
}

format_bytes :: proc(value: u64) -> string {
	if value >= 1024*1024*1024 { return fmt.tprintf("%.1f GB", f64(value)/(1024*1024*1024)) }
	if value >= 1024*1024 { return fmt.tprintf("%.1f MB", f64(value)/(1024*1024)) }
	if value >= 1024 { return fmt.tprintf("%.1f KB", f64(value)/1024) }
	return fmt.tprintf("%d B", value)
}

process_memory_primary_label :: proc() -> string {
	when ODIN_OS == .Darwin {
		return "RESIDENT"
	}
	return "WS"
}

process_memory_secondary_label :: proc() -> string {
	when ODIN_OS == .Darwin {
		return "FOOTPRINT"
	}
	return "PRIVATE"
}

system_memory_label :: proc() -> string {
	when ODIN_OS == .Darwin {
		return "System memory (non-free)"
	}
	return "System memory"
}

process_monitor_render :: proc(rt: ^alicorn.Runtime, app: ^Process_Monitor, logical_width, logical_height: f32, dpi_scale: f32) -> Monitor_Nodes {
	ui, build := alicorn.begin_frame(rt)
	if !build { return Monitor_Nodes{} }
	process_monitor_prepare_visible(app)
	root_style := alicorn.layout_style(padding=MONITOR_ROOT_PADDING, gap=MONITOR_ROOT_GAP, clip=true)
	alicorn.container_begin(&ui, .Root, label="Process Monitor", style=root_style, color=alicorn.Color{0.035, 0.045, 0.065, 1})
	alicorn.text(&ui, "Process Monitor / Alicorn dogfood", style=alicorn.layout_style(height=MONITOR_TITLE_HEIGHT))
	header_style := alicorn.layout_style(.Row, height=MONITOR_SUMMARY_HEIGHT, gap=8)
	alicorn.container_begin(&ui, .Container, label="system-summary", style=header_style, color=alicorn.Color{0.08, 0.14, 0.24, 1})
	alicorn.text(&ui, fmt.tprintf("CPU %.1f%%", app.cpu_percent), style=alicorn.layout_style(.Row, width=SUMMARY_CPU_WIDTH, height=28))
	alicorn.text(&ui, fmt.tprintf("%s %s / %s", system_memory_label(), format_bytes(app.memory_used), format_bytes(app.memory_total)), style=alicorn.layout_style(.Row, width=SUMMARY_MEMORY_WIDTH, height=28))
	alicorn.text(&ui, process_monitor_process_summary(app), style=alicorn.layout_style(.Row, width=SUMMARY_PROCESSES_WIDTH, height=28))
	alicorn.text(&ui, "CPU 250ms · table 1s", style=alicorn.layout_style(.Row, width=200, height=28))
	alicorn.container_end(&ui)
	scheduler_stats := host.application_scheduler_stats(app.scheduler)
	alicorn.text(&ui, fmt.tprintf(
		"Scheduler · frequent %d · opportunistic %d · deferred %d · max late %.1f ms",
		scheduler_stats.frequent_wakes,
		scheduler_stats.opportunistic_wakes,
		scheduler_stats.opportunistic_deferrals,
		f64(scheduler_stats.maximum_lateness_ns)/1_000_000,
	), style=alicorn.layout_style(height=18))

	graph_width := logical_width - 24
	if graph_width < 260 { graph_width = 260 }
	if graph_width > 1000 { graph_width = 1000 }
	graph_color := alicorn.Color{0.055, 0.08, 0.13, 1}
	graph_header_color := alicorn.Color{0.07, 0.11, 0.18, 1}
	graph_latest, _, graph_max := process_monitor_graph_range(app)
	alicorn.container_begin(&ui, .Container, label="cpu-graph", style=alicorn.layout_style(width=graph_width, height=MONITOR_GRAPH_HEIGHT, padding=6, gap=6), color=graph_color)
	// These containers are layout-only, but the current public container API
	// paints when no color is supplied. Use the intended graph colors so the
	// default light fill cannot leak into the chart area.
	alicorn.container_begin(&ui, .Container, label="cpu-graph-header", style=alicorn.layout_style(.Row, height=24, gap=8), color=graph_header_color)
	alicorn.text(&ui, "CPU history / GPU surface", style=alicorn.layout_style(.Row, width=260, height=24))
	// The graph is historical, not a second rendering of the summary value.
	// Showing its latest and maximum samples makes a high earlier sample
	// distinguishable from a current-CPU calculation error.
	alicorn.text(&ui, fmt.tprintf("Latest %.1f%% / max %.1f%%", graph_latest*100, graph_max*100), style=alicorn.layout_style(.Row, width=230, height=24))
	alicorn.container_end(&ui)
	alicorn.container_begin(&ui, .Container, label="cpu-graph-body", style=alicorn.layout_style(.Row, height=150, gap=4), color=graph_color)
	alicorn.container_begin(&ui, .Container, label="cpu-graph-axis", style=alicorn.layout_style(width=42, height=150), color=graph_color)
	alicorn.text(&ui, "100%", style=alicorn.layout_style(width=42, height=50))
	alicorn.text(&ui, "50%", style=alicorn.layout_style(width=42, height=50))
	alicorn.text(&ui, "0%", style=alicorn.layout_style(width=42, height=50))
	alicorn.container_end(&ui)
	surface_width := graph_width - 58
	if surface_width < 160 { surface_width = 160 }
	// The description revision tracks surface configuration only. High-frequency
	// sample changes are published independently through gpu_surface_update.
	surface := alicorn.gpu_surface(&ui, "cpu-history", 0, alicorn.Rect{0, 0, surface_width, 150}, int(surface_width*dpi_scale), int(150*dpi_scale), dpi_scale)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.text(&ui, fmt.tprintf("Filter (%d matching)", len(app.visible)), style=alicorn.layout_style(height=MONITOR_FILTER_LABEL_HEIGHT))
	filter_id := alicorn.text_field(&ui, app.filter, style=alicorn.layout_style(height=MONITOR_FILTER_HEIGHT))

	alicorn.container_begin(&ui, .Container, label="sort-controls", style=alicorn.layout_style(.Row, height=MONITOR_SORT_HEIGHT, padding=6, gap=6), color=alicorn.Color{0.06, 0.09, 0.14, 1})
	clicked_cpu := alicorn.button(&ui, "Sort CPU", key=alicorn.key_string("sort-cpu"), state=alicorn.Button_State{selected=app.sort == .CPU}, style=alicorn.layout_style(.Row, width=110, height=28, gap=4))
	clicked_memory := alicorn.button(&ui, "Sort Memory", key=alicorn.key_string("sort-memory"), state=alicorn.Button_State{selected=app.sort == .Memory}, style=alicorn.layout_style(.Row, width=125, height=28, gap=4))
	clicked_name := alicorn.button(&ui, "Sort Name", key=alicorn.key_string("sort-name"), state=alicorn.Button_State{selected=app.sort == .Name}, style=alicorn.layout_style(.Row, width=110, height=28, gap=4))
	clicked_pause := alicorn.button(&ui, "Pause / Resume", key=alicorn.key_string("pause"), state=alicorn.Button_State{selected=app.paused}, style=alicorn.layout_style(.Row, width=145, height=28, gap=4))
	controls_changed := clicked_cpu || clicked_memory || clicked_name || clicked_pause
	if clicked_cpu { app.sort = .CPU; app.sort_descending = !app.sort_descending }
	if clicked_memory { app.sort = .Memory; app.sort_descending = !app.sort_descending }
	if clicked_name { app.sort = .Name; app.sort_descending = !app.sort_descending }
	if clicked_pause {
		app.paused = !app.paused
		process_monitor_schedule_sampling(app, resume=!app.paused)
	}
	alicorn.container_end(&ui)

	table_body_width := logical_width - 24
	if table_body_width < 180 { table_body_width = 180 }
	if table_body_width > 1000 { table_body_width = 1000 }
	table_list_width := table_body_width - 2*MONITOR_TABLE_BODY_PADDING - alicorn.SCROLLBAR_THICKNESS
	if table_list_width < 120 { table_list_width = 120 }
	header_width := table_body_width - alicorn.SCROLLBAR_THICKNESS
	alicorn.container_begin(&ui, .Container, label="process-table-header", style=alicorn.layout_style(.Row, width=header_width, height=MONITOR_TABLE_HEADER_HEIGHT, padding=MONITOR_TABLE_BODY_PADDING), color=alicorn.Color{0.08, 0.11, 0.16, 1})
	alicorn.text(&ui, "", style=alicorn.layout_style(.Row, width=TABLE_MARKER_WIDTH, height=MONITOR_TABLE_HEADER_HEIGHT))
	alicorn.text(&ui, "PID", style=alicorn.layout_style(.Row, width=TABLE_PID_WIDTH, height=MONITOR_TABLE_HEADER_HEIGHT))
	alicorn.text(&ui, "PROCESS", style=alicorn.layout_style(.Row, height=MONITOR_TABLE_HEADER_HEIGHT, grow=1))
	alicorn.text(&ui, "CPU", style=alicorn.layout_style(.Row, width=TABLE_CPU_WIDTH, height=MONITOR_TABLE_HEADER_HEIGHT))
	alicorn.text(&ui, process_memory_primary_label(), style=alicorn.layout_style(.Row, width=TABLE_MEMORY_WIDTH, height=MONITOR_TABLE_HEADER_HEIGHT))
	alicorn.text(&ui, process_memory_secondary_label(), style=alicorn.layout_style(.Row, width=TABLE_MEMORY_WIDTH, height=MONITOR_TABLE_HEADER_HEIGHT))
	alicorn.container_end(&ui)
	row_height: f32 = 24
	alicorn.container_begin(&ui, .Container, label="process-table-body", style=alicorn.layout_style(.Row, width=table_body_width, grow=1, padding=MONITOR_TABLE_BODY_PADDING, clip=true))
	process_list := alicorn.virtual_list_begin(
		&ui,
		len(app.visible),
		row_height,
		key=alicorn.key_string("process-scroll"),
		style=alicorn.layout_style(grow=1, clip=true),
		content_width=table_list_width,
		label="process-list",
		axes=.Vertical,
	)
	app.scroll_node = process_list.scroll.id
	for position := process_list.first; position < process_list.last; position += 1 {
		row := app.rows[app.visible[position]]
		if !alicorn.component_begin(&ui, alicorn.key_pair(u64(row.key.pid), row.key.creation_time)) { continue }
		row_style := alicorn.layout_style(.Row, height=row_height, clip=true)
		alicorn.container_begin(&ui, .Container, label="process-row", style=row_style)
		selected := app.has_selected && process_key_equal(app.selected, row.key)
		marker := selected ? ">" : ""
		clicked_marker := alicorn.button(&ui, marker, state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, width=TABLE_MARKER_WIDTH, height=row_height))
		clicked_pid := alicorn.button(&ui, fmt.tprintf("%d", row.key.pid), state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, width=TABLE_PID_WIDTH, height=row_height))
		clicked_row_name := alicorn.button(&ui, row.name, state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, height=row_height, grow=1, clip=true))
		clicked_cpu := alicorn.button(&ui, fmt.tprintf("%.1f%%", row.cpu_percent), state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, width=TABLE_CPU_WIDTH, height=row_height))
		clicked_ws := alicorn.button(&ui, format_bytes(row.working_set_bytes), state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, width=TABLE_MEMORY_WIDTH, height=row_height))
		clicked_private := alicorn.button(&ui, format_bytes(row.private_bytes), state=alicorn.Button_State{selected=selected}, style=alicorn.layout_style(.Row, width=TABLE_MEMORY_WIDTH, height=row_height))
		if clicked_marker || clicked_pid || clicked_row_name || clicked_cpu || clicked_ws || clicked_private {
			app.selected = row.key
			app.has_selected = true
		}
		alicorn.container_end(&ui)
		alicorn.component_end(&ui)
	}
	alicorn.virtual_list_end(&ui, process_list)
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
	previous_temp_allocator := context.temp_allocator
	context.temp_allocator = app.scratch_allocator
	defer {
		context.temp_allocator = previous_temp_allocator
		process_monitor_scratch_reset(app)
	}
	first_build := app.filter_node == 0
	nodes := process_monitor_render(rt, app, f32(logical_width), f32(logical_height), dpi_scale)
	if first_build && nodes.filter != 0 { alicorn.focus(rt, nodes.filter) }
	return nodes.surface
}

// process_monitor_adopt_text_change is the application-owned side of the
// public Text_Change contract. The callback borrows runtime-owned text for
// the duration of the call, so a changed result is cloned into the monitor's
// persistent allocator. The host releases the original runtime product.
process_monitor_adopt_text_change :: proc(app: ^Process_Monitor, change: alicorn.Text_Change) {
	if change.changed {
		copy, err := strings.clone(change.text, app.persistent_allocator)
		if err == nil {
			if len(app.filter) > 0 { delete(app.filter, app.persistent_allocator) }
			app.filter = copy
		}
	}
}

process_monitor_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^Process_Monitor)state
	process_monitor_adopt_text_change(app, change)
	if change.changed { alicorn.invalidate_root(rt, "process monitor filter changed") }
}

MONITOR_FREQUENT_INTERVAL_NS :: u64(250_000_000)
MONITOR_OPPORTUNISTIC_INTERVAL_NS :: u64(1_000_000_000)
MONITOR_OPPORTUNISTIC_INITIAL_NS :: u64(500_000_000)

process_monitor_has_sampler :: proc() -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin { return true }
	return false
}

process_monitor_cancel_sampling :: proc(app: ^Process_Monitor) {
	_ = host.application_cancel_scheduled_wake(app.scheduler, .Frequent)
	_ = host.application_cancel_scheduled_wake(app.scheduler, .Opportunistic)
}

process_monitor_schedule_sampling :: proc(app: ^Process_Monitor, resume: bool = false) {
	process_monitor_cancel_sampling(app)
	if app.paused || app.disable_sampler || !process_monitor_has_sampler() { return }
	frequent_delay := MONITOR_FREQUENT_INTERVAL_NS
	opportunistic_delay := MONITOR_OPPORTUNISTIC_INTERVAL_NS
	if resume {
		frequent_delay = 0
		opportunistic_delay = 100_000_000
	} else if app.sample_count == 0 {
		frequent_delay = 0
		opportunistic_delay = MONITOR_OPPORTUNISTIC_INITIAL_NS
	}
	_ = host.application_schedule_after(app.scheduler, .Frequent, frequent_delay)
	_ = host.application_schedule_after(app.scheduler, .Opportunistic, opportunistic_delay)
}

process_monitor_on_services :: proc(state: rawptr, services: host.Application_Services) {
	app := cast(^Process_Monitor)state
	app.scheduler = services.scheduler
	process_monitor_schedule_sampling(app)
}

process_monitor_publish_frequent_sample :: proc(app: ^Process_Monitor, rt: ^alicorn.Runtime, sampled: bool) {
	if !sampled { return }
	app.sample_count += 1
	process_monitor_graph_tick(app)
	if app.surface_node != 0 && !app.disable_surface {
		_ = alicorn.gpu_surface_update(rt, app.surface_node, app.graph_revision, app.cpu_history[:])
	}
	alicorn.invalidate_root(rt, "frequent process monitor sample")
}

process_monitor_on_scheduled_wake :: proc(state: rawptr, rt: ^alicorn.Runtime, class: host.Scheduled_Wake_Class) {
	app := cast(^Process_Monitor)state
	if app.paused || app.disable_sampler || !process_monitor_has_sampler() { return }
	if app.input_debug && rt.stats.pointer_events != app.last_pointer_events {
		fmt.println("monitor_input", "pointer_events", rt.stats.pointer_events, "focused", rt.focused, "selected", rt.selected)
		app.last_pointer_events = rt.stats.pointer_events
	}
	switch class {
	case .Frequent:
		previous_temp_allocator := context.temp_allocator
		context.temp_allocator = app.scratch_allocator
		sampled := process_monitor_sample_system(app)
		context.temp_allocator = previous_temp_allocator
		process_monitor_scratch_reset(app)
		process_monitor_publish_frequent_sample(app, rt, sampled)
		_ = host.application_schedule_after(app.scheduler, .Frequent, MONITOR_FREQUENT_INTERVAL_NS)
	case .Opportunistic:
		previous_temp_allocator := context.temp_allocator
		context.temp_allocator = app.scratch_allocator
		sampled := process_monitor_sample_processes(app)
		context.temp_allocator = previous_temp_allocator
		process_monitor_scratch_reset(app)
		if sampled {
			app.process_sample_count += 1
			alicorn.invalidate_root(rt, "opportunistic process table refresh")
		}
		_ = host.application_schedule_after(app.scheduler, .Opportunistic, MONITOR_OPPORTUNISTIC_INTERVAL_NS)
	}
}

process_monitor_handle_key :: proc(app: ^Process_Monitor, rt: ^alicorn.Runtime, key: Monitor_Key) -> bool {
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
		page := max(1, int(alicorn.scroll_region_state(rt, app.scroll_node).viewport_height/24)-1)
		if key == .Page_Up { delta = -page }
		if key == .Page_Down { delta = page }
		next := selected_position + delta
		if next < 0 { next = 0 }
			if next >= len(app.visible) { next = len(app.visible)-1 }
			app.selected = app.rows[app.visible[next]].key
			app.has_selected = true
			_ = alicorn.virtual_list_ensure_visible(rt, app.scroll_node, next, "process selection visibility")
	case:
		return false
	}
	return true
}
