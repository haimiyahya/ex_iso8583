defmodule MsgTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
    52 => "b 64",
    53 => "n 16",
    54 => "an ...120",
    55 => "b ...7992",
    56 => "ans ...999",
    57 => "ans ...999",
    58 => "ans ...999",
    59 => "ans ...999",
    60 => "ans ...999",
    61 => "ans ...999",
    62 => "ans ...999",
    63 => "ans ...999",
    64 => "b 64",
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

  @data_element_format_ascii %{
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
    28 => "ans 8",
    29 => "ans 8",
    30 => "ans 9",
    31 => "ans 8",
    32 => "n ..11",
    33 => "n ..11",
    34 => "ns ..28",
    35 => "z ..37",
    36 => "n ...104",
    37 => "an 12",
    38 => "an 6",
    39 => "an 2",
    40 => "an 3",
    41 => "ans 16",
    42 => "ans 15",
    43 => "ans 40",
    44 => "an ..25",
    45 => "an ..76",
    46 => "an ...999",
    47 => "an ...999",
    48 => "ans ...999",
    49 => "n 3",
    50 => "a or n 3",
    51 => "a or n 3",
    52 => "b 16",
    53 => "n 16",
    54 => "an ...120",
    55 => "ans ...999b",
    56 => "ans ...999",
    57 => "ans ...999",
    58 => "ans ...999",
    59 => "ans ...999",
    60 => "ans 19",
    61 => "ans 22",
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
    128 => "ans 16"
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
      |> Map.put(64, Base.decode16!("2487F2488859065A"))

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

  end

  test "form a sale message" do
    sale_txn_sample = %{
      3 => "000000",
      4 => "000000000500",
      11 => "000120",
      22 => "261",
      23 => "000",
      24 => "550",
      25 => "00",
      35 => "1111111111111111D300522300000011034000",
      41 => "50472359",
      42 => "501100377530001",
      52 => Base.decode16!("38382957384F8146"),
      55 =>
        Base.decode16!(
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        ),
      62 => "000165",
      64 => Base.decode16!("6E674BA362DEA886")
    }

    config = [bitmap_type: :binary, field_header_type: :bcd]
    raw_msg = Ex_Iso8583.form_iso_msg(sale_txn_sample, config, @data_element_format_bcd)

    #assert iso_data == Ex_Iso8583.extract_iso_msg(raw_msg, config, @data_element_format_bcd)
  end

  test "parse an ascii txn" do
    ascii_txn_sample = <<66, 50, 51,
    56, 67, 54, 50, 53, 50, 56, 69, 49, 57, 50, 49, 56, 48, 48, 48, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 48, 48, 48, 57, 48, 48, 48, 48, 48, 48, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 53, 48, 48, 48, 51, 50, 56, 49, 48, 52, 54, 53, 54,
    48, 48, 48, 48, 54, 51, 49, 48, 52, 54, 53, 54, 48, 51, 50, 56, 48, 51, 50,
    56, 55, 51, 57, 57, 50, 54, 49, 48, 48, 48, 54, 68, 48, 48, 48, 48, 48, 48,
    48, 48, 49, 49, 48, 48, 48, 48, 48, 49, 48, 48, 48, 48, 48, 51, 55, 53, 52,
    54, 51, 52, 49, 48, 48, 48, 52, 53, 50, 49, 53, 51, 51, 68, 51, 48, 48, 53,
    50, 50, 51, 48, 48, 48, 48, 48, 48, 49, 49, 48, 51, 52, 48, 48, 54, 55, 51,
    51, 52, 52, 53, 52, 49, 48, 51, 56, 49, 50, 51, 52, 53, 54, 55, 56, 32, 32,
    32, 32, 32, 32, 32, 32, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49,
    49, 49, 48, 48, 48, 49, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
    32, 32, 32, 32, 32, 75, 85, 65, 76, 65, 32, 76, 85, 77, 80, 85, 82, 32, 75,
    85, 65, 77, 89, 48, 50, 55, 67, 65, 82, 68, 32, 80, 65, 89, 32, 83, 68, 78,
    32, 66, 72, 68, 32, 32, 32, 55, 51, 57, 57, 53, 55, 48, 48, 52, 53, 56, 70,
    70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 49, 52, 57, 5,
    147, 95, 42, 2, 4, 88, 130, 2, 24, 0, 132, 7, 160, 0, 0, 5, 65, 0, 2, 149, 5,
    128, 0, 4, 128, 0, 154, 3, 32, 9, 34, 156, 1, 0, 159, 2, 6, 0, 0, 0, 0, 5, 0,
    159, 3, 6, 0, 0, 0, 0, 0, 0, 159, 16, 32, 15, 165, 5, 162, 1, 193, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 159, 26, 2,
    4, 88, 159, 38, 8, 196, 122, 32, 50, 162, 241, 112, 160, 159, 39, 1, 128, 159,
    52, 3, 2, 3, 0, 159, 54, 2, 0, 118, 159, 55, 4, 91, 24, 28, 244, 159, 119, 2,
    1, 0, 155, 2, 104, 0, 159, 66, 2, 7, 2, 159, 68, 1, 2, 95, 40, 2, 7, 2, 48,
    49, 54, 48, 48, 48, 49, 80, 82, 79, 50, 43, 48, 48, 48, 48, 48, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 49, 57, 80, 82, 79, 50, 48, 32, 32, 32, 32, 32, 32,
    32, 32, 48, 49, 50, 80, 32, 66, 73, 67, 73, 66, 50, 52, 32, 49, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48>>

    ascii_txn_sample = <<66, 50, 51,
    56, 67, 54, 50, 53, 50, 56, 69, 49, 57, 50, 49, 56, 48, 48, 48, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 48, 48, 48, 57, 48, 48, 48, 48, 48, 48, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 53, 48, 48, 48, 51, 50, 56, 49, 50, 52, 53, 48, 48,
    48, 48, 48, 48, 54, 55, 49, 50, 52, 53, 48, 48, 48, 51, 50, 56, 48, 51, 50,
    56, 55, 51, 57, 57, 50, 54, 49, 48, 48, 48, 54, 68, 48, 48, 48, 48, 48, 48,
    48, 48, 49, 49, 48, 48, 48, 48, 48, 49, 48, 48, 48, 48, 48, 51, 55, 53, 52,
    54, 51, 52, 49, 48, 48, 48, 52, 53, 50, 49, 53, 51, 51, 68, 51, 48, 48, 53,
    50, 50, 51, 48, 48, 48, 48, 48, 48, 49, 49, 48, 51, 52, 48, 48, 52, 55, 51,
    49, 52, 51, 51, 53, 48, 50, 55, 48, 49, 50, 51, 52, 53, 54, 55, 56, 32, 32,
    32, 32, 32, 32, 32, 32, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49,
    49, 49, 48, 48, 48, 49, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
    32, 32, 32, 32, 32, 75, 85, 65, 76, 65, 32, 76, 85, 77, 80, 85, 82, 32, 75,
    85, 65, 77, 89, 48, 50, 55, 67, 65, 82, 68, 32, 80, 65, 89, 32, 83, 68, 78,
    32, 66, 72, 68, 32, 32, 32, 55, 51, 57, 57, 53, 55, 48, 48, 52, 53, 56, 70,
    70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 49, 52, 57, 5,
    147, 95, 42, 2, 4, 88, 130, 2, 24, 0, 132, 7, 160, 0, 0, 5, 65, 0, 2, 149, 5,
    128, 0, 4, 128, 0, 154, 3, 32, 9, 34, 156, 1, 0, 159, 2, 6, 0, 0, 0, 0, 5, 0,
    159, 3, 6, 0, 0, 0, 0, 0, 0, 159, 16, 32, 15, 165, 5, 162, 1, 193, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 159, 26, 2,
    4, 88, 159, 38, 8, 196, 122, 32, 50, 162, 241, 112, 160, 159, 39, 1, 128, 159,
    52, 3, 2, 3, 0, 159, 54, 2, 0, 118, 159, 55, 4, 91, 24, 28, 244, 159, 119, 2,
    1, 0, 155, 2, 104, 0, 159, 66, 2, 7, 2, 159, 68, 1, 2, 95, 40, 2, 7, 2, 48,
    49, 54, 48, 48, 48, 49, 80, 82, 79, 50, 43, 48, 48, 48, 48, 48, 48, 48, 48,
    49, 57, 67, 73, 77, 66, 80, 82, 79, 50, 48, 48, 48, 32, 32, 32, 32, 32, 32,
    32, 32, 48, 49, 50, 80, 32, 66, 73, 67, 73, 66, 50, 52, 32, 49, 48, 48, 48,
    48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48>>

    config = [bitmap_type: :ascii, field_header_type: :ascii]

    raw_msg = Ex_Iso8583.extract_iso_msg(ascii_txn_sample, config, @data_element_format_ascii)

  end

  test "form a message then extract it then form it again contains field 35" do
    iso_data =
      %{}
      |> Map.put(3, "920000")
      |> Map.put(11, "000085")
      |> Map.put(24, "501")
      |> Map.put(35, "1111111111111111D30052230000001103400")
      |> Map.put(41, "51619968")
      |> Map.put(42, "501100564190001")
      |> Map.put(55, Base.decode16!("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"))
      |> Map.put(60, "765424")
      |> Map.put(63, "123456789012345678901234567890")
      |> Map.put(64, Base.decode16!("2487F2488859065A"))

    config = [bitmap_type: :binary, field_header_type: :bcd]
    raw_msg = Ex_Iso8583.form_iso_msg(iso_data, config, @data_element_format_bcd)

    assert iso_data == Ex_Iso8583.extract_iso_msg(raw_msg, config, @data_element_format_bcd)
  end

  test "parse paynet ascii message" do

    msg = "B23AC6052EE08018000000401000000900000000000000050003280143350000540143350328032803280000261000D000000001100000100000375463410004521533D300522300000011034003821531922610000006812345678        1111111111111110000000000000000000001                  4580160001PRO2+0000000000000019PRO20        0200382153192261032801433500032800000000001100000000000012P BICIB24 100000000000000000"

    config = [bitmap_type: :ascii, field_header_type: :ascii]

    raw_msg = Ex_Iso8583.extract_iso_msg(msg, config, @data_element_format_ascii)


  end

end
