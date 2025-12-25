defmodule Sykli.K8s.ErrorTest do
  use ExUnit.Case, async: true

  alias Sykli.K8s.Error

  describe "new/2" do
    test "creates error with type and message" do
      error = Error.new(:not_found, "Job not found")

      assert %Error{} = error
      assert error.type == :not_found
      assert error.message == "Job not found"
    end

    test "creates error with all fields" do
      error = Error.new(:api_error,
        message: "Internal server error",
        status_code: 500,
        reason: "InternalError",
        details: %{"causes" => []}
      )

      assert error.type == :api_error
      assert error.status_code == 500
      assert error.reason == "InternalError"
    end
  end

  describe "from_status_code/2" do
    test "maps 401 to auth_failed" do
      error = Error.from_status_code(401, %{"message" => "Unauthorized"})

      assert error.type == :auth_failed
      assert error.status_code == 401
    end

    test "maps 403 to forbidden" do
      error = Error.from_status_code(403, %{"message" => "forbidden"})

      assert error.type == :forbidden
      assert error.status_code == 403
    end

    test "maps 404 to not_found" do
      error = Error.from_status_code(404, %{"reason" => "NotFound"})

      assert error.type == :not_found
      assert error.status_code == 404
    end

    test "maps 409 to conflict" do
      error = Error.from_status_code(409, %{"reason" => "AlreadyExists"})

      assert error.type == :conflict
      assert error.status_code == 409
    end

    test "maps 422 to validation_error" do
      error = Error.from_status_code(422, %{"reason" => "Invalid"})

      assert error.type == :validation_error
      assert error.status_code == 422
    end

    test "maps 5xx to api_error" do
      error = Error.from_status_code(503, %{"message" => "Service Unavailable"})

      assert error.type == :api_error
      assert error.status_code == 503
    end

    test "extracts reason from K8s status response" do
      error = Error.from_status_code(404, %{
        "kind" => "Status",
        "apiVersion" => "v1",
        "status" => "Failure",
        "message" => "jobs.batch \"nonexistent\" not found",
        "reason" => "NotFound",
        "details" => %{"name" => "nonexistent", "kind" => "jobs"}
      })

      assert error.type == :not_found
      assert error.reason == "NotFound"
      assert error.message == "jobs.batch \"nonexistent\" not found"
    end
  end

  describe "Exception implementation" do
    test "can be raised" do
      assert_raise Error, "Not found: Job not found", fn ->
        raise Error.new(:not_found, "Job not found")
      end
    end
  end

  describe "retryable?/1" do
    test "5xx errors are retryable" do
      assert Error.retryable?(%Error{type: :api_error, status_code: 500})
      assert Error.retryable?(%Error{type: :api_error, status_code: 502})
      assert Error.retryable?(%Error{type: :api_error, status_code: 503})
    end

    test "connection errors are retryable" do
      assert Error.retryable?(%Error{type: :connection_error})
    end

    test "timeout errors are retryable" do
      assert Error.retryable?(%Error{type: :timeout})
    end

    test "4xx errors are not retryable" do
      refute Error.retryable?(%Error{type: :not_found, status_code: 404})
      refute Error.retryable?(%Error{type: :forbidden, status_code: 403})
      refute Error.retryable?(%Error{type: :auth_failed, status_code: 401})
    end
  end
end
