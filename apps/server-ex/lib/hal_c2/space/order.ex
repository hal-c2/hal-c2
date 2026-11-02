defmodule HalC2.Space.Order do
  @moduledoc """
  Order keys for a page's blocks: strings that sort as plain binaries, so a block
  inserted or moved takes a key between its neighbours' and no other block changes.

  Keys use the digits `0-9a-z` and never end in `0`, which leaves room between any
  two of them; repeated inserts at one place make keys a digit longer at a time.
  """

  @digits ~c"0123456789abcdefghijklmnopqrstuvwxyz"
  @base length(@digits)

  @doc """
  A key after `low` and before `high`; `nil` stands for the start or the end.
  `low` must sort before `high`.
  """
  @spec between(String.t() | nil, String.t() | nil) :: String.t()
  def between(low, high),
    do: low |> Kernel.||("") |> digits() |> mid(high && digits(high)) |> key()

  # The midpoint of two digit lists, `low` read as padded with zeros and a nil
  # `high` as no bound (see "Implementing Fractional Indexing", David Greenspan).
  defp mid(low, high) when is_list(high) do
    case common_prefix(low, high) do
      [] -> mid_first(low, high)
      prefix -> prefix ++ mid(Enum.drop(low, length(prefix)), Enum.drop(high, length(prefix)))
    end
  end

  defp mid(low, nil), do: mid_first(low, nil)

  defp mid_first(low, high) do
    lo = List.first(low, 0)
    hi = if high, do: hd(high), else: @base

    cond do
      hi - lo > 1 -> [div(lo + hi, 2)]
      # `high` is longer: its first digit alone sorts between the two.
      high != nil and length(high) > 1 -> [hi]
      true -> [lo | mid(Enum.drop(low, 1), nil)]
    end
  end

  defp common_prefix(low, high) do
    high
    |> Enum.with_index()
    |> Enum.take_while(fn {digit, index} -> Enum.at(low, index, 0) == digit end)
    |> Enum.map(&elem(&1, 0))
  end

  defp digits(key), do: for(<<char <- key>>, do: Enum.find_index(@digits, &(&1 == char)))
  defp key(digits), do: List.to_string(Enum.map(digits, &Enum.at(@digits, &1)))
end
