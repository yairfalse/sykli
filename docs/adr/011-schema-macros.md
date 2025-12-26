# ADR-011: Schema Macros — One DSL, All SDKs

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

Sykli has SDKs in Go, Rust, TypeScript, and Elixir. Maintaining type parity across four languages is painful:

- Add a field → update 4 files
- Types drift over time
- Validation logic duplicated
- Documentation diverges

We need a single source of truth.

---

## Decision

**Use Elixir macros to define types once, generate all SDKs.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    SCHEMA AS ABSTRACTION                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Same pattern as Target:                                       │
│                                                                 │
│   TARGET:  Define WHAT → inject WHERE (K8s, Local, Lambda)     │
│   SCHEMA:  Define WHAT → generate WHERE (Go, Rust, TS, Elixir) │
│                                                                 │
│   Abstraction is the product.                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## The DSL

### Type Definitions

```elixir
# core/lib/sykli/schema/types.ex

defmodule Sykli.Schema.Types do
  use Sykli.Schema

  @moduledoc "Sykli type definitions — source of truth for all SDKs"

  deftype Task do
    @doc "A unit of work in a pipeline"

    field :name, :string,
      required: true,
      doc: "Unique task identifier"

    field :command, :string,
      doc: "Shell command to execute"

    field :container, :string,
      doc: "Container image (e.g., 'golang:1.21')"

    field :timeout, :integer,
      default: 300,
      min: 0,
      doc: "Timeout in seconds"

    field :depends_on, {:list, :string},
      doc: "Task dependencies"

    field :condition, Condition,
      doc: "When to run this task"

    field :k8s, K8sOptions,
      doc: "Kubernetes-specific options"
  end

  deftype Condition, :variant do
    @doc "Conditional execution rules"

    variant :branch, :string,
      doc: "Run on matching branch (glob pattern)"

    variant :tag, :string,
      doc: "Run on matching tag (glob pattern)"

    variant :and, {:list, Condition},
      doc: "All conditions must match"

    variant :or, {:list, Condition},
      doc: "Any condition must match"

    variant :not, Condition,
      doc: "Invert condition"

    variant :always, :boolean,
      doc: "Always run (default: true)"
  end

  deftype K8sOptions do
    @doc "Kubernetes-specific configuration"

    field :namespace, :string

    field :resources, K8sResources

    field :gpu, :integer,
      min: 0,
      doc: "NVIDIA GPU count"

    field :tolerations, {:list, K8sToleration}

    field :node_selector, {:map, :string, :string},
      doc: "Node label selector"

    field :service_account, :string,
      doc: "ServiceAccount name"
  end

  deftype K8sResources do
    @doc "CPU and memory resources"

    field :cpu, :string,
      pattern: ~r/^[0-9]+(\.[0-9]+)?m?$/,
      doc: "CPU (e.g., '500m', '2')"

    field :memory, :string,
      pattern: ~r/^[0-9]+(Ki|Mi|Gi|Ti)$/,
      doc: "Memory (e.g., '512Mi', '4Gi')"

    field :request_cpu, :string
    field :request_memory, :string
    field :limit_cpu, :string
    field :limit_memory, :string
  end

  deftype K8sToleration do
    field :key, :string, required: true
    field :operator, {:enum, [:Exists, :Equal]}, default: :Equal
    field :value, :string
    field :effect, {:enum, [:NoSchedule, :PreferNoSchedule, :NoExecute]}
  end

  deftype SecretRef, :variant do
    @doc "Reference to a secret value"

    variant :from_env, :string,
      doc: "Environment variable name"

    variant :from_vault, :string,
      doc: "Vault path (path#field)"

    variant :from_file, :string,
      doc: "File path"

    variant :from_k8s, :string,
      doc: "K8s secret (namespace/name#key)"
  end
end
```

---

## Macro Implementation

### Core DSL

```elixir
# core/lib/sykli/schema.ex

defmodule Sykli.Schema do
  @moduledoc "DSL for defining Sykli types"

  defmacro __using__(_opts) do
    quote do
      import Sykli.Schema, only: [deftype: 2, deftype: 3, field: 2, field: 3, variant: 2, variant: 3]
      Module.register_attribute(__MODULE__, :__types__, accumulate: true)
      @before_compile Sykli.Schema
    end
  end

  defmacro deftype(name, do: block) do
    deftype_impl(name, :struct, block)
  end

  defmacro deftype(name, :variant, do: block) do
    deftype_impl(name, :variant, block)
  end

  defp deftype_impl(name, kind, block) do
    quote do
      @__current_type__ %{name: unquote(name), kind: unquote(kind), doc: nil, fields: [], variants: []}

      unquote(block)

      @__types__ @__current_type__

      # Generate Elixir struct for :struct types
      if unquote(kind) == :struct do
        defstruct Enum.map(@__current_type__.fields, fn f ->
          {f.name, f.opts[:default]}
        end)
      end
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @__current_type__ Map.update!(@__current_type__, :fields, fn fields ->
        [%{name: unquote(name), type: unquote(Macro.escape(type)), opts: unquote(opts)} | fields]
      end)
    end
  end

  defmacro variant(name, type, opts \\ []) do
    quote do
      @__current_type__ Map.update!(@__current_type__, :variants, fn variants ->
        [%{name: unquote(name), type: unquote(Macro.escape(type)), opts: unquote(opts)} | variants]
      end)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __schema__ do
        @__types__
        |> Enum.map(fn t ->
          %{t | fields: Enum.reverse(t.fields), variants: Enum.reverse(t.variants)}
        end)
        |> Enum.reverse()
      end

      def to_json_schema do
        Sykli.Schema.JSONSchema.generate(__schema__())
      end

      def validate(type, data) do
        Sykli.Schema.Validator.validate(__schema__(), type, data)
      end
    end
  end
end
```

### JSON Schema Generator

```elixir
# core/lib/sykli/schema/json_schema.ex

defmodule Sykli.Schema.JSONSchema do
  @moduledoc "Export schema to JSON Schema format"

  def generate(types) do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$id" => "https://sykli.io/schema/v1",
      "definitions" => Map.new(types, &type_to_definition/1)
    }
  end

  defp type_to_definition(%{name: name, kind: :struct, doc: doc, fields: fields}) do
    required = fields
      |> Enum.filter(fn f -> f.opts[:required] end)
      |> Enum.map(fn f -> Atom.to_string(f.name) end)

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Map.new(fields, &field_to_property/1)
    }

    schema = if doc, do: Map.put(schema, "description", doc), else: schema
    schema = if required != [], do: Map.put(schema, "required", required), else: schema

    {Atom.to_string(name), schema}
  end

  defp type_to_definition(%{name: name, kind: :variant, doc: doc, variants: variants}) do
    schema = %{
      "oneOf" => Enum.map(variants, &variant_to_schema/1)
    }

    schema = if doc, do: Map.put(schema, "description", doc), else: schema

    {Atom.to_string(name), schema}
  end

  defp field_to_property(%{name: name, type: type, opts: opts}) do
    schema = type_to_schema(type)
    schema = if d = opts[:doc], do: Map.put(schema, "description", d), else: schema
    schema = if d = opts[:default], do: Map.put(schema, "default", d), else: schema
    schema = if p = opts[:pattern], do: Map.put(schema, "pattern", Regex.source(p)), else: schema
    schema = if m = opts[:min], do: Map.put(schema, "minimum", m), else: schema
    schema = if m = opts[:max], do: Map.put(schema, "maximum", m), else: schema

    {Atom.to_string(name), schema}
  end

  defp variant_to_schema(%{name: name, type: type, opts: opts}) do
    inner = type_to_schema(type)
    inner = if d = opts[:doc], do: Map.put(inner, "description", d), else: inner

    %{
      "type" => "object",
      "required" => [Atom.to_string(name)],
      "properties" => %{Atom.to_string(name) => inner},
      "additionalProperties" => false
    }
  end

  defp type_to_schema(:string), do: %{"type" => "string"}
  defp type_to_schema(:integer), do: %{"type" => "integer"}
  defp type_to_schema(:boolean), do: %{"type" => "boolean"}
  defp type_to_schema(:float), do: %{"type" => "number"}
  defp type_to_schema({:list, inner}), do: %{"type" => "array", "items" => type_to_schema(inner)}
  defp type_to_schema({:map, k, v}), do: %{"type" => "object", "additionalProperties" => type_to_schema(v)}
  defp type_to_schema({:enum, values}), do: %{"type" => "string", "enum" => Enum.map(values, &Atom.to_string/1)}
  defp type_to_schema(module) when is_atom(module), do: %{"$ref" => "#/definitions/#{module}"}
end
```

---

## SDK Generation

### Mix Task

```elixir
# core/lib/mix/tasks/sykli.gen.sdk.ex

defmodule Mix.Tasks.Sykli.Gen.Sdk do
  use Mix.Task

  @shortdoc "Generate SDK types from Elixir schema"

  @targets [
    {:go, "../sdk/go/types_gen.go", ["--package", "sykli"]},
    {:rust, "../sdk/rust/src/types_gen.rs", []},
    {:typescript, "../sdk/ts/src/types.gen.ts", []},
    {:python, "../sdk/python/sykli/types_gen.py", []}
  ]

  def run(_args) do
    Mix.Task.run("compile")

    # Export JSON Schema
    schema = Sykli.Schema.Types.to_json_schema()
    json = Jason.encode!(schema, pretty: true)

    schema_path = "priv/schema.json"
    File.write!(schema_path, json)
    Mix.shell().info("✓ Generated #{schema_path}")

    # Generate each SDK
    for {lang, output, extra_args} <- @targets do
      args = [schema_path, "-o", output, "--lang", to_string(lang)] ++ extra_args

      case System.cmd("quicktype", args, stderr_to_stdout: true) do
        {_, 0} ->
          Mix.shell().info("✓ Generated #{output}")
        {error, _} ->
          Mix.shell().error("✗ Failed to generate #{output}: #{error}")
      end
    end

    Mix.shell().info("\nDone. Schema → #{length(@targets)} SDKs")
  end
end
```

### Workflow

```bash
$ cd core
$ mix sykli.gen.sdk

✓ Generated priv/schema.json
✓ Generated ../sdk/go/types_gen.go
✓ Generated ../sdk/rust/src/types_gen.rs
✓ Generated ../sdk/ts/src/types.gen.ts
✓ Generated ../sdk/python/sykli/types_gen.py

Done. Schema → 4 SDKs
```

---

## Generated Output Examples

### Go

```go
// types_gen.go — DO NOT EDIT
// Generated from Sykli schema

package sykli

type Task struct {
    Name      string      `json:"name"`
    Command   *string     `json:"command,omitempty"`
    Container *string     `json:"container,omitempty"`
    Timeout   int         `json:"timeout,omitempty"`
    DependsOn []string    `json:"depends_on,omitempty"`
    Condition *Condition  `json:"condition,omitempty"`
    K8s       *K8sOptions `json:"k8s,omitempty"`
}

type Condition struct {
    Branch *string      `json:"branch,omitempty"`
    Tag    *string      `json:"tag,omitempty"`
    And    []Condition  `json:"and,omitempty"`
    Or     []Condition  `json:"or,omitempty"`
    Not    *Condition   `json:"not,omitempty"`
    Always *bool        `json:"always,omitempty"`
}

type K8sOptions struct {
    Namespace      *string           `json:"namespace,omitempty"`
    Resources      *K8sResources     `json:"resources,omitempty"`
    GPU            *int              `json:"gpu,omitempty"`
    Tolerations    []K8sToleration   `json:"tolerations,omitempty"`
    NodeSelector   map[string]string `json:"node_selector,omitempty"`
    ServiceAccount *string           `json:"service_account,omitempty"`
}
```

### Rust

```rust
// types_gen.rs — DO NOT EDIT
// Generated from Sykli schema

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    #[serde(default = "default_timeout")]
    pub timeout: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub depends_on: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub condition: Option<Condition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub k8s: Option<K8sOptions>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Condition {
    Branch { branch: String },
    Tag { tag: String },
    And { and: Vec<Condition> },
    Or { or: Vec<Condition> },
    Not { not: Box<Condition> },
    Always { always: bool },
}

fn default_timeout() -> i32 { 300 }
```

### TypeScript

```typescript
// types.gen.ts — DO NOT EDIT
// Generated from Sykli schema

export interface Task {
  name: string;
  command?: string;
  container?: string;
  timeout?: number;
  depends_on?: string[];
  condition?: Condition;
  k8s?: K8sOptions;
}

export type Condition =
  | { branch: string }
  | { tag: string }
  | { and: Condition[] }
  | { or: Condition[] }
  | { not: Condition }
  | { always: boolean };

export interface K8sOptions {
  namespace?: string;
  resources?: K8sResources;
  gpu?: number;
  tolerations?: K8sToleration[];
  node_selector?: Record<string, string>;
  service_account?: string;
}
```

---

## What's Generated vs Hand-Written

```
┌─────────────────────────────────────────────────────────────────┐
│                    GENERATED (70%)                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ✓ Type definitions (structs, interfaces, classes)            │
│   ✓ Field types and optionality                                │
│   ✓ JSON serialization tags                                    │
│   ✓ Default values                                             │
│   ✓ Enum types                                                 │
│   ✓ Variant/union types                                        │
│   ✓ Documentation comments                                     │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    HAND-WRITTEN (30%)                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ✎ Fluent builder API (.Task("name").Run("cmd"))              │
│   ✎ Convenience constructors (Branch("main"))                  │
│   ✎ Language idioms (Result<T>, Option<T>)                     │
│   ✎ Runtime integration                                        │
│   ✎ Validation logic (beyond schema)                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Validation

### Schema-Level

```elixir
# In the macro
field :gpu, :integer, min: 0
field :cpu, :string, pattern: ~r/^[0-9]+m?$/
field :name, :string, required: true
```

Generates validation in each language:

```go
// Go
func (k *K8sOptions) Validate() []error {
    var errs []error
    if k.GPU != nil && *k.GPU < 0 {
        errs = append(errs, errors.New("gpu must be >= 0"))
    }
    return errs
}
```

```rust
// Rust (via validator crate)
#[derive(Validate)]
pub struct K8sOptions {
    #[validate(range(min = 0))]
    pub gpu: Option<i32>,
}
```

---

## CI Integration

```yaml
# .github/workflows/schema.yml
name: Schema Check

on: [push, pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Generate SDKs
        run: |
          cd core
          mix sykli.gen.sdk

      - name: Check for drift
        run: |
          git diff --exit-code sdk/
          if [ $? -ne 0 ]; then
            echo "SDK types are out of sync with schema!"
            echo "Run 'mix sykli.gen.sdk' and commit the changes."
            exit 1
          fi
```

---

## The Philosophy

```
┌─────────────────────────────────────────────────────────────────┐
│                    ABSTRACTION PATTERN                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   SYKLI PATTERN:                                                │
│   ├── Target:   WHAT (task) → WHERE (K8s, Local)               │
│   ├── Runtime:  WHAT (run)  → HOW (Docker, Shell)              │
│   └── Schema:   WHAT (type) → WHERE (Go, Rust, TS)             │
│                                                                 │
│   Define once. Generate everywhere.                             │
│   Abstraction is the product.                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Success Criteria

1. Single source of truth for all types (Elixir macros)
2. `mix sykli.gen.sdk` generates all SDK types
3. CI fails if generated code is out of sync
4. Zero type drift between SDKs
5. Validation rules propagate to all languages
6. Documentation stays in sync

---

## Future Work

- Custom code generation templates (beyond quicktype)
- Validation code generation
- SDK documentation generation
- Breaking change detection
- Version compatibility checks
