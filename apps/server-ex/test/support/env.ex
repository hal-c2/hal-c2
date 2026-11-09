defmodule HalC2.Test.Env do
  @moduledoc """
  Application and OS settings a test changes, put back as they were when it ends
  (an unset one stays unset), so a test leaves nothing for the tests after it.
  Call these from a test or its `setup`; the restore is the test's `on_exit`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "`Application.put_env(:hal_c2, key, value)` for the rest of the test."
  def put_app(key, value) do
    prior = Application.fetch_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:hal_c2, key, value)
        :error -> Application.delete_env(:hal_c2, key)
      end
    end)
  end

  @doc "`System.put_env(name, value)` for the rest of the test."
  def put_system(name, value) do
    prior = System.fetch_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      case prior do
        {:ok, value} -> System.put_env(name, value)
        :error -> System.delete_env(name)
      end
    end)
  end
end
