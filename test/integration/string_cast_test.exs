defmodule Jamdb.Oracle.Integration.StringCastTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  import Ecto.Query

  alias Jamdb.Oracle.Integration
  alias Jamdb.Oracle.Integration.Repo

  setup_all do
    start_supervised!({Repo, Integration.config()})
    :ok
  end

  @long String.duplicate("x", 3000)

  test "type/2 to :string keeps values longer than 2000 characters" do
    query = from d in fragment("SELECT 1 x FROM dual"), select: type(^@long, :string)

    assert Repo.all(query) == [@long]
  end

  test "type/2 to :string converts numbers and dates" do
    query =
      from d in fragment("SELECT 42 n, 1.5 f FROM dual"),
        select: {type(d.n, :string), type(d.f, :string)}

    assert Repo.all(query) == [{"42", "1.5"}]
  end

  test "values/2 keeps string values longer than 2000 characters" do
    query =
      from v in values([%{s: @long}, %{s: "short"}], %{s: :string}),
        order_by: v.s,
        select: v.s

    assert Repo.all(query) == ["short", @long]
  end
end
