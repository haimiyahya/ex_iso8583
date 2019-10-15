defmodule MsgTest do
  use ExUnit.Case, async: true

  test "form a message then extract it then form it again" do
    iso_data =
      %{}
      |> Map.put(3, "920000")
      |> Map.put(11, "000085")
      |> Map.put(24, "501")
      |> Map.put(41, "51619968")
      |> Map.put(42, "501100564190001")
      |> Map.put(60, "765424")
      |> Map.put(63, "123456789012345678901234567890")
      |> Map.put(64, "2487F2488859065A")

    config = [bitmap_type: :binary, field_header_type: :bcd]
    raw_msg = Ex_Iso8583.form_iso_msg(iso_data, config)

    assert iso_data == Ex_Iso8583.extract_iso_msg(raw_msg, config)
  end
end
