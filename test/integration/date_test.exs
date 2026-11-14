defmodule Jamdb.Oracle.Integration.DateTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  import Ecto.Query

  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.Repo

  defmodule Validity do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "jamdb_it_date" do
      field :valid_from, :date
      field :valid_to, :date
    end
  end

  setup_all do
    start_supervised!({Repo, Integration.config()})
    Integration.drop_table(Repo, "jamdb_it_date")

    [ddl] =
      Ecto.Adapters.Jamdb.Oracle.Connection.execute_ddl(
        {:create, Ecto.Migration.table(:jamdb_it_date, primary_key: false),
         [{:add, :id, :bigint, primary_key: true}, {:add, :valid_from, :date, []},
          {:add, :valid_to, :date, []}]}
      )

    Repo.query!(IO.iodata_to_binary(ddl))

    on_exit(fn ->
      Integration.with_repo(Repo, fn ->
        Integration.drop_table(Repo, "jamdb_it_date")
      end)
    end)

    :ok
  end

  test ":date fields round-trip through an Ecto schema" do
    Repo.insert!(%Validity{id: 1, valid_from: ~D[2026-03-04], valid_to: nil})

    assert %Validity{valid_from: ~D[2026-03-04], valid_to: nil} = Repo.get!(Validity, 1)

    assert [1] =
             Repo.all(from v in Validity, where: v.valid_from == ^~D[2026-03-04], select: v.id)

    assert [~D[2026-03-04]] = Repo.all(from v in Validity, where: v.id == 1, select: v.valid_from)
  end

  test "DATE values with a time part load as the date" do
    Repo.query!(
      "INSERT INTO jamdb_it_date (id, valid_from, valid_to) " <>
        "VALUES (2, TO_DATE('2026-05-06 13:14:15', 'YYYY-MM-DD HH24:MI:SS'), SYSDATE)"
    )

    assert %Validity{valid_from: ~D[2026-05-06], valid_to: %Date{}} = Repo.get!(Validity, 2)
  end
  test "values/2 rows join and group by date" do
    Repo.insert_all(Validity, [
      %{id: 10, valid_from: ~D[2026-07-01], valid_to: ~D[2026-07-02]},
      %{id: 11, valid_from: ~D[2026-07-02], valid_to: ~D[2026-07-03]}
    ])

    days = for i <- 0..3, do: %{day: Date.add(~D[2026-07-01], i), label: "d#{i}"}

    query =
      from d in values(days, %{day: :date, label: :string}),
        left_join: v in Validity,
        on: v.id in [10, 11] and v.valid_from <= d.day and v.valid_to >= d.day,
        group_by: [d.day, d.label],
        order_by: d.day,
        select: {d.day, d.label, count(v.id)}

    assert Repo.all(query) == [
             {~D[2026-07-01], "d0", 1},
             {~D[2026-07-02], "d1", 2},
             {~D[2026-07-03], "d2", 1},
             {~D[2026-07-04], "d3", 0}
           ]
  end
end
