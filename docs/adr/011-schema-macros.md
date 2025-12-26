# ADR-011: Schema Macros — One DSL, All SDKs

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

Sykli has SDKs in Go, Rust, and Elixir. Maintaining type parity across languages is painful:

- Add a field → update 3 files
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

### Custom Codegen (No External Dependencies)

We own the codegen - simple Elixir modules that emit idiomatic code for each language.

```elixir
# core/lib/sykli/schema/codegen/go.ex

defmodule Sykli.Schema.Codegen.Go do
  @moduledoc "Generate Go structs from schema"

  def generate(types) do
    header = """
    // Code generated by sykli schema. DO NOT EDIT.
    package sykli
    """

    structs = Enum.map(types, &generate_type/1)

    [header | structs] |> Enum.join("\n\n")
  end

  defp generate_type(%{name: name, kind: :struct, fields: fields, doc: doc}) do
    doc_comment = if doc, do: "// #{doc}\n", else: ""
    field_lines = Enum.map(fields, &generate_field/1)

    """
    #{doc_comment}type #{name} struct {
    #{Enum.join(field_lines, "\n")}
    }
    """
  end

  defp generate_field(%{name: name, type: type, opts: opts}) do
    go_type = elixir_to_go_type(type, opts)
    json_tag = json_tag(name, opts)
    doc = if opts[:doc], do: " // #{opts[:doc]}", else: ""

    "    #{pascal_case(name)} #{go_type} `json:\"#{json_tag}\"`#{doc}"
  end

  defp elixir_to_go_type(:string, _), do: "string"
  defp elixir_to_go_type(:integer, _), do: "int"
  defp elixir_to_go_type(:boolean, _), do: "bool"
  defp elixir_to_go_type({:list, inner}, opts), do: "[]#{elixir_to_go_type(inner, opts)}"
  defp elixir_to_go_type({:map, _, v}, opts), do: "map[string]#{elixir_to_go_type(v, opts)}"
  defp elixir_to_go_type(module, _) when is_atom(module), do: to_string(module)

  defp json_tag(name, opts) do
    base = Atom.to_string(name)
    if opts[:required], do: base, else: "#{base},omitempty"
  end

  defp pascal_case(atom) do
    atom |> Atom.to_string() |> Macro.camelize()
  end
end
```

```elixir
# core/lib/sykli/schema/codegen/rust.ex

defmodule Sykli.Schema.Codegen.Rust do
  @moduledoc "Generate Rust structs from schema"

  def generate(types) do
    header = """
    // Code generated by sykli schema. DO NOT EDIT.
    use serde::{Deserialize, Serialize};
    """

    structs = Enum.map(types, &generate_type/1)

    [header | structs] |> Enum.join("\n\n")
  end

  defp generate_type(%{name: name, kind: :struct, fields: fields, doc: doc}) do
    doc_comment = if doc, do: "/// #{doc}\n", else: ""

    """
    #{doc_comment}#[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct #{name} {
    #{Enum.map_join(fields, "\n", &generate_field/1)}
    }
    """
  end

  defp generate_field(%{name: name, type: type, opts: opts}) do
    rust_type = elixir_to_rust_type(type, opts)
    serde_attr = if opts[:required], do: "", else: "    #[serde(skip_serializing_if = \"Option::is_none\")]\n"
    doc = if opts[:doc], do: "    /// #{opts[:doc]}\n", else: ""

    "#{doc}#{serde_attr}    pub #{name}: #{rust_type},"
  end

  defp elixir_to_rust_type(:string, %{required: true}), do: "String"
  defp elixir_to_rust_type(:string, _), do: "Option<String>"
  defp elixir_to_rust_type(:integer, %{required: true}), do: "i32"
  defp elixir_to_rust_type(:integer, _), do: "Option<i32>"
  defp elixir_to_rust_type(:boolean, _), do: "bool"
  defp elixir_to_rust_type({:list, inner}, opts), do: "Vec<#{elixir_to_rust_type(inner, Map.put(opts, :required, true))}>"
  defp elixir_to_rust_type(module, _) when is_atom(module), do: to_string(module)
end
```

### Mix Task

```elixir
# core/lib/mix/tasks/sykli.gen.sdk.ex

defmodule Mix.Tasks.Sykli.Gen.Sdk do
  use Mix.Task

  @shortdoc "Generate SDK types from Elixir schema"

  alias Sykli.Schema.Codegen

  def run(_args) do
    Mix.Task.run("compile")

    types = Sykli.Schema.Types.__schema__()

    # Generate each SDK using our own codegen
    generators = [
      {"../sdk/go/types_gen.go", &Codegen.Go.generate/1},
      {"../sdk/rust/src/types_gen.rs", &Codegen.Rust.generate/1}
    ]

    for {path, generator} <- generators do
      code = generator.(types)
      File.write!(path, code)
      Mix.shell().info("✓ Generated #{path}")
    end

    Mix.shell().info("\nDone. Schema → #{length(generators)} SDKs")
  end
end
```

### Workflow

```bash
$ cd core
$ mix sykli.gen.sdk

✓ Generated ../sdk/go/types_gen.go
✓ Generated ../sdk/rust/src/types_gen.rs

Done. Schema → 2 SDKs
```

### Why Custom Codegen

- **No external dependencies** - just Elixir
- **Idiomatic output** - we control the style
- **Easy to extend** - add a language by adding a module
- **Simple** - our schema is small, don't need a framework

---

## Generated Output Examples

### Go

```go
// Code generated by sykli schema. DO NOT EDIT.
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
// Code generated by sykli schema. DO NOT EDIT.
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

- TypeScript codegen module
- Validation code generation
- SDK documentation generation
- Breaking change detection
- Version compatibility checks
