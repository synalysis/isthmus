defmodule IsthmusWeb.Plugs.ForceSSLTest do
  use IsthmusWeb.ConnCase, async: false

  alias IsthmusWeb.Plugs.ForceSSL

  setup do
    previous = Application.get_env(:isthmus, :force_ssl)

    on_exit(fn ->
      Application.put_env(:isthmus, :force_ssl, previous)
    end)

    :ok
  end

  test "passes HTTP through when FORCE_SSL is off" do
    Application.put_env(:isthmus, :force_ssl, false)

    conn =
      :get
      |> Plug.Test.conn("http://isthmus.lan/")
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "isthmus.lan")
      |> ForceSSL.call([])

    refute conn.halted
  end

  test "redirects LAN HTTP to HTTPS when FORCE_SSL is on" do
    Application.put_env(:isthmus, :force_ssl,
      rewrite_on: [:x_forwarded_proto],
      exclude: [
        paths: ["/healthz", "/readyz", "/metrics"],
        hosts: ["localhost", "127.0.0.1"]
      ]
    )

    conn =
      :get
      |> Plug.Test.conn("http://isthmus.lan/")
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "isthmus.lan")
      |> ForceSSL.call([])

    assert conn.halted
    assert conn.status == 301
    assert List.first(get_resp_header(conn, "location")) =~ ~r/^https:/
  end

  test "does not redirect /healthz when FORCE_SSL is on" do
    Application.put_env(:isthmus, :force_ssl,
      rewrite_on: [:x_forwarded_proto],
      exclude: [
        paths: ["/healthz", "/readyz", "/metrics"],
        hosts: ["localhost", "127.0.0.1"]
      ]
    )

    conn =
      :get
      |> Plug.Test.conn("http://isthmus.lan/healthz")
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "isthmus.lan")
      |> ForceSSL.call([])

    refute conn.halted
  end
end
