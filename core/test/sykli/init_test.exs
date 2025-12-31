defmodule Sykli.InitTest do
  use ExUnit.Case, async: true

  alias Sykli.Init

  @moduletag :tmp_dir

  describe "detect_language/1" do
    test "detects Go from go.mod", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "go.mod"), "module example.com/foo")

      assert Init.detect_language(tmp_dir) == {:ok, :go}
    end

    test "detects Rust from Cargo.toml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]\nname = \"foo\"")

      assert Init.detect_language(tmp_dir) == {:ok, :rust}
    end

    test "detects Elixir from mix.exs", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Foo.MixProject do")

      assert Init.detect_language(tmp_dir) == {:ok, :elixir}
    end

    test "returns error when no marker files found", %{tmp_dir: tmp_dir} do
      assert Init.detect_language(tmp_dir) == {:error, :unknown_project}
    end

    test "returns first match when multiple marker files present", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "go.mod"), "module foo")
      File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]")

      # Order depends on map iteration - just verify we get a valid result
      assert {:ok, lang} = Init.detect_language(tmp_dir)
      assert lang in [:go, :rust, :elixir]
    end
  end

  describe "generate/2" do
    test "generates Go sykli file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "go.mod"), "module example.com/myapp")

      assert :ok = Init.generate(tmp_dir, :go)

      sykli_path = Path.join(tmp_dir, "sykli.go")
      assert File.exists?(sykli_path)

      content = File.read!(sykli_path)
      assert content =~ "package main"
      assert content =~ "sykli.New()"
      assert content =~ "go test"
      assert content =~ "s.Emit()"
    end

    test "generates Rust sykli file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]\nname = \"myapp\"")

      assert :ok = Init.generate(tmp_dir, :rust)

      sykli_path = Path.join(tmp_dir, "sykli.rs")
      assert File.exists?(sykli_path)

      content = File.read!(sykli_path)
      assert content =~ "use sykli::Pipeline"
      assert content =~ "cargo test"
      assert content =~ "p.emit()"
    end

    test "generates Elixir sykli file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MyApp.MixProject do")

      assert :ok = Init.generate(tmp_dir, :elixir)

      sykli_path = Path.join(tmp_dir, "sykli.exs")
      assert File.exists?(sykli_path)

      content = File.read!(sykli_path)
      assert content =~ "Sykli.pipeline"
      assert content =~ "mix test"
    end

    test "returns error if sykli file already exists", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sykli.go"), "existing content")

      assert {:error, :already_exists} = Init.generate(tmp_dir, :go)
    end

    test "overwrites with force option", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sykli.go"), "old content")

      assert :ok = Init.generate(tmp_dir, :go, force: true)

      content = File.read!(Path.join(tmp_dir, "sykli.go"))
      assert content =~ "sykli.New()"
    end
  end

  describe "init/2" do
    test "auto-detects and generates", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "go.mod"), "module example.com/foo")

      assert {:ok, :go} = Init.init(tmp_dir)
      assert File.exists?(Path.join(tmp_dir, "sykli.go"))
    end

    test "respects explicit language override", %{tmp_dir: tmp_dir} do
      # No marker files, but user specifies rust
      assert {:ok, :rust} = Init.init(tmp_dir, language: :rust)
      assert File.exists?(Path.join(tmp_dir, "sykli.rs"))
    end

    test "returns error when no language detected and none specified", %{tmp_dir: tmp_dir} do
      assert {:error, :unknown_project} = Init.init(tmp_dir)
    end
  end

  describe "project_name/1" do
    test "extracts name from go.mod", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "go.mod"), "module github.com/user/myproject\n")

      assert Init.project_name(tmp_dir, :go) == "myproject"
    end

    test "extracts name from Cargo.toml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]\nname = \"my-rust-app\"\n")

      assert Init.project_name(tmp_dir, :rust) == "my-rust-app"
    end

    test "extracts name from mix.exs", %{tmp_dir: tmp_dir} do
      content = """
      defmodule MyElixirApp.MixProject do
        use Mix.Project

        def project do
          [app: :my_elixir_app]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "mix.exs"), content)

      assert Init.project_name(tmp_dir, :elixir) == "my_elixir_app"
    end

    test "returns directory name as fallback", %{tmp_dir: tmp_dir} do
      assert Init.project_name(tmp_dir, :go) == Path.basename(tmp_dir)
    end
  end
end
