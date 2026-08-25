defmodule Jamdb.OracleBinaryTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  defmodule BinarySchema do
    use Ecto.Schema

    schema "binary_records" do
      field :payload, :binary
    end
  end

  test "preserves Ecto binary type while dumping and encoding binds" do
    value = <<0, 255, 71, 71>>

    assert {:ok, tagged = %Ecto.Query.Tagged{value: ^value, type: :binary}} =
             Ecto.Type.adapter_dump(Jamdb.Oracle, :binary, value)

    query = %Jamdb.Oracle.Query{statement: "SELECT :1 FROM dual"}

    assert DBConnection.Query.encode(query, [tagged], []) == [value]
  end

  test "keeps nil binary binds as nil" do
    assert Ecto.Type.adapter_dump(Jamdb.Oracle, :binary, nil) == {:ok, nil}
  end

  test "preserves binary type in Ecto query binds" do
    value = <<0, 255, 71, 71>>
    query = from(record in BinarySchema, where: record.payload == ^value, select: record.id)

    {planned, _cast_params, dump_params} =
      Ecto.Adapter.Queryable.plan_query(:all, Jamdb.Oracle, query)

    assert [%Ecto.Query.Tagged{value: ^value, type: :binary}] = dump_params
    assert IO.iodata_to_binary(Jamdb.Oracle.Query.all(planned)) ==
             "SELECT b0.id FROM binary_records b0 WHERE (b0.payload = :1)"

    driver_query = %Jamdb.Oracle.Query{statement: "SELECT :1 FROM dual"}
    assert DBConnection.Query.encode(driver_query, dump_params, []) == [value]
  end
end
