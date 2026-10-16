defmodule Midgard.Platform.Compiler do
  @moduledoc """
  Compiles trusted-local browser source only inside a restricted Docker container.
  No host-VM compilation fallback exists. An immutable image ID is used for each
  build, and the image's Elixir source commit is checked before execution.
  """
  @image "midgard-elixir-compiler:13299af"
  @source_commit "13299af2b91a6aff7e430f25849f586c02b3231f"
  @timeout 90_000
  @max_log 65_536
  @max_source 65_536
  @sdk Path.expand("../../../../midgard/lib/midgard", __DIR__)
  @files ~w(request.ex protocol.ex worker.ex)

  def compile(slug, source, destination)
      when is_binary(slug) and is_binary(source) and is_binary(destination) and
             byte_size(source) in 1..@max_source do
    with true <- Regex.match?(~r/\A[a-z][a-z0-9_]{0,39}\z/, slug),
         {:ok, image_id} <- image_id(),
         {:ok, uid} <- identity("-u"),
         {:ok, gid} <- identity("-g"),
         :ok <- available_destination(destination) do
      build_root =
        Path.join(System.tmp_dir!(), "midgard-compiler-#{System.unique_integer([:positive])}")

      workspace = Path.join(build_root, "workspace")
      output = Path.join(build_root, "output")

      try do
        File.mkdir_p!(Path.join(workspace, "sdk"))
        File.mkdir_p!(Path.join(output, "modules"))
        File.write!(Path.join(workspace, "worker.ex"), source)

        File.cp!(
          Path.join(Application.app_dir(:midgard_platform, "priv/compiler"), "compile.exs"),
          Path.join(workspace, "compile.exs")
        )

        for file <- @files do
          File.cp!(Path.join(@sdk, file), Path.join(workspace, "sdk/#{file}"))
        end

        name = "midgard-compile-#{System.unique_integer([:positive])}"
        module = "Elixir." <> Macro.camelize(slug)
        args = docker_args(name, workspace, output, uid, gid, image_id, slug, module)

        case run_docker(args, name) do
          {:ok, _log} ->
            # Parse the staged, immutable bytes before publishing them by rename.
            with {:ok, shipment} <- Midgard.Platform.Shipment.read(output),
                 ^module <- shipment.module,
                 :ok <- File.rename(output, destination) do
              {:ok,
               %{path: destination, digest: shipment.digest, modules: length(shipment.modules)}}
            else
              {:error, reason} -> {:error, "compiled shipment rejected: #{inspect(reason)}"}
              _ -> {:error, "compiler emitted the wrong entrypoint"}
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.rm_rf!(build_root)
      end
    else
      false -> {:error, "invalid worker name"}
      {:error, _} = error -> error
    end
  end

  def compile(_, _, _), do: {:error, "source must contain 1..65,536 bytes"}

  defp image_id do
    with executable when is_binary(executable) <- System.find_executable("docker"),
         {output, 0} <-
           System.cmd(
             executable,
             [
               "image",
               "inspect",
               @image,
               "--format",
               "{{index .Config.Labels \"org.midgard.elixir-source\"}} {{.Id}}"
             ],
             stderr_to_stdout: true
           ),
         [@source_commit, "sha256:" <> digest] <- String.split(String.trim(output)),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      {:ok, "sha256:" <> digest}
    else
      _ -> {:error, "pinned compiler image unavailable; run priv/compiler/build-image.sh"}
    end
  end

  defp identity(flag) do
    case System.cmd("id", [flag]) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, "cannot determine local Docker volume owner"}
    end
  end

  defp available_destination(path) do
    case {File.lstat(path), File.lstat(Path.dirname(path))} do
      {{:error, :enoent}, {:ok, %{type: :directory}}} -> :ok
      _ -> {:error, "shipment destination must be a new directory inside an existing directory"}
    end
  end

  defp docker_args(name, workspace, output, uid, gid, image_id, slug, module) do
    [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      name,
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "64",
      "--memory",
      "512m",
      "--cpus",
      "1",
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=64m",
      "--user",
      "#{uid}:#{gid}",
      "-e",
      "HOME=/tmp",
      "--mount",
      "type=bind,src=#{workspace},dst=/workspace,readonly",
      "--mount",
      "type=bind,src=#{output},dst=/output",
      image_id,
      "elixir",
      "/workspace/compile.exs",
      slug,
      module,
      image_id
    ]
  end

  defp run_docker(args, name) do
    docker = System.find_executable("docker")

    port =
      Port.open({:spawn_executable, docker}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    deadline = System.monotonic_time(:millisecond) + @timeout
    result = collect(port, <<>>, deadline)

    # Closing the client on timeout/output overflow does not guarantee that
    # Docker stopped the container. The unique container name lets us reclaim it.
    System.cmd(docker, ["rm", "-f", name], stderr_to_stdout: true)
    result
  end

  defp collect(port, log, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if byte_size(log) + byte_size(chunk) <= @max_log do
          collect(port, log <> chunk, deadline)
        else
          Port.close(port)
          {:error, "compiler output exceeded 64 KiB"}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, log}

      {^port, {:exit_status, _}} ->
        {:error, "compiler failed: #{log |> String.replace_invalid() |> String.slice(0, 8_192)}"}
    after
      remaining ->
        Port.close(port)
        {:error, "compiler timed out after 90 seconds"}
    end
  end
end
