defmodule ExtractAlphanumericHeaderTypeFieldTest do
  use ExUnit.Case
  doctest IsoField
  alias IsoField

  test "for fixed size numeric - extract_field with one element where message type is ascii encoded" do
    # fixed size numeric
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {7, {0, :bcd, 10}},
        {acc_result, Base.decode16!("30313133323335393333")},
        :ascii
      )

    assert acc_result == {%{7 => "0113235933"}, ""}
  end

  test "for fixed size alphanumeric - extract_field with one element where message type is ascii encoded" do
    # fixed size alphanumeric
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {41, {0, :ascii, 8}},
        {acc_result, Base.decode16!("3132333435363738")},
        :ascii
      )

    assert acc_result == {%{41 => "12345678"}, ""}
  end

  test "for non-fixed size numeric 2 digit header - extract_field with one element where message type is ascii encoded" do
    # non fixed size numeric 2 digit header
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {99, {2, :ascii, 11}},
        {acc_result, Base.decode16!("31313132333435363738393031")},
        :ascii
      )

    assert acc_result == {%{99 => "12345678901"}, ""}
  end

  test "for non-fixed size numeric 3 digit header - extract_field with one element where message type is ascii encoded" do
    # non fixed size numeric 3 digit header
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {46, {3, :ascii, 999}},
        {acc_result, Base.decode16!("3031313132333435363738393031")},
        :ascii
      )

    assert acc_result == {%{46 => "12345678901"}, ""}
  end

  test "for non-fixed size numeric 2 digit header - extract_field with one element where message type is ascii encoded with truncation" do
    # non fixed size numeric 2 digit header with truncation
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {99, {2, :bcd, 11}},
        {acc_result, Base.decode16!("3132313233343536373839303132")},
        :ascii
      )

    assert acc_result == {%{99 => "12345678901"}, ""}
  end

  test "for non-fixed size alphanumeric 2 digit header - extract_field with one element where message type is ascii encoded with truncation" do
    # non fixed size alphanumeric 2 digit header with truncation
    acc_result = %{}

    acc_result =
      IsoField.extract_field(
        {101, {2, :ascii, 17}},
        {acc_result, Base.decode16!("3138313233343536373839303132333435363738")},
        :ascii
      )

    assert acc_result == {%{101 => "12345678901234567"}, ""}
  end
end
