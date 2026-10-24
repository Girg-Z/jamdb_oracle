defmodule Jamdb.Oracle.Integration.ConstraintTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  import Ecto.Changeset

  alias Ecto.Adapters.Jamdb.Oracle.Connection
  alias Ecto.Migration.{Constraint, Index, Reference}
  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.Repo

  defmodule Parent do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "jamdb_it_cparent" do
      field :code, :integer
      field :qty, :integer
      has_many :children, Jamdb.Oracle.Integration.ConstraintTest.Child, foreign_key: :parent_id
    end
  end

  defmodule Child do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "jamdb_it_cchild" do
      belongs_to :parent, Jamdb.Oracle.Integration.ConstraintTest.Parent
    end
  end

  setup_all do
    start_supervised!({Repo, Integration.config()})
    :ok
  end

  setup do
    previous = Application.get_env(:jamdb_oracle, :quote_identifiers)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:jamdb_oracle, :quote_identifiers),
        else: Application.put_env(:jamdb_oracle, :quote_identifiers, previous)
    end)

    :ok
  end

  defp create_tables(quoted?, unique_name) do
    Application.put_env(:jamdb_oracle, :quote_identifiers, quoted?)
    drop_tables(quoted?)
    on_exit(fn -> drop_tables(quoted?) end)

    ddl = [
      {:create, Ecto.Migration.table(:jamdb_it_cparent, primary_key: false),
       [{:add, :id, :bigint, primary_key: true}, {:add, :code, :integer, []},
        {:add, :qty, :integer, []}]},
      {:create, %Index{table: "jamdb_it_cparent", name: unique_name, columns: [:code], unique: true}},
      {:create, %Constraint{table: "jamdb_it_cparent", name: "jamdb_it_qty_positive", check: qty_check(quoted?)}},
      {:create, Ecto.Migration.table(:jamdb_it_cchild, primary_key: false),
       [{:add, :id, :bigint, primary_key: true},
        {:add, :parent_id, %Reference{table: "jamdb_it_cparent", type: :bigint}, []}]}
    ]

    for command <- ddl, sql <- Connection.execute_ddl(command) do
      Repo.query!(IO.iodata_to_binary(sql))
    end

    Repo.insert!(%Parent{id: 1, code: 1, qty: 1})
    Repo.insert!(%Child{id: 1, parent_id: 1})
  end

  defp qty_check(true), do: ~s("qty" > 0)
  defp qty_check(false), do: "qty > 0"

  defp drop_tables(quoted?) do
    for table <- ~w(jamdb_it_cchild jamdb_it_cparent) do
      Integration.drop_table(Repo, if(quoted?, do: ~s("#{table}"), else: table))
    end
  end

  defp assert_constraint_errors(unique_name) do
    assert {:error, changeset} =
             %Parent{}
             |> change(id: 2, code: 1, qty: 1)
             |> unique_constraint(:code, name: unique_name)
             |> Repo.insert()

    assert [code: {_, [constraint: :unique, constraint_name: ^unique_name]}] = changeset.errors

    assert {:error, changeset} =
             %Parent{}
             |> change(id: 1, code: 3, qty: 1)
             |> unique_constraint(:id, name: :jamdb_it_cparent_pkey)
             |> Repo.insert()

    assert [id: {_, [constraint: :unique, constraint_name: "jamdb_it_cparent_pkey"]}] =
             changeset.errors

    assert {:error, changeset} =
             %Parent{}
             |> change(id: 4, code: 4, qty: -1)
             |> check_constraint(:qty, name: :jamdb_it_qty_positive)
             |> Repo.insert()

    assert [qty: {_, [constraint: :check, constraint_name: "jamdb_it_qty_positive"]}] =
             changeset.errors

    assert {:error, changeset} =
             %Child{}
             |> change(id: 2, parent_id: 99)
             |> foreign_key_constraint(:parent_id)
             |> Repo.insert()

    assert [parent_id: {_, [constraint: :foreign, constraint_name: "jamdb_it_cchild_parent_id_fkey"]}] =
             changeset.errors

    assert {:error, changeset} =
             # Not loaded with Repo.get!: Ecto caches the SQL of read queries,
             # which would leak the identifier quoting between the two tests.
             %Parent{id: 1}
             |> Ecto.put_meta(state: :loaded)
             |> change()
             |> no_assoc_constraint(:children)
             |> Repo.delete()

    assert [children: {_, [constraint: :no_assoc, constraint_name: "jamdb_it_cchild_parent_id_fkey"]}] =
             changeset.errors
  end

  test "constraint violations become changeset errors with unquoted identifiers" do
    create_tables(false, "jamdb_it_cparent_code_uq")
    assert_constraint_errors("jamdb_it_cparent_code_uq")
  end

  test "constraint violations keep the name case with quoted identifiers" do
    create_tables(true, "jamdb_it_cParent_Code_uq")
    assert_constraint_errors("jamdb_it_cParent_Code_uq")
  end
end
