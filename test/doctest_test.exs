defmodule Sig.DoctestTest do
  use ExUnit.Case, async: true

  doctest Sig.Flow
  doctest Sig.Node
  doctest Sig.NodeContext
  doctest Sig.Serializer
end
