defmodule Agonex.Client do
  @moduledoc false

  use GenServer
  require Logger
  alias Agones.Dev.Sdk.{Duration, Empty, KeyValue, SDK.Stub}

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def allocate,
    do: GenServer.call(__MODULE__, :allocate)

  def ready,
    do: GenServer.call(__MODULE__, :ready)

  def shutdown,
    do: GenServer.call(__MODULE__, :shutdown)

  def reserve(seconds),
    do: GenServer.call(__MODULE__, {:reserve, seconds})

  def get_game_server,
    do: GenServer.call(__MODULE__, :game_server)

  def watch_game_server,
    do: GenServer.call(__MODULE__, {:watch_game_server, self()})

  def set_label(key, value),
    do: GenServer.call(__MODULE__, {:set_label, key, value})

  def set_annotation(key, value),
    do: GenServer.call(__MODULE__, {:set_annotation, key, value})

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def init(options) do
    host = Keyword.fetch!(options, :host)
    port = Keyword.fetch!(options, :port)
    health_interval = Keyword.fetch!(options, :health_interval)
    grpc_opts = Keyword.fetch!(options, :grpc_opts)

    state = %{
      channel: nil,
      health_stream: nil,
      health_interval: health_interval
    }

    {:ok, state, {:continue, {:connect, host, port, grpc_opts}}}
  end

  def handle_continue({:connect, host, port, opts}, state) do
    case GRPC.Stub.connect(host, port, opts) do
      {:ok, channel} ->
        health_stream = Stub.health(channel)

        state = %{
          state
          | channel: channel,
            health_stream: health_stream
        }

        send(self(), :health)

        {:noreply, state}

      {:error, "Error when opening connection: protocol " <> proto} ->
        {:stop, {:error, {:protocol_mismatch, proto |> String.to_existing_atom()}}, state}

      {:error, "Error when opening connection: :" <> reason} ->
        {:stop, {:error, reason |> String.to_existing_atom()}, state}
    end
  end

  def handle_info(:health, state) do
    GRPC.Stub.send_request(state.health_stream, Empty.new())
    Process.send_after(self(), :health, state.health_interval)
    {:noreply, state}
  end

  def handle_call(_, _, %{channel: nil} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:ready, _, state) do
    case Stub.ready(state.channel, Empty.new()) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:allocate, _, state) do
    case Stub.allocate(state.channel, Empty.new()) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:shutdown, _, state) do
    case Stub.shutdown(state.channel, Empty.new()) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:reserve, seconds}, _, state) do
    case Stub.reserve(state.channel, Duration.new(seconds: seconds)) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:game_server, _, state) do
    case Stub.get_game_server(state.channel, Empty.new()) do
      {:ok, game_server} ->
        {:reply, {:ok, game_server}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:watch_game_server, sub_pid}, _, state) do
    case Stub.watch_game_server(state.channel, Empty.new()) do
      {:error, _} = error ->
        {:stop, error, state}

      stream ->
        Task.Supervisor.start_child(
          Agonex.TaskSupervisor,
          Agonex.Watcher,
          :loop,
          [{stream, sub_pid}]
        )

        {:noreply, state}
    end
  end

  def handle_call({:set_label, key, value}, _, state) do
    case Stub.set_label(state.channel, KeyValue.new(key: key, value: value)) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:set_annotation, key, value}, _, state) do
    case Stub.set_annotation(state.channel, KeyValue.new(key: key, value: value)) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end
end

defmodule Agonex.Watcher do
  @moduledoc false

  def loop({stream, sub_pid}) do
    with {:ok, game_server} <- GRPC.Stub.recv(stream) do
      send(sub_pid, {:game_server_change, game_server})
      loop({stream, sub_pid})
    end
  end
end
