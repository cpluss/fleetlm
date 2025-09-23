defmodule Fleetlm.Chat.Supervisor do
  @moduledoc """
  Top-level supervisor for chat runtime processes.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {Registry, keys: :unique, name: Fleetlm.Chat.ConversationRegistry},
      {Fleetlm.Chat.ConversationSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
