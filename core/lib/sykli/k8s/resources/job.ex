defmodule Sykli.K8s.Resources.Job do
  @moduledoc """
  Kubernetes Job resource operations.

  Provides high-level operations for creating, monitoring, and
  cleaning up batch/v1 Jobs.
  """

  alias Sykli.K8s.Client
  alias Sykli.K8s.Error

  @default_poll_interval 1000
  @default_timeout 300_000

  @doc """
  Creates a Job from a manifest.

  ## Parameters
    * `manifest` - Job manifest map
    * `config` - K8s auth config
    * `opts` - Options (`:client` for testing)

  ## Returns
    * `{:ok, job}` - Created job
    * `{:error, %Error{}}` - Error (e.g., :conflict if exists)
  """
  @spec create(map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create(manifest, config, opts \\ []) do
    client = Keyword.get(opts, :client, &do_client_request/5)
    namespace = get_in(manifest, ["metadata", "namespace"]) || config[:namespace] || "default"
    path = "/apis/batch/v1/namespaces/#{namespace}/jobs"

    client.(:post, path, manifest, config, opts)
  end

  @doc """
  Gets a Job by name and namespace.
  """
  @spec get(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(name, namespace, config, opts \\ []) do
    client = Keyword.get(opts, :client, &do_client_request/5)
    path = "/apis/batch/v1/namespaces/#{namespace}/jobs/#{name}"

    client.(:get, path, nil, config, opts)
  end

  @doc """
  Deletes a Job.

  ## Options
    * `:propagation` - Deletion propagation policy (:background, :foreground, :orphan)
  """
  @spec delete(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete(name, namespace, config, opts \\ []) do
    client = Keyword.get(opts, :client, &do_client_request/5)
    path = "/apis/batch/v1/namespaces/#{namespace}/jobs/#{name}"

    propagation =
      case Keyword.get(opts, :propagation, :background) do
        :background -> "Background"
        :foreground -> "Foreground"
        :orphan -> "Orphan"
      end

    body = %{"propagationPolicy" => propagation}
    client.(:delete, path, body, config, opts)
  end

  @doc """
  Waits for a Job to complete.

  Polls the job status until it succeeds, fails, or times out.

  ## Options
    * `:timeout` - Max wait time in ms (default: 300000)
    * `:poll_interval` - Time between polls in ms (default: 1000)

  ## Returns
    * `{:ok, :succeeded}` - Job completed successfully
    * `{:ok, :failed}` - Job failed
    * `{:error, %Error{type: :timeout}}` - Timed out
    * `{:error, %Error{}}` - Other error
  """
  @spec wait_complete(String.t(), String.t(), map(), keyword()) ::
          {:ok, :succeeded | :failed} | {:error, Error.t()}
  def wait_complete(name, namespace, config, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait(name, namespace, config, opts, poll_interval, deadline)
  end

  @doc """
  Gets logs from a Job's pod.

  Finds the pod created by the job and fetches its logs.

  ## Options
    * `:container` - Container name (for multi-container pods)
    * `:retry_delay` - Delay between retries when pod not ready
    * `:max_retries` - Max retries to find pod
  """
  @spec logs(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, :no_pods | Error.t()}
  def logs(name, namespace, config, opts \\ []) do
    pod_client = Keyword.get(opts, :pod_client, &do_client_request/5)
    container = Keyword.get(opts, :container)
    retry_delay = Keyword.get(opts, :retry_delay, 1000)
    max_retries = Keyword.get(opts, :max_retries, 10)

    find_and_get_logs(name, namespace, config, pod_client, container, retry_delay, max_retries)
  end

  @doc """
  Returns the status of a job.

  ## Returns
    * `:succeeded` - Job completed successfully
    * `:failed` - Job failed
    * `:active` - Job is running
    * `:pending` - Job hasn't started yet
  """
  @spec status(map()) :: :succeeded | :failed | :active | :pending
  def status(job) do
    job_status = job["status"] || %{}

    cond do
      Map.get(job_status, "succeeded", 0) > 0 -> :succeeded
      Map.get(job_status, "failed", 0) > 0 -> :failed
      Map.get(job_status, "active", 0) > 0 -> :active
      true -> :pending
    end
  end

  @doc """
  Builds a Job manifest from options.

  ## Required Options
    * `:image` - Container image
    * `:command` - Command to run
    * `:namespace` - Target namespace

  ## Optional
    * `:labels` - Labels map
    * `:env` - Environment variables map
    * `:volumes` - Volume mounts list
    * `:backoff_limit` - Retry count
    * `:ttl_seconds` - TTL after finished
  """
  @spec build_manifest(String.t(), keyword()) :: map()
  def build_manifest(name, opts) do
    image = Keyword.fetch!(opts, :image)
    command = Keyword.fetch!(opts, :command)
    namespace = Keyword.fetch!(opts, :namespace)

    labels = Keyword.get(opts, :labels, %{})
    env = Keyword.get(opts, :env, %{})
    volumes = Keyword.get(opts, :volumes, [])
    backoff_limit = Keyword.get(opts, :backoff_limit, 0)
    ttl_seconds = Keyword.get(opts, :ttl_seconds)

    env_vars = for {k, v} <- env, do: %{"name" => k, "value" => v}

    {volume_specs, volume_mounts} = build_volumes(volumes)

    container = %{
      "name" => "main",
      "image" => image,
      "command" => command
    }

    container =
      container
      |> then(fn c -> if env_vars != [], do: Map.put(c, "env", env_vars), else: c end)
      |> then(fn c ->
        if volume_mounts != [], do: Map.put(c, "volumeMounts", volume_mounts), else: c
      end)

    spec = %{
      "backoffLimit" => backoff_limit,
      "template" => %{
        "spec" =>
          %{
            "containers" => [container],
            "restartPolicy" => "Never"
          }
          |> then(fn s ->
            if volume_specs != [], do: Map.put(s, "volumes", volume_specs), else: s
          end)
      }
    }

    spec =
      if ttl_seconds do
        Map.put(spec, "ttlSecondsAfterFinished", ttl_seconds)
      else
        spec
      end

    %{
      "apiVersion" => "batch/v1",
      "kind" => "Job",
      "metadata" =>
        %{
          "name" => name,
          "namespace" => namespace
        }
        |> then(fn m -> if labels != %{}, do: Map.put(m, "labels", labels), else: m end),
      "spec" => spec
    }
  end

  # Private helpers

  defp do_wait(name, namespace, config, opts, poll_interval, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, Error.new(:timeout, "Job did not complete within timeout")}
    else
      case get(name, namespace, config, opts) do
        {:ok, job} ->
          case status(job) do
            :succeeded ->
              {:ok, :succeeded}

            :failed ->
              {:ok, :failed}

            _ ->
              Process.sleep(poll_interval)
              do_wait(name, namespace, config, opts, poll_interval, deadline)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp find_and_get_logs(name, namespace, config, pod_client, container, retry_delay, max_retries) do
    do_find_pod(name, namespace, config, pod_client, container, retry_delay, max_retries, 0)
  end

  defp do_find_pod(
         _name,
         _namespace,
         _config,
         _pod_client,
         _container,
         _retry_delay,
         max_retries,
         retries
       )
       when retries >= max_retries do
    {:error, :no_pods}
  end

  defp do_find_pod(
         name,
         namespace,
         config,
         pod_client,
         container,
         retry_delay,
         max_retries,
         retries
       ) do
    # List pods with job-name label
    path = "/api/v1/namespaces/#{namespace}/pods?labelSelector=job-name=#{name}"

    case pod_client.(:get, path, nil, config, []) do
      {:ok, %{"items" => []}} ->
        Process.sleep(retry_delay)

        do_find_pod(
          name,
          namespace,
          config,
          pod_client,
          container,
          retry_delay,
          max_retries,
          retries + 1
        )

      {:ok, %{"items" => [pod | _]}} ->
        pod_name = get_in(pod, ["metadata", "name"])
        get_pod_logs(pod_name, namespace, config, pod_client, container)

      {:error, _} = error ->
        error
    end
  end

  defp get_pod_logs(pod_name, namespace, config, pod_client, container) do
    query = if container, do: "?container=#{container}", else: ""
    path = "/api/v1/namespaces/#{namespace}/pods/#{pod_name}/log#{query}"

    pod_client.(:get, path, nil, config, [])
  end

  defp build_volumes(volumes) do
    Enum.reduce(volumes, {[], []}, fn vol, {specs, mounts} ->
      name = vol[:name]
      host_path = vol[:host_path]
      mount_path = vol[:mount_path]

      spec = %{"name" => name, "hostPath" => %{"path" => host_path}}
      mount = %{"name" => name, "mountPath" => mount_path}

      {[spec | specs], [mount | mounts]}
    end)
    |> then(fn {specs, mounts} -> {Enum.reverse(specs), Enum.reverse(mounts)} end)
  end

  defp do_client_request(method, path, body, config, opts) do
    Client.request(method, path, body, config, opts)
  end
end
