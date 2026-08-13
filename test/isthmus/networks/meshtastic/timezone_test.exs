defmodule Isthmus.Networks.Meshtastic.TimezoneTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.Timezone

  test "host_posix returns a non-empty POSIX TZ string" do
    posix = Timezone.host_posix()
    assert is_binary(posix)
    assert posix != ""
  end

  test "posix passes through an existing POSIX string" do
    assert Timezone.posix("CET-1CEST,M3.5.0,M10.5.0/3") == "CET-1CEST,M3.5.0,M10.5.0/3"
    assert Timezone.posix("UTC0") == "UTC0"
  end

  test "posix maps America/New_York from zoneinfo when present" do
    posix = Timezone.posix("America/New_York")
    assert posix != ""

    if File.exists?("/usr/share/zoneinfo/America/New_York") do
      assert posix == "EST5EDT,M3.2.0,M11.1.0"
    end
  end
end
