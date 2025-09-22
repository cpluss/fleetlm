defmodule Fleetlm.Chat.DmKey do
  @moduledoc """
  We use deterministic direct messaging keys to identify conversations between two participants. This
  allows us to recognise the conversation regardless of who messages who.

  DM keys are normalized identifiers that encode the two participants in a
  direct conversation. They have the format "type_a:id_a:type_b:id_b" with
  lexicographical ordering enforced so the same pair always yields the same key.
  """

  @type participant_id :: String.t()
  @type t :: %__MODULE__{key: String.t(), first: participant_id(), second: participant_id()}

  defstruct [:key, :first, :second]

  @doc """
  Build a dm_key from two participant identifiers.
  """
  @spec build(participant_id(), participant_id()) :: String.t()
  def build(participant_a, participant_b)
      when is_binary(participant_a) and is_binary(participant_b) do
    participants = Enum.sort([participant_a, participant_b])

    case participants do
      [first, second] -> "#{first}:#{second}"
      _ -> raise ArgumentError, "must provide two participants"
    end
  end

  @doc """
  Parse a dm_key, returning structured participant information.
  """
  @spec parse!(String.t()) :: t()
  def parse!(dm_key) when is_binary(dm_key) do
    case String.split(dm_key, ":") do
      [first_type, first_id, second_type, second_id] ->
        first = "#{first_type}:#{first_id}"
        second = "#{second_type}:#{second_id}"
        normalized = build(first, second)

        %__MODULE__{key: normalized, first: first, second: second}

      _ ->
        raise ArgumentError, "invalid dm_key format: #{dm_key}"
    end
  end

  @doc """
  Ensure a participant is part of the dm_key.
  """
  @spec includes?(t(), participant_id()) :: boolean()
  def includes?(%__MODULE__{first: first, second: second}, participant_id)
      when is_binary(participant_id) do
    participant_id in [first, second]
  end

  @doc """
  Given a participant, return the other participant in the dm.
  Raises if the participant is not part of the dm key.
  """
  @spec other_participant(t(), participant_id()) :: participant_id()
  def other_participant(%__MODULE__{} = dm_key, participant_id) do
    cond do
      dm_key.first == participant_id -> dm_key.second
      dm_key.second == participant_id -> dm_key.first
      true -> raise ArgumentError, "participant #{participant_id} is not part of dm #{dm_key.key}"
    end
  end
end
