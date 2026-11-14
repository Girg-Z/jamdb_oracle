defmodule Jamdb.Oracle.Integration.NumberTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  import Ecto.Query

  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.Repo

  @table "jamdb_it_number"

  setup_all do
    start_supervised!({Repo, Integration.config()})
    Integration.drop_table(Repo, @table)

    Repo.query!(
      "CREATE TABLE #{@table} (id NUMBER(10) PRIMARY KEY, grp NUMBER(10), " <>
        "num NUMBER, dec NUMBER(10,2), flt FLOAT)"
    )

    Repo.query!("INSERT INTO #{@table} VALUES (1, 1, 1.5, 2, 4)")
    Repo.query!("INSERT INTO #{@table} VALUES (2, 1, 2, 3, 5)")
    Repo.query!("INSERT INTO #{@table} VALUES (3, 2, 3, 4, 6)")

    on_exit(fn ->
      Integration.with_repo(Repo, fn -> Integration.drop_table(Repo, @table) end)
    end)

    :ok
  end

  # FETCH NEXT wraps the query in a subquery, where Oracle describes count(*)
  # as an unconstrained NUMBER instead of NUMBER(p,0).
  test "grouped count with limit returns integers" do
    query =
      from t in @table,
        group_by: t.grp,
        order_by: t.grp,
        limit: 2,
        select: {t.grp, count()}

    assert Repo.all(query) == [{1, 2}, {2, 1}]
  end

  test "unconstrained NUMBER returns integers for integral values only" do
    rows = Repo.query!("SELECT num FROM #{@table} ORDER BY id").rows
    assert rows == [[1.5], [2], [3]]
  end

  test "FLOAT and NUMBER with a scale keep returning floats" do
    assert Repo.query!("SELECT dec, flt FROM #{@table} WHERE id = 1").rows == [[2.0, 4.0]]
  end
end
