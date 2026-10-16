defmodule Midgard.Platform.BuildInfo do
  @moduledoc """
  Shows the commit whose tracked sources were packaged into the runtime image.
  In development it uses the checkout; an invalid explicit image revision
  never falls back to a potentially unrelated checkout.
  """
  @repository "https://github.com/leostera/midgard"
  @sha ~r/\A[0-9a-f]{40}\z/

  def current_commit(root \\ source_root()) do
    case System.fetch_env("MIDGARD_SOURCE_COMMIT") do
      {:ok, sha} -> if Regex.match?(@sha, sha), do: commit(sha), else: nil
      :error -> checkout_commit(root)
    end
  end

  defp checkout_commit(root) do
    with executable when is_binary(executable) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(executable, ["rev-parse", "--verify", "HEAD"],
             cd: root,
             stderr_to_stdout: true
           ),
         sha = String.trim(output),
         true <- Regex.match?(@sha, sha) do
      commit(sha)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp commit(sha),
    do: %{sha: sha, short: String.slice(sha, 0, 7), url: @repository <> "/commit/" <> sha}

  defp source_root do
    Path.expand("../../../..", Application.app_dir(:midgard_platform))
  end
end
