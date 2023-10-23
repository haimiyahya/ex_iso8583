defmodule IsoFieldTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Integer



  property "extract_field - bcd header - track 2" do

    data_type = :z
    max_length = 37
    pos = 35
    accum = %{}

    check all header_size <- positive_integer(),
      field_val <- StreamData.string(Enum.concat([?0..?9, ?A..?F]))
                    |> StreamData.filter(fn x -> String.length(x) > 0 && String.length(x) <= max_length end)
    do

      header_val =
        field_val
          |> String.length()
          |> Integer.to_string()
          |> String.pad_leading(header_size + rem(header_size, 2), "0")
          |> Base.decode16!()

      size_after_padding = String.length(field_val) + rem(String.length(field_val), 2)

      body_val =
        field_val
          |> String.pad_trailing(size_after_padding, "0")
          |> Base.decode16!()

      iso_msg = header_val <> body_val

      format = {header_size, data_type, max_length}
      {%{^pos => fpos}, _trail} = IsoField.extract_field({pos, format}, {accum, iso_msg}, :bcd)

      assert(fpos == field_val)

    end
  end

  property "extract_field - bcd header - ascii body" do

    data_type = :ascii
    max_length = 999
    pos = 60
    accum = %{}

    check all header_size <- positive_integer(),
              field_val <- string(:ascii) |> StreamData.filter(fn x -> String.length(x) > 0 && String.length(x) <= max_length end)do
      header_val =
        field_val
          |> String.length()
          |> Integer.to_string()
          |> String.pad_leading(header_size + rem(header_size, 2), "0")
          |> Base.decode16!()


      body_val =
        field_val

      iso_msg = header_val <> body_val

      format = {header_size, data_type, max_length}
      {%{^pos => fpos}, _trail} = IsoField.extract_field({pos, format}, {accum, iso_msg}, :bcd)

      assert(fpos == field_val)

    end
  end

  property "extract_field - bcd header - bcd body" do

    data_type = :bcd
    max_length = 999
    pos = 42
    accum = %{}

    check all header_size <- positive_integer(),
              field_val <- StreamData.string([?0..?9]) |> StreamData.filter(fn x -> String.length(x) > 0 && String.length(x) <= max_length end)do
      header_val =
        field_val
          |> String.length()
          |> Integer.to_string()
          |> String.pad_leading(header_size + rem(header_size, 2), "0")
          |> Base.decode16!()

      size_after_padding = String.length(field_val) + rem(String.length(field_val), 2)

      body_val =
        field_val
          |> String.pad_trailing(size_after_padding, "0")
          |> Base.decode16!()

      iso_msg = header_val <> body_val

      format = {header_size, data_type, max_length}
      {%{^pos => fpos}, _trail} = IsoField.extract_field({pos, format}, {accum, iso_msg}, :bcd)

      assert(fpos == field_val)

    end
  end

end
