package main

import "core:fmt"
import "core:strings"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

Dogfood_Test_State :: struct {
	failures: int,
}

Dogfood_Fake_Scheduler :: struct {
	delays_ns: [2]u64,
	pending:   [2]bool,
	scheduled: u64,
	cancelled: u64,
}

dogfood_scheduler_index :: proc(class: host.Scheduled_Wake_Class) -> int {
	return 0 if class == .Frequent else 1
}

dogfood_scheduler_schedule :: proc(data: rawptr, class: host.Scheduled_Wake_Class, delay_ns: u64) -> bool {
	state := cast(^Dogfood_Fake_Scheduler)data
	index := dogfood_scheduler_index(class)
	state.delays_ns[index] = delay_ns
	state.pending[index] = true
	state.scheduled += 1
	return true
}

dogfood_scheduler_cancel :: proc(data: rawptr, class: host.Scheduled_Wake_Class) -> bool {
	state := cast(^Dogfood_Fake_Scheduler)data
	index := dogfood_scheduler_index(class)
	state.pending[index] = false
	state.cancelled += 1
	return true
}

dogfood_scheduler_stats :: proc(data: rawptr) -> host.Application_Scheduler_Stats {
	state := cast(^Dogfood_Fake_Scheduler)data
	return host.Application_Scheduler_Stats{
		scheduled=state.scheduled,
		frequent_pending=state.pending[0],
		opportunistic_pending=state.pending[1],
	}
}

dogfood_expect :: proc(state: ^Dogfood_Test_State, condition: bool, message: string) {
	if !condition {
		state.failures += 1
		fmt.println("FAIL:", message)
	}
}

dogfood_expect_filter :: proc(state: ^Dogfood_Test_State, app: ^Process_Monitor, expected: string, message: string) {
	dogfood_expect(state, app.filter == expected, message)
}

dogfood_append_row :: proc(app: ^Process_Monitor, pid: u32, name: string) {
	name_copy, name_err := strings.clone(name)
	identity_copy, identity_err := strings.clone(fmt.tprintf("pid=%d", pid))
	if name_err != nil || identity_err != nil {
		if name_err == nil { delete(name_copy) }
		if identity_err == nil { delete(identity_copy) }
		return
	}
	append(&app.rows, Process_Record{
		key=Process_Key{pid, u64(pid)}, identity=identity_copy, name=name_copy,
		cpu_percent=f32(pid), working_set_bytes=u64(pid),
	})
}

dogfood_node_by_label :: proc(rt: ^alicorn.Runtime, label: string) -> ^alicorn.Node {
	for _, node in rt.nodes {
		if node.label == label { return node }
	}
	return nil
}

// process_monitor_run_dogfood_tests exercises the monitor's external side of
// the public text-editing boundary. The callback clones the borrowed runtime
// text, while this direct test call releases each returned product explicitly
// as the native host would after the callback returns.
process_monitor_run_dogfood_tests :: proc() -> bool {
	state := Dogfood_Test_State{}
	scheduler_app := process_monitor_new()
	defer process_monitor_destroy(&scheduler_app)
	fake_scheduler := Dogfood_Fake_Scheduler{}
	scheduler_app.scheduler = host.Application_Scheduler{
		data=rawptr(&fake_scheduler),
		schedule=dogfood_scheduler_schedule,
		cancel=dogfood_scheduler_cancel,
		read_stats=dogfood_scheduler_stats,
	}
	process_monitor_schedule_sampling(&scheduler_app)
	dogfood_expect(&state,
		fake_scheduler.pending[0] && fake_scheduler.delays_ns[0] == 0 &&
			fake_scheduler.pending[1] && fake_scheduler.delays_ns[1] == MONITOR_OPPORTUNISTIC_INITIAL_NS,
		"startup should schedule immediate frequent work and delayed table work")
	scheduler_app.paused = true
	process_monitor_schedule_sampling(&scheduler_app)
	dogfood_expect(&state, !fake_scheduler.pending[0] && !fake_scheduler.pending[1], "pause should cancel every scheduled wake")
	scheduler_app.paused = false
	process_monitor_schedule_sampling(&scheduler_app, resume=true)
	dogfood_expect(&state,
		fake_scheduler.pending[0] && fake_scheduler.delays_ns[0] == 0 &&
			fake_scheduler.pending[1] && fake_scheduler.delays_ns[1] == 100_000_000,
		"resume should promptly refresh both fidelity tiers")

	fidelity_app := process_monitor_new()
	defer process_monitor_destroy(&fidelity_app)
	dogfood_append_row(&fidelity_app, 1, "alpha process")
	dogfood_append_row(&fidelity_app, 2, "beta process")
	fidelity_app.process_revision = 1
	process_monitor_prepare_visible(&fidelity_app)
	projection_rebuilds_before_graph := fidelity_app.projection_rebuilds
	fidelity_rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 360})
	defer alicorn.destroy_runtime(&fidelity_rt)
	fidelity_app.cpu_percent = 42
	process_monitor_publish_frequent_sample(&fidelity_app, &fidelity_rt, true)
	process_monitor_prepare_visible(&fidelity_app)
	dogfood_expect(&state,
		fidelity_app.graph_revision == 1 && fidelity_app.process_revision == 1 &&
			fidelity_app.projection_rebuilds == projection_rebuilds_before_graph,
		"frequent graph refresh must not force the process table projection to rebuild")

	scroll_app := process_monitor_new()
	defer process_monitor_destroy(&scroll_app)
	scroll_rt := alicorn.new_runtime(alicorn.Rect{0, 0, 960, 720})
	defer alicorn.destroy_runtime(&scroll_rt)
	for i := 0; i < 100; i += 1 { dogfood_append_row(&scroll_app, u32(i+1), fmt.tprintf("process %d", i+1)) }
	scroll_app.process_revision = 1
	process_monitor_build(rawptr(&scroll_app), &scroll_rt, 960, 720, 1)
	scroll_node := scroll_rt.nodes[scroll_app.scroll_node]
	precise := alicorn.process_scroll(&scroll_rt, alicorn.Scroll_Event{delta_y=-0.5, x=scroll_node.bounds.x+4, y=scroll_node.bounds.y+4})
	dogfood_expect(&state, precise && alicorn.scroll_region_offset(&scroll_rt, scroll_app.scroll_node) == 12, "retained scroll regions preserve fractional wheel movement")
	_ = alicorn.process_scroll(&scroll_rt, alicorn.Scroll_Event{ticks_y=-1, x=scroll_node.bounds.x+4, y=scroll_node.bounds.y+4})
	dogfood_expect(&state, alicorn.scroll_region_offset(&scroll_rt, scroll_app.scroll_node) == 12, "precise deltas remain authoritative over coarse wheel ticks")
	_ = alicorn.scroll_region_set_offset(&scroll_rt, scroll_app.scroll_node, 99999)
	state_after_clamp := alicorn.scroll_region_state(&scroll_rt, scroll_app.scroll_node)
	dogfood_expect(&state, alicorn.scroll_region_offset(&scroll_rt, scroll_app.scroll_node) == state_after_clamp.max_scroll_y, "retained scrolling clamps to content minus the resolved viewport")
	projection_app := process_monitor_new()
	defer process_monitor_destroy(&projection_app)
	dogfood_append_row(&projection_app, 1, "alpha process")
	dogfood_append_row(&projection_app, 2, "beta process")
	projection_app.process_revision = 1
	process_monitor_prepare_visible(&projection_app)
	projection_rebuilds := projection_app.projection_rebuilds
	process_monitor_prepare_visible(&projection_app)
	dogfood_expect(&state, projection_app.projection_rebuilds == projection_rebuilds, "unchanged process projection is reused")
	projection_app.filter, _ = strings.clone("alpha")
	process_monitor_prepare_visible(&projection_app)
	dogfood_expect(&state, projection_app.projection_rebuilds == projection_rebuilds+1 && len(projection_app.visible) == 1, "filter changes rebuild only the visible projection")
	if len(projection_app.filter) > 0 { delete(projection_app.filter) }
	projection_app.filter = ""
	projection_app.selected = projection_app.rows[1].key
	projection_app.has_selected = true
	projection_app.rows[0].cpu_percent = 90
	projection_app.rows[1].cpu_percent = 1
	projection_app.process_revision += 1
	process_monitor_prepare_visible(&projection_app)
	dogfood_expect(&state, projection_app.has_selected && process_key_equal(projection_app.selected, projection_app.rows[1].key), "selection follows process identity across live reorder")
	projection_app.filter, _ = strings.clone("beta")
	process_monitor_prepare_visible(&projection_app)
	dogfood_expect(&state, projection_app.has_selected && process_key_equal(projection_app.selected, projection_app.rows[1].key), "selection survives filtering when the process remains in the snapshot")
	if len(projection_app.filter) > 0 { delete(projection_app.filter) }
	projection_app.filter = ""
	for row in projection_app.rows {
		if len(row.identity) > 0 { delete(row.identity) }
		if len(row.name) > 0 { delete(row.name) }
	}
	clear(&projection_app.rows)
	projection_app.process_revision += 1
	process_monitor_prepare_visible(&projection_app)
	dogfood_expect(&state, !projection_app.has_selected, "selection clears deterministically when its process disappears")
	projection_app.unavailable_this_sample = 3
	dogfood_expect(&state, process_monitor_process_summary(&projection_app) == "Processes 0 · 3 unavailable", "summary exposes unavailable process queries")
	layout_app := process_monitor_new()
	layout_rt := alicorn.new_runtime(alicorn.Rect{0, 0, 960, 720})
	defer alicorn.destroy_runtime(&layout_rt)
	defer process_monitor_destroy(&layout_app)
	process_monitor_build(rawptr(&layout_app), &layout_rt, 960, 720, 1)
	root_bottom := layout_rt.viewport.y + layout_rt.viewport.h
	table_body := dogfood_node_by_label(&layout_rt, "process-table-body")
	process_list := dogfood_node_by_label(&layout_rt, "process-list")
	process_scrollbar := dogfood_node_by_label(&layout_rt, "process-scrollbar")
	dogfood_expect(&state,
		table_body != nil && process_list != nil && process_scrollbar != nil &&
			table_body.bounds.y+table_body.bounds.h <= root_bottom &&
			process_list.bounds.y+process_list.bounds.h <= root_bottom &&
			process_scrollbar.bounds.y+process_scrollbar.bounds.h <= root_bottom,
		"monitor table body, virtual list, and scrollbar must stay inside the window")
	app := process_monitor_new()
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 360})
	// The callback adopts text allocated by the runtime, so destroy the app
	// before destroying the runtime that owns those allocations.
	defer alicorn.destroy_runtime(&rt)
	defer process_monitor_destroy(&app)

	process_monitor_build(rawptr(&app), &rt, 640, 360, 1)
	field := app.filter_node
	dogfood_expect(&state, field != 0 && rt.focused == field, "monitor filter must be the initially focused public text field")
	if field != 0 {
		sort_cpu := dogfood_node_by_label(&rt, "Sort CPU")
		dogfood_expect(&state, sort_cpu != nil && alicorn.focus_traverse(&rt, .Next) == sort_cpu.id, "monitor Tab order must leave the filter at Sort CPU")
		if sort_cpu != nil {
			dogfood_expect(&state, alicorn.activate_focused(&rt), "monitor focused sort button must accept keyboard activation")
			process_monitor_build(rawptr(&app), &rt, 640, 360, 1)
			dogfood_expect(&state, app.sort == .CPU && !app.sort_descending, "monitor keyboard activation must reach the sort command")
		}
		change := alicorn.process_text_input(&rt, field, "alpha beta")
		process_monitor_on_text_change(rawptr(&app), &rt, change)
		if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
		dogfood_expect_filter(&state, &app, "alpha beta", "external text callback must adopt committed insertion")

		_ = alicorn.set_text_caret(&rt, field, len(app.filter))
		change = alicorn.process_text_edit(&rt, field, alicorn.Text_Edit{.Backspace, ""})
		process_monitor_on_text_change(rawptr(&app), &rt, change)
		if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
		dogfood_expect(&state, change.changed, "backspace at the end must produce a changed Text_Change")
		dogfood_expect_filter(&state, &app, "alpha bet", "external text callback must adopt Backspace")

		_ = alicorn.set_text_caret(&rt, field, 0)
		change = alicorn.process_text_edit(&rt, field, alicorn.Text_Edit{.Delete, ""})
		process_monitor_on_text_change(rawptr(&app), &rt, change)
		if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
		dogfood_expect(&state, change.changed, "delete at the start must produce a changed Text_Change")
		dogfood_expect_filter(&state, &app, "lpha bet", "external text callback must adopt Delete")

		_ = alicorn.set_text_selection(&rt, field, 0, 4)
		change = alicorn.process_text_edit(&rt, field, alicorn.Text_Edit{.Insert, "proc"})
		process_monitor_on_text_change(rawptr(&app), &rt, change)
		if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
		dogfood_expect_filter(&state, &app, "proc bet", "external text callback must adopt replacement of a public selection")

		_ = alicorn.set_text_caret(&rt, field, 0)
		change = alicorn.process_text_edit(&rt, field, alicorn.Text_Edit{.Backspace, ""})
		process_monitor_on_text_change(rawptr(&app), &rt, change)
		if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
		dogfood_expect(&state, !change.changed, "backspace at the start must report a no-op")
		dogfood_expect_filter(&state, &app, "proc bet", "external callback must release a no-op change without changing app state")
	}

	if state.failures == 0 {
		fmt.println("Alicorn monitor dogfood tests: PASS")
		return true
	}
	fmt.println("Alicorn monitor dogfood tests: FAILURES", state.failures)
	return false
}
