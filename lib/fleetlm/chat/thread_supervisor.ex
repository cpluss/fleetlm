defmodule Fleetlm.Chat.ThreadSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Fleetlm.Chat.ThreadServer

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_thread(thread_id) do
    child_spec = ThreadServer.child_spec(thread_id)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
