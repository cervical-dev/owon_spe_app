defmodule Ui.PsuSupervisor do
  require Logger

  def connect(port) do
    DynamicSupervisor.start_child(__MODULE__, %{
      id: port,
      start: {GenServer, :start_link, [OwonSpeInterface, nil, [name: :"#{port}"]]}
    })

    OwonSpeInterface.connect(:"#{port}", port: port)
  end

  def disconnect(port) do
    DynamicSupervisor.terminate_child(__MODULE__, Process.whereis(:"#{port}"))
  end

  def active_connections() do
    Supervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> Process.info(pid, :registered_name) end)
  end
end
