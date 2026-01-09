# ADR 019: Schema-Driven SDK Code Generation

## Status
Proposed

## Context

Maintaining 4+ SDKs (Go, Rust, Elixir, TypeScript) manually is unsustainable. Each new feature requires:
- 4 implementations
- 4 sets of tests
- 4 documentation updates
- Drift detection across all of them

**The Dagger approach**: A central schema generates thin SDK wrappers.

**The Sykli advantage**: We're already on BEAM with Elixir's metaprogramming.

## Decision

Build a **Schema-Driven Code Generation Engine** where:

1. **Single Source of Truth**: `sdk/schema/` defines all types and methods
2. **EEx Templates**: One per language, generates idiomatic code
3. **Generator**: `mix sdk.generate` produces all SDKs

### The Schema Registry

```elixir
# sdk/schema/registry.ex
defmodule Sykli.SDK.Schema do
  @moduledoc "Central definition of all SDK types and methods"

  def types do
    [
      pipeline(),
      task(),
      directory(),
      cache(),
      template(),
      condition()
    ]
  end

  defp pipeline do
    %{
      name: :Pipeline,
      doc: "A CI pipeline with tasks and resources.",
      constructor: %{
        name: :new,
        doc: "Creates a new pipeline.",
        args: [],
        returns: :Pipeline
      },
      methods: [
        %{
          name: :task,
          doc: "Creates a new task with the given name.",
          args: [%{name: :name, type: :string, doc: "Task name"}],
          returns: :Task
        },
        %{
          name: :dir,
          doc: "Creates a directory resource for mounting.",
          args: [%{name: :path, type: :string, doc: "Directory path"}],
          returns: :Directory
        },
        %{
          name: :cache,
          doc: "Creates a named cache volume.",
          args: [%{name: :name, type: :string, doc: "Cache name"}],
          returns: :Cache
        },
        %{
          name: :template,
          doc: "Creates a reusable task template.",
          args: [],
          returns: :Template
        },
        %{
          name: :emit,
          doc: "Outputs the pipeline as JSON and exits.",
          args: [],
          returns: :void
        }
      ]
    }
  end

  defp task do
    %{
      name: :Task,
      doc: "A single task in the pipeline.",
      fluent: true,  # All methods return self for chaining
      methods: [
        %{
          name: :run,
          doc: "Sets the command to execute.",
          args: [%{name: :command, type: :string}],
          required: true  # Task must have a command
        },
        %{
          name: :container,
          doc: "Sets the Docker image to run in.",
          args: [%{name: :image, type: :string}]
        },
        %{
          name: :workdir,
          doc: "Sets the working directory inside the container.",
          args: [%{name: :path, type: :string}]
        },
        %{
          name: :mount,
          doc: "Mounts a directory into the container.",
          args: [
            %{name: :resource, type: :Directory},
            %{name: :path, type: :string}
          ]
        },
        %{
          name: :mount_cache,
          doc: "Mounts a cache volume into the container.",
          args: [
            %{name: :cache, type: :Cache},
            %{name: :path, type: :string}
          ],
          # Language-specific naming
          aliases: %{
            go: :MountCache,
            rust: :mount_cache,
            ts: :mountCache,
            elixir: :mount_cache
          }
        },
        %{
          name: :after,
          doc: "Declares dependencies on other tasks.",
          args: [%{name: :tasks, type: {:list, :string}}],
          variadic: true  # Can be called as .after("a", "b") or .after(["a", "b"])
        },
        %{
          name: :requires,
          doc: "Declares required node labels for placement.",
          args: [%{name: :labels, type: {:list, :string}}],
          variadic: true
        },
        %{
          name: :env,
          doc: "Sets an environment variable.",
          args: [
            %{name: :key, type: :string},
            %{name: :value, type: :string}
          ]
        },
        %{
          name: :timeout,
          doc: "Sets the task timeout.",
          args: [%{name: :seconds, type: :int}]
        },
        %{
          name: :retry,
          doc: "Sets the number of retries on failure.",
          args: [%{name: :count, type: :int}]
        },
        %{
          name: :when,
          doc: "Sets a condition for task execution.",
          args: [%{name: :condition, type: {:union, [:string, :Condition]}}],
          aliases: %{go: :When, rust: :when_cond, ts: :when, elixir: :when_cond}
        },
        %{
          name: :inputs,
          doc: "Sets input file patterns for caching.",
          args: [%{name: :patterns, type: {:list, :string}}],
          variadic: true
        },
        %{
          name: :outputs,
          doc: "Declares output artifacts.",
          args: [%{name: :outputs, type: {:map, :string, :string}}]
        },
        %{
          name: :secret,
          doc: "Declares a required secret.",
          args: [%{name: :name, type: :string}]
        },
        %{
          name: :from,
          doc: "Applies a template's configuration.",
          args: [%{name: :template, type: :Template}]
        }
      ]
    }
  end

  defp directory do
    %{
      name: :Directory,
      doc: "A directory resource that can be mounted.",
      methods: [
        %{
          name: :glob,
          doc: "Filters to files matching patterns.",
          args: [%{name: :patterns, type: {:list, :string}}],
          variadic: true
        }
      ]
    }
  end

  defp cache do
    %{
      name: :Cache,
      doc: "A named cache volume for persistent storage."
    }
  end

  defp template do
    %{
      name: :Template,
      doc: "Reusable task configuration.",
      fluent: true,
      methods: [
        # Same as Task, minus :run and :after
        %{name: :container, doc: "Sets the default container.", args: [%{name: :image, type: :string}]},
        %{name: :workdir, doc: "Sets the default workdir.", args: [%{name: :path, type: :string}]},
        %{name: :mount, doc: "Adds a mount.", args: [%{name: :resource, type: :Directory}, %{name: :path, type: :string}]},
        %{name: :mount_cache, doc: "Adds a cache mount.", args: [%{name: :cache, type: :Cache}, %{name: :path, type: :string}]},
        %{name: :env, doc: "Sets an env var.", args: [%{name: :key, type: :string}, %{name: :value, type: :string}]}
      ]
    }
  end

  defp condition do
    %{
      name: :Condition,
      doc: "A condition for task execution.",
      constructors: [
        %{name: :branch, doc: "Matches git branch.", args: [%{name: :pattern, type: :string}]},
        %{name: :env, doc: "Checks environment variable.", args: [%{name: :name, type: :string}]},
        %{name: :and, doc: "Logical AND.", args: [%{name: :conditions, type: {:list, :Condition}}]},
        %{name: :or, doc: "Logical OR.", args: [%{name: :conditions, type: {:list, :Condition}}]}
      ],
      methods: [
        %{name: :equals, doc: "Checks equality.", args: [%{name: :value, type: :string}]},
        %{name: :starts_with, doc: "Prefix match.", args: [%{name: :prefix, type: :string}], aliases: %{go: :StartsWith, ts: :startsWith}},
        %{name: :contains, doc: "Substring match.", args: [%{name: :substring, type: :string}]}
      ]
    }
  end
end
```

### Language Templates

**Go Template** (`sdk/templates/go.eex`):

```eex
// Code generated by Sykli SDK Generator. DO NOT EDIT.
// Source: sdk/schema/registry.ex

package sykli

import (
    "encoding/json"
    "fmt"
    "io"
    "os"
)

<%= for type <- @types do %>
// <%= type.doc %>
type <%= type.name %> struct {
    <%= for field <- type.fields do %>
    <%= field.name %> <%= go_type(field.type) %> `json:"<%= json_name(field.name) %>,omitempty"`
    <% end %>
}

<%= for method <- type.methods do %>
// <%= method.doc %>
func (<%= receiver(type) %> *<%= type.name %>) <%= go_method_name(method) %>(<%= go_args(method.args) %>) *<%= type.name %> {
    <%= go_body(type, method) %>
    return <%= receiver(type) %>
}
<% end %>
<% end %>
```

**TypeScript Template** (`sdk/templates/typescript.eex`):

```eex
// Code generated by Sykli SDK Generator. DO NOT EDIT.
// Source: sdk/schema/registry.ex

<%= for type <- @types do %>
/**
 * <%= type.doc %>
 */
export class <%= type.name %> {
    <%= for field <- type.fields do %>
    private <%= ts_field_name(field.name) %>: <%= ts_type(field.type) %>;
    <% end %>

    <%= for method <- type.methods do %>
    /**
     * <%= method.doc %>
     <%= for arg <- method.args do %>
     * @param <%= arg.name %> - <%= arg.doc %>
     <% end %>
     */
    <%= ts_method_name(method) %>(<%= ts_args(method.args) %>): this {
        <%= ts_body(type, method) %>
        return this;
    }
    <% end %>
}
<% end %>
```

**Rust Template** (`sdk/templates/rust.eex`):

```eex
// Code generated by Sykli SDK Generator. DO NOT EDIT.
// Source: sdk/schema/registry.ex

use serde::Serialize;
use std::collections::HashMap;

<%= for type <- @types do %>
/// <%= type.doc %>
#[derive(Clone, Default)]
pub struct <%= type.name %> {
    <%= for field <- type.fields do %>
    <%= rust_field_name(field.name) %>: <%= rust_type(field.type) %>,
    <% end %>
}

impl <%= type.name %> {
    <%= for method <- type.methods do %>
    /// <%= method.doc %>
    #[must_use]
    pub fn <%= rust_method_name(method) %>(mut self, <%= rust_args(method.args) %>) -> Self {
        <%= rust_body(type, method) %>
        self
    }
    <% end %>
}
<% end %>
```

### The Generator

```elixir
# sdk/lib/generator.ex
defmodule Sykli.SDK.Generator do
  @moduledoc "Generates SDK code from schema"

  alias Sykli.SDK.Schema

  def generate_all do
    types = Schema.types()

    generate(:go, types, "sdk/go/sykli_generated.go")
    generate(:rust, types, "sdk/rust/src/generated.rs")
    generate(:typescript, types, "sdk/typescript/src/generated.ts")
    generate(:elixir, types, "sdk/elixir/lib/sykli/generated.ex")

    IO.puts("Generated SDKs for: go, rust, typescript, elixir")
  end

  defp generate(lang, types, output_path) do
    template = read_template(lang)
    helpers = language_helpers(lang)

    content = EEx.eval_string(template, [types: types] ++ helpers)

    File.write!(output_path, content)
    IO.puts("  → #{output_path}")
  end

  defp read_template(lang) do
    File.read!("sdk/templates/#{lang}.eex")
  end

  defp language_helpers(:go) do
    [
      go_type: &go_type/1,
      go_method_name: &go_method_name/1,
      go_args: &go_args/1,
      # ...
    ]
  end

  # Type mappings
  defp go_type(:string), do: "string"
  defp go_type(:int), do: "int"
  defp go_type(:bool), do: "bool"
  defp go_type({:list, t}), do: "[]#{go_type(t)}"
  defp go_type({:map, k, v}), do: "map[#{go_type(k)}]#{go_type(v)}"
  defp go_type(custom) when is_atom(custom), do: "*#{custom}"

  defp ts_type(:string), do: "string"
  defp ts_type(:int), do: "number"
  defp ts_type(:bool), do: "boolean"
  defp ts_type({:list, t}), do: "#{ts_type(t)}[]"
  defp ts_type({:map, k, v}), do: "Record<#{ts_type(k)}, #{ts_type(v)}>"
  defp ts_type(custom) when is_atom(custom), do: to_string(custom)

  defp rust_type(:string), do: "String"
  defp rust_type(:int), do: "u32"
  defp rust_type(:bool), do: "bool"
  defp rust_type({:list, t}), do: "Vec<#{rust_type(t)}>"
  defp rust_type({:map, k, v}), do: "HashMap<#{rust_type(k)}, #{rust_type(v)}>"
  defp rust_type(custom) when is_atom(custom), do: to_string(custom)
end
```

### Usage

```bash
# Generate all SDKs
$ mix sdk.generate

Generating SDKs from schema...
  → sdk/go/sykli_generated.go
  → sdk/rust/src/generated.rs
  → sdk/typescript/src/generated.ts
  → sdk/elixir/lib/sykli/generated.ex
Generated SDKs for: go, rust, typescript, elixir

# Verify consistency
$ mix sdk.verify
Checking SDK parity...
  ✓ All 4 SDKs have 47 methods
  ✓ All methods documented
  ✓ All types match JSON schema
```

### What Gets Generated vs Hand-Written

| Generated | Hand-Written |
|-----------|--------------|
| Type definitions | Language-specific optimizations |
| Fluent builder methods | Preset helpers (Go().Test()) |
| JSON serialization | Error messages |
| Doc comments | Examples |
| Validation stubs | Integration tests |

The generated code is the **80%**. The hand-written code is the **20%** that makes each SDK feel native.

## Consequences

### Positive

- **One change, all SDKs**: Add `retry_delay` once, regenerate
- **Guaranteed parity**: Impossible for SDKs to drift
- **Self-documenting**: Docs come from schema
- **Type-safe templates**: Elixir validates before generation

### Negative

- **Initial investment**: Building the generator takes time
- **Template complexity**: EEx templates get hairy for edge cases
- **Debugging indirection**: Errors point to generated code, not schema

### Neutral

- Generated code is committed (not runtime generated)
- Hand-written code imports/extends generated code

## Implementation Plan

1. **Week 1**: Schema design, basic types (Pipeline, Task)
2. **Week 2**: Go template, verify output matches current SDK
3. **Week 3**: TypeScript template, new SDK from scratch
4. **Week 4**: Rust template, migrate existing SDK
5. **Week 5**: Elixir template, CI integration

## Alternatives Considered

### 1. Protobuf + gRPC
Like Dagger's GraphQL approach. Rejected because:
- Heavy runtime dependency
- Overkill for "emit JSON" use case
- Would require rewriting core

### 2. UniFFI (Rust core + FFI bindings)
Mozilla's approach. Rejected because:
- Requires shipping native binaries
- Complex cross-compilation
- Elixir core is already working

### 3. Manual maintenance
Current approach. Rejected because:
- Doesn't scale past 3 SDKs
- Drift is inevitable
- New features take 4x effort

## Related ADRs

- [ADR-005](./005-sdk-api.md) - Original SDK API design
- [ADR-018](./018-typescript-sdk.md) - TypeScript SDK requirements
