defmodule Sykli.CLITest do
  use ExUnit.Case, async: true

  # ─────────────────────────────────────────────────────────────────────────────
  # RUN ARGS PARSING
  # ─────────────────────────────────────────────────────────────────────────────

  describe "parse_run_args/1" do
    test "parses --target=k8s" do
      {path, opts} = Sykli.CLI.parse_run_args(["--target=k8s"])

      assert opts[:target] == :k8s
      assert path == "."
    end

    test "parses --target=local" do
      {path, opts} = Sykli.CLI.parse_run_args(["--target=local"])

      assert opts[:target] == :local
      assert path == "."
    end

    test "defaults target to nil when not specified" do
      {_path, opts} = Sykli.CLI.parse_run_args([])

      assert opts[:target] == nil
    end

    test "parses --allow-dirty" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--allow-dirty"])

      assert opts[:allow_dirty] == true
    end

    test "parses --git-ssh-secret=NAME" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--git-ssh-secret=my-deploy-key"])

      assert opts[:git_ssh_secret] == "my-deploy-key"
    end

    test "parses --git-token-secret=NAME" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--git-token-secret=github-token"])

      assert opts[:git_token_secret] == "github-token"
    end

    test "parses multiple K8s options together" do
      args = [
        "--target=k8s",
        "--allow-dirty",
        "--git-ssh-secret=deploy-key",
        "./my-project"
      ]

      {path, opts} = Sykli.CLI.parse_run_args(args)

      assert path == "./my-project"
      assert opts[:target] == :k8s
      assert opts[:allow_dirty] == true
      assert opts[:git_ssh_secret] == "deploy-key"
    end

    test "existing flags still work (--mesh, --filter)" do
      {path, opts} = Sykli.CLI.parse_run_args(["--mesh", "--filter=test", "./project"])

      assert path == "./project"
      assert opts[:mesh] == true
      assert opts[:filter] == "test"
    end

    test "parses --timeout=10m as 600000ms" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=10m"])

      assert opts[:timeout] == 600_000
    end

    test "parses --timeout=30s as 30000ms" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=30s"])

      assert opts[:timeout] == 30_000
    end

    test "parses --timeout=2h as 7200000ms" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=2h"])

      assert opts[:timeout] == 7_200_000
    end

    test "parses --timeout=1d as 86400000ms" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=1d"])

      assert opts[:timeout] == 86_400_000
    end

    test "parses --timeout=0 as :infinity" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=0"])

      assert opts[:timeout] == :infinity
    end

    test "parses --timeout=5000 as raw milliseconds" do
      {_path, opts} = Sykli.CLI.parse_run_args(["--timeout=5000"])

      assert opts[:timeout] == 5000
    end

    test "parses --timeout with other options" do
      args = ["--timeout=15m", "--target=k8s", "./my-project"]
      {path, opts} = Sykli.CLI.parse_run_args(args)

      assert path == "./my-project"
      assert opts[:timeout] == 900_000
      assert opts[:target] == :k8s
    end
  end
end
