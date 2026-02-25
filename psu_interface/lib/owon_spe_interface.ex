defmodule OwonSpeInterface do
  @moduledoc """
  A non-blocking interface for the Owon SPE Power Supply.
  """
  use GenServer
  require Logger
  alias Circuits.UART

  @uart_default_config [
    speed: 115_200,
    active: true,
    framing: {UART.Framing.Line, separator: "\r"}
  ]
  @nil_state %{
    uart: nil,
    port: nil,
    pending_cmd: nil,
    pending_caller: nil,
    timer_ref: nil,
    remote: false
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def enumerate() do
    UART.enumerate() |> Enum.filter(fn {_k, v} -> v != %{} end) |> Enum.into(%{})
  end

  def connect(pid, opts \\ []) do
    GenServer.call(pid, {:connect, opts}, 10000)
  end

  def connected?(pid) do
    GenServer.call(pid, :connected?)
  end

  def disconnect(pid) do
    GenServer.call(pid, :disconnect)
  end

  def id(pid) do
    GenServer.call(pid, :id)
  end

  def local(pid) do
    GenServer.cast(pid, :local)
  end

  def remote(pid) do
    GenServer.cast(pid, :remote)
  end

  def remote?(pid) do
    GenServer.call(pid, :remote?)
  end

  @doc "Requests the current voltage. Returns {:ok, float} or {:error, reason}."
  def measure_voltage(pid) do
    # 2-second timeout
    GenServer.call(pid, :measure_voltage, 2000)
  end

  @doc "Sets the output state"
  def get_output(pid) do
    GenServer.call(pid, :output?)
  end

  @doc "Sets the output state"
  def set_output(pid, state) when state in [:on, :off] do
    GenServer.cast(pid, {:set_output, state})
  end

  def get_voltage(pid) do
    GenServer.call(pid, :volt?)
  end

  def set_voltage(pid, v) do
    GenServer.cast(pid, {:volt, v})
  end

  def get_voltage_lim(pid) do
    GenServer.call(pid, :volt_lim?)
  end

  def set_voltage_lim(pid, v) do
    GenServer.cast(pid, {:volt_lim, v})
  end

  def get_current(pid) do
    GenServer.call(pid, :curr?)
  end

  def set_current(pid, c) do
    GenServer.cast(pid, {:curr, c})
  end

  def get_current_lim(pid) do
    GenServer.call(pid, :curr_lim?)
  end

  def set_current_lim(pid, c) do
    GenServer.cast(pid, {:curr_lim, c})
  end

  def measure_all(pid) do
    GenServer.call(pid, :measure_all)
  end

  # Server Callbacks

  @impl GenServer
  def init(_opts) do
    Logger.info("interface started, #{inspect(self())}")
    {:ok, @nil_state}
  end

  @impl GenServer
  def handle_call({:connect, opts}, _from, %{uart: nil, port: nil} = state) do
    port_name = Keyword.get(opts, :port, "ttyUSB0")
    {:ok, uart_pid} = UART.start_link()
    Logger.info("Owon SPE Interface Server started on #{port_name}")

    with :ok <-
           UART.open(uart_pid, port_name, @uart_default_config),
         :ok <- test_connection(uart_pid),
         cmd_write(:remote, uart_pid) do
      Logger.info("Connected to UART device")

      {:reply, :ok, %{state | uart: uart_pid, port: port_name, remote: true}}
    else
      e ->
        UART.close(uart_pid)
        UART.stop(uart_pid)
        Logger.info("Owon SPE Interface Server stopped")
        {:reply, e, %{state | uart: nil, port: nil}}
    end
  end

  @impl GenServer
  def handle_call(:connected?, _from, %{uart: uart_pid} = state) do
    {:reply, nil != uart_pid, state}
  end

  @impl GenServer
  def handle_call(:disconnect, _from, %{uart: nil} = _state) do
    {:reply, :ok, @nil_state}
  end

  @impl GenServer
  def handle_call(:remote?, _from, state) do
    {:reply, state.remote, state}
  end

  @impl GenServer
  def handle_call(:disconnect, _from, %{uart: uart_pid} = _state) do
    UART.close(uart_pid)
    UART.stop(uart_pid)
    Logger.info("Owon SPE Interface Server stopped")
    {:reply, :ok, @nil_state}
  end

  @impl GenServer
  def handle_call(cmd, from, %{pending_caller: nil} = state) do
    with :ok <- cmd_write(cmd, state.uart) do
      # reply later for backpressure.
      timer_ref = Process.send_after(self(), :hardware_timeout, 500)

      {:noreply, %{state | pending_cmd: cmd, pending_caller: from, timer_ref: timer_ref}}
    else
      e -> {:reply, e, state}
    end
  end

  # Backpressure: If a client asks for voltage while we are already waiting for the hardware
  @impl GenServer
  def handle_call(_cmd, _from, %{pending_caller: caller} = state)
      when not is_nil(caller) do
    {:reply, {:error, :hardware_busy}, state}
  end

  @impl GenServer
  def handle_cast(cmd, %{pending_caller: caller} = state)
      when not is_nil(caller) do
    GenServer.cast(self(), cmd)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(cmd, state) do
    cmd_write(cmd, state.uart)

    {:noreply,
     state
     |> then(fn s ->
       # track remote state
       case cmd do
         :remote ->
           %{s | remote: true}

         :local ->
           %{s | remote: false}

         _ ->
           s
       end
     end)}
  end

  @impl GenServer
  def handle_info(
        {:circuits_uart, _port, data},
        %{pending_caller: caller, timer_ref: timer_ref} = state
      )
      when not is_nil(caller) do
    # Logger.debug("Response: #{String.trim(data)}")

    if timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    GenServer.reply(caller, parse_response(state.pending_cmd, data))

    {:noreply, %{state | pending_cmd: nil, pending_caller: nil, timer_ref: nil}}
  end

  @impl GenServer
  def handle_info(:hardware_timeout, %{pending_caller: caller} = state) do
    if caller do
      Logger.warning("Hardware failed to respond in time!")
      GenServer.reply(caller, {:error, :hardware_timeout})
    end

    {:noreply, %{state | pending_caller: nil, timer_ref: nil}}
  end

  def handle_info({:circuits_uart, _port, data}, state) do
    Logger.warning("Received unsolicited data from PSU: #{inspect(data)}")
    {:noreply, state}
  end

  defp cmd_write(cmd, uart_pid) do
    with {:ok, scpi} <- to_scpi(cmd),
         # Logger.debug("Sending: #{scpi}"),
         :ok <- UART.write(uart_pid, scpi) do
      :ok
    end
  end

  defp to_scpi(cmd) do
    case cmd do
      :id ->
        "*IDN?"

      :reset ->
        "*RST"

      :measure_volt ->
        "MEAS:VOLT?"

      :measure_curr ->
        "MEAS:CURR?"

      :measure_pow ->
        "MEAS:POW?"

      :measure_all ->
        "MEAS:ALL?"

      :output? ->
        "OUTP?"

      {:set_output, :on} ->
        "OUTP 1"

      {:set_output, :off} ->
        "OUTP 0"

      {:volt, volt} ->
        "VOLT #{:erlang.float(volt) |> :erlang.float_to_binary(decimals: 3)}"

      {:volt_lim, volt} ->
        "VOLT:LIM #{:erlang.float(volt) |> :erlang.float_to_binary(decimals: 3)}"

      {:curr, curr} ->
        "CURR #{:erlang.float(curr) |> :erlang.float_to_binary(decimals: 3)}"

      {:curr_lim, curr} ->
        "CURR:LIM #{:erlang.float(curr) |> :erlang.float_to_binary(decimals: 3)}"

      :volt? ->
        "VOLT?"

      :curr? ->
        "CURR?"

      :volt_lim? ->
        "VOLT:LIM?"

      :curr_lim? ->
        "CURR:LIM?"

      :local ->
        "SYST:LOC"

      :remote ->
        "SYST:REM"

      _ ->
        {:error, :unkown_command}
    end
    |> case do
      # wrap response in {:ok, scpi} tuple
      scpi when is_binary(scpi) -> {:ok, scpi}
      e -> e
    end
  end

  defp parse_response(cmd, resp) do
    case cmd do
      :id ->
        [brand, model, id, firmware_version] = String.trim(resp) |> String.split(",")

        {:ok,
         %{
           brand: brand,
           model: model,
           id: id,
           firmware_version: String.split(firmware_version, ":") |> Enum.at(1)
         }}

      :output? ->
        case String.trim(resp) do
          "ON" ->
            {:ok, :on}

          "OFF" ->
            {:ok, :off}

          e ->
            Logger.error("Invalid format: #{inspect(e)}")
            {:error, :invalid_format}
        end

      :measure_all ->
        with [resp_v, resp_i] <- String.split(resp, ","),
             {:ok, v_meas} <- parse_scpi_float(resp_v),
             {:ok, i_meas} <- parse_scpi_float(resp_i) do
          {:ok, [v_meas, i_meas]}
        end

      _ ->
        parse_scpi_float(resp)
    end
  end

  defp parse_scpi_float(raw_string) do
    case Float.parse(String.trim(raw_string)) do
      {float, _rest} ->
        {:ok, float}

      :error ->
        Logger.error("Invalid float format: #{raw_string}")
        {:error, :invalid_format}
    end
  end

  defp test_connection(uart_pid) do
    Logger.debug("Testing connection")

    with :ok <- UART.configure(uart_pid, Keyword.merge(@uart_default_config, active: false)),
         :ok <- cmd_write(:id, uart_pid),
         {:ok, r} <- UART.read(uart_pid, 2000),
         # Logger.debug("Response: #{inspect(r)}"),
         :ok <- UART.configure(uart_pid, @uart_default_config) do
      if r != "", do: :ok, else: {:error, :connection_test_failed}
    end
  end
end
