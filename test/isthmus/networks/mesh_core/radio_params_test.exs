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

  test "cast applies a MeshCore app preset" do
    assert {:ok, params} =
             RadioParams.cast(%{"preset" => "usa_canada", "tx_power" => "10"})

    assert_in_delta params.freq_mhz, 910.525, 0.0001
    assert_in_delta params.bw_khz, 62.5, 0.0001
    assert params.sf == 7
    assert params.cr == 5
    assert params.tx_power == 10
  end

  test "to_form_params matches USA/Canada preset" do
    form =
      RadioParams.to_form_params(%{
        freq_mhz: 910.525,
        bw_khz: 62.5,
        sf: 7,
        cr: 5,
        tx_power: 10
      })

    assert form["preset"] == "usa_canada"
  end

  test "apply_form_change fills fields when a preset is selected" do
    params =
      RadioParams.apply_form_change(
        %{"preset" => "eu_uk_narrow", "tx_power" => "14", "freq_mhz" => "1"},
        ["radio", "preset"]
      )

    assert params["preset"] == "eu_uk_narrow"
    assert params["freq_mhz"] == "869.618"
    assert params["sf"] == "8"
    assert params["tx_power"] == "14"
  end

  test "apply_form_change switches to custom when values diverge" do
    params =
      RadioParams.apply_form_change(
        %{
          "preset" => "usa_canada",
          "freq_mhz" => "910.525",
          "bw_khz" => "62.5",
          "sf" => "9",
          "cr" => "5",
          "tx_power" => "10"
        },
        ["radio", "sf"]
      )

    assert params["preset"] == "custom"
  end
end
