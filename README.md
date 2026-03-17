# Owon SPE Power Supply Control Center

A high-performance, fault-tolerant IoT gateway for the **Owon SPE 3103** Programmable Power Supply. This project demonstrates a modern approach to industrial hardware orchestration, built with **Elixir**, **Nerves**, and **Phoenix LiveView**,

## 🏗 System Architecture

The project is structured as a multi-app repository to ensure a strict separation of concerns:

* **`psu_interface`**: A library that exposes the SCPI commands through a non-blocking `GenServer` architecture that uses `Circuits.UART` to handle hardware communication.
* **`ui`**: A Phoenix LiveView web application. It provides a real-time, responsive dashboard with low-latency telemetry visualization using **Vega-Lite**.
* **`psu_nerves`**: The deployment wrapper that packages the UI and Interface into a minimal, read-only firmware image for the **Raspberry Pi Zero 2 W**.

---

## Features

* **Automatic Recovery:** If the USB cable is pulled, the `psu_interface` detects the `enoent` error, notifies the UI.
* **Process Isolation:** A crash in the Serial parser cannot take down the Web Server.
* **PubSub Integration:** Telemetry is broadcasted via `Phoenix.PubSub`. Multiple web clients can monitor the PSU simultaneously without additional hardware overhead.
* Leveraging **Vega-Lite** and **Phoenix JS Hooks**, the telemetry charts are rendered on the client side. The server only pushes lightweight JSON data points, reducing CPU usage on the Raspberry Pi.

---

## 🛠 Tech Stack

* **Language:** Elixir (Erlang/BEAM VM)
* **Framework:** Phoenix (LiveView, PubSub)
* **Embedded:** Nerves Project (Buildroot-based firmware)
* **Hardware Interface:** SCPI over USB-Serial (`Circuits.UART`)
* **Visuals:** Vega-Lite (Declarative Graphics), Tailwind CSS

---

## 📖 Getting Started

### Development (Local Machine)
To run the UI and Interface on your laptop with the PSU plugged in:
1. `cd ui`
2. `mix setup`
3. `iex -S mix phx.server`

### Production (Nerves)
To burn the firmware to an SD card for the Raspberry Pi:
1. `export MIX_TARGET=rpi0_2w`
2. `cd psu_nerves`
3. `mix deps.get`
4. `mix firmware.burn`

---

## 🛡 Safety Note
This software includes software-level current limiting and heartbeats. However, always ensure a physical emergency stop is accessible when working with high-power laboratory equipment.
