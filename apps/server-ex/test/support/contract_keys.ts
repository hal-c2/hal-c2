// Prints the rpc contract of `packages/contracts/src/rpc.ts` as JSON:
// `results` maps each method to the keys its encoded success must carry (a list
// for a struct, "null" for a void result, the AST tag otherwise) and `errors` to
// the `_tag`s of its error union. Usage: bun contract_keys.ts
import { WsRpcGroup } from "../../../../packages/contracts/src/rpc.ts";

// effect resolves from the contracts package, so the schemas and helpers match.
const contracts = new URL("../../../../packages/contracts/src/", import.meta.url).pathname;
const SchemaAST = await import(Bun.resolveSync("effect/SchemaAST", contracts));
const Schema = await import(Bun.resolveSync("effect/Schema", contracts));

const keys = (ast: any): unknown => {
  if (ast._tag === "Suspend") return keys(ast.thunk());
  if (ast._tag === "Objects")
    return ast.propertySignatures
      .filter((p: any) => !(p.type.context?.isOptional ?? false))
      .map((p: any) => String(p.name));
  if (ast._tag === "Void" || ast._tag === "Undefined" || ast._tag === "Null") return "null";
  return ast._tag;
};

const tags = (ast: any): string[] => {
  if (ast._tag === "Suspend") return tags(ast.thunk());
  if (ast._tag === "Union") return ast.types.flatMap(tags);
  const sentinel = ast.annotations?.["~sentinels"]?.find((s: any) => s.key === "_tag");
  if (sentinel) return [String(sentinel.literal)];
  const tag = ast.propertySignatures?.find((p: any) => p.name === "_tag")?.type.literal;
  return tag === undefined ? [] : [String(tag)];
};

const results: Record<string, unknown> = {};
const errors: Record<string, string[]> = {};
for (const [method, rpc] of WsRpcGroup.requests as Map<string, any>) {
  results[method] = keys(SchemaAST.toEncoded(Schema.toCodecJson(rpc.successSchema).ast));
  errors[method] = tags(rpc.errorSchema.ast);
}
console.log(JSON.stringify({ results, errors }));
