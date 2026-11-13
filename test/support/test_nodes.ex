defmodule Sig.TestNodes do
  defmodule AddNumbers do
    use Sig.Node

    @impl true
    def run(context) do
      a = context.params[:a] || context.params["a"] || 0
      b = context.params[:b] || context.params["b"] || 0
      {:ok, %{"sum" => a + b}}
    end
  end

  defmodule MultiplyBy do
    use Sig.Node

    @impl true
    def run(context) do
      sum =
        Enum.find_value(context.results, 0, fn {_k, v} ->
          if is_map(v), do: v["sum"]
        end)

      factor = context.params[:factor] || context.params["factor"] || 1
      {:ok, %{"total" => sum * factor}}
    end
  end

  defmodule FormatOutput do
    # Arity 2 definition: run(params, context)
    def run(params, context) do
      prefix = params[:prefix] || params["prefix"] || "Result:"
      total = get_in(context.results, ["multiply", "total"]) || 0
      user = context.context[:user] || context.context["user"] || "anonymous"
      {:ok, %{"output" => "#{prefix} #{total} for #{user}"}}
    end
  end

  defmodule FlakyNode do
    use Sig.Node

    @impl true
    def run(context) do
      attempt = context.attempt

      if attempt < 2 do
        {:error, "temporary network glitch"}
      else
        {:ok, %{"status" => "recovered_on_attempt_#{attempt}"}}
      end
    end
  end

  defmodule AlwaysFailingNode do
    use Sig.Node

    @impl true
    def run(_context) do
      {:error, "permanent failure"}
    end
  end

  defmodule CountingNode do
    use Sig.Node

    def start_counter do
      Agent.start_link(fn -> 0 end, name: __MODULE__)
    end

    def get_count do
      Agent.get(__MODULE__, & &1)
    end

    @impl true
    def run(_context) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, &(&1 + 1))
      end

      {:ok, %{"done" => true}}
    end
  end
end
