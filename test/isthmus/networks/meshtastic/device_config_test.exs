defmodule Isthmus.Networks.Meshtastic.DeviceConfigTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.DeviceConfig

  test "cast accepts numeric and slug buzzer modes" do
    assert {:ok, device} = DeviceConfig.cast(%{"buzzer_mode" => "1"})
    assert device.buzzer_mode == 1

    assert {:ok, disabled} = DeviceConfig.cast(%{"buzzer_mode" => "disabled"})
    assert disabled.buzzer_mode == 1
    assert DeviceConfig.buzzer_slug(1) == "disabled"
  end

  test "merge only overlays editable keys" do
    base = %{DeviceConfig.empty() | role: 2, tzdef: "UTC0", buzzer_mode: 0}
    overlay = %{DeviceConfig.empty() | role: 0, tzdef: "", buzzer_mode: 1}

    merged = DeviceConfig.merge(base, overlay)
    assert merged.buzzer_mode == 1
    assert merged.role == 2
    assert merged.tzdef == "UTC0"
  end

  test "to_form_params roundtrips buzzer_mode" do
    {:ok, device} = DeviceConfig.cast(%{"buzzer_mode" => "2"})
    form = DeviceConfig.to_form_params(device)
    assert form["buzzer_mode"] == "2"
  end

  test "cast rejects unknown buzzer mode" do
    assert {:error, _} = DeviceConfig.cast(%{"buzzer_mode" => "siren"})
  end
end
