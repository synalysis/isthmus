defmodule Isthmus.Networks.Meshtastic.RadioConfigTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.RadioConfig

  test "cast accepts region and modem preset form params" do
    assert {:ok, lora} =
             RadioConfig.cast(%{
               "mode" => "preset",
               "region" => "3",
               "modem_preset" => "4",
               "hop_limit" => "3",
               "tx_power" => "0",
               "channel_num" => "0"
             })

    assert lora.use_preset
    assert lora.region == 3
    assert lora.modem_preset == 4
    assert lora.tx_enabled
  end

  test "cast accepts custom bandwidth / SF / CR" do
    assert {:ok, lora} =
             RadioConfig.cast(%{
               "mode" => "custom",
               "region" => "1",
               "bandwidth" => "125",
               "spread_factor" => "11",
               "coding_rate" => "5",
               "hop_limit" => "4",
               "tx_power" => "22",
               "override_frequency" => "906.875"
             })

    refute lora.use_preset
    assert lora.bandwidth == 125
    assert lora.spread_factor == 11
    assert_in_delta lora.override_frequency, 906.875, 0.0001
  end

  test "cast rejects illegal hop limit" do
    assert {:error, _} =
             RadioConfig.cast(%{
               "mode" => "preset",
               "region" => "1",
               "modem_preset" => "0",
               "hop_limit" => "9"
             })
  end

  test "to_form_params roundtrips region" do
    {:ok, lora} = RadioConfig.cast(%{"region" => "6", "mode" => "preset", "modem_preset" => "0"})
    form = RadioConfig.to_form_params(lora)
    assert form["region"] == "6"
    assert form["mode"] == "preset"
  end
end
