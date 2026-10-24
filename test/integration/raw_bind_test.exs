defmodule Jamdb.Oracle.Integration.RawBindTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.Repo

  defmodule Token do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "jamdb_it_raw_tokens" do
      field :token, :binary
      field :user_id, :integer
      field :context, :string
      field :inserted_at, :utc_datetime
    end
  end

  setup_all do
    start_supervised!({Repo, Integration.config()})
    Integration.drop_table(Repo, "jamdb_it_raw")
    Integration.drop_table(Repo, "jamdb_it_raw_tokens")

    Repo.query!("""
    CREATE TABLE jamdb_it_raw (
      id NUMBER, r RAW(2000), n NUMBER, ts TIMESTAMP, tz TIMESTAMP WITH TIME ZONE,
      d DATE, v VARCHAR2(100), b BLOB, c CLOB)
    """)

    Repo.query!("""
    CREATE TABLE jamdb_it_raw_tokens (
      id NUMBER(19) PRIMARY KEY, token RAW(32) NOT NULL, user_id NUMBER(19) NOT NULL,
      context VARCHAR2(255) NOT NULL, inserted_at TIMESTAMP NOT NULL)
    """)

    on_exit(fn ->
      {:ok, _} = Repo.start_link(Integration.config())
      Integration.drop_table(Repo, "jamdb_it_raw")
      Integration.drop_table(Repo, "jamdb_it_raw_tokens")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM jamdb_it_raw")
    Repo.query!("DELETE FROM jamdb_it_raw_tokens")
    :ok
  end

  defp raw(value), do: %Ecto.Query.Tagged{value: value, type: :binary}

  defp row(id) do
    %{rows: [row]} =
      Repo.query!("SELECT r, n, ts, tz, d, v FROM jamdb_it_raw WHERE id = :1", [id])

    row
  end

  test "RAW bind of any size followed by number, timestamp, date and varchar binds" do
    ts = ~N[2026-01-02 03:04:05.123456]
    tz = ~U[2026-01-02 03:04:05.654321Z]
    d = ~N[2026-01-02 00:00:00]

    for {size, id} <- Enum.with_index([1, 4, 32, 64, 65, 252, 253, 255, 1000, 2000], 1) do
      bytes = :crypto.strong_rand_bytes(size)

      Repo.query!(
        "INSERT INTO jamdb_it_raw (r, n, ts, tz, d, v, id) VALUES (:1, :2, :3, :4, :5, :6, :7)",
        [raw(bytes), 42, ts, tz, d, "text", id]
      )

      assert [^bytes, n, ^ts, ^tz, ^d, "text"] = row(id)
      assert n == 42
    end
  end

  test "RAW bind in the middle and last position" do
    bytes = :crypto.strong_rand_bytes(32)

    Repo.query!("INSERT INTO jamdb_it_raw (n, r, v, id) VALUES (:1, :2, :3, :4)",
      [7, raw(bytes), "mid", 1])

    Repo.query!("INSERT INTO jamdb_it_raw (n, v, id, r) VALUES (:1, :2, :3, :4)",
      [8, "last", 2, raw(bytes)])

    assert [^bytes, n1, nil, nil, nil, "mid"] = row(1)
    assert [^bytes, n2, nil, nil, nil, "last"] = row(2)
    assert {n1, n2} == {7, 8}
  end

  test "RAW binds in WHERE clauses keep the following binds intact" do
    for size <- [4, 32] do
      bytes = :crypto.strong_rand_bytes(size)

      assert %{num_rows: 1} =
               Repo.query!("SELECT 1 FROM dual WHERE :1 IS NOT NULL AND :2 = 1", [raw(bytes), 1])

      assert %{num_rows: 1} =
               Repo.query!("SELECT 1 FROM dual WHERE :1 IS NOT NULL AND :2 < SYSTIMESTAMP",
                 [raw(bytes), DateTime.utc_now()])
    end
  end

  test "NULL and empty RAW binds followed by other binds" do
    Repo.query!("INSERT INTO jamdb_it_raw (r, n, v, id) VALUES (:1, :2, :3, :4)",
      [nil, 1, "nil", 1])

    Repo.query!("INSERT INTO jamdb_it_raw (r, n, v, id) VALUES (:1, :2, :3, :4)",
      [raw(<<>>), 2, "empty", 2])

    # Oracle stores an empty RAW as NULL.
    assert [nil, n1, nil, nil, nil, "nil"] = row(1)
    assert [nil, n2, nil, nil, nil, "empty"] = row(2)
    assert {n1, n2} == {1, 2}
  end

  test "same statement executed with changing bind types" do
    sql = "INSERT INTO jamdb_it_raw (r, n, id) VALUES (:1, :2, :3)"
    values = [nil, <<1, 2, 3>>, <<4, 5>>, nil, <<>>, :crypto.strong_rand_bytes(2000), <<6>>]

    for {value, id} <- Enum.with_index(values, 1) do
      bind = if value, do: raw(value), else: nil
      Repo.query!(sql, [bind, id, id])
    end

    %{rows: rows} = Repo.query!("SELECT id, n, r FROM jamdb_it_raw ORDER BY id")

    expected =
      for {value, id} <- Enum.with_index(values, 1) do
        [id, id, if(value in [nil, <<>>], do: nil, else: value)]
      end

    assert Enum.map(rows, fn [id, n, r] -> [trunc(id), trunc(n), r] end) == expected
  end

  test "LONG RAW and long VARCHAR binds before other binds" do
    blob = :crypto.strong_rand_bytes(5000)
    clob = String.duplicate("x", 5000)

    Repo.query!("INSERT INTO jamdb_it_raw (b, n, v, id) VALUES (:1, :2, :3, :4)",
      [raw(blob), 1, "blob", 1])

    Repo.query!("INSERT INTO jamdb_it_raw (c, n, v, id) VALUES (:1, :2, :3, :4)",
      [clob, 2, "clob", 2])

    Repo.query!("INSERT INTO jamdb_it_raw (n, b, r, id) VALUES (:1, :2, :3, :4)",
      [3, raw(blob), raw(<<9, 9>>), 3])

    %{rows: rows} =
      Repo.query!(
        "SELECT id, n, dbms_lob.getlength(b), dbms_lob.getlength(c), v, r " <>
          "FROM jamdb_it_raw ORDER BY id"
      )

    assert Enum.map(rows, fn [id, n, b, c, v, r] -> [trunc(id), trunc(n), b, c, v, r] end) == [
             [1, 1, 5000, nil, "blob", nil],
             [2, 2, nil, 5000, "clob", nil],
             [3, 3, 5000, nil, nil, <<9, 9>>]
           ]
  end

  test "Ecto schema with a :binary field first in the insert" do
    token = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Token{id: 1, token: token, user_id: 10, context: "session", inserted_at: now})

    Repo.query!(
      "INSERT INTO jamdb_it_raw_tokens (token, user_id, context, inserted_at, id) " <>
        "VALUES (:1, :2, :3, :4, :5)",
      [raw(:crypto.strong_rand_bytes(32)), 11, "reset", now, 2]
    )

    import Ecto.Query
    assert %Token{user_id: 10, context: "session", inserted_at: ^now} =
             Repo.one!(from t in Token, where: t.token == ^token and t.user_id == ^10)

    assert Repo.aggregate(Token, :count) == 2
  end
end
