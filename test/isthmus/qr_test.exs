defmodule Isthmus.QRTest do
  use ExUnit.Case, async: true

  alias Isthmus.QR

  test "svg includes explicit pixel size for scannable display" do
    svg = QR.svg("meshcore://channel/add?name=Camp&secret=abcd")

    assert svg =~ ~s(width="220")
    assert svg =~ ~s(height="220")
    assert svg =~ "viewBox="
    refute svg =~ "<?xml"
  end
end
