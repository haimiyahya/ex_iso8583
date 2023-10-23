defmodule Track2Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  test "extract incomplete track 2" do
    format = {2, :z, 37}
    accum = %{}
    iso_msg = "7897139012628084D2312" # fail case
    #iso_msg = "7897139012628084D2312000000000000000" # success case
    iso_msg = iso_msg <> "0"
    len_ = String.length(iso_msg)

    iso_msg = String.slice(iso_msg, 0, len_ - rem(len_, 2)) # make even length so it wont crash during conversion from hex to binary

    IO.inspect iso_msg

    size = String.length(iso_msg)
    sa = rem(size, 10)
    puluh = rem(size, 100) - sa |> div(10)

    IO.inspect "puluh: #{puluh}"
    IO.inspect "sa: #{sa}"

    iso_msg = <<puluh::4, sa::4>> <> Base.decode16!(iso_msg)

    IO.inspect iso_msg

    IO.inspect String.length(iso_msg)
    value = IsoField.extract_field({35, format}, {accum, iso_msg}, :bcd)
    IO.inspect value
  end


  test "form incomplete track 2" do
    format = {2, :z, 37}
    accum = %{}
    field_value = "7897139012628084D2312" # fail case

    value = IsoField.form_field({35, format}, field_value, :bcd)
    IO.inspect Base.encode16 value
  end


end
