defmodule FormBcdHeaderTypeTest do
  use ExUnit.Case
  doctest IsoField
  alias IsoField

  test "data is bcd" do
    formatted_field =
      IsoField.form_field(
        {7, {2, :bcd, 19}},
        "1234567890123456",
        :ascii
      )

    assert formatted_field == "161234567890123456"
  end

  test "data is ascii" do
    formatted_field =
      IsoField.form_field(
        {7, {2, :ascii, 21}},
        "12345678901234567",
        :ascii
      )

    assert formatted_field == "1712345678901234567"
  end

end
