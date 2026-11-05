defmodule Jamdb.Oracle.Integration.SlowResponseTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  alias Jamdb.Oracle.Integration

  # Forwards a TCP connection to the database, holding back chunks coming
  # from the server so a response arrives with pauses in the middle of it.
  defmodule SlowProxy do
    def start(target_port, delay) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      pid = spawn_link(fn -> accept(listen, target_port, delay) end)
      {port, pid}
    end

    defp accept(listen, target_port, delay) do
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, server} = :gen_tcp.connect(~c"127.0.0.1", target_port, [:binary, active: false])
      spawn_link(fn -> pipe(client, server, 0) end)
      pipe(server, client, delay)
    end

    defp pipe(from, to, delay) do
      case :gen_tcp.recv(from, 0) do
        {:ok, data} ->
          if delay > 0, do: Process.sleep(delay)
          :gen_tcp.send(to, data)
          pipe(from, to, delay)

        {:error, _} ->
          :gen_tcp.close(to)
      end
    end
  end

  test "a response with pauses longer than read_timeout is read whole" do
    config = Integration.config()
    {proxy_port, _proxy} = SlowProxy.start(config[:port], 100)

    opts = [
      host: String.to_charlist(config[:hostname]),
      port: proxy_port,
      user: String.to_charlist(config[:username]),
      password: String.to_charlist(config[:password]),
      service_name: String.to_charlist(config[:database]),
      timeout: 15_000,
      read_timeout: 20
    ]

    {:ok, conn} = :jamdb_oracle.start(opts)

    # About 80 KB, so the response spans several packets.
    sql = ~c"SELECT level, RPAD('x', 4000, 'x') FROM dual CONNECT BY level <= 20"

    assert {:ok, [{:result_set, _, _, rows}]} = :jamdb_oracle.sql_query(conn, {sql, []}, 15_000)
    assert length(rows) == 20
    assert Enum.all?(rows, fn [_level, value] -> length(value) == 4000 end)

    :jamdb_oracle.stop(conn)
  end
end
