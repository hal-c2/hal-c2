# Used by "mix format"
[
  import_deps: [:plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,prop}/**/*.{ex,exs}"],
  # PropCheck's macros (prop/ only, so not an `import_deps`: it is absent outside MIX_ENV=prop).
  locals_without_parens: [
    property: 1,
    property: 2,
    property: 3,
    forall: 2,
    forall_targeted: 2,
    exists: 2,
    let: 2,
    let_shrink: 2,
    such_that: 2,
    such_that_maybe: 2,
    lazy: 1,
    sized: 2,
    trap_exit: 1,
    timeout: 2,
    when_fail: 2,
    collect: 2,
    collect: 3,
    aggregate: 2,
    aggregate: 3,
    measure: 3,
    classify: 3,
    equals: 2,
    defcommand: 1
  ]
]
