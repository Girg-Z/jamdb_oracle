defmodule Jamdb.Oracle.Integration do
  @moduledoc false
  # Real database tests are tagged :oracle and excluded by default.
  # Run them with `mix test --include oracle`; the connection is taken from
  # JAMDB_ORACLE_TEST_{HOST,PORT,USER,PASSWORD,DATABASE} and defaults to the
  # local Oracle Free container (system/JamdbTest1@127.0.0.1:1521/FREEPDB1).

  def config(extra \\ []) do
    [
      hostname: System.get_env("JAMDB_ORACLE_TEST_HOST", "127.0.0.1"),
      port: String.to_integer(System.get_env("JAMDB_ORACLE_TEST_PORT", "1521")),
      username: System.get_env("JAMDB_ORACLE_TEST_USER", "system"),
      password: System.get_env("JAMDB_ORACLE_TEST_PASSWORD", "JamdbTest1"),
      database: System.get_env("JAMDB_ORACLE_TEST_DATABASE", "FREEPDB1"),
      pool_size: 1,
      log: false
    ]
    |> Keyword.merge(extra)
  end

  def drop_table(repo, table) do
    repo.query!(
      "BEGIN EXECUTE IMMEDIATE 'DROP TABLE #{table}'; " <>
        "EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;"
    )
  end
end

defmodule Jamdb.Oracle.Integration.Repo do
  use Ecto.Repo, otp_app: :jamdb_oracle, adapter: Ecto.Adapters.Jamdb.Oracle
end
