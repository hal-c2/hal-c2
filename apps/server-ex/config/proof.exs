import Config

# The Maude proofs (proof/) read the MC's modules as the unit tests compile them.
import_config "test.exs"

# The Maude binary: MAUDE_PATH, else where `mix proof` installs it.
config :ex_maude,
  maude_path: System.get_env("MAUDE_PATH") || Path.expand("../_build/maude/maude", __DIR__)
