# ID-indexed JSON Patch specification

## Definition

ID-indexed JSON Patch is [RFC 6902 JSON Patch](https://www.rfc-editor.org/rfc/rfc6902)
over JSON documents whose selected collections have been converted to objects
keyed by stable IDs. It introduces no new operation syntax or version.

## Document preparation

The integration defines which collections to index and which field identifies
each entry. Both documents must use the same rules. Require unique, non-null
IDs and a defined conversion to string keys; reject collisions.

```json
[{ "id": "u42", "name": "Ada" }]
```

becomes:

```json
{ "u42": { "id": "u42", "name": "Ada" } }
```

Indexing discards collection order. Only selected collections are indexed;
remaining arrays keep their order and numeric indices. JSON values and types
are otherwise preserved unless the integration explicitly defines normalization.

The patch transforms the **prepared baseline** into the **prepared candidate**.
It does not directly patch the original array representation or restore
information discarded during preparation.

## Generation preference

Prefer explicit paths to the changed fields, even when that produces more
operations. Two edits at `/users/u42/profile/name` and
`/users/u42/profile/enabled` are easier to review than replacing all of
`/users/u42/profile` with a large object containing unchanged fields.

Recurse into existing objects and keep unrelated fields out of the patch.
Retain the full path on each operation so it identifies its target independently.
Do not combine field edits into a parent replacement merely to reduce operation
count. This is a readability preference within JSON Patch, not a syntax change.

Add or remove a whole entry when the entry itself appears or disappears; do
not expand it into artificial field operations. Arrays still need correct
sequential edits. Readability takes priority over the fewest operations, while
every patch must reconstruct the prepared candidate exactly.

## Patch structure

The document is a JSON array of operations. Each operation has `op` and `path`.

| `op`                     | Other required fields |
| ------------------------ | --------------------- |
| `add`, `replace`, `test` | `value`               |
| `remove`                 | None                  |
| `move`, `copy`           | `from`                |

All operation semantics follow RFC 6902. Operations execute sequentially;
each sees the result of preceding operations. Preserve their order. Equivalent
patches may contain different operation sequences.

`[]` means the prepared documents compare equal. The patch contains no source
labels, indexing policy, or old-value metadata. The integration supplies those
separately. Whitespace and object-member ordering are not part of the contract.

## Paths

`path` and `from` are [RFC 6901 JSON Pointers](https://www.rfc-editor.org/rfc/rfc6901).

| Pointer           | Meaning                               |
| ----------------- | ------------------------------------- |
| `""`              | Entire document                       |
| `/`               | Empty key at the root                 |
| `/users/u42/name` | User `u42`'s name                     |
| `/users/42/name`  | ID `42` when `users` is an object     |
| `/tags/0`         | First element when `tags` is an array |
| `/users/a~1b~0c`  | Literal ID `a/b~c`                    |

Decode `~1` to `/`, then `~0` to `~`. JSON string escaping also applies.
The parent value determines whether a numeric token is an object key or an
array index. The `-` token supports appending to an array through `add`.
