defmodule Isthmus.Networks.Meshtastic.SettingsTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.Settings

  test "sections lists lora and device" do
    assert :lora in Settings.sections()
    assert :device in Settings.sections()
  end

  test "cast accepts nested device and lora form params" do
    assert {:ok, settings} =
             Settings.cast(%{
               "device" => %{"buzzer_mode" => "disabled"},
               "lora" => %{
                 "mode" => "preset",
                 "region" => "1",
                 "modem_preset" => "0",
                 "hop_limit" => "3",
                 "tx_power" => "0",
                 "channel_num" => "0"
               }
             })

    assert settings.device.buzzer_mode == 1
    assert settings.lora.region == 1
  end

  test "cast allows a device-only patch" do
    assert {:ok, settings} = Settings.cast(%{"device" => %{"buzzer_mode" => "1"}})
    assert settings.device.buzzer_mode == 1
    assert is_nil(settings.lora)
  end

  test "to_form_params nests section maps" do
    form = Settings.to_form_params(Settings.empty())
    assert is_map(form["lora"])
    assert is_map(form["device"])
    assert form["device"]["buzzer_mode"] == "0"
  end
end
