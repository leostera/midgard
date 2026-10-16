defmodule Midgard.Platform.BuildInfo do
  @moduledoc """
  The local dashboard points at the checkout's current Git commit. No commit
  link is shown when the application is run outside its source repository.
  """
  @repository "https://github.com/leostera/midgard"
  @sha ~r/\A[0-9a-f]{40}\z/

  def current_commit(root \\ source_root()) do
    with executable when is_binary(executable) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(executable, ["rev-parse", "--verify", "HEAD"],
             cd: root,
             stderr_to_stdout: true
           ),
         sha = String.trim(output),
         true <- Regex.match?(@sha, sha) do
      %{sha: sha, short: String.slice(sha, 0, 7), url: @repository <> "/commit/" <> sha}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp source_root do
    Path.expand("../../../..", Application.app_dir(:midgard_platform))
  end
end
