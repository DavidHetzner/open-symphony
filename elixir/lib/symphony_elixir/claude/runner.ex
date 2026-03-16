defmodule SymphonyElixir.Claude.Runner do
  @moduledoc """
  Claude Code subprocess management for per-turn CLI invocations.

  Unlike Codex's long-lived JSON-RPC app-server, Claude Code uses per-turn
  subprocesses with `--resume <session_id>` for session continuity.

  Public API mirrors `Codex.AppServer`:
  - `start_session/2` — validates workspace, returns a lightweight session struct.
  - `run_turn/4` — launches a `claude` subprocess, streams events, returns updated session.
  - `stop_session/1` — no-op (subprocess already exited after each turn).
  """

  require Logger
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          worker_host: String.t() | nil,
          session_id: String.t() | nil,
          metadata: map()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_workspace(workspace, worker_host) do
      {:ok, expanded_workspace} ->
        {:ok,
         %{
           workspace: expanded_workspace,
           worker_host: worker_host,
           session_id: nil,
           metadata: %{}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    settings = Config.settings!()

    case start_claude_port(session, prompt, settings) do
      {:ok, port} ->
        metadata = port_metadata(port, session.worker_host)

        emit_message(on_message, :session_started, %{session_id: session.session_id}, metadata)

        Logger.info(
          "Claude session started for #{issue_context(issue)} session_id=#{session.session_id} workspace=#{session.workspace}"
        )

        case receive_loop(port, on_message, settings.codex.turn_timeout_ms, "") do
          {:ok, result_event} ->
            session_id = result_event.session_id || session.session_id
            usage = result_event.usage

            emit_message(
              on_message,
              :turn_completed,
              %{
                payload: result_event.raw,
                raw: Jason.encode!(result_event.raw),
                details: result_event.raw,
                session_id: session_id
              },
              Map.merge(metadata, usage_metadata(usage))
            )

            Logger.info(
              "Claude session completed for #{issue_context(issue)} session_id=#{session_id}"
            )

            {:ok, %{session | session_id: session_id, metadata: metadata}}

          {:error, reason} ->
            Logger.warning(
              "Claude session ended with error for #{issue_context(issue)} session_id=#{session.session_id}: #{inspect(reason)}"
            )

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{session_id: session.session_id, reason: reason},
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, session.metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # --- Subprocess launch ---

  defp start_claude_port(session, prompt, settings) do
    command = build_command(session, prompt, settings)

    case session.worker_host do
      nil -> start_local_port(command, session.workspace)
      worker_host -> start_remote_port(command, session.workspace, worker_host)
    end
  end

  defp build_command(session, prompt, settings) do
    base_command = settings.codex.claude_command
    approval_policy = settings.codex.approval_policy

    args = ["-p", "--output-format", "stream-json"]

    args =
      case session.session_id do
        id when is_binary(id) and id != "" -> args ++ ["--resume", id]
        _ -> args
      end

    args =
      if skip_permissions?(approval_policy) do
        args ++ ["--dangerously-skip-permissions"]
      else
        args
      end

    escaped_prompt = shell_escape(prompt)
    arg_string = Enum.map_join(args, " ", &shell_escape/1)

    "#{base_command} #{arg_string} #{escaped_prompt}"
  end

  defp skip_permissions?(approval_policy) do
    approval_policy == "never" or
      (is_map(approval_policy) and
         Map.get(approval_policy, "reject") == %{
           "sandbox_approval" => true,
           "rules" => true,
           "mcp_elicitations" => true
         })
  end

  defp start_local_port(command, workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_remote_port(command, workspace, worker_host) do
    remote_command = "cd #{shell_escape(workspace)} && #{command}"
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  # --- Receive loop ---

  defp receive_loop(port, on_message, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        {:error, {:port_exit_before_result, 0}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, line, timeout_ms) do
    case StreamParser.parse_line(line) do
      {:ok, %{type: "result", subtype: "success"} = event} ->
        {:ok, event}

      {:ok, %{type: "result", subtype: "error"} = event} ->
        {:error, {:turn_failed, event.error || event.content}}

      {:ok, %{type: "system", subtype: "init"} = event} ->
        emit_message(on_message, :notification, %{
          payload: event.raw,
          raw: Jason.encode!(event.raw)
        })

        receive_loop(port, on_message, timeout_ms, "")

      {:ok, %{type: type} = event}
      when type in ["assistant", "tool_use", "tool_result"] ->
        emit_message(on_message, :notification, %{
          payload: event.raw,
          raw: Jason.encode!(event.raw)
        })

        receive_loop(port, on_message, timeout_ms, "")

      {:ok, event} ->
        emit_message(on_message, :notification, %{
          payload: event.raw,
          raw: Jason.encode!(event.raw)
        })

        receive_loop(port, on_message, timeout_ms, "")

      {:error, :empty_line} ->
        receive_loop(port, on_message, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(line)

        emit_message(on_message, :malformed, %{
          payload: line,
          raw: line
        })

        receive_loop(port, on_message, timeout_ms, "")
    end
  end

  # --- Workspace validation ---

  defp validate_workspace(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  # --- Helpers ---

  defp port_metadata(port, worker_host) when is_port(port) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base, :worker_host, host)
      _ -> base
    end
  end

  defp usage_metadata(nil), do: %{}

  defp usage_metadata(usage) when is_map(usage) do
    %{usage: usage}
  end

  defp emit_message(on_message, event, details, metadata \\ %{}) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
