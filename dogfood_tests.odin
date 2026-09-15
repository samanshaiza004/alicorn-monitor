package main

import "core:fmt"
import alicorn "vendor/alicorn/runtime"

Dogfood_Test_State :: struct {
	failures: int,
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

// process_monitor_run_dogfood_tests exercises the monitor's external side of
// the public text-editing boundary. The callback clones the borrowed runtime
// text, while this direct test call releases each returned product explicitly
// as the native host would after the callback returns.
process_monitor_run_dogfood_tests :: proc() -> bool {
	state := Dogfood_Test_State{}
	scroll_app := process_monitor_new()
	defer process_monitor_destroy(&scroll_app)
	scroll_app.list_viewport_height = 240
	scroll_app.row_height = 24
	for i := 0; i < 100; i += 1 { append(&scroll_app.visible, i) }
	process_monitor_scroll(&scroll_app, alicorn.Scroll_Event{delta_y=-0.5})
	dogfood_expect(&state, scroll_app.scroll_y == 12, "precise scroll deltas preserve fractional pixel movement")
	process_monitor_scroll(&scroll_app, alicorn.Scroll_Event{ticks_y=-1})
	dogfood_expect(&state, scroll_app.scroll_y == 84, "wheel ticks use a native three-line scroll step")
	process_monitor_scroll(&scroll_app, alicorn.Scroll_Event{ticks_y=-100})
	dogfood_expect(&state, scroll_app.scroll_y == 2160, "scrolling clamps to the actual content and viewport extent")
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
