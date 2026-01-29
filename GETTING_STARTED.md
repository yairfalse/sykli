# Getting Started with Sykli

Get up and running with Sykli in under 5 minutes.

## Prerequisites

- **Elixir 1.15+** (only if building from source)
- **Docker** (optional, for container tasks)
- One of: Go 1.21+, Rust 1.70+, Node.js 18+, or Elixir 1.15+

## Installation

### Option 1: Install Script (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash
```

### Option 2: Download Binary

Download from [GitHub Releases](https://github.com/yairfalse/sykli/releases/latest) and add to your PATH.

### Option 3: Build from Source

```bash
git clone https://github.com/yairfalse/sykli.git
cd sykli/core
mix deps.get
mix escript.build
sudo mv sykli /usr/local/bin/
```

## Your First Pipeline

### 1. Install the SDK

Pick your language:

```bash
# Go
go get github.com/yairfalse/sykli/sdk/go@latest

# Rust
cargo add sykli

# TypeScript
npm install sykli

# Elixir - add to mix.exs: {:sykli_sdk, "~> 0.3.0"}
```

### 2. Create a Pipeline File

**Go** (`sykli.go`):
```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("hello").Run("echo 'Hello from Sykli!'")
    s.Task("goodbye").Run("echo 'Goodbye!'").After("hello")
    s.Emit()
}
```

**TypeScript** (`sykli.ts`):
```typescript
import { Pipeline } from 'sykli';

const p = new Pipeline();
p.task('hello').run("echo 'Hello from Sykli!'");
p.task('goodbye').run("echo 'Goodbye!'").after('hello');
p.emit();
```

### 3. Run It

```bash
sykli
```

You should see:

```
-- Level with 1 task(s) --
[1/2] hello
Hello from Sykli!

-- Level with 1 task(s) --
[2/2] goodbye
Goodbye!

hello -> goodbye

2 passed in 0.1s
```

## Next Steps

- **[README](README.md)** - Full documentation, all SDK examples, CLI reference
- **[docs/adr/](docs/adr/)** - Architecture Decision Records
- **[Examples](examples/)** - Real-world pipeline examples

## Quick Tips

- Add `.Inputs("**/*.go")` to enable caching
- Add `.After("task1", "task2")` for dependencies
- Run `sykli graph` to visualize your pipeline
- Run `sykli delta` to only run tasks affected by git changes
