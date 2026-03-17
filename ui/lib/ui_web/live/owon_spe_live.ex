defmodule UiWeb.OwonSpeLive do
  require Logger
  use UiWeb, :live_view
  alias VegaLite, as: Vl

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="gap-4 p-4 rounded-lg mb-6 border">
        <%= if length(@ports) > 0 do %>
          <div class="flex items-center">
            <span class={"h-3 w-3 rounded-full mr-2 #{if @connected, do: "bg-green-500", else: "bg-red-500"}"}>
            </span>
            {if @connected, do: "Online", else: "Offline"}
          </div>
          <form phx-submit={if @connected, do: "disconnect", else: "connect"}>
            <.input field={@form_port[:port]} type="select" options={@ports} />
            <.button>
              {if @connected, do: "Disconnect", else: "Connect"}
            </.button>
          </form>
        <% else %>
          No devices found
        <% end %>
      </div>

      <%= if @connected do %>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="p-6 rounded-lg border font-mono text-sm">
            <form class="flex flex-col gap-2" phx-change="update_settings">
              <h2 class="text-lg font-semibold">Output Controls</h2>
              <div class="flex flex-col border-l-1 gap-1 font-mono text-xs mb-2 pl-2">
                <p><label>Brand:</label> {@brand}</p>
                <p><label>Model:</label> {@model}</p>
                <p><label>ID:</label> {@id}</p>
                <p><label>Firmware version:</label> {@firmware_version}</p>
              </div>
              <div class="flex mb-4">
                <label class="block text-sm font-medium mr-4">Mode: </label>
                <span class="text-xs">
                  LOCAL
                  <input
                    name={@form_controls[:mode][:name]}
                    type="checkbox"
                    checked={@mode == :remote}
                    class="toggle"
                  /> REMOTE
                </span>
              </div>

              <%= if @mode == :remote do %>
                <div class="flex">
                  <label class="block text-sm font-medium mr-4">Output: </label>

                  <span class="text-xs">
                    OFF
                    <input
                      name={@form_controls[:output][:name]}
                      type="checkbox"
                      checked={@output == :on}
                      class="toggle"
                    /> ON
                  </span>
                </div>

                <div class="flex">
                  <label class="mr-4">Set Voltage: </label>
                  <input
                    name={@form_controls[:v][:name]}
                    value={@form_controls[:v][:value] || 0}
                    type="number"
                    min="0"
                    max="30"
                    step="0.1"
                    phx-debounce="1000"
                  /> V
                </div>
                <div class="flex">
                  <label class="mr-4">Set Voltage Limit: </label>
                  <input
                    name={@form_controls[:v_lim][:name]}
                    value={@form_controls[:v_lim][:value] || 0}
                    type="number"
                    min="0"
                    max="30"
                    step="0.1"
                    phx-debounce="1000"
                  /> V
                </div>
                <div class="flex">
                  <label class="mr-4">Set Current: </label>
                  <input
                    name={@form_controls[:i][:name]}
                    value={@form_controls[:i][:value] || 0}
                    type="number"
                    min="0"
                    max="10"
                    step="0.1"
                    phx-debounce="1000"
                  /> A
                </div>
                <div class="flex">
                  <label class="mr-4">Set Current Limit: </label>
                  <input
                    name={@form_controls[:i_lim][:name]}
                    value={@form_controls[:i_lim][:value] || 0}
                    type="number"
                    min="0"
                    max="10"
                    step="0.1"
                    phx-debounce="1000"
                  /> A
                </div>
              <% end %>
            </form>
          </div>

          <div class="flex flex-col flex-grow bg-black rounded-lg p-6 font-mono gap-2">
            <div class="flex">
              <p class="flex-1 text-white">LIVE TELEMETRY</p>
            </div>

            <p class="flex-1 text-center text-sm text-red-400 font-bold uppercase">
              <%= if @output_reset_required do %>
                reset output
              <% end %>
            </p>
            <div class="flex">
              <div class="flex-1">
                <p class="text-2xl text-green-400">{@metrics.v_meas} V</p>
                <%= if @ov_protection do %>
                  <span class="text-sm text-red-400 font-bold uppercase">
                    <.icon name="hero-exclamation-triangle" class="size-6" /> OV Protection!
                  </span>
                <% end %>
              </div>

              <div class="justify-self-end">
                <p class="text-2xl text-blue-400">{@metrics.i_meas} A</p>
                <%= if @oc_protection do %>
                  <span class="text-sm text-red-400 font-bold uppercase">
                    <.icon name="hero-exclamation-triangle" class="size-6" /> OC Protection!
                  </span>
                <% end %>
              </div>
            </div>
            <div
              id="psu-chart"
              phx-hook="VegaChart"
              data-spec={@chart_spec}
              phx-update="ignore"
              class="bg-black text-green-400 rounded-lg p-2 pb-6"
            >
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    available_ports = OwonSpeInterface.enumerate() |> Map.keys()

    selected_port =
      Ui.PsuSupervisor.active_connections()
      |> Enum.map(fn {_, name} -> name end)
      |> List.first()

    if selected_port do
      Ui.PsuTelemetry.subscribe(Atom.to_string(selected_port))
    end

    {:ok,
     assign(socket,
       page_title: "Power Supply Control Center",
       ports: available_ports,
       active_connections: Ui.PsuSupervisor.active_connections(),
       selected_port: selected_port,
       connected: false,
       brand: nil,
       model: nil,
       id: nil,
       firmware_version: nil,
       mode: nil,
       output: nil,
       output_reset_required: false,
       oc_protection: false,
       ov_protection: false,
       metrics: %{v: 0.0, i: 0.0, v_meas: 0.0, i_meas: 0.0},
       chart_spec: psu_telemetry_spec(),
       chart_data: []
     )
     |> assign(:form_port, to_form(%{"port" => nil}))
     |> assign(
       :form_controls,
       to_form(%{
         "v" => nil,
         "v_lim" => nil,
         "i" => nil,
         "i_lim" => nil,
         "mode" => :local,
         "output" => nil
       })
     )}
  end

  @impl true
  def handle_event("connect", %{"port" => port}, socket) do
    with :ok <- Ui.PsuSupervisor.connect(port),
         Ui.PsuTelemetry.start_telemetry(port),
         Ui.PsuTelemetry.subscribe(port),
         :ok <- OwonSpeInterface.remote(:"#{port}"),
         {:ok, %{brand: brand, model: model, id: id, firmware_version: firmware_version}} <-
           OwonSpeInterface.id(:"#{port}") do
      {:noreply,
       assign(socket,
         connected: true,
         selected_port: :"#{port}",
         brand: brand,
         model: model,
         id: id,
         firmware_version: firmware_version
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Connection Failed")}
    end
  end

  @impl true
  def handle_event("disconnect", %{"port" => port}, socket) do
    case Ui.PsuSupervisor.disconnect(port) do
      :ok -> {:noreply, assign(socket, connected: false, selected_port: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Disconnection Failed")}
    end
  end

  @impl true
  def handle_event(
        "update_settings",
        %{"_target" => ["output" | _]} = params,
        %{assigns: assigns} = socket
      ) do
    output = if params["output"], do: :on, else: :off
    OwonSpeInterface.set_output(assigns.selected_port, output)
    {:noreply, assign(socket, output_reset_required: false == params["output"])}
  end

  @impl true
  def handle_event(
        "update_settings",
        %{"_target" => [target | _]} = params,
        %{assigns: assigns} = socket
      ) do
    case target do
      "mode" ->
        if params[target] do
          OwonSpeInterface.remote(assigns.selected_port)
        else
          OwonSpeInterface.local(assigns.selected_port)
        end

      # "output" ->
      #   output = if params[target], do: :on, else: :off
      #   OwonSpeInterface.set_output(assigns.selected_port, output)

      "i" ->
        {float, _rest} = Float.parse(String.trim(params[target]))
        OwonSpeInterface.set_current(assigns.selected_port, float)

      "i_lim" ->
        {float, _rest} = Float.parse(String.trim(params[target]))
        OwonSpeInterface.set_current_lim(assigns.selected_port, float)

      "v" ->
        {float, _rest} = Float.parse(String.trim(params[target]))
        OwonSpeInterface.set_voltage(assigns.selected_port, float)

      "v_lim" ->
        {float, _rest} = Float.parse(String.trim(params[target]))
        OwonSpeInterface.set_voltage_lim(assigns.selected_port, float)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:connection_lost = _msg, socket) do
    {:noreply, put_flash(socket, :error, "Connection Lost")}
  end

  @impl true
  def handle_info({:psu_data, data} = _msg, socket) do
    connected = Keyword.get(data, :connected)
    info = Keyword.get(data, :info, %{})
    mode = Keyword.get(data, :mode)
    output = Keyword.get(data, :output)
    v = Keyword.get(data, :v)
    v_lim = Keyword.get(data, :v_lim)
    i = Keyword.get(data, :i)
    i_lim = Keyword.get(data, :i_lim)
    v_meas = Keyword.get(data, :v_meas)
    i_meas = Keyword.get(data, :i_meas)
    # new_point = %{t: DateTime.utc_now(), v: v, i: i}
    new_point = %{
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "voltage" => v_meas,
      "current" => i_meas
    }

    # Prepend the new point, keep only the last 60 points

    points = Enum.take([new_point | socket.assigns.chart_data], 60)

    oc_protection = if nil != i and nil != i_lim, do: i > i_lim, else: false
    ov_protection = if nil != v and nil != v_lim, do: v > v_lim, else: false

    output_reset_required =
      if oc_protection or ov_protection, do: true, else: socket.assigns.output_reset_required

    {:noreply,
     assign(socket,
       brand: Map.get(info, :brand),
       model: Map.get(info, :model),
       id: Map.get(info, :id),
       firmware_version: Map.get(info, :firmware_version),
       connected: connected,
       mode: mode,
       output: output,
       output_reset_required: output_reset_required,
       oc_protection: oc_protection,
       ov_protection: ov_protection,
       metrics: %{v: v, i: i, v_meas: v_meas, i_meas: i_meas},
       chart_data: points,
       form_controls:
         to_form(%{
           "v" => v,
           "v_lim" => v_lim,
           "i" => i,
           "i_lim" => i_lim,
           "mode" => mode,
           "output" => output
         })
     )
     |> then(fn s ->
       if connected, do: s |> push_event("update_chart", %{points: Enum.reverse(points)}), else: s
     end)}
  end

  defp psu_telemetry_spec do
    Vl.new(width: "container", height: 300)
    |> Vl.config(background: "#000000", view: [stroke: "transparent"])
    |> Vl.config(
      axis: [
        grid_color: "#374151",
        grid_dash: [2, 2],
        label_color: "#9ca3af",
        title_color: "#f3f4f6",
        tick_color: "#374151"
      ]
    )
    |> Vl.data_from_values([], name: "telemetry")
    |> Vl.resolve(:scale, y: :independent)
    |> Vl.layers([
      # Layer 1: Voltage (Blue Line)
      Vl.new()
      |> Vl.mark(:line, color: "#05df72", stroke_width: 2)
      |> Vl.encode_field(:x, "time", type: :temporal, title: nil, axis: [format: "%H:%M:%S"])
      |> Vl.encode_field(:y, "voltage",
        type: :quantitative,
        title: "Voltage (V)",
        scale: [domain: [0, 32]]
      ),

      # Layer 2: Current (Green Line)
      Vl.new()
      |> Vl.mark(:line, color: "#51a2ff", stroke_width: 2)
      |> Vl.encode_field(:x, "time", type: :temporal)
      |> Vl.encode_field(:y, "current",
        type: :quantitative,
        title: "Current (A)",
        scale: [domain: [0, 11]]
      )
    ])
    |> Vl.to_spec()
    |> Jason.encode!()
  end
end
