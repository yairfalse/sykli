defmodule Sykli.Target.K8sOptionsTest do
  use ExUnit.Case, async: true

  alias Sykli.Target.K8sOptions
  alias Sykli.Target.K8sOptions.{Resources, Toleration, Volume}

  # ─────────────────────────────────────────────────────────────────────────────
  # MEMORY VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 memory formats" do
    test "accepts valid memory formats" do
      valid = ["512Mi", "4Gi", "1Ti", "256Ki", "1G", "500M", "100"]

      for mem <- valid do
        opts = %K8sOptions{resources: %Resources{memory: mem}}
        assert {:ok, _} = K8sOptions.validate(opts), "expected #{mem} to be valid"
      end
    end

    test "rejects invalid memory formats with helpful suggestions" do
      cases = [
        {"32gb", "did you mean 'Gi'"},
        {"512mb", "did you mean 'Mi'"},
        {"1kb", "did you mean 'Ki'"},
        {"4GB", "did you mean 'Gi'"},
        {"lots", "invalid memory format"}
      ]

      for {mem, expected_hint} <- cases do
        opts = %K8sOptions{resources: %Resources{memory: mem}}
        assert {:error, errors} = K8sOptions.validate(opts)
        assert length(errors) > 0
        {_field, _value, message} = hd(errors)

        assert String.contains?(message, expected_hint),
               "expected error for #{mem} to contain '#{expected_hint}', got: #{message}"
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CPU VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 CPU formats" do
    test "accepts valid CPU formats" do
      valid = ["100m", "500m", "1", "2", "0.5", "1.5"]

      for cpu <- valid do
        opts = %K8sOptions{resources: %Resources{cpu: cpu}}
        assert {:ok, _} = K8sOptions.validate(opts), "expected #{cpu} to be valid"
      end
    end

    test "rejects invalid CPU formats" do
      invalid = ["100cores", "2 cores", "fast"]

      for cpu <- invalid do
        opts = %K8sOptions{resources: %Resources{cpu: cpu}}
        assert {:error, errors} = K8sOptions.validate(opts)
        assert length(errors) > 0
        {_field, _value, message} = hd(errors)
        assert String.contains?(message, "invalid CPU format")
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TOLERATION VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 tolerations" do
    test "accepts valid toleration operators" do
      for op <- ["Exists", "Equal"] do
        opts = %K8sOptions{
          tolerations: [
            %Toleration{key: "key", operator: op, effect: "NoSchedule"}
          ]
        }

        assert {:ok, _} = K8sOptions.validate(opts)
      end
    end

    test "rejects invalid toleration operator" do
      opts = %K8sOptions{
        tolerations: [
          %Toleration{key: "key", operator: "Invalid", effect: "NoSchedule"}
        ]
      }

      assert {:error, errors} = K8sOptions.validate(opts)
      {field, value, message} = hd(errors)
      assert field == "tolerations[0].operator"
      assert value == "Invalid"
      assert String.contains?(message, "'Exists' or 'Equal'")
    end

    test "accepts valid toleration effects" do
      for effect <- ["NoSchedule", "PreferNoSchedule", "NoExecute"] do
        opts = %K8sOptions{
          tolerations: [
            %Toleration{key: "key", operator: "Exists", effect: effect}
          ]
        }

        assert {:ok, _} = K8sOptions.validate(opts)
      end
    end

    test "rejects invalid toleration effect" do
      opts = %K8sOptions{
        tolerations: [
          %Toleration{key: "key", operator: "Exists", effect: "Invalid"}
        ]
      }

      assert {:error, errors} = K8sOptions.validate(opts)
      {field, _value, message} = hd(errors)
      assert field == "tolerations[0].effect"
      assert String.contains?(message, "'NoSchedule'")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DNS POLICY VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 DNS policy" do
    test "accepts valid DNS policies" do
      valid = ["ClusterFirst", "ClusterFirstWithHostNet", "Default", "None"]

      for policy <- valid do
        opts = %K8sOptions{dns_policy: policy}
        assert {:ok, _} = K8sOptions.validate(opts)
      end
    end

    test "rejects invalid DNS policy" do
      opts = %K8sOptions{dns_policy: "InvalidPolicy"}
      assert {:error, errors} = K8sOptions.validate(opts)
      {field, value, message} = hd(errors)
      assert field == "dns_policy"
      assert value == "InvalidPolicy"
      assert String.contains?(message, "ClusterFirst")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUME VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 volumes" do
    test "rejects empty mount path" do
      opts = %K8sOptions{
        volumes: [%Volume{name: "vol", mount_path: ""}]
      }

      assert {:error, errors} = K8sOptions.validate(opts)
      {field, _value, message} = hd(errors)
      assert field == "volumes[0].mount_path"
      assert String.contains?(message, "mount path is required")
    end

    test "rejects relative mount path" do
      opts = %K8sOptions{
        volumes: [%Volume{name: "vol", mount_path: "relative/path"}]
      }

      assert {:error, errors} = K8sOptions.validate(opts)
      {field, _value, message} = hd(errors)
      assert field == "volumes[0].mount_path"
      assert String.contains?(message, "must be absolute")
    end

    test "accepts absolute mount path" do
      opts = %K8sOptions{
        volumes: [%Volume{name: "vol", mount_path: "/data"}]
      }

      assert {:ok, _} = K8sOptions.validate(opts)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VALIDATE! HELPER
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate!/1" do
    test "returns nil for valid options" do
      opts = %K8sOptions{resources: %Resources{memory: "4Gi"}}
      assert is_nil(K8sOptions.validate!(opts))
    end

    test "returns formatted error message for invalid options" do
      opts = %K8sOptions{resources: %Resources{memory: "32gb"}}
      error = K8sOptions.validate!(opts)
      assert String.contains?(error, "k8s.resources.memory")
      assert String.contains?(error, "did you mean 'Gi'")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EDGE CASES
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate/1 edge cases" do
    test "validates nil options" do
      assert {:ok, nil} = K8sOptions.validate(nil)
    end

    test "validates empty options struct" do
      assert {:ok, _} = K8sOptions.validate(%K8sOptions{})
    end
  end
end
