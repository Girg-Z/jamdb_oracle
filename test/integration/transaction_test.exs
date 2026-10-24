defmodule Jamdb.Oracle.Integration.TransactionTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.{OtherRepo, Repo, SandboxRepo}

  defmodule Row do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "jamdb_it_tx" do
      field :name, :string
    end
  end

  setup_all do
    start_supervised!({Repo, Integration.config()})
    start_supervised!({OtherRepo, Integration.config()})
    start_supervised!({SandboxRepo, Integration.config(pool: Sandbox)})
    Integration.drop_table(Repo, "jamdb_it_tx")
    Repo.query!("CREATE TABLE jamdb_it_tx (id NUMBER(19) PRIMARY KEY, name VARCHAR2(50))")

    on_exit(fn ->
      {:ok, _} = Repo.start_link(Integration.config())
      Integration.drop_table(Repo, "jamdb_it_tx")
      Integration.drop_table(Repo, "jamdb_it_tx_ddl")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM jamdb_it_tx")
    :ok
  end

  defp insert(repo, id), do: repo.insert!(%Row{id: id, name: "row #{id}"})

  # What another session sees, i.e. what has been committed.
  defp committed_ids do
    OtherRepo.all(from r in Row, select: r.id, order_by: r.id)
  end

  test "statements outside a transaction are committed" do
    insert(Repo, 1)
    assert committed_ids() == [1]
  end

  test "rollback discards everything done in the transaction" do
    assert {:error, :rollback} =
             Repo.transaction(fn ->
               insert(Repo, 1)
               insert(Repo, 2)
               Repo.update_all(Row, set: [name: "changed"])
               Repo.rollback(:rollback)
             end)

    assert committed_ids() == []
    assert Repo.all(Row) == []
  end

  test "nothing is committed before COMMIT, everything after" do
    assert {:ok, :done} =
             Repo.transaction(fn ->
               insert(Repo, 1)
               insert(Repo, 2)
               assert committed_ids() == []
               assert Repo.aggregate(Row, :count) == 2
               :done
             end)

    assert committed_ids() == [1, 2]
  end

  test "a failing statement inside a transaction rolls back the earlier work" do
    insert(Repo, 1)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        insert(Repo, 2)
        insert(Repo, 1)
      end)
    end

    assert committed_ids() == [1]
    # The connection is still usable and back to autocommit.
    insert(Repo, 3)
    assert committed_ids() == [1, 3]
  end

  test "Ecto.Multi is atomic" do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:a, %Row{id: 1, name: "a"})
      |> Ecto.Multi.insert(:b, %Row{id: 2, name: "b"})
      |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :nope} end)

    assert {:error, :fail, :nope, _} = Repo.transaction(multi)
    assert committed_ids() == []
  end

  test "statements after a transaction autocommit again" do
    Repo.transaction(fn -> insert(Repo, 1) end)
    Repo.transaction(fn -> insert(Repo, 2) ; Repo.rollback(:no) end)

    insert(Repo, 3)
    assert committed_ids() == [1, 3]

    Repo.delete_all(Row)
    assert committed_ids() == []
  end

  test "DDL inside a transaction commits implicitly but rollback still works" do
    Integration.drop_table(Repo, "jamdb_it_tx_ddl")

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               insert(Repo, 1)
               Repo.query!("CREATE TABLE jamdb_it_tx_ddl (id NUMBER)")
               insert(Repo, 2)
               Repo.rollback(:rollback)
             end)

    # Oracle committed the work done before the DDL statement.
    assert committed_ids() == [1]
    insert(Repo, 3)
    assert committed_ids() == [1, 3]
  end

  test "sandbox savepoints: nested rollback keeps the outer work" do
    :ok = Sandbox.checkout(SandboxRepo)

    insert(SandboxRepo, 1)

    assert {:error, :inner} =
             SandboxRepo.transaction(fn ->
               insert(SandboxRepo, 2)
               SandboxRepo.rollback(:inner)
             end)

    assert {:ok, _} = SandboxRepo.transaction(fn -> insert(SandboxRepo, 3) end)

    assert SandboxRepo.all(from r in Row, select: r.id, order_by: r.id) == [1, 3]
    assert committed_ids() == []

    :ok = Sandbox.checkin(SandboxRepo)
    assert committed_ids() == []
  end

  test "sandbox checkout/checkin leaves no data, connection autocommits afterwards" do
    for _ <- 1..3 do
      :ok = Sandbox.checkout(SandboxRepo)
      insert(SandboxRepo, 1)
      SandboxRepo.transaction(fn -> insert(SandboxRepo, 2) end)
      :ok = Sandbox.checkin(SandboxRepo)
      assert committed_ids() == []
    end

    Sandbox.unboxed_run(SandboxRepo, fn -> insert(SandboxRepo, 4) end)
    assert committed_ids() == [4]
  end

  test "autocommit: 0 in the config is kept outside transactions" do
    {:ok, pid} =
      Repo.start_link(Integration.config(name: nil, parameters: [autocommit: 0]))

    Repo.put_dynamic_repo(pid)

    try do
      Repo.transaction(fn -> insert(Repo, 1) end)
      assert committed_ids() == [1]

      insert(Repo, 2)
      assert committed_ids() == [1]
      Repo.query!("COMMIT")
      assert committed_ids() == [1, 2]
    after
      Repo.put_dynamic_repo(Repo)
      Supervisor.stop(pid)
    end
  end
end
