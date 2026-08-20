defmodule Isthmus.Networks.Firmware.VersionTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Firmware.Version

  test "newer official build" do
    assert Version.compare("1.16.0", "1.17.1") == :newer_available
    assert Version.compare("v1.16.0-abc", "1.17.1") == :newer_available
  end

  test "meshtastic git suffix is ignored for equality" do
    assert Version.compare("2.7.26.54e0d8d", "2.7.26.aaaaaaa") == :current
  end

  test "running ahead of catalog" do
    assert Version.compare("1.18.0", "1.17.1") == :running_ahead
  end

  test "missing running version is unknown" do
    assert Version.compare(nil, "1.17.1") == :unknown
    assert Version.compare("", "1.17.1") == :unknown
  end
end
