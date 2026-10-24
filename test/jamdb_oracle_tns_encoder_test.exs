defmodule Jamdb.OracleTnsEncoderTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp :oraclient,
    Record.extract(:oraclient, from: "include/jamdb_oracle.hrl")
  Record.defrecordp :format,
    Record.extract(:format, from: "include/jamdb_oracle.hrl")

  @raw 23
  @long_raw 24

  defp oac_type(value) do
    <<type, _rest::binary>> = :jamdb_oracle_tns_encoder.encode_token(:oac, value, format(charset: 871))
    type
  end

  defp exec(type, binds) do
    record =
      oraclient(type: type, auto: 1, charset: 871, fetch: 10, seq: 1,
        req: {0, ~c"SELECT 1 FROM dual", binds, [], []})

    :jamdb_oracle_tns_encoder.encode_record(:exec, record)
  end

  # Encoded row data (TTI_RXD + values) for the given rows, in the given order.
  defp rxd(rows), do: :jamdb_oracle_tns_encoder.encode_token(:rxd, rows, <<>>)

  test "binary binds up to 4000 bytes are RAW, larger ones LONG RAW" do
    assert oac_type(<<1>>) == @raw
    assert oac_type(:binary.copy(<<1>>, 4000)) == @raw
    assert oac_type(:binary.copy(<<1>>, 4001)) == @long_raw
  end

  test "values of long binds go after the other values of a SQL row" do
    long = :binary.copy(<<1>>, 5000)
    data = exec(:change, [long, 42, ~c"abc"])

    assert String.ends_with?(data, rxd([[42, ~c"abc", long]]))
  end

  test "rows without long binds keep their order" do
    raw = :crypto.strong_rand_bytes(32)
    data = exec(:select, [raw, 42])

    assert String.ends_with?(data, rxd([[raw, 42]]))
  end

  test "PL/SQL blocks keep long binds in place" do
    long = :binary.copy(<<1>>, 5000)
    data = exec(:block, [long, 42])

    assert String.ends_with?(data, rxd([[long, 42]]))
  end

  test "batch rows are reordered like the first row" do
    long = :binary.copy(<<1>>, 5000)
    record =
      oraclient(type: :change, auto: 1, charset: 871, fetch: 10, seq: 1,
        req: {0, ~c"INSERT INTO t VALUES (:1, :2)", [long, 1], [[long, 2]], []})

    data = :jamdb_oracle_tns_encoder.encode_record(:exec, record)

    assert String.ends_with?(data, rxd([[1, long], [2, long]]))
  end
end
