defmodule Sykli.ConfigTest do
  @moduledoc """
  Regression guard for the config/*.exs wiring.

  The :test env must configure Sykli.Runtime.Fake as the default runtime
  so that mix test does not require a container runtime. If this test
  fails, someone likely edited config/test.exs.
  """

  use ExUnit.Case, async: true

  test ":test env configures Sykli.Runtime.Fake as the default runtime" do
    assert Application.get_env(:sykli, :default_runtime) == Sykli.Runtime.Fake
  end
end
