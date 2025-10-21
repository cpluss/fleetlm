defmodule Fleetlm.Webhook.Job do
  @moduledoc """
  Generic webhook job execution.

  Jobs can be:
  - :message - Send messages to agent, stream responses back
  - :compact - Send history to compaction endpoint, get summary

  Both have same shape: POST → stream JSONL → persist results
  """

  @type job_type :: :message | :compact
  @type t :: %{
          type: job_type(),
          session_id: String.t(),
          webhook_url: String.t(),
          payload: map(),
          context: map()
        }

  @doc """
  Execute a webhook job.
  """
  @callback execute(job :: t()) :: :ok | {:error, term()}
end
