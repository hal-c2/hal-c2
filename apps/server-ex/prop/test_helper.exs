# The stateful property tests (`mix prop`), GPL-3.0 (LICENSE.md). See README.md for
# what belongs here and how to write one.
#
# PROPCHECK_NUMTESTS raises or lowers the number of cases every property runs, such
# as 1000 before a release or 20 while writing a model.
HalC2.Test.StopSignal.fail_run()

ExUnit.start(exclude: [:slow])

# Keep the MC's git include, if we run inside one, out of the tests.
HalC2.Test.GitEnv.scrub()

# Before anything starts distribution: reaches the MCs a test names as members do
# (`HalC2.Prop.Epmd`), and every other node as `:erl_epmd` does.
Application.put_env(:kernel, :epmd_module, HalC2.Prop.Epmd)

# Scratch homes sit in `tmp` inside the checkout; git must not find the checkout from them.
System.put_env("GIT_CEILING_DIRECTORIES", Path.expand("../tmp", __DIR__))
