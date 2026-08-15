defmodule Isthmus.Networks.MeshCore.Transport do
  @moduledoc """
  Behaviour for MeshCore companion transports (USB serial and BLE / NUS).
  """

  @type state :: map()

  @callback connect(opts :: map()) :: {:ok, state()} | {:error, term()}
  @callback write(state(), iodata()) :: :ok | {:error, term()}
  @callback close(state()) :: :ok
  @callback info(state()) :: map()
end
