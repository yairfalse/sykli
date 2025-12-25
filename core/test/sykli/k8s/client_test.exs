defmodule Sykli.K8s.ClientTest do
  use ExUnit.Case, async: true

  alias Sykli.K8s.Client
  alias Sykli.K8s.Error

  # These tests use a mock HTTP layer
  # In implementation, we'll inject the HTTP module for testability

  describe "request/5" do
    test "makes GET request with bearer token auth" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "test-token"},
        ca_cert: nil
      }

      # Mock would return this
      mock_response = {:ok, %{"kind" => "Job", "metadata" => %{"name" => "test"}}}

      result = Client.request(:get, "/apis/batch/v1/namespaces/default/jobs/test", nil, config,
        http_client: fn _method, _url, _headers, _body, _opts ->
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(%{"kind" => "Job", "metadata" => %{"name" => "test"}})}}
        end
      )

      assert {:ok, body} = result
      assert body["kind"] == "Job"
    end

    test "makes POST request with JSON body" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "test-token"},
        ca_cert: nil
      }

      manifest = %{"apiVersion" => "batch/v1", "kind" => "Job"}

      result = Client.request(:post, "/apis/batch/v1/namespaces/default/jobs", manifest, config,
        http_client: fn :post, url, headers, body, _opts ->
          # Verify the request
          assert String.contains?(url, "/apis/batch/v1/namespaces/default/jobs")
          assert Enum.any?(headers, fn {k, _} -> k == ~c"Authorization" end)
          assert Enum.any?(headers, fn {k, _} -> k == ~c"Content-Type" end)

          decoded = Jason.decode!(body)
          assert decoded["kind"] == "Job"

          {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], body}}
        end
      )

      assert {:ok, _body} = result
    end

    test "returns typed error for 401 Unauthorized" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "bad-token"},
        ca_cert: nil
      }

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 401, ~c"Unauthorized"}, [], "{\"message\": \"Unauthorized\"}"}}
        end
      )

      assert {:error, %Error{type: :auth_failed, status_code: 401}} = result
    end

    test "returns typed error for 403 Forbidden" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "limited-token"},
        ca_cert: nil
      }

      result = Client.request(:get, "/api/v1/secrets", nil, config,
        http_client: fn _, _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 403, ~c"Forbidden"}, [], "{\"message\": \"forbidden\"}"}}
        end
      )

      assert {:error, %Error{type: :forbidden, status_code: 403}} = result
    end

    test "returns typed error for 404 Not Found" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      result = Client.request(:get, "/apis/batch/v1/namespaces/default/jobs/nonexistent", nil, config,
        http_client: fn _, _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "{\"reason\": \"NotFound\"}"}}
        end
      )

      assert {:error, %Error{type: :not_found, status_code: 404}} = result
    end

    test "returns typed error for 409 Conflict" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      result = Client.request(:post, "/apis/batch/v1/namespaces/default/jobs", %{}, config,
        http_client: fn _, _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 409, ~c"Conflict"}, [], "{\"reason\": \"AlreadyExists\"}"}}
        end
      )

      assert {:error, %Error{type: :conflict, status_code: 409}} = result
    end

    test "retries on 5xx errors with exponential backoff" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      call_count = :counters.new(1, [:atomics])

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, _, _, _ ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count < 3 do
            {:ok, {{~c"HTTP/1.1", 503, ~c"Service Unavailable"}, [], "{}"}}
          else
            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{\"items\": []}"}}
          end
        end,
        retry_delays: [10, 20, 40]  # Fast for testing
      )

      assert {:ok, _} = result
      assert :counters.get(call_count, 1) == 3
    end

    test "gives up after max retries on 5xx" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 503, ~c"Service Unavailable"}, [], "{\"message\": \"overloaded\"}"}}
        end,
        retry_delays: [10, 20, 40]
      )

      assert {:error, %Error{type: :api_error, status_code: 503}} = result
    end

    test "does not retry on 4xx errors" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      call_count = :counters.new(1, [:atomics])

      result = Client.request(:get, "/api/v1/secrets", nil, config,
        http_client: fn _, _, _, _, _ ->
          :counters.add(call_count, 1, 1)
          {:ok, {{~c"HTTP/1.1", 403, ~c"Forbidden"}, [], "{}"}}
        end,
        retry_delays: [10, 20, 40]
      )

      assert {:error, %Error{type: :forbidden}} = result
      assert :counters.get(call_count, 1) == 1  # No retries
    end

    test "handles connection errors" do
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: nil
      }

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, _, _, _ ->
          {:error, :econnrefused}
        end
      )

      assert {:error, %Error{type: :connection_error}} = result
    end

    test "includes CA cert in TLS options when provided" do
      ca_cert = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----"
      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "token"},
        ca_cert: ca_cert
      }

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, _, _, opts ->
          # Verify SSL options include the CA
          ssl_opts = Keyword.get(opts, :ssl, [])
          assert Keyword.has_key?(ssl_opts, :cacerts) or Keyword.has_key?(ssl_opts, :verify)
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{}"}}
        end
      )

      assert {:ok, _} = result
    end

    test "uses client cert auth when configured" do
      # Self-signed test certificate (not for production use)
      test_cert = """
      -----BEGIN CERTIFICATE-----
      MIIBkTCB+wIJAKHBfpegDyBdMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnVu
      dXNlZDAeFw0yNDAxMDEwMDAwMDBaFw0yNTAxMDEwMDAwMDBaMBExDzANBgNVBAMM
      BnVudXNlZDBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC5xdH1RVSvY1rMWJvLELGU
      SXqPRfPjL8JMTb8eLOZBzZy/nLwDXS/WOvL3vEBOE6lNx0VnBnWiLrpJOoHIpnF1
      AgMBAAEwDQYJKoZIhvcNAQELBQADQQBiDnz8bPJDHVNxFEF2qYKTKBPGkJaJQHQL
      XJnPEqVF7j/IHUjD1pXc8VrXL7M1d+r0qrHqo+yLvJVjqJNZB9Gh
      -----END CERTIFICATE-----
      """

      test_key = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIBOgIBAAJBALnF0fVFVK9jWsxYm8sQsZRJeo9F8+MvwkxNvx4s5kHNnL+cvANd
      L9Y68ve8QE4TqU3HRWcGdaIuukk6gcimcXUCAwEAAQJAb8B+GVsJQmLETqLHnGDn
      aCnINtjdZGR9j9ZrLk0aKq5wlKl8C6yj+UBFNndIyJRUzDWgXo7zQ7l/P7WUE3sJ
      gQIhAOl1I9mfL0rFbqpLLqD+AEFm+6YwZJVdM8xhIYn5r/0VAiEAy5gLzQ8+bDmI
      K8q5uzF78GEbOCJdvPqFz8i0vq7kUTECIE8KQ0xj3C3SfsfNVHVjJNR7HJR0q75Y
      5lN9x8qIbrzxAiEApKHFk/0l8FT7KQZQ5lNxR0qfE9B0VMGB8j8xn5YJ5pECIFSk
      q5L1wxQnjqz8n5fqLMNp7IY2HbFi0bLBlzQ0v7Wy
      -----END RSA PRIVATE KEY-----
      """

      config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:cert, {test_cert, test_key}},
        ca_cert: nil
      }

      result = Client.request(:get, "/api/v1/namespaces", nil, config,
        http_client: fn _, _, headers, _, opts ->
          # Should NOT have Authorization header
          refute Enum.any?(headers, fn {k, _} -> k == ~c"Authorization" end)
          # Should have client cert in SSL options
          ssl_opts = Keyword.get(opts, :ssl, [])
          assert Keyword.has_key?(ssl_opts, :cert) or Keyword.has_key?(ssl_opts, :certfile)
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{}"}}
        end
      )

      assert {:ok, _} = result
    end
  end

  describe "build_url/2" do
    test "combines api_url and path" do
      config = %{api_url: "https://kubernetes.default.svc"}

      assert Client.build_url("/api/v1/namespaces", config) ==
             "https://kubernetes.default.svc/api/v1/namespaces"
    end

    test "handles trailing slash in api_url" do
      config = %{api_url: "https://kubernetes.default.svc/"}

      assert Client.build_url("/api/v1/namespaces", config) ==
             "https://kubernetes.default.svc/api/v1/namespaces"
    end
  end
end
