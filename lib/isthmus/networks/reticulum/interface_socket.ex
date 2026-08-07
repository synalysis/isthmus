defmodule Isthmus.Networks.Reticulum.InterfaceSocket do
  @moduledoc """
  Unix-domain socket bridge for `IsthmusInterface` (MeshChatX / local RNS).

  HDLC-framed RNS packets (same framing as RNS `PipeInterface`) are accepted from
  connected MeshChat instances and fed to `Tunnel.Engine`. Outbound tunnel frames
  are written back to connected clients.
  """
  use GenServer

  require Logger

  alias Isthmus.Tunnel.Engine

  @flag 0x7E
  @esc 0x7D
  @esc_mask 0x20
  @hw_mtu 1064

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health, do: GenServer.call(__MODULE__, :health)

  def send_frame(binary) when is_binary(binary) do
    GenServer.call(__MODULE__, {:send_frame, binary})
  end

  @impl true
  def init(_opts) do
    path =
      System.get_env("ISTHMUS_RNS_SOCKET") ||
        Path.join(System.tmp_dir!(), "isthmus.sock")

    File.rm(path)

    case :gen_tcp.listen(0, [
           :binary,
           {:ifaddr, {:local, String.to_charlist(path)}},
           {:packet, :raw},
           active: false,
           reuseaddr: true
         ]) do
      {:ok, listen} ->
        Logger.info("RNS interface socket listening at #{path}")
        state = %{path: path, listen: listen, clients: %{}, acceptor: nil, last_error: nil}
        {:ok, accept_next(state)}

      {:error, reason} ->
        Logger.warning("RNS interface socket failed to bind #{path}: #{inspect(reason)}")
        {:ok, %{path: path, listen: nil, clients: %{}, acceptor: nil, last_error: reason}}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       path: state.path,
       listening: state.listen != nil,
       clients: map_size(state.clients),
       last_error: Map.get(state, :last_error)
     }, state}
  end

  def handle_call({:send_frame, _binary}, _from, %{clients: clients} = state)
      when map_size(clients) == 0 do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_frame, binary}, _from, %{clients: clients} = state) do
    frame = hdlc_encode(binary)

    Enum.each(clients, fn {socket, _} ->
      :gen_tcp.send(socket, frame)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:"$socket", listen, {:accept, socket}}, %{listen: listen} = state) do
    # Older OTP may not use this; kept for compatibility no-ops
    {:noreply, state |> put_client(socket) |> accept_next()}
  end

  def handle_info({:tcp, socket, data}, state) do
    case Map.get(state.clients, socket) do
      nil ->
        {:noreply, state}

      client ->
        {frames, client} = hdlc_feed(client, data)

        Enum.each(frames, fn frame ->
          Engine.handle_inbound_frame(frame)
        end)

        :inet.setopts(socket, active: :once)
        {:noreply, put_in(state.clients[socket], client)}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    Logger.info("RNS interface client disconnected")
    {:noreply, %{state | clients: Map.delete(state.clients, socket)}}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.warning("RNS interface client error: #{inspect(reason)}")
    :gen_tcp.close(socket)
    {:noreply, %{state | clients: Map.delete(state.clients, socket)}}
  end

  def handle_info({:accept, socket}, state) do
    Logger.info("RNS interface client connected")
    {:noreply, state |> put_client(socket) |> accept_next()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp accept_next(%{listen: nil} = state), do: state

  defp accept_next(%{listen: listen} = state) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        case :gen_tcp.accept(listen) do
          {:ok, socket} -> send(parent, {:accept, socket})
          {:error, _} -> :ok
        end
      end)

    %{state | acceptor: pid}
  end

  defp put_client(state, socket) do
    :inet.setopts(socket, active: :once)
    client = %{buffer: <<>>, in_frame: false, escape: false}
    %{state | clients: Map.put(state.clients, socket, client)}
  end

  defp hdlc_encode(data) when is_binary(data) do
    <<@flag, hdlc_escape(data)::binary, @flag>>
  end

  defp hdlc_escape(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn
      @esc -> [@esc, Bitwise.bxor(@esc, @esc_mask)]
      @flag -> [@esc, Bitwise.bxor(@flag, @esc_mask)]
      b -> [b]
    end)
    |> :binary.list_to_bin()
  end

  defp hdlc_feed(client, data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce({[], client}, fn byte, {frames, c} ->
      cond do
        c.in_frame and byte == @flag ->
          frame = c.buffer
          c = %{c | in_frame: false, buffer: <<>>, escape: false}
          if frame == <<>>, do: {frames, c}, else: {[frame | frames], c}

        byte == @flag ->
          {frames, %{c | in_frame: true, buffer: <<>>, escape: false}}

        c.in_frame and byte_size(c.buffer) < @hw_mtu ->
          {b, escape} =
            if c.escape do
              decoded =
                cond do
                  byte == Bitwise.bxor(@flag, @esc_mask) -> @flag
                  byte == Bitwise.bxor(@esc, @esc_mask) -> @esc
                  true -> byte
                end

              {decoded, false}
            else
              if byte == @esc, do: {nil, true}, else: {byte, false}
            end

          if is_nil(b) do
            {frames, %{c | escape: escape}}
          else
            {frames, %{c | buffer: c.buffer <> <<b>>, escape: escape}}
          end

        true ->
          {frames, c}
      end
    end)
    |> then(fn {frames, c} -> {Enum.reverse(frames), c} end)
  end
end
