defmodule Sykli.Services.SecretMaskerTest do
  use ExUnit.Case, async: true

  alias Sykli.Services.SecretMasker

  describe "mask_string/2" do
    test "replaces known secrets" do
      result = SecretMasker.mask_string("token is abc123xyz", ["abc123xyz"])
      assert result == "token is ***MASKED***"
    end

    test "handles multiple secrets" do
      result = SecretMasker.mask_string("key=secret1 pass=secret2", ["secret1", "secret2"])
      assert result == "key=***MASKED*** pass=***MASKED***"
    end

    test "ignores short secrets (< 4 chars)" do
      result = SecretMasker.mask_string("ab is short", ["ab"])
      assert result == "ab is short"
    end

    test "returns string unchanged when no secrets" do
      assert SecretMasker.mask_string("hello", []) == "hello"
    end

    test "handles non-string input" do
      assert SecretMasker.mask_string(nil, ["secret"]) == nil
      assert SecretMasker.mask_string(42, ["secret"]) == 42
    end
  end

  describe "mask_deep/2" do
    test "masks strings in maps" do
      data = %{"output" => "error: token is mysecret123", "code" => 1}
      result = SecretMasker.mask_deep(data, ["mysecret123"])
      assert result["output"] == "error: token is ***MASKED***"
      assert result["code"] == 1
    end

    test "masks strings in nested maps" do
      data = %{"error" => %{"message" => "failed with key=supersecret"}}
      result = SecretMasker.mask_deep(data, ["supersecret"])
      assert result["error"]["message"] == "failed with key=***MASKED***"
    end

    test "masks strings in lists" do
      data = ["line1: ok", "line2: token=mypassword123"]
      result = SecretMasker.mask_deep(data, ["mypassword123"])
      assert result == ["line1: ok", "line2: token=***MASKED***"]
    end

    test "handles empty secrets list" do
      data = %{"a" => "b"}
      assert SecretMasker.mask_deep(data, []) == data
    end

    test "masks strings in deeply nested structures (map inside list inside map)" do
      data = %{
        "tasks" => [
          %{
            "name" => "build",
            "steps" => [
              %{"output" => "Downloading with token=super_secret_token_123"}
            ]
          },
          %{
            "name" => "test",
            "steps" => [
              %{"output" => "All good"}
            ]
          }
        ]
      }

      result = SecretMasker.mask_deep(data, ["super_secret_token_123"])

      build_output =
        result
        |> Map.get("tasks")
        |> List.first()
        |> Map.get("steps")
        |> List.first()
        |> Map.get("output")

      assert build_output == "Downloading with token=***MASKED***"

      # Unrelated output is untouched
      test_output =
        result
        |> Map.get("tasks")
        |> List.last()
        |> Map.get("steps")
        |> List.first()
        |> Map.get("output")

      assert test_output == "All good"
    end

    test "masks with atom keys in maps" do
      data = %{output: "error: key=my_api_key_value here", code: 1}
      result = SecretMasker.mask_deep(data, ["my_api_key_value"])
      assert result[:output] == "error: key=***MASKED*** here"
      assert result[:code] == 1
    end

    test "masks with mixed atom and string keys" do
      data = %{
        :log => "token=secret_val_1234",
        "detail" => %{:inner => "password=secret_val_1234"}
      }

      result = SecretMasker.mask_deep(data, ["secret_val_1234"])
      assert result[:log] == "token=***MASKED***"
      assert result["detail"][:inner] == "password=***MASKED***"
    end

    test "handles non-string non-map non-list values" do
      assert SecretMasker.mask_deep(42, ["secret"]) == 42
      assert SecretMasker.mask_deep(true, ["secret"]) == true
      assert SecretMasker.mask_deep(nil, ["secret"]) == nil
      assert SecretMasker.mask_deep(:atom, ["secret"]) == :atom
    end

    test "handles list of mixed types" do
      data = ["text with secret_value_here", 42, nil, %{"key" => "has secret_value_here too"}]
      result = SecretMasker.mask_deep(data, ["secret_value_here"])

      assert Enum.at(result, 0) == "text with ***MASKED***"
      assert Enum.at(result, 1) == 42
      assert Enum.at(result, 2) == nil
      assert Enum.at(result, 3) == %{"key" => "has ***MASKED*** too"}
    end
  end

  describe "mask_string/2 with env var pattern values" do
    # These test that the masker correctly handles typical secret values
    # that would be collected from env vars matching patterns like
    # _TOKEN, _SECRET, _KEY, _PASSWORD, _URL, _DSN, _URI, _CONN

    test "masks a typical _TOKEN value" do
      token = "ghp_abc123XYZ789defGHI"
      result = SecretMasker.mask_string("Authorization: Bearer #{token}", [token])
      assert result == "Authorization: Bearer ***MASKED***"
    end

    test "masks a typical _SECRET value" do
      secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCY"
      result = SecretMasker.mask_string("AWS_SECRET=#{secret}", [secret])
      assert result == "AWS_SECRET=***MASKED***"
    end

    test "masks a typical _KEY value" do
      key = "AKIAIOSFODNN7EXAMPLE"
      result = SecretMasker.mask_string("key=#{key} in config", [key])
      assert result == "key=***MASKED*** in config"
    end

    test "masks a typical _PASSWORD value" do
      password = "P@ssw0rd!2024#Secure"
      result = SecretMasker.mask_string("connecting with password #{password}", [password])
      assert result == "connecting with password ***MASKED***"
    end

    test "masks a typical _URL connection string" do
      url = "postgres://user:pass@db.example.com:5432/mydb"
      result = SecretMasker.mask_string("DATABASE_URL=#{url}", [url])
      assert result == "DATABASE_URL=***MASKED***"
    end

    test "masks a typical _DSN value" do
      dsn = "https://abc123@o123456.ingest.sentry.io/123456"
      result = SecretMasker.mask_string("SENTRY_DSN=#{dsn}", [dsn])
      assert result == "SENTRY_DSN=***MASKED***"
    end

    test "masks a typical _URI value" do
      uri = "redis://default:mypassword@redis.example.com:6379"
      result = SecretMasker.mask_string("REDIS_URI=#{uri}", [uri])
      assert result == "REDIS_URI=***MASKED***"
    end

    test "masks a typical _CONN value" do
      conn = "Server=tcp:myserver.database.windows.net;Password=mypass"
      result = SecretMasker.mask_string("DB_CONN=#{conn}", [conn])
      assert result == "DB_CONN=***MASKED***"
    end

    test "masks multiple different secret types in one string" do
      token = "ghp_testtoken123"
      password = "super_secure_pass"

      input = "token=#{token} password=#{password}"
      result = SecretMasker.mask_string(input, [token, password])
      assert result == "token=***MASKED*** password=***MASKED***"
    end
  end
end
