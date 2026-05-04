# mochi_codegen

Code generation (TypeScript types, GraphQL SDL, Gleam types + resolver stubs)
and CLI for [mochi](https://github.com/qwexvf/mochi) GraphQL.

## Installation

```sh
gleam add mochi_codegen
```

## CLI

```sh
gleam run -m mochi_codegen/cli -- init       # create mochi.config.yaml
gleam run -m mochi_codegen/cli -- generate   # generate from config
```

## Config (`mochi.config.yaml`)

```yaml
schema: "graphql/*.graphql"

# Optional: generate resolver boilerplate from .gql client operation files
operations_input: "src/graphql/**/*.gql"

output:
  typescript: "src/generated/types.ts"   # TypeScript type definitions
  gleam_types: "src/api/domain/"         # Gleam domain types (dir = one file per schema)
  resolvers: "src/api/schema/"           # Gleam resolver stubs (preserved on regen)
  operations: "src/api/schema/"          # Gleam operation resolvers (from .gql files)
  sdl: null                              # Normalised SDL (omit to skip)

gleam:
  types_module_prefix: "api/domain"
  resolvers_module_prefix: "api/schema"
  type_suffix: "_types"
  resolver_suffix: "_resolvers"
  generate_docs: true
```

Output paths ending in `/` produce one file per schema file. Paths without `/` merge all schemas into a single file.

### Write policies

| Output | Policy |
|--------|--------|
| `typescript`, `sdl` | Always overwrite |
| `gleam_types` | Overwrite only when content changed |
| `resolvers`, `operations` | Never overwrite existing functions — only appends new stubs |

### Validation and error surfaces

- **Unknown operation fields fail the build.** If an `operations_input` `.gql` file references a root field that doesn't exist in the schema, `generate` exits with `UnknownOperationFields` listing the offending fields. The emitted Gleam (if you force generation some other way) contains a `<MISSING:field_name>` sentinel rather than a generic `TODO`, so it's greppable.
- **Argument defaults round-trip in SDL.** Scalar defaults (`Bool`, `Int`, `Float`, `String`) are rendered in `sdl` output. Complex defaults (lists, objects, enums) are omitted rather than emitted as broken syntax — `mochi/schema` stores them as type-erased `Option(Dynamic)` which isn't reversible for non-scalars.
- **TypeScript enum values are identifier-checked.** Values that don't match `[_A-Za-z][_0-9A-Za-z]*` (which GraphQL itself forbids, but custom schema builders can bypass) are replaced with a `// Skipped: ...` comment rather than a broken `enum` member. Grep the output for `// Skipped:` to find them.
- **Playground endpoints are escaped.** `graphiql`, `playground`, `apollo_sandbox`, and `simple_explorer` all escape the endpoint URL before interpolating it into inline JS / HTML. Callers can pass any string without worrying about breaking the generated page.
- **Unmapped type-builder fields surface in the CLI output.** Resolver generation emits `// TODO: register field "<name>"` for types the generator can't map (uncommon custom scalars, unsupported non-null list shapes). The CLI success line is decorated with the count — e.g. `Generated resolvers (3 unmapped fields — see TODO comments): src/generated/schema_resolvers.gleam` — so these don't silently accumulate across regenerations.

## Programmatic Usage

```gleam
import mochi_codegen

let ts   = mochi_codegen.to_typescript(schema)
let sdl  = mochi_codegen.to_sdl(schema)
let html = mochi_codegen.graphiql("/graphql")
```

## License

Apache-2.0

