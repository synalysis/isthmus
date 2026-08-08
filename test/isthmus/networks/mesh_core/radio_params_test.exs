defmodule Isthmus.Networks.MeshCore.RadioParamsTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.RadioParams

  test "cast accepts string form params" do
    assert {:ok, params} =
             RadioParams.cast(%{
               "freq_mhz" => "910.525",
               "bw_khz" => "62.5",
               "sf" => "7",
               "cr" => "5",
               "tx_power" => "10"
             })

    assert_in_delta params.freq_mhz, 910.525, 0.0001
    assert params.sf == 7
    assert params.tx_power == 10
  end

  test "cast rejects out-of-range values" do
    assert {:error, _} =
             RadioParams.cast(%{
               freq_mhz: 910.0,
               bw_khz: 62.5,
               sf: 3,
               cr: 5,
               tx_power: 10
             })
  end

  test "cli_radio_command formats set radio" do
    {:ok, params} =
      RadioParams.cast(%{freq_mhz: 910.525, bw_khz: 62.5, sf: 7, cr: 5, tx_power: 10})

    assert RadioParams.cli_radio_command(params) == "set radio 910.525,62.5,7,5"
    assert RadioParams.cli_tx_command(params) == "set tx 10"
  end
end
