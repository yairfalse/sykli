defmodule Sykli.GitHub.AppTest do
  use ExUnit.Case, async: false

  alias Sykli.GitHub.App
  alias Sykli.GitHub.App.Cache
  alias Sykli.GitHub.App.Real

  setup do
    Cache.clear()
    Application.put_env(:sykli, :github_clock_fake_now_ms, 1_700_000_000_000)
    Application.delete_env(:sykli, :github_http_fake_calls)
    :ok
  end

  test "sign_jwt creates RS256 GitHub App claims" do
    assert {:ok, jwt} = Real.sign_jwt("12345", private_key_pem(), 1_700_000_000)
    [header, claims, _signature] = String.split(jwt, ".")

    assert %{"alg" => "RS256"} = decode_part(header)

    assert %{"iss" => "12345", "iat" => 1_699_999_940, "exp" => 1_700_000_540} =
             decode_part(claims)
  end

  test "installation_token fetches and caches an installation token" do
    opts = [
      app_id: "12345",
      private_key: private_key_pem(),
      http_client: __MODULE__.HTTP,
      clock: Sykli.GitHub.Clock.Fake,
      impl: Real
    ]

    assert {:ok, "token-1", 1_700_003_600} = App.installation_token(42, opts)
    assert {:ok, "token-1", 1_700_003_600} = App.installation_token(42, opts)
    assert Application.get_env(:sykli, :github_http_fake_calls) == 1
  end

  defmodule HTTP do
    def request(:post, url, headers, "{}") do
      assert url =~ "/app/installations/42/access_tokens"

      assert Enum.any?(headers, fn {name, value} ->
               name == ~c"Authorization" and to_string(value) =~ "Bearer "
             end)

      calls = Application.get_env(:sykli, :github_http_fake_calls, 0)
      Application.put_env(:sykli, :github_http_fake_calls, calls + 1)

      {:ok, 201, ~s({"token":"token-1","expires_at":"2023-11-14T23:13:20Z"})}
    end
  end

  defp private_key_pem do
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([entry])
  end

  defp decode_part(part) do
    part
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end
end
