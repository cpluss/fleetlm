defmodule Fleetlm.Agent.StreamAssembler do
  @moduledoc """
  Minimal state machine for AI SDK UI chunk streams. It accumulates structured
  parts, tracks open segments, and emits actions describing lifecycle events.

  This module is intentionally pure: it never persists or broadcasts, it just
  mutates internal state and surfaces actions for callers to interpret.
  """

  alias __MODULE__.State

  @type chunk :: map()

  @type action ::
          {:chunk, chunk()}
          | {:finalize, map(), %{termination: :finish | :abort, finish_chunk: chunk() | nil}}
          | {:abort, chunk()}

  @type ingest_result ::
          {:ok, State.t(), [action()]}
          | {:error, term(), State.t(), [action()]}

  @text_family %{
    start: "text-start",
    delta: "text-delta",
    finish: "text-end",
    part_type: "text"
  }

  @reasoning_family %{
    start: "reasoning-start",
    delta: "reasoning-delta",
    finish: "reasoning-end",
    part_type: "reasoning"
  }

  @tool_events [
    "tool-input-start",
    "tool-input-delta",
    "tool-input-available",
    "tool-input-error",
    "tool-output-available",
    "tool-output-error",
    "tool-approval-request",
    "tool-output-denied"
  ]

  defmodule State do
    @moduledoc false

    # `open_streams` keeps track of text/reasoning segments that are still
    # accumulating deltas; `tool_state` serves the same purpose for tool
    # invocations (it stores the part index plus any JSON buffer we need while
    # arguments stream in). Both maps let us modify parts in O(1) without
    # walking the list of accumulated parts for every chunk.
    defstruct role: "assistant",
              message_id: nil,
              metadata: %{},
              parts: [],
              open_streams: %{},
              tool_state: %{},
              terminated: nil

    @type t :: %__MODULE__{
            role: String.t(),
            message_id: String.t() | nil,
            metadata: map(),
            parts: [map()],
            open_streams: %{
              optional(String.t()) => %{index: non_neg_integer(), family: :text | :reasoning}
            },
            tool_state: %{
              optional(String.t()) => %{
                index: non_neg_integer(),
                buffer: String.t(),
                dynamic?: boolean()
              }
            },
            terminated: :finish | :abort | nil
          }
  end

  @spec new(keyword()) :: State.t()
  def new(opts \\ []) do
    role = Keyword.get(opts, :role, "assistant")
    message_id = Keyword.get(opts, :message_id)

    %State{role: role, message_id: message_id}
  end

  @spec ingest(State.t(), chunk()) :: ingest_result()
  def ingest(%State{terminated: term} = state, _chunk) when term in [:finish, :abort],
    do: {:ok, state, []}

  def ingest(state, %{"type" => type} = chunk) do
    cond do
      text_chunk?(type) -> handle_part_stream(state, chunk, @text_family)
      reasoning_chunk?(type) -> handle_part_stream(state, chunk, @reasoning_family)
      type in @tool_events -> handle_tool_event(state, chunk)
      lifecycle_chunk?(type) -> handle_lifecycle(state, chunk)
      data_chunk?(type) -> handle_data_chunk(state, chunk)
      simple_append_chunk?(type) -> handle_simple_append(state, chunk)
      true -> {:ok, state, [{:chunk, chunk}]}
    end
  rescue
    error ->
      {:error, error, state, [{:chunk, chunk}]}
  end

  def ingest(state, chunk), do: {:error, :missing_type, state, [{:chunk, chunk}]}

  ## Families -----------------------------------------------------------------

  defp handle_part_stream(state, chunk, family) do
    id = Map.get(chunk, "id")

    {state, index} = ensure_part_stream(state, id, family)

    state =
      case chunk["type"] do
        type when type == family.start ->
          update_part(state, index, fn part ->
            part
            |> merge_chunk(chunk, ["type", "id"])
          end)

        type when type == family.delta ->
          append_delta(state, index, chunk, family.part_type)

        type when type == family.finish ->
          finalize_part(state, index, chunk, family.part_type, id)
      end

    {:ok, state, [{:chunk, chunk}]}
  end

  defp ensure_part_stream(state, nil, _family), do: {state, nil}

  defp ensure_part_stream(state, id, family) do
    case Map.fetch(state.open_streams, id) do
      {:ok, %{index: index}} -> {state, index}
      :error -> allocate_part(state, id, family)
    end
  end

  defp allocate_part(state, id, %{part_type: type}) do
    part =
      case type do
        "text" -> %{"type" => "text", "text" => "", "state" => "streaming"}
        "reasoning" -> %{"type" => "reasoning", "text" => "", "state" => "streaming"}
      end

    {state, index} = append_part(state, part)
    open = Map.put(state.open_streams, id, %{index: index, family: family_key(type)})
    {%State{state | open_streams: open}, index}
  end

  defp append_delta(state, nil, _chunk, _type), do: state

  defp append_delta(state, index, chunk, type) do
    update_part(state, index, fn part ->
      delta = Map.get(chunk, "delta", "")

      part
      |> Map.update("text", delta, &(&1 <> delta))
      |> maybe_put("providerMetadata", chunk["providerMetadata"])
      |> maybe_put("state", (type == "text" or type == "reasoning") && "streaming")
    end)
  end

  defp finalize_part(state, nil, _chunk, _type, _id), do: state

  defp finalize_part(state, index, chunk, _type, id) do
    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", "done")
        |> maybe_put("providerMetadata", chunk["providerMetadata"])
      end)

    open = Map.delete(state.open_streams, id)
    %State{state | open_streams: open}
  end

  defp family_key("text"), do: :text
  defp family_key("reasoning"), do: :reasoning

  ## Tool handling -------------------------------------------------------------

  defp handle_tool_event(state, chunk) do
    tool_call_id = chunk["toolCallId"]
    tool_name = chunk["toolName"]

    {state, index} = ensure_tool_part(state, tool_call_id, tool_name, chunk)

    tool_state =
      Map.get(state.tool_state, tool_call_id, %{
        index: index,
        buffer: "",
        dynamic?: chunk["dynamic"] || false
      })

    {state, tool_state} =
      case chunk["type"] do
        "tool-input-start" ->
          handle_tool_start(state, tool_state, index, chunk)

        "tool-input-delta" ->
          handle_tool_delta(state, tool_state, index, chunk)

        "tool-input-available" ->
          handle_tool_state_transition(state, tool_state, index, chunk, "input-available")

        "tool-input-error" ->
          handle_tool_state_transition(state, tool_state, index, chunk, "output-error")

        "tool-output-available" ->
          handle_tool_state_transition(state, tool_state, index, chunk, "output-available")

        "tool-output-error" ->
          handle_tool_state_transition(state, tool_state, index, chunk, "output-error")

        "tool-approval-request" ->
          handle_tool_approval(state, tool_state, index, chunk)

        "tool-output-denied" ->
          handle_tool_denied(state, tool_state, index, chunk)
      end

    tool_state_map =
      case chunk["type"] do
        type
        when type in [
               "tool-input-available",
               "tool-input-error",
               "tool-output-available",
               "tool-output-error"
             ] ->
          Map.delete(state.tool_state, tool_call_id)

        "tool-input-delta" ->
          Map.put(state.tool_state, tool_call_id, tool_state)

        "tool-input-start" ->
          Map.put(state.tool_state, tool_call_id, tool_state)

        _ ->
          state.tool_state
      end

    # We persist the updated scratch map so the next chunk for this tool call
    # can pick up where we left off (or clear it entirely if the tool has
    # finished streaming results).
    state = %State{state | tool_state: tool_state_map}

    {:ok, state, [{:chunk, chunk}]}
  end

  defp ensure_tool_part(state, tool_call_id, tool_name, chunk) do
    case find_part_index(state.parts, fn part -> part["toolCallId"] == tool_call_id end) do
      {:ok, index} -> {state, index}
      :error -> allocate_tool_part(state, tool_call_id, tool_name, chunk)
    end
  end

  defp allocate_tool_part(state, tool_call_id, tool_name, chunk) do
    dynamic? = chunk["dynamic"] || false
    part_type = if dynamic?, do: "dynamic-tool", else: "tool-#{tool_name}"

    part =
      %{"type" => part_type, "toolCallId" => tool_call_id, "state" => "input-streaming"}
      |> merge_chunk(chunk, ["type", "dynamic", "inputTextDelta"])
      |> maybe_put("toolName", tool_name)
      |> maybe_put("providerExecuted", chunk["providerExecuted"])

    {state, index} = append_part(state, part)
    {state, index}
  end

  defp handle_tool_start(state, tool_state, index, chunk) do
    dynamic? = chunk["dynamic"] || tool_state.dynamic?

    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", "input-streaming")
        |> Map.put("input", nil)
        |> maybe_put("toolName", chunk["toolName"])
        |> maybe_put("providerExecuted", chunk["providerExecuted"])
        |> merge_chunk(chunk, ["type", "dynamic", "inputTextDelta"])
      end)

    {state, %{tool_state | buffer: "", dynamic?: dynamic?}}
  end

  defp handle_tool_delta(state, tool_state, index, chunk) do
    buffer = tool_state.buffer <> (chunk["inputTextDelta"] || "")
    input = decode_partial_json(buffer)

    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", "input-streaming")
        |> maybe_put("input", input)
      end)

    {state, %{tool_state | buffer: buffer}}
  end

  defp handle_tool_state_transition(state, tool_state, index, chunk, new_state) do
    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", new_state)
        |> merge_chunk(chunk, ["type"])
      end)

    {state, %{tool_state | buffer: ""}}
  end

  defp handle_tool_approval(state, tool_state, index, chunk) do
    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", "approval-requested")
        |> Map.put("approval", %{"id" => chunk["approvalId"]})
      end)

    {state, tool_state}
  end

  defp handle_tool_denied(state, tool_state, index, chunk) do
    state =
      update_part(state, index, fn part ->
        part
        |> Map.put("state", "output-denied")
        |> Map.put("approval", Map.get(part, "approval", %{"id" => chunk["toolCallId"]}))
      end)

    {state, tool_state}
  end

  ## Lifecycle ----------------------------------------------------------------

  defp handle_lifecycle(state, %{"type" => "start"} = chunk) do
    metadata = Map.get(chunk, "messageMetadata")

    state =
      state
      |> maybe_put_message_id(chunk["messageId"])
      |> merge_metadata(metadata)

    {:ok, state, [{:chunk, chunk}]}
  end

  defp handle_lifecycle(state, %{"type" => "message-metadata"} = chunk) do
    {:ok, merge_metadata(state, Map.get(chunk, "messageMetadata")), [{:chunk, chunk}]}
  end

  defp handle_lifecycle(state, %{"type" => "start-step"} = chunk) do
    {state, _} = append_part(state, %{"type" => "step-start"})
    {:ok, state, [{:chunk, chunk}]}
  end

  defp handle_lifecycle(state, %{"type" => "finish-step"} = chunk) do
    {:ok, state, [{:chunk, chunk}]}
  end

  defp handle_lifecycle(state, %{"type" => "finish"} = chunk) do
    state =
      state
      |> merge_metadata(chunk["messageMetadata"])
      |> finalize_open_parts()

    # By this point all open segments have been closed and every part contains
    # its final payload. We hand the assembled message back to the caller and
    # let the dispatcher decide what to do with it.
    message = build_message(state)

    {:ok, %State{state | terminated: :finish},
     [{:chunk, chunk}, {:finalize, message, %{termination: :finish, finish_chunk: chunk}}]}
  end

  defp handle_lifecycle(state, %{"type" => "abort"} = chunk) do
    state = finalize_open_parts(state)
    message = build_message(state)

    actions = [
      {:chunk, chunk},
      {:finalize, message, %{termination: :abort, finish_chunk: chunk}},
      {:abort, chunk}
    ]

    {:ok, %State{state | terminated: :abort}, actions}
  end

  ## Data & attachments -------------------------------------------------------

  defp handle_data_chunk(state, chunk) do
    part_payload = Map.delete(chunk, "transient")
    id = Map.get(part_payload, "id")

    state =
      case find_part_index(state.parts, fn part ->
             part["type"] == part_payload["type"] and part["id"] == id
           end) do
        {:ok, index} ->
          update_part(state, index, fn _ -> part_payload end)

        :error ->
          {state, _} = append_part(state, part_payload)
          state
      end

    {:ok, state, [{:chunk, chunk}]}
  end

  defp handle_simple_append(state, chunk) do
    {state, _} = append_part(state, Map.delete(chunk, "transient"))
    {:ok, state, [{:chunk, chunk}]}
  end

  ## Helpers ------------------------------------------------------------------

  defp append_part(state, part) do
    new_parts = state.parts ++ [part]
    {%State{state | parts: new_parts}, length(new_parts) - 1}
  end

  defp update_part(state, nil, _fun), do: state

  defp update_part(state, index, fun) do
    case Enum.fetch(state.parts, index) do
      {:ok, existing} ->
        updated = fun.(existing)
        new_parts = List.replace_at(state.parts, index, drop_nils(updated))
        %State{state | parts: new_parts}

      :error ->
        state
    end
  end

  defp find_part_index(parts, predicate) do
    case Enum.find_index(parts, predicate) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp finalize_open_parts(state) do
    # Anything still in `open_streams` has not seen its terminating chunk; we
    # still mark the part as done so the persisted payload is well-formed.
    Enum.reduce(state.open_streams, state, fn {id, %{index: index}}, acc ->
      acc
      |> update_part(index, &Map.put(&1, "state", "done"))
      |> delete_open_stream(id)
    end)
  end

  defp build_message(state) do
    message_id = state.message_id || Uniq.UUID.uuid7(:slug)

    %{
      "id" => message_id,
      "role" => state.role,
      "parts" => state.parts,
      "metadata" => state.metadata
    }
  end

  defp merge_metadata(state, nil), do: state

  defp merge_metadata(%State{metadata: metadata} = state, incoming) when is_map(incoming) do
    %State{state | metadata: Map.merge(metadata, incoming)}
  end

  defp maybe_put_message_id(%State{} = state, nil), do: state
  defp maybe_put_message_id(%State{} = state, id), do: %State{state | message_id: id}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp merge_chunk(part, chunk, drop_keys) do
    Map.merge(part, Map.drop(chunk, drop_keys))
  end

  defp decode_partial_json(buffer) do
    case Jason.decode(buffer) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp delete_open_stream(state, id) do
    %State{state | open_streams: Map.delete(state.open_streams, id)}
  end

  defp drop_nils(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_k, nil}, acc -> acc
      {k, v}, acc when is_map(v) -> Map.put(acc, k, drop_nils(v))
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp drop_nils(other), do: other

  defp text_chunk?(type),
    do: type in [@text_family.start, @text_family.delta, @text_family.finish]

  defp reasoning_chunk?(type),
    do: type in [@reasoning_family.start, @reasoning_family.delta, @reasoning_family.finish]

  defp lifecycle_chunk?(type),
    do: type in ["start", "message-metadata", "start-step", "finish-step", "finish", "abort"]

  defp data_chunk?(type), do: String.starts_with?(type, "data-")
  defp simple_append_chunk?(type), do: type in ["file", "source-url", "source-document"]
end
