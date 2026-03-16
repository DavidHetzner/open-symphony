defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses line-delimited JSON from `claude -p --output-format stream-json`.

  Claude stream-json format emits one JSON object per line:

      {"type":"system","subtype":"init","session_id":"...","tools":[...]}
      {"type":"assistant","subtype":"thinking","content":"..."}
      {"type":"assistant","subtype":"text","content":"..."}
      {"type":"tool_use","tool":"Read","input":{...}}
      {"type":"tool_result","tool":"Read","content":"..."}
      {"type":"result","subtype":"success","result":"...","session_id":"...","usage":{...}}
      {"type":"result","subtype":"error","error":"..."}
  """

  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:error, :empty_line}
    else
      case Jason.decode(trimmed) do
        {:ok, %{"type" => type} = parsed} ->
          {:ok, normalize_event(type, parsed)}

        {:ok, _other} ->
          {:error, {:missing_type, trimmed}}

        {:error, reason} ->
          {:error, {:json_decode_error, reason}}
      end
    end
  end

  defp normalize_event(type, parsed) do
    %{
      type: type,
      subtype: Map.get(parsed, "subtype"),
      session_id: Map.get(parsed, "session_id"),
      content: Map.get(parsed, "content") || Map.get(parsed, "result"),
      usage: normalize_usage(Map.get(parsed, "usage")),
      error: Map.get(parsed, "error"),
      raw: parsed
    }
  end

  defp normalize_usage(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and is_integer(output) do
    total = Map.get(usage, "total_tokens", input + output)

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => total
    }
  end

  defp normalize_usage(_usage), do: nil
end
