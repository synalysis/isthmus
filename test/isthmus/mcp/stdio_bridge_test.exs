defmodule Isthmus.MCP.StdioBridgeTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../bin/isthmus-mcp-stdio", __DIR__)

  defmodule EchoPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)

      conn
      |> put_resp_header("mcp-session-id", "sess-1")
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
    end
  end

  test "python script is valid" do
    {_, 0} = System.cmd("python3", ["-m", "py_compile", @script], stderr_to_stdout: true)
  end

  test "forwards a JSON-RPC line to Streamable HTTP and prints the reply" do
    port = Enum.random(51_000..61_000)

    start_supervised!(
      {Bandit, plug: EchoPlug, scheme: :http, port: port, startup_log: false, ip: {127, 0, 0, 1}}
    )

    env =
      System.get_env()
      |> Map.merge(%{
        "ISTHMUS_MCP_URL" => "http://127.0.0.1:#{port}/mcp",
        "ISTHMUS_MCP_TOKEN" => "test-token",
        "PYTHONUNBUFFERED" => "1"
      })
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port_pid =
      Port.open(
        {:spawn_executable, System.find_executable("python3")},
        [:binary, :exit_status, :use_stdio, args: [@script], env: env]
      )

    req = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)
    true = Port.command(port_pid, req)

    assert_receive {^port_pid, {:data, data}}, 2_000
    reply = data |> String.split("\n", trim: true) |> List.last()
    assert Jason.decode!(reply) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}}

    Port.close(port_pid)
  end
end
