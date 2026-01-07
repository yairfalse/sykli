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
  end
end
