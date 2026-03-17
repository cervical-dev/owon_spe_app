defmodule Ui.PsuTelemetry do
  use GenServer
  alias Phoenix.PubSub
  require Logger

  @interval 1000

  def start_link(psu_pid) do
    GenServer.start_link(__MODULE__, psu_pid)
  end

  @impl GenServer
  def init(psu_pid) do
    Logger.debug("Broadcaster started")
    Process.send_after(self(), :poll_and_broadcast, 1000)
    {:ok, %{psu_pid: psu_pid, retries: 0}}
  end

  @impl GenServer
  def handle_info(:poll_and_broadcast, state) do
    Process.send_after(self(), :poll_and_broadcast, @interval)

    if OwonSpeInterface.connected?(state.psu_pid) do
      with {:ok, info} <- OwonSpeInterface.id(state.psu_pid),
           {:ok, output} <- OwonSpeInterface.get_output(state.psu_pid),
           {:ok, v} <- OwonSpeInterface.get_voltage(state.psu_pid),
           {:ok, v_lim} <- OwonSpeInterface.get_voltage_lim(state.psu_pid),
           {:ok, i} <- OwonSpeInterface.get_current(state.psu_pid),
           {:ok, i_lim} <- OwonSpeInterface.get_current_lim(state.psu_pid),
           {:ok, [v_meas, i_meas]} <-
             OwonSpeInterface.measure_all(state.psu_pid) do
        mode = if OwonSpeInterface.remote?(state.psu_pid), do: :remote, else: :local

        broadcast(state.psu_pid,
          info: info,
          connected: true,
          mode: mode,
          output: output,
          v: v,
          v_lim: v_lim,
          i: i,
          i_lim: i_lim,
          v_meas: v_meas,
          i_meas: i_meas
        )

        {:noreply, %{state | retries: 0}}
      else
        _ ->
          if state.retries > 5 do
            broadcast_connection_lost(state.psu_pid)
            broadcast(state.psu_pid, connected: false)
            Ui.PsuSupervisor.disconnect(state.psu_pid)
            DynamicSupervisor.terminate_child(Ui.PsuTelemetrySupervisor, self())
          end

          {:noreply, %{state | retries: state.retries + 1}}
      end
    else
      broadcast(state.psu_pid, connected: false)
      {:noreply, state}
    end
  end

  defp broadcast(port, data) do
    Logger.debug("broadcasting #{inspect(data)}")
    PubSub.broadcast(Ui.PubSub, port |> Atom.to_string(), {:psu_data, data})
  end

  defp broadcast_connection_lost(port) do
    PubSub.broadcast(Ui.PubSub, port |> Atom.to_string(), :connection_lost)
  end

  def subscribe(port) do
    PubSub.subscribe(Ui.PubSub, port)
  end

  def telemetry_process_name(port) do
    :"#{port}_telemetry"
  end

  def start_telemetry(port) do
    DynamicSupervisor.start_child(Ui.PsuTelemetrySupervisor, %{
      id: telemetry_process_name(port),
      start:
        {GenServer, :start_link, [__MODULE__, :"#{port}", [name: telemetry_process_name(port)]]}
    })
  end

  def stop_telemetry(port) do
    DynamicSupervisor.terminate_child(Ui.PsuTelemetrySupervisor, telemetry_process_name(port))
  end
end
