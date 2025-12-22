// Test all Go SDK features
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	// Basic task
	p.Task("echo").Run("echo 'Hello from Go SDK'")

	// Task with inputs (caching)
	p.Task("cached").
		Run("echo 'This should cache'").
		Inputs("sykli.go")

	// Task with dependency
	p.Task("dependent").
		Run("echo 'Runs after echo'").
		After("echo")

	// Task with retry (will succeed on first try)
	p.Task("retry_test").
		Run("echo 'Testing retry'").
		Retry(2)

	// Task with timeout
	p.Task("timeout_test").
		Run("echo 'Quick task'").
		Timeout(30)

	// Task with condition (should run - we're not in CI)
	p.Task("conditional").
		Run("echo 'Condition: not CI'").
		When("ci != true")

	// Task that depends on multiple
	p.Task("final").
		Run("echo 'All features work!'").
		After("cached", "dependent", "retry_test", "timeout_test", "conditional")

	p.Emit()
}
