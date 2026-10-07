# License of the property tests

Everything in this directory (`apps/server-ex/prop/`) is licensed under the GNU General
Public License, version 3 or later (see [COPYING](COPYING)), because it uses
[PropCheck](https://hex.pm/packages/propcheck) and [PropEr](https://proper-testing.github.io/),
which are GPL-3.0.

The rest of HAL-C2, the MC included, stays under the repository's MIT license
([LICENSE](../../../LICENSE)). Nothing outside this directory may depend on it: PropCheck is a
dependency of the `:prop` Mix environment only, so it is never compiled into `mix test`, a
development MC, or a release.
