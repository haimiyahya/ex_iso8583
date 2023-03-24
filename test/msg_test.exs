defmodule MsgTest do
  use ExUnit.Case, async: true

  @data_element_format_bcd %{
    1 => "b 64",
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    5 => "n 12",
    6 => "n 12",
    7 => "n 10",
    8 => "n 8",
    9 => "n 8",
    10 => "n 8",
    11 => "n 6",
    12 => "n 6",
    13 => "n 4",
    14 => "n 4",
    15 => "n 4",
    16 => "n 4",
    17 => "n 4",
    18 => "n 4",
    19 => "n 3",
    20 => "n 3",
    21 => "n 3",
    22 => "n 3",
    23 => "n 3",
    24 => "n 3",
    25 => "n 2",
    26 => "n 2",
    27 => "n 1",
    28 => "x+n 8",
    29 => "x+n 8",
    30 => "x+n 8",
    31 => "x+n 8",
    32 => "n ..11",
    33 => "n ..11",
    34 => "ns ..28",
    35 => "z ..37",
    36 => "n ...104",
    37 => "an 12",
    38 => "an 6",
    39 => "an 2",
    40 => "an 3",
    41 => "ans 8",
    42 => "ans 15",
    43 => "ans 40",
    44 => "an ..25",
    45 => "an ..76",
    46 => "an ...999",
    47 => "an ...999",
    48 => "an ...999",
    49 => "a or n 3",
    50 => "a or n 3",
    51 => "a or n 3",
    52 => "b 8",
    53 => "n 16",
    54 => "an ...120",
    55 => "ans ...999b",
    56 => "ans ...999",
    57 => "ans ...999",
    58 => "ans ...999",
    59 => "ans ...999",
    60 => "ans ...999",
    61 => "ans ...999",
    62 => "ans ...999",
    63 => "ans ...999",
    64 => "b 16",
    65 => "b 1",
    66 => "n 1",
    67 => "n 2",
    68 => "n 3",
    69 => "n 3",
    70 => "an 3",
    71 => "n 4",
    72 => "n 4",
    73 => "n 6",
    74 => "n 10",
    75 => "n 10",
    76 => "n 10",
    77 => "n 10",
    78 => "n 10",
    79 => "n 10",
    80 => "n 10",
    81 => "n 10",
    82 => "n 12",
    83 => "n 12",
    84 => "n 12",
    85 => "n 12",
    86 => "n 16",
    87 => "n 16",
    88 => "n 16",
    89 => "n 16",
    90 => "n 42",
    91 => "an 1",
    92 => "an 2",
    93 => "an 5",
    94 => "an 7",
    95 => "an 42",
    96 => "b 64",
    97 => "x+n 16",
    98 => "ans 25",
    99 => "n ..11",
    100 => "n ..11",
    101 => "ans ..17",
    102 => "ans ..28",
    103 => "ans ..28",
    104 => "ans ...100",
    105 => "ans ...999",
    106 => "ans ...999",
    107 => "ans ...999",
    108 => "ans ...999",
    109 => "ans ...999",
    110 => "ans ...999",
    111 => "ans ...999",
    112 => "ans ...999",
    113 => "ans ...999",
    114 => "ans ...999",
    115 => "ans ...999",
    116 => "ans ...999",
    117 => "ans ...999",
    118 => "ans ...999",
    119 => "ans ...999",
    120 => "ans ...999",
    121 => "ans ...999",
    122 => "ans ...999",
    123 => "ans ...999",
    124 => "ans ...999",
    125 => "ans ...999",
    126 => "ans ...999",
    127 => "ans ...999",
    128 => "b 64"
  }

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
    raw_msg = Ex_Iso8583.form_iso_msg(iso_data, config, @data_element_format_bcd)

    assert iso_data == Ex_Iso8583.extract_iso_msg(raw_msg, config, @data_element_format_bcd)
  end

  test "form a message with ascii bmp" do
    msg = %{
      7 => "0323160024",
      11 => "000451",
      70 => "301"
    }

    header_config = [bitmap_type: :ascii, field_header_type: :ascii]

    txn_bytes = Ex_Iso8583.form_iso_msg(msg, header_config, @data_element_format_bcd)

    raw_message = "ISO025000077" <> "0800" <> txn_bytes
    msg_size = byte_size(raw_message)

    IO.inspect(raw_message, limit: :infinity)
  end
end
