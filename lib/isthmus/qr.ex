defmodule Isthmus.QR do
  @moduledoc "SVG QR helpers for identity handoff."

  @default_width 220

  def svg(nil), do: nil
  def svg(""), do: nil

  def svg(payload) when is_binary(payload), do: svg(payload, [])

  def svg(payload, opts) when is_binary(payload) and is_list(opts) do
    width = Keyword.get(opts, :width, @default_width)

    payload
    |> EQRCode.encode()
    # Keep viewBox for crisp scaling, but EQRCode omits width/height when
    # viewbox: true — without them the SVG collapses to module units (~37px).
    |> EQRCode.svg(width: width, viewbox: true)
    |> strip_xml_declaration()
    |> put_svg_dimensions(width)
  end

  defp strip_xml_declaration(svg) do
    String.replace(svg, ~r/<\?xml[^?]*\?>\s*/u, "")
  end

  defp put_svg_dimensions(svg, width) do
    String.replace(
      svg,
      "<svg ",
      ~s(<svg width="#{width}" height="#{width}" ),
      global: false
    )
  end
end
