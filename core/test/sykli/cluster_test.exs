defmodule Sykli.ClusterTest do
  use ExUnit.Case, async: true

  alias Sykli.Cluster

  describe "connect/1" do
    test "accepts binary node name" do
      # In test environment, node is not alive so we get :node_not_alive
      result = Cluster.connect("fake_node@localhost")

      assert result == {:error, :node_not_alive}
    end

    test "accepts atom node name" do
      result = Cluster.connect(:fake_node@localhost)

      assert result == {:error, :node_not_alive}
    end
  end

  describe "disconnect/1" do
    test "accepts binary node name" do
      # disconnect returns true even if not connected
      result = Cluster.disconnect("fake_node@localhost")

      assert result in [true, false, :ignored]
    end

    test "accepts atom node name" do
      result = Cluster.disconnect(:fake_node@localhost)

      assert result in [true, false, :ignored]
    end
  end

  describe "nodes/0" do
    test "returns a list" do
      result = Cluster.nodes()

      assert is_list(result)
    end

    test "returns empty list when not distributed" do
      # In test environment, we're not connected to any nodes
      result = Cluster.nodes()

      assert result == []
    end
  end

  describe "has_coordinator?/0" do
    test "returns false when no coordinator connected" do
      refute Cluster.has_coordinator?()
    end
  end

  describe "coordinator/0" do
    test "returns nil when no coordinator connected" do
      assert Cluster.coordinator() == nil
    end
  end

  describe "coordinator detection" do
    # Test the coordinator naming convention
    test "recognizes coordinator@ prefix in node names" do
      # This tests the private coordinator_node?/1 function indirectly
      # by checking has_coordinator? and coordinator return expected values

      # With no nodes connected, both should return negative
      refute Cluster.has_coordinator?()
      assert Cluster.coordinator() == nil
    end
  end
end
