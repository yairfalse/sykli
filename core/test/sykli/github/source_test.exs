defmodule Sykli.GitHub.SourceTest do
  use ExUnit.Case, async: false

  alias Sykli.GitHub.Source

  @fixture Path.expand("../../../priv/test_fixtures/github_source/simple", __DIR__)

  test "fake source copies a fixture repo and cleans it up" do
    context = %{
      repo: "false-systems/sykli",
      head_sha: "abc123",
      delivery_id: "source-test",
      run_id: "github:source-test"
    }

    assert {:ok, path} =
             Source.acquire(context, "installation-token",
               impl: Sykli.GitHub.Source.Fake,
               source_fixture: @fixture
             )

    assert File.exists?(Path.join(path, "sykli.exs"))
    refute String.contains?(path, ":")

    assert :ok = Source.cleanup(path, impl: Sykli.GitHub.Source.Fake)
    refute File.exists?(path)
  end

  test "real source uses transient git auth and does not persist the token" do
    token = "ghs_secret_installation_token"
    parent = self()

    git_runner = fn "git", args, opts ->
      send(parent, {:git_invocation, args, opts})

      case args do
        ["clone", "--depth", "1", url, repo_dir] ->
          init_repo(repo_dir, url)
          {"", 0}

        _ ->
          {"", 0}
      end
    end

    assert {:ok, path} =
             Sykli.GitHub.Source.Real.acquire(
               %{
                 repo: "false-systems/sykli",
                 head_sha: "HEAD",
                 delivery_id: "token-safe",
                 run_id: "github:token-safe"
               },
               token,
               git_runner: git_runner
             )

    config = File.read!(Path.join([path, ".git", "config"]))

    refute String.contains?(path, ":")
    refute String.contains?(config, token)
    refute String.contains?(config, "x-access-token")
    assert String.contains?(config, "https://github.com/false-systems/sykli.git")

    assert_receive {:git_invocation, ["clone", "--depth", "1", url, _repo_dir], opts}
    assert url == "https://github.com/false-systems/sykli.git"
    refute url =~ token
    refute inspect(opts) =~ token

    env = Keyword.fetch!(opts, :env)
    {"GIT_CONFIG_GLOBAL", auth_config} = List.keyfind(env, "GIT_CONFIG_GLOBAL", 0)

    refute inspect(env) =~ token
    refute File.exists?(auth_config)

    assert :ok = Sykli.GitHub.Source.Real.cleanup(path)
  end

  test "real cleanup refuses paths outside the sykli temp root" do
    decoy =
      Path.join(System.tmp_dir!(), "not-sykli-source-decoy-#{System.unique_integer([:positive])}")

    sentinel = Path.join(decoy, "sentinel")

    File.mkdir_p!(decoy)
    File.write!(sentinel, "keep")
    on_exit(fn -> File.rm_rf!(decoy) end)

    assert :ok = Sykli.GitHub.Source.Real.cleanup(decoy)
    assert File.exists?(sentinel)
  end

  defp init_repo(repo_dir, remote_url) do
    File.mkdir_p!(repo_dir)
    File.write!(Path.join(repo_dir, "sykli.exs"), "[]\n")

    System.cmd("git", ["init", "-b", "main"], cd: repo_dir, stderr_to_stdout: true)

    System.cmd("git", ["config", "user.email", "test@example.com"],
      cd: repo_dir,
      stderr_to_stdout: true
    )

    System.cmd("git", ["config", "user.name", "Source Test"],
      cd: repo_dir,
      stderr_to_stdout: true
    )

    System.cmd("git", ["remote", "add", "origin", remote_url],
      cd: repo_dir,
      stderr_to_stdout: true
    )

    System.cmd("git", ["add", "sykli.exs"], cd: repo_dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: repo_dir, stderr_to_stdout: true)
  end
end
