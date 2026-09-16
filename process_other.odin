#+build !windows
#+build !darwin

package main

process_monitor_sample :: proc(app: ^Process_Monitor) -> bool {
	// The first dogfood is intentionally Windows-first. Keep the app package
	// buildable on other hosts while the native sampler boundary is expanded.
	return false
}
