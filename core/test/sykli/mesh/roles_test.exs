defmodule Sykli.Mesh.RolesTest do
  use ExUnit.Case, async: false

  alias Sykli.Mesh.Roles

  setup do
    Roles.clear()
    :ok
  end

  test "acquire release and holder semantics" do
    assert Roles.holder(:webhook_receiver) == nil
    assert :ok = Roles.acquire(:webhook_receiver, :node_a)
    assert Roles.holder(:webhook_receiver) == :node_a
    assert :ok = Roles.acquire(:webhook_receiver, :node_a)
    assert {:error, {:role_held, :node_a}} = Roles.acquire(:webhook_receiver, :node_b)
    assert {:error, {:role_held, :node_a}} = Roles.release(:webhook_receiver, :node_b)
    assert :ok = Roles.release(:webhook_receiver, :node_a)
    assert Roles.holder(:webhook_receiver) == nil
  end
end
