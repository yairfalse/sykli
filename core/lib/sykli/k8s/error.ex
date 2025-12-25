defmodule Sykli.K8s.Error do
  @moduledoc """
  Typed error struct for K8s API operations.

  Provides structured errors with semantic types that map to HTTP status codes
  and K8s API reasons, making error handling more predictable.
  """

  @type error_type ::
          :auth_failed
          | :forbidden
          | :not_found
          | :conflict
          | :validation_error
          | :timeout
          | :api_error
          | :connection_error

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t() | nil,
          status_code: integer() | nil,
          reason: String.t() | nil,
          details: map() | nil
        }

  defexception [:type, :message, :status_code, :reason, :details]

  @doc """
  Creates a new error with the given type and message or options.

  ## Examples

      Error.new(:not_found, "Job not found")
      Error.new(:api_error, message: "Server error", status_code: 500)
  """
  @spec new(error_type(), String.t() | keyword()) :: t()
  def new(type, message) when is_binary(message) do
    %__MODULE__{type: type, message: message}
  end

  def new(type, opts) when is_list(opts) do
    %__MODULE__{
      type: type,
      message: Keyword.get(opts, :message),
      status_code: Keyword.get(opts, :status_code),
      reason: Keyword.get(opts, :reason),
      details: Keyword.get(opts, :details)
    }
  end

  @doc """
  Creates an error from an HTTP status code and K8s API response body.

  Maps standard HTTP codes to semantic error types and extracts
  additional context from the K8s Status response format.
  """
  @spec from_status_code(integer(), map() | nil) :: t()
  def from_status_code(status_code, body \\ nil) do
    type = type_from_status(status_code)
    message = extract_message(body)
    reason = extract_reason(body)
    details = extract_details(body)

    %__MODULE__{
      type: type,
      message: message,
      status_code: status_code,
      reason: reason,
      details: details
    }
  end

  @doc """
  Returns whether this error is retryable.

  5xx errors, connection errors, and timeouts are generally retryable.
  4xx client errors are not.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{type: :api_error, status_code: code})
      when is_integer(code) and code >= 500 do
    true
  end

  def retryable?(%__MODULE__{type: :connection_error}), do: true
  def retryable?(%__MODULE__{type: :timeout}), do: true
  def retryable?(%__MODULE__{}), do: false

  # Exception callback
  @impl true
  def message(%__MODULE__{type: type, message: nil}) do
    type_to_string(type)
  end

  def message(%__MODULE__{type: type, message: msg}) do
    "#{type_to_string(type)}: #{msg}"
  end

  # Private helpers

  defp type_from_status(401), do: :auth_failed
  defp type_from_status(403), do: :forbidden
  defp type_from_status(404), do: :not_found
  defp type_from_status(409), do: :conflict
  defp type_from_status(422), do: :validation_error
  defp type_from_status(code) when code >= 400 and code < 500, do: :api_error
  defp type_from_status(code) when code >= 500, do: :api_error
  defp type_from_status(_), do: :api_error

  defp extract_message(nil), do: nil
  defp extract_message(%{"message" => msg}), do: msg
  defp extract_message(_), do: nil

  defp extract_reason(nil), do: nil
  defp extract_reason(%{"reason" => reason}), do: reason
  defp extract_reason(_), do: nil

  defp extract_details(nil), do: nil
  defp extract_details(%{"details" => details}), do: details
  defp extract_details(_), do: nil

  defp type_to_string(:auth_failed), do: "Authentication failed"
  defp type_to_string(:forbidden), do: "Forbidden"
  defp type_to_string(:not_found), do: "Not found"
  defp type_to_string(:conflict), do: "Conflict"
  defp type_to_string(:validation_error), do: "Validation error"
  defp type_to_string(:timeout), do: "Timeout"
  defp type_to_string(:api_error), do: "API error"
  defp type_to_string(:connection_error), do: "Connection error"
end
