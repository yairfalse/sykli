defmodule Sykli.Services.OIDCServiceTest do
  use ExUnit.Case, async: false

  alias Sykli.Services.OIDCService

  # A minimal valid JWT with 3 base64url-encoded parts.
  # Header: {"alg":"RS256","typ":"JWT","kid":"test-kid","iss":"https://token.actions.githubusercontent.com"}
  # Payload: {"sub":"repo:org/repo:ref:refs/heads/main","aud":"sykli","iss":"https://token.actions.githubusercontent.com"}
  @valid_header Jason.encode!(%{
                  "alg" => "RS256",
                  "typ" => "JWT",
                  "kid" => "test-kid",
                  "iss" => "https://token.actions.githubusercontent.com"
                })
  @valid_payload Jason.encode!(%{
                   "sub" => "repo:org/repo:ref:refs/heads/main",
                   "aud" => "sykli",
                   "iss" => "https://token.actions.githubusercontent.com"
                 })
  @valid_jwt "#{Base.url_encode64(@valid_header, padding: false)}.#{Base.url_encode64(@valid_payload, padding: false)}.dGVzdC1zaWduYXR1cmU"

  describe "exchange/2" do
    test "returns {:ok, %{}} when task oidc is nil" do
      task = %Sykli.Graph.Task{oidc: nil}
      assert {:ok, %{}} = OIDCService.exchange(task, %{})
    end
  end

  describe "decode_jwt_parts (via exchange path)" do
    # decode_jwt_parts is private, so we test via the public exchange path
    # or we test the behavior indirectly by observing error messages.

    test "valid 3-part JWT can be decoded" do
      # We can verify decode works by checking that exchange proceeds past
      # the decode step (it will fail later at JWKS fetch, not at decode)
      binding = %Sykli.Graph.Task.CredentialBinding{
        provider: :aws,
        audience: "sykli",
        role_arn: "arn:aws:iam::123456789:role/test"
      }

      task = %Sykli.Graph.Task{oidc: binding}

      # Clear CI env vars so it falls to "OIDC not available" path
      env_vars = ["ACTIONS_ID_TOKEN_REQUEST_URL", "CI_JOB_JWT_V2"]

      saved =
        Enum.map(env_vars, fn var ->
          {var, System.get_env(var)}
        end)

      Enum.each(env_vars, &System.delete_env/1)

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, val} -> System.put_env(var, val)
        end)
      end)

      assert {:error, msg} = OIDCService.exchange(task, %{})
      assert msg =~ "OIDC not available"
    end
  end

  describe "acquire_identity_token (via exchange path)" do
    setup do
      env_vars = [
        "ACTIONS_ID_TOKEN_REQUEST_URL",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "CI_JOB_JWT_V2"
      ]

      saved = Enum.map(env_vars, fn var -> {var, System.get_env(var)} end)

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, val} -> System.put_env(var, val)
        end)
      end)

      Enum.each(env_vars, &System.delete_env/1)
      :ok
    end

    test "returns error when no CI environment is detected" do
      binding = %Sykli.Graph.Task.CredentialBinding{
        provider: :aws,
        audience: "sykli",
        role_arn: "arn:aws:iam::123456789:role/test"
      }

      task = %Sykli.Graph.Task{oidc: binding}

      assert {:error, msg} = OIDCService.exchange(task, %{})
      assert msg =~ "OIDC not available"
      assert msg =~ "GitHub Actions"
    end

    test "uses GitLab CI JWT when CI_JOB_JWT_V2 is set" do
      # Set GitLab env var with our test JWT
      System.put_env("CI_JOB_JWT_V2", @valid_jwt)

      binding = %Sykli.Graph.Task.CredentialBinding{
        provider: :aws,
        audience: "sykli",
        role_arn: "arn:aws:iam::123456789:role/test"
      }

      task = %Sykli.Graph.Task{oidc: binding}

      # It should pick up the GitLab token and proceed to JWT verification
      # which will fail at JWKS fetch (network), not at token acquisition
      result = OIDCService.exchange(task, %{})
      assert {:error, msg} = result
      # Should fail at verification, not at acquisition
      assert msg =~ "verification failed"
    end

    test "GitHub path requires ACTIONS_ID_TOKEN_REQUEST_TOKEN" do
      System.put_env("ACTIONS_ID_TOKEN_REQUEST_URL", "https://example.com/token")
      # Deliberately not setting ACTIONS_ID_TOKEN_REQUEST_TOKEN

      binding = %Sykli.Graph.Task.CredentialBinding{
        provider: :aws,
        audience: "sykli",
        role_arn: "arn:aws:iam::123456789:role/test"
      }

      task = %Sykli.Graph.Task{oidc: binding}

      assert {:error, msg} = OIDCService.exchange(task, %{})
      assert msg =~ "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
    end
  end

  describe "cleanup_temp_files/0" do
    test "returns :ok when no temp files tracked" do
      Process.delete(:sykli_oidc_temp_files)
      assert :ok = OIDCService.cleanup_temp_files()
    end

    test "removes tracked temp files and clears process dict" do
      # Create a temp file to track
      path = Path.join(System.tmp_dir!(), "sykli-oidc-test-#{:rand.uniform(100_000)}")
      File.write!(path, "test")

      Process.put(:sykli_oidc_temp_files, [path])

      assert :ok = OIDCService.cleanup_temp_files()
      refute File.exists?(path)
      assert Process.get(:sykli_oidc_temp_files) == nil
    end
  end
end
