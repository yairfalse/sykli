defmodule Sykli.Services.RetryService do
  @moduledoc """
  Service for retry logic with exponential backoff.

  Provides a consistent retry mechanism for task execution,
  with configurable retry count and backoff strategy.
  """

  @type retry_opts :: [
          max_attempts: pos_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          jitter: boolean()
        ]

  @default_opts [
    max_attempts: 1,
    base_delay_ms: 1000,
    max_delay_ms: 30_000,
    jitter: true
  ]

  @doc """
  Execute a function with retry logic.

  The function should return `:ok` on success or `{:error, reason}` on failure.
  Retries are performed with exponential backoff.

  ## Options

    * `:max_attempts` - Maximum number of attempts (default: 1, meaning no retries)
    * `:base_delay_ms` - Initial delay between retries in ms (default: 1000)
    * `:max_delay_ms` - Maximum delay between retries in ms (default: 30000)
    * `:jitter` - Add random jitter to delay (default: true)

  ## Example

      RetryService.with_retry(fn -> run_task(task) end, max_attempts: 3)

  """
  @spec with_retry((-> :ok | {:error, term()}), retry_opts()) ::
          :ok | {:error, term()}
  def with_retry(fun, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    max_attempts = opts[:max_attempts]
    do_retry(fun, 1, max_attempts, opts)
  end

  @doc """
  Execute a function with retry, passing attempt number to the function.

  Similar to `with_retry/2` but the function receives the current attempt number.

  ## Example

      RetryService.with_retry_attempt(fn attempt ->
        IO.puts("Attempt \#{attempt}")
        run_task(task)
      end, max_attempts: 3)

  """
  @spec with_retry_attempt(
          (attempt :: pos_integer() -> :ok | {:error, term()}),
          retry_opts()
        ) :: :ok | {:error, term()}
  def with_retry_attempt(fun, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    max_attempts = opts[:max_attempts]
    do_retry_with_attempt(fun, 1, max_attempts, opts)
  end

  @doc """
  Calculate the delay for a given attempt using exponential backoff.

  Returns delay in milliseconds.
  """
  @spec calculate_delay(pos_integer(), retry_opts()) :: non_neg_integer()
  def calculate_delay(attempt, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    base = opts[:base_delay_ms]
    max = opts[:max_delay_ms]
    jitter = opts[:jitter]

    # Exponential backoff: base * 2^(attempt-1)
    delay = (base * :math.pow(2, attempt - 1)) |> round()
    delay = min(delay, max)

    # Add jitter if enabled (0-50% of delay)
    if jitter do
      jitter_amount = :rand.uniform(delay) |> div(2)
      delay + jitter_amount
    else
      delay
    end
  end

  # Private implementation

  defp do_retry(fun, attempt, max_attempts, opts) do
    case fun.() do
      :ok ->
        :ok

      {:error, _reason} when attempt < max_attempts ->
        delay = calculate_delay(attempt, opts)
        Process.sleep(delay)
        do_retry(fun, attempt + 1, max_attempts, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_retry_with_attempt(fun, attempt, max_attempts, opts) do
    case fun.(attempt) do
      :ok ->
        :ok

      {:error, _reason} when attempt < max_attempts ->
        delay = calculate_delay(attempt, opts)
        Process.sleep(delay)
        do_retry_with_attempt(fun, attempt + 1, max_attempts, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
