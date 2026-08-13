defmodule Isthmus.Networks.Reticulum.RNodeTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Reticulum.RNode

  test "detect_response? matches KISS detect reply" do
    assert RNode.detect_response?(<<0xC0, 0x08, 0x46, 0xC0>>)
    assert RNode.detect_response?(<<0x00, 0xC0, 0x08, 0x46, 0xC0, 0xFF>>)
    refute RNode.detect_response?(<<0xC0, 0x08, 0x73, 0xC0>>)
    refute RNode.detect_response?("ver\r\n-> 1.0")
  end

  test "config_from_form converts MHz and kHz to Hz" do
    attrs =
      RNode.config_from_form(%{
        "port" => "/dev/ttyACM3",
        "frequency_mhz" => "915.0",
        "bandwidth_khz" => "125",
        "txpower" => "7",
        "spreadingfactor" => "8",
        "codingrate" => "5"
      })

    assert attrs.port == "/dev/ttyACM3"
    assert attrs.frequency == 915_000_000
    assert attrs.bandwidth == 125_000
    assert attrs.txpower == 7
    assert RNode.validate_config(attrs) == :ok
  end

  test "validate_config rejects a missing port" do
    assert {:error, :missing_port} = RNode.validate_config(%{port: ""})
  end
end
