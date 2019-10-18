defmodule ISOMsg do
  defstruct config: %{ascii_format: false, ascii_bitmap: true, tpdu_length: 10},
            tpdu: "",
            mti: "",
            data: %{}
end
