defmodule JamdbOracleTnsDecoderTest do
  use ExUnit.Case, async: true

  @tti_rxh 6
  @tti_rxd 7
  @tti_rpa 8
  @tti_status 9

  # SELECT ... FOR UPDATE responses repeat the row header before every row.
  test "row headers between rows keep the rows already decoded" do
    row_format = [{:format, "ID", :in, 2, 22, -127, 0}]
    # flag, num requests, iter num, num iters, buffer length, bit vector, rxhrid
    row_header = <<@tti_rxh, 0, 0, 0, 0, 0, 0, 0>>
    row = fn number -> <<@tti_rxd, 2, 193, number + 1>> end

    data = <<row_header::binary, row.(1)::binary, row_header::binary, row.(2)::binary,
             row_header::binary, row.(3)::binary, @tti_status>>

    assert {:ok, {0, ^row_format, [0], [[{1.0}], [{2.0}], [{3.0}]]}} =
             :jamdb_oracle_tns_decoder.decode_two_task(data, {0, row_format, []})
  end

  test "return parameters skip chunked keyword values" do
    data = return_parameters(<<0>>, chunked_field())
    assert_decoded(data)
  end

  test "return parameters skip chunked keywords" do
    data = return_parameters(chunked_field(), <<0>>)
    assert_decoded(data)
  end

  defp chunked_field do
    first_chunk = :binary.copy(<<0xAA>>, 64)
    encoded_value = <<254, 64, first_chunk::binary, 1, 0xBB, 0>>
    <<1, 65, encoded_value::binary>>
  end

  defp return_parameters(keyword, value) do
    <<
      @tti_rpa,
      # no array parameters
      0,
      # no text value
      0,
      # one keyword/value pair
      1,
      1,
      keyword::binary,
      value::binary,
      # keyword number
      0,
      # no registration info
      0,
      @tti_status
    >>
  end

  defp assert_decoded(data) do
    accumulator = {0, [], []}

    assert {:ok, ^accumulator} = :jamdb_oracle_tns_decoder.decode_two_task(data, accumulator)
  end
end
