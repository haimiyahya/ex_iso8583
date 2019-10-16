defmodule FormAlphanumericHeaderTypeFieldTest do
  use ExUnit.Case
  doctest Ex_Iso8583
  alias Ex_Iso8583

  test "for fixed size numeric - form_field with one element where message type is ascii encoded" do
    # fixed size numeric

    formatted_field =
      Ex_Iso8583.form_field(
        {7, {0, :bcd, 10}},
        "0113235933",
        :ascii
      )

    assert formatted_field == "0113235933"
  end

  test "for fixed size alphanumeric - form_field with one element where message type is ascii encoded" do
    # fixed size alphanumeric

    formatted_field =
      Ex_Iso8583.form_field(
        {41, {0, :ascii, 8}},
        "12345678",
        :ascii
      )

    assert formatted_field == "12345678"
  end

  test "for non-fixed size numeric 2 digit header - form_field with one element where message type is ascii encoded" do
    # non fixed size numeric 2 digit header

    formatted_field =
      Ex_Iso8583.form_field(
        {99, {2, :ascii, 11}},
        "12345678901",
        :ascii
      )

    assert formatted_field == "1112345678901"
  end
end
