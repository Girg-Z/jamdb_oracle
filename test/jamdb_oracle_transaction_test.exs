defmodule Jamdb.OracleTransactionTest do
  use ExUnit.Case, async: true

  # Stands in for the jamdb_oracle gen_server and records the statements.
  defmodule FakeConn do
    use GenServer

    def init(test), do: {:ok, test}

    def handle_call({:sql_query, {sql, []}, _timeout}, _from, test) do
      send(test, {:sql, List.to_string(sql)})
      {:reply, {:ok, []}, test}
    end
  end

  defp state(fields \\ []) do
    {:ok, pid} = GenServer.start_link(FakeConn, self())
    struct!(%Jamdb.Oracle{pid: pid, mode: :idle, timeout: 1000}, fields)
  end

  defp sent do
    receive do
      {:sql, sql} -> [sql | sent()]
    after
      0 -> []
    end
  end

  test "a transaction disables autocommit until COMMIT" do
    assert {:ok, _, s} = Jamdb.Oracle.handle_begin([], state())
    assert s.mode == :transaction
    assert sent() == ["COMOFF"]

    assert {:ok, _, s} = Jamdb.Oracle.handle_commit([], s)
    assert s.mode == :idle
    assert sent() == ["COMMIT", "COMON"]
  end

  test "rollback of a transaction is a full ROLLBACK" do
    {:ok, _, s} = Jamdb.Oracle.handle_begin([], state())
    sent()

    assert {:ok, _, s} = Jamdb.Oracle.handle_rollback([], s)
    assert s.mode == :idle
    assert sent() == ["ROLLBACK", "COMON"]
  end

  test "savepoints inside a transaction" do
    {:ok, _, s} = Jamdb.Oracle.handle_begin([], state())
    sent()

    assert {:ok, _, s} = Jamdb.Oracle.handle_begin([mode: :savepoint], s)
    assert {:ok, _, s} = Jamdb.Oracle.handle_rollback([mode: :savepoint], s)
    assert {:ok, _, s} = Jamdb.Oracle.handle_begin([mode: :savepoint], s)
    assert {:ok, _, s} = Jamdb.Oracle.handle_commit([mode: :savepoint], s)
    assert s.mode == :transaction
    assert sent() == ["SAVEPOINT svpt", "ROLLBACK TO svpt", "SAVEPOINT svpt"]
  end

  test "rollback in error mode ends the transaction" do
    assert {:ok, _, s} = Jamdb.Oracle.handle_rollback([], state(mode: :error))
    assert s.mode == :idle
    assert sent() == ["ROLLBACK", "COMON"]
  end

  test "autocommit is left alone when disabled in the config" do
    s = state(autocommit: 0)
    {:ok, _, s} = Jamdb.Oracle.handle_begin([], s)
    {:ok, _, s} = Jamdb.Oracle.handle_commit([], s)
    {:ok, _, s} = Jamdb.Oracle.handle_begin([], s)
    {:ok, _, _} = Jamdb.Oracle.handle_rollback([], s)
    assert sent() == ["COMMIT", "ROLLBACK"]
  end

  test "status mismatches are reported to DBConnection" do
    assert {:idle, _} = Jamdb.Oracle.handle_commit([], state())
    assert {:idle, _} = Jamdb.Oracle.handle_begin([mode: :savepoint], state())
    assert {:transaction, _} = Jamdb.Oracle.handle_begin([], state(mode: :transaction))
    assert sent() == []
  end
end
