# The stateful property tests (`mix prop`), GPL-3.0 (LICENSE.md). See README.md for
# what belongs here and how to write one.
#
# PROPCHECK_NUMTESTS raises or lowers the number of cases every property runs, such
# as 1000 before a release or 20 while writing a model.
ExUnit.start(exclude: [:slow])
